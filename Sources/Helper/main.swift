import Foundation
import Security
import Darwin

let kHelperVersion = kSharedHelperVersion

private let kClientRequirement = "identifier \"com.clashhalo.app\""

/// Validate that an incoming XPC peer is the ClashHalo app.
/// Three layers, each more permissive than the last, to handle all signing variants:
///   1. Security framework: identifier check with basic-validate-only flags
///   2. SecCodeCopyPath: bundle-root URL check (must be inside the .app bundle)
///   3. proc_pidpath: raw executable path check (must be inside .app/Contents/MacOS/)
func isAuthorizedClient(_ conn: NSXPCConnection) -> Bool {
    let pid = conn.processIdentifier
    guard pid > 0 else { return false }

    // Layer 1: Security framework requirement check.
    // kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources (== kSecCSBasicValidateOnly)
    // skips hash and seal verification — only the code-signing metadata (identifier) is
    // checked. This handles developer-signed and most ad-hoc builds.
    var code: SecCode?
    let attrs = [kSecGuestAttributePid: pid] as CFDictionary
    if SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code {
        var req: SecRequirement?
        if SecRequirementCreateWithString(kClientRequirement as CFString, [], &req) == errSecSuccess,
           let req {
            let flags = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
            if SecCodeCheckValidity(code, flags, req) == errSecSuccess { return true }
        }

        // Layer 2: bundle-root URL from SecStaticCode (SecCodeCopyPath returns the .app bundle root)
        var staticCode: SecStaticCode?
        if SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
           let sc = staticCode {
            var pathURL: CFURL?
            if SecCodeCopyPath(sc, SecCSFlags(rawValue: 0), &pathURL) == errSecSuccess,
               let path = (pathURL as URL?)?.path {
                if isClashAppBundlePath(path) {
                    log("isAuthorizedClient: SecCode-path fallback accepted pid \(pid): \(path)")
                    return true
                }
            }
        }
    }

    // Layer 3: proc_pidpath — returns the actual executable path regardless of signing.
    // Most reliable for ad-hoc builds where Security framework may reject the code object.
    var pathBuf = [Int8](repeating: 0, count: 4096)
    if proc_pidpath(pid, &pathBuf, 4096) > 0 {
        let path = String(cString: pathBuf)
        if isClashExecutablePath(path) {
            log("isAuthorizedClient: proc_pidpath fallback accepted pid \(pid): \(path)")
            return true
        }
    }

    log("isAuthorizedClient: REJECTED pid \(pid)")
    return false
}

/// True only for a genuine ClashHalo app bundle root path, not any
/// path that merely contains the substring (prevents a rogue app at e.g.
/// /tmp/clashhalo-evil/x from impersonating the client).
private func isClashAppBundlePath(_ path: String) -> Bool {
    let p = path.lowercased()
    return p.hasSuffix("/clashhalo.app") || p.hasSuffix("/clashpow.app")
}

/// True only for an executable inside ClashHalo.app/Contents/MacOS/.
/// Requires the full bundle-internal structure, not a substring match.
private func isClashExecutablePath(_ path: String) -> Bool {
    let p = path.lowercased()
    return p.contains("/clashhalo.app/contents/macos/") ||
           p.contains("/clashpow.app/contents/macos/")
}

/// Only permit launching a binary at the canonical ClashHalo kernel path.
func isAllowedKernelPath(_ path: String) -> Bool {
    let std = (path as NSString).standardizingPath
    guard !std.contains(".."),
          (std.hasSuffix("/Library/Application Support/ClashHalo/bin/mihomo") ||
           std.hasSuffix("/Library/Application Support/ClashPow/bin/mihomo")) else { return false }
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: std, isDirectory: &isDir), !isDir.boolValue else { return false }
    if let type = (try? fm.attributesOfItem(atPath: std))?[.type] as? FileAttributeType,
       type == .typeSymbolicLink { return false }
    return true
}

func log(_ msg: String) {
    let logDir = "/Library/Logs/ClashHalo"
    let logFile = "\(logDir)/helper.log"
    let line = "[\(Date())] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    let fm = FileManager.default
    try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logDir)
    if !fm.fileExists(atPath: logFile) { fm.createFile(atPath: logFile, contents: nil) }
    if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logFile)) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(data)
    }
}

class Helper: NSObject, HelperProtocol {
    /// Shared across all XPC connection instances — NSXPCListener creates a new
    /// Helper() per connection, so an instance var would always be nil on stop.
    private static var mihomoProcess: Process?
    /// Guards concurrent access to mihomoProcess from parallel XPC connections.
    private static let processLock = NSLock()

    /// Which system-level mutations this helper performed for the current
    /// client session. Client-death cleanup is gated on these so a session
    /// that never enabled anything cannot clobber user DNS / proxy / kernels,
    /// and so the cleanup fires the right subset (v1.0.20).
    fileprivate static var stateMihomoStarted = false
    fileprivate static var stateProxyOn = false
    fileprivate static var stateGatewayOn = false
    /// Mixed-port of the last proxy this helper wrote (0 = forgotten, e.g.
    /// after a helper restart). Client-death cleanup uses it to scope the
    /// reality check to OUR proxy: the unscoped any-loopback match would also
    /// wipe a co-resident proxy app's settings when only our client died.
    fileprivate static var stateLastProxyPort = 0
    fileprivate static let stateLock = NSLock()

    fileprivate static func setState(_ apply: (inout Bool, inout Bool, inout Bool) -> Void) {
        stateLock.lock(); defer { stateLock.unlock() }
        apply(&stateMihomoStarted, &stateProxyOn, &stateGatewayOn)
    }

    /// Arm the client-death watchdog for the connection currently being served.
    /// Called from every state-mutating XPC method — the PID that turned
    /// something on is the one whose death must trigger cleanup.
    fileprivate static func armWatchForCurrentClient() {
        if let pid = NSXPCConnection.current()?.processIdentifier, pid > 0 {
            HelperDelegate.armClientWatch(pid: pid)
        }
    }

    func getVersion(withReply reply: @escaping (String) -> Void) {
        log("getVersion called")
        reply(kHelperVersion)
    }

    func setSystemProxy(enabled: Bool, port: Int, withReply reply: @escaping (Bool) -> Void) {
        log("setSystemProxy(enabled: \(enabled), port: \(port))")
        let ok = ProxyManager.setSystemProxy(enabled: enabled, port: port)
        // Track intent even on partial failure: some services may have been
        // configured before an error, so a later cleanup disable is the safe state.
        Self.setState { _, proxyOn, _ in proxyOn = enabled }
        Self.stateLock.lock()
        Self.stateLastProxyPort = port
        Self.stateLock.unlock()
        if enabled { Self.armWatchForCurrentClient() }
        reply(ok)
    }

    func startMihomo(binPath: String, homeDir: String, withReply reply: @escaping (Bool) -> Void) {
        log("startMihomo(binPath: \(binPath), homeDir: \(homeDir))")
        guard isAllowedKernelPath(binPath) else {
            log("startMihomo REJECTED: binPath not in allowlist: \(binPath)")
            reply(false); return
        }

        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        // Terminate any tracked process first. Poll instead of a fixed sleep —
        // the common restart case (process already exited via REST shutdown)
        // must not pay a latency penalty.
        if let existing = Self.mihomoProcess, existing.isRunning {
            existing.terminate()
            let deadline = Date().addingTimeInterval(0.5)
            while existing.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if existing.isRunning { kill(existing.processIdentifier, SIGKILL) }
        }
        Self.mihomoProcess = nil

        // Kill ALL mihomo processes (handles untracked processes from previous
        // helper instances or session remnants that would block the port).
        // killall exits 0 only when it actually signalled something — only then
        // wait (briefly, polled) for the process table to clear so ports/utun
        // are released. A clean start pays no fixed delay.
        let killAll = Process()
        killAll.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killAll.arguments = ["-9", "mihomo"]
        killAll.standardOutput = Pipe(); killAll.standardError = Pipe()
        try? killAll.run(); killAll.waitUntilExit()
        if killAll.terminationStatus == 0 {
            let deadline = Date().addingTimeInterval(0.3)
            while Date() < deadline {
                let check = Process()
                check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                check.arguments = ["-x", "mihomo"]
                check.standardOutput = Pipe(); check.standardError = Pipe()
                guard (try? check.run()) != nil else { break }
                check.waitUntilExit()
                if check.terminationStatus == 1 { break }   // no match — table clear
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binPath)
        process.arguments = ["-d", homeDir]
        var env = ProcessInfo.processInfo.environment
        env["GOGC"] = "50"
        env["GODEBUG"] = "madvdontneed=1"
        process.environment = env

        let logDir = "/Library/Logs/ClashHalo"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let logFile = "\(logDir)/mihomo-root.log"
        FileManager.default.createFile(atPath: logFile, contents: nil)
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logFile)) {
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
            Self.mihomoProcess = process
            Self.setState { mihomo, _, _ in mihomo = true }
            Self.armWatchForCurrentClient()
            log("startMihomo: started pid \(process.processIdentifier)")
            reply(true)
        } catch {
            log("startMihomo: failed to start: \(error)")
            reply(false)
        }
    }

    static func stopMihomoInternal() {
        log("stopMihomoInternal called")
        setState { mihomo, _, _ in mihomo = false }
        processLock.lock()
        defer { processLock.unlock() }
        if let process = mihomoProcess, process.isRunning {
            process.terminate()
            // Wait up to 0.6s for graceful exit, then SIGKILL.
            // Keep this short: GUI callStopMihomo has a 4s hard timeout; long
            // sleeps here used to make kernel-switch feel frozen.
            let deadline = Date().addingTimeInterval(0.6)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                log("stopMihomoInternal: SIGTERM timeout, sending SIGKILL to pid \(process.processIdentifier)")
                kill(process.processIdentifier, SIGKILL)
            }
            mihomoProcess = nil
        }
        // killall as final safety net (catches processes not owned by this instance)
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        t.arguments = ["-9", "mihomo"]
        t.standardOutput = Pipe(); t.standardError = Pipe()
        try? t.run(); t.waitUntilExit()
    }

    func stopMihomo(withReply reply: @escaping (Bool) -> Void) {
        log("stopMihomo called")
        // Never block the XPC reply path longer than necessary — run stop work
        // and reply as soon as killall returns. GUI side also has a hard timeout.
        DispatchQueue.global(qos: .userInitiated).async {
            Self.stopMihomoInternal()
            reply(true)
        }
    }

    func setGatewayMode(enabled: Bool, withReply reply: @escaping (Bool) -> Void) {
        let value = enabled ? "1" : "0"
        let keys = [
            "net.inet.ip.forwarding",
            "net.inet6.ip6.forwarding"
        ]
        var ok = true

        for key in keys {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
            process.arguments = ["-w", "\(key)=\(value)"]
            let err = Pipe()
            process.standardError = err
            process.standardOutput = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let data = err.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    log("setGatewayMode: \(key)=\(value) failed status \(process.terminationStatus) \(msg)")
                    ok = false
                }
            } catch {
                log("setGatewayMode: \(key)=\(value) failed: \(error)")
                ok = false
            }
        }

        log("setGatewayMode: \(enabled) -> \(ok ? "success" : "failed")")
        Self.setState { _, _, gateway in gateway = enabled }
        if enabled { Self.armWatchForCurrentClient() }
        reply(ok)
    }

    // MARK: - Exclude routes
    //
    // These prefixes belong to *other* tunnels (Tailscale, ZeroTier, a corporate
    // VPN). The caller discovers them by reading the route table — which means
    // the overwhelming majority of them are routes their owner installed and
    // still manages. That is the hazard this code exists to respect:
    //
    //   A route we did not create is never ours to delete.
    //
    // The previous implementation kept `addedRoutes = <everything the caller
    // asked for>` regardless of whether `route add` had actually created
    // anything, and teardown deleted that whole set. Since the caller harvests
    // the peer's own routes, teardown deleted the peer's own routes: observed in
    // the field as Tailscale subnet routes (10.1.1.0/24, 192.168.3.0/24)
    // vanishing for good — tailscaled only reprograms on a netmap change, so
    // nothing ever put them back, and the next scan could no longer even see the
    // prefixes it had destroyed.
    //
    // Now: install only what is genuinely missing, record only what `route add`
    // actually created, and before deleting re-verify the route still points
    // where we put it. In the common case (peer routes already present) this is
    // a no-op — which is the correct amount of work to do.

    /// Routes this helper created itself, `dest -> iface`. Never populated from
    /// the caller's wish list.
    ///
    /// Persisted, because the helper restarts on every app upgrade and an
    /// in-memory record does not survive it. That is not hypothetical: a
    /// diagnosed machine had `10.1.1.0/24` (its own LAN), `224.0.0.0/4` and
    /// `255.255.255.255/32` installed pointing at a Tailscale utun, the helper
    /// upgraded 22 minutes later, and the record went with it — leaving orphans
    /// that nothing could attribute and nothing ever withdrew. `reclaimOrphans`
    /// covers what was already lost; this keeps it from recurring.
    private static var addedRoutes: [String: String] = {
        (NSDictionary(contentsOfFile: addedRoutesPath) as? [String: String]) ?? [:]
    }()

    private static let addedRoutesPath = "/Library/Application Support/ClashHalo/added-routes.plist"

    /// Mirror `addedRoutes` to disk. Best-effort: a failed write costs the same
    /// orphan risk as the previous in-memory-only behaviour, never worse.
    private static func persistAddedRoutes() {
        let dir = (addedRoutesPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        (addedRoutes as NSDictionary).write(toFile: addedRoutesPath, atomically: true)
    }

    fileprivate static let routesLock = NSLock()

    /// The interface carrying exactly `dest`, nil when nothing routes that
    /// prefix. See `RouteTable` (shared with the app) for why "exactly" is the
    /// whole point.
    private static func routeInterface(exactly dest: String) -> String? {
        RouteTable.interface(exactly: dest)
    }

    /// Run `/sbin/route` with `args`, returning true on exit status 0.
    private static func runRoute(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/route")
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            log("route \(args.joined(separator: " ")): exec failed: \(error)")
            return false
        }
    }

    private static func routeArgs(_ verb: String, dest: String, iface: String) -> [String] {
        let isHost = !dest.contains("/") || dest.hasSuffix("/32")
        let destClean = dest.replacingOccurrences(of: "/32", with: "")
        return isHost
            ? ["-n", verb, "-host", destClean, "-interface", iface]
            : ["-n", verb, "-net", dest, "-interface", iface]
    }

    /// Withdraw every route this helper installed. Each one is re-verified
    /// first: if it no longer points where we put it, its owner has taken it
    /// over and deleting would destroy their route, not ours.
    fileprivate static func cleanupAllExcludeRoutesInternal() {
        // Orphans first: a prefix that must never point at a tunnel is wrong
        // whether or not we still hold the record that put it there.
        _ = reclaimOrphanedPeerRoutes()
        let ours = addedRoutes
        addedRoutes.removeAll()
        persistAddedRoutes()
        for (dest, iface) in ours {
            guard routeInterface(exactly: dest) == iface else {
                log("cleanupAllExcludeRoutes: \(dest) 已不指向 \(iface)，跳过删除（归属已变）")
                continue
            }
            if !runRoute(routeArgs("delete", dest: dest, iface: iface)) {
                log("cleanupAllExcludeRoutes: route delete \(dest) -> \(iface) 失败")
            }
        }
    }

    /// Delete interface routes into a tunnel for prefixes that may never live
    /// there — link-only ranges and this machine's own attached subnets.
    ///
    /// This is repair, not bookkeeping: it runs against the route table itself,
    /// so it also catches entries whose provenance record was lost in a helper
    /// restart. Two conditions keep it from touching anything that is not ours:
    /// the route must be *unscoped* (a peer's own routes for these prefixes are
    /// interface-scoped and legitimate — deleting those is precisely the damage
    /// v1.1.9 fixed), and its Gateway column must repeat the interface name,
    /// the shape only `route add -interface` produces. A peer's own entries name
    /// their link (`link#32`) and are left alone.
    private static func reclaimOrphanedPeerRoutes() -> Int {
        let owners = PeerRouteGuard.localSubnetOwners()
        let localSubnets = Array(owners.keys)
        var removed = 0
        for entry in RouteTable.current()
        where entry.interface.hasPrefix("utun")
            && entry.interface != kPinnedTunDevice
            && !entry.isScoped
            && entry.isInterfaceRoute
            && PeerRouteGuard.isForbidden(entry.cidr, localSubnets: localSubnets) {
            guard runRoute(routeArgs("delete", dest: entry.cidr, iface: entry.interface)) else {
                log("reclaimOrphanedPeerRoutes: 撤回 \(entry.cidr) -> \(entry.interface) 失败")
                continue
            }
            log("reclaimOrphanedPeerRoutes: 已撤回 \(entry.cidr) -> \(entry.interface)（该前缀不得指向隧道）")
            addedRoutes.removeValue(forKey: entry.cidr)
            removed += 1

            // Deleting is only half the repair. The tunnel route *replaced* the
            // NIC's own subnet route (observed: en0 held 10.1.1.20/24 while the
            // table's only 10.1.1.0/24 entry pointed at a utun), so withdrawing
            // it without checking can leave the LAN with no route at all — a
            // worse outcome than the hijack. Put the prefix back on the interface
            // that is actually attached to it, and only if nothing else picked it
            // up in the meantime.
            if let owner = owners[entry.cidr], RouteTable.interface(exactly: entry.cidr) == nil {
                if runRoute(routeArgs("add", dest: entry.cidr, iface: owner)) {
                    log("reclaimOrphanedPeerRoutes: 已将 \(entry.cidr) 归还直连网卡 \(owner)")
                } else {
                    log("reclaimOrphanedPeerRoutes: 归还 \(entry.cidr) -> \(owner) 失败，请检查网络")
                }
            }
        }
        return removed
    }

    func setupExcludeRoutes(_ routes: [String: String], withReply reply: @escaping (Bool) -> Void) {
        Self.routesLock.lock()
        defer { Self.routesLock.unlock() }

        var installed = 0, present = 0, failed = 0, refused = 0
        var stillOurs = [String: String]()

        // Repair first: whatever the caller wants, prefixes that must never point
        // at a tunnel get taken back — including orphans from a previous process.
        let reclaimed = Self.reclaimOrphanedPeerRoutes()

        // The caller applies the same rule (see `Coexistence.routesByInterface`);
        // enforcing it again here is what makes it true of the system rather than
        // of one code path. An older GUI talking to this helper cannot reintroduce
        // the LAN hijack.
        let localSubnets = PeerRouteGuard.localAttachedSubnets()
        let routes = routes.filter { dest, _ in
            guard PeerRouteGuard.isForbidden(dest, localSubnets: localSubnets) else { return true }
            log("setupExcludeRoutes: 拒绝 \(dest) — 链路专用或本机直连网段，不得指向隧道")
            refused += 1
            return false
        }

        // Withdraw only entries we created that are no longer wanted.
        for (dest, iface) in Self.addedRoutes where routes[dest] != iface {
            if Self.routeInterface(exactly: dest) == iface {
                _ = Self.runRoute(Self.routeArgs("delete", dest: dest, iface: iface))
            }
        }

        for (dest, iface) in routes {
            if let current = Self.routeInterface(exactly: dest) {
                if current == iface {
                    // The peer installed it and still owns it. Nothing to do —
                    // and nothing to record, or teardown would delete theirs.
                    present += 1
                    // Carry a prior self-install forward so we can still withdraw it.
                    if Self.addedRoutes[dest] == iface { stillOurs[dest] = iface }
                    continue
                }
                if current != kPinnedTunDevice {
                    // Someone else's route. Whatever it is doing, it is not ours
                    // to override — that judgement is what destroyed peer routes.
                    log("setupExcludeRoutes: \(dest) 由 \(current) 承载（期望 \(iface)），非本应用所有，保持不动")
                    present += 1
                    continue
                }
                // Our own TUN grabbed the peer's prefix — auto-route beat the
                // exclusion. This one *is* ours to correct: take it back, and
                // record it so teardown returns it rather than leaving our
                // override behind.
                log("setupExcludeRoutes: \(dest) 被本应用 TUN(\(current)) 抢占，改回 \(iface)")
                _ = Self.runRoute(Self.routeArgs("delete", dest: dest, iface: current))
                if Self.runRoute(Self.routeArgs("add", dest: dest, iface: iface)) {
                    stillOurs[dest] = iface
                    installed += 1
                } else {
                    log("setupExcludeRoutes: 夺回 \(dest) -> \(iface) 失败")
                    failed += 1
                }
                continue
            }
            if Self.runRoute(Self.routeArgs("add", dest: dest, iface: iface)) {
                stillOurs[dest] = iface
                installed += 1
            } else {
                log("setupExcludeRoutes: route add \(dest) -> \(iface) 失败")
                failed += 1
            }
        }

        Self.addedRoutes = stillOurs
        Self.persistAddedRoutes()
        log("setupExcludeRoutes: 请求 \(routes.count) 条 — 新建 \(installed)、已存在保持不动 \(present)、失败 \(failed)、拒绝 \(refused)、回收孤儿 \(reclaimed)；自有记账 \(stillOurs.count) 条")
        Self.armWatchForCurrentClient()
        reply(failed == 0)
    }

    func cleanupAllExcludeRoutes(withReply reply: @escaping (Bool) -> Void) {
        log("cleanupAllExcludeRoutes called")
        Self.routesLock.lock()
        Self.cleanupAllExcludeRoutesInternal()
        Self.routesLock.unlock()
        reply(true)
    }

    func cleanupTUNResidual(withReply reply: @escaping (Bool) -> Void) {
        log("cleanupTUNResidual called")
        // Route-table mutations share the lock with setupExcludeRoutes /
        // cleanupAllExcludeRoutes so we never delete routes while another call
        // is injecting them. ifconfig down/IP-delete themselves are sequential
        // underneath; the GUI gates this on hasDownedMihomoTun so it only runs
        // when a mihomo utun residue actually exists.
        Self.routesLock.lock()
        let ok = ProxyManager.cleanupTUNResidual()
        Self.routesLock.unlock()
        reply(ok)
    }
}

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    /// Tracks active connections per client PID. Cleanup only fires when a
    /// client's LAST connection closes AND the process is confirmed gone —
    /// this prevents short-lived one-shot connections (setGatewayMode,
    /// verifyConnectivity) from triggering false cleanup while the app is
    /// still running with other active connections.
    private static var activeConnections: [Int32: Int] = [:]
    private static let connLock = NSLock()

    // MARK: Client process watchdog (v1.0.20)
    //
    // The connection-invalidation cleanup below only fires when a connection
    // happens to be open at client-death time. The GUI talks to this helper
    // almost exclusively over throwaway connections that live ~50ms per call,
    // so a force-quit usually happened with ZERO open connections — the helper
    // never noticed, and root mihomo / system proxy / tunnel DNS leaked until
    // the network broke. A kqueue NOTE_EXIT source on the client PID fires on
    // ANY death (force quit included), independent of connection state. Armed
    // by every state-mutating call; cleanup itself is state-gated.
    private static var clientWatch: DispatchSourceProcess?
    private static var watchedPid: Int32 = 0
    /// Most recent accepted connection (any pid) — takeover signal: a fresh
    /// live client after the watched pid died means a relaunched app now owns
    /// the kernel/proxy state, so death-cleanup must stand down.
    private static var lastSeenClient: (pid: Int32, at: Date) = (0, .distantPast)

    static func armClientWatch(pid: Int32) {
        connLock.lock(); defer { connLock.unlock() }
        if watchedPid == pid, clientWatch != nil { return }
        clientWatch?.cancel()
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                   queue: DispatchQueue.global())
        src.setEventHandler {
            log("clientWatch: watched pid \(pid) exited")
            // Same grace the invalidation path uses: give an immediate relaunch
            // (app update / crash-restart) time to reconnect and take over.
            // Ownership/once-only checks live inside handleClientExit so both
            // entry points are guarded identically.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                HelperDelegate.handleClientExit(pid: pid)
            }
        }
        src.setCancelHandler { }
        src.resume()
        watchedPid = pid
        clientWatch = src
        log("armClientWatch: watching pid \(pid)")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        log("New connection attempt from pid: \(newConnection.processIdentifier)")
        guard isAuthorizedClient(newConnection) else {
            log("REJECTED unauthorized connection from pid \(newConnection.processIdentifier)")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = Helper()

        let clientPid = newConnection.processIdentifier

        // Increment active connection count for this client
        Self.connLock.lock()
        Self.activeConnections[clientPid, default: 0] += 1
        Self.lastSeenClient = (clientPid, Date())
        Self.connLock.unlock()

        // Arm the death watchdog for ANY authenticated client, not just after a
        // state-mutating call (v1.0.21). If the helper restarts mid-session (its
        // own upgrade), the previously-armed watch is gone with the old process;
        // without re-arming here, a later force-quit would go entirely unnoticed
        // and leak proxy/DNS/root-kernel. Safe to arm broadly because
        // handleClientExit is reality-gated and no-ops when nothing needs undoing.
        //
        // Re-arming rides on whatever the GUI does next. Its status poll dropped
        // from 5 s to 60 s in v1.1.10 (it was costing ~17k signature validations a
        // day and observing nothing), so the unwatched window after a helper
        // restart is now up to a minute rather than five seconds. That window is
        // the helper's own upgrade, which the GUI drives and immediately follows
        // with privileged calls — each of which arms this too.
        Self.armClientWatch(pid: clientPid)

        newConnection.invalidationHandler = {
            log("Connection invalidated from pid \(clientPid)")

            // Decrement; only proceed to cleanup check if this was the last connection
            Self.connLock.lock()
            let remaining = (Self.activeConnections[clientPid] ?? 1) - 1
            if remaining <= 0 {
                Self.activeConnections[clientPid] = nil
            } else {
                Self.activeConnections[clientPid] = remaining
            }
            Self.connLock.unlock()

            guard remaining <= 0 else {
                log("pid \(clientPid) still has \(remaining) active connection(s). Skipping cleanup check.")
                return
            }

            // Last connection closed — wait and re-verify the process is actually gone.
            // 2s grace handles the gap between one-shot connection teardown and a
            // potential immediately-following new connection from the same client.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                // Re-check: a new connection may have opened during the grace window
                Self.connLock.lock()
                let reopened = (Self.activeConnections[clientPid] ?? 0) > 0
                Self.connLock.unlock()
                guard !reopened else {
                    log("pid \(clientPid) reopened a connection during grace. Skipping cleanup.")
                    return
                }
                // kill(pid, 0) sends a null signal to detect process existence.
                // Since helper runs as root, EPERM will not be returned if process exists,
                // so any non-zero return means the process is gone (ESRCH).
                if kill(clientPid, 0) != 0 {
                    log("Client process with pid \(clientPid) has exited. Performing cleanup.")
                    HelperDelegate.handleClientExit(pid: clientPid)
                } else {
                    log("Client process with pid \(clientPid) is still running. Skipping cleanup.")
                }
            }
        }

        newConnection.resume()
        return true
    }

    /// Pids whose cleanup already ran. Each of a client's connections invalidates
    /// separately, so without this the teardown fired once *per connection* —
    /// observed 2–3 times per exit, and with reality-based gating every repeat
    /// re-detected the loopback proxy and disabled it again.
    private static var cleanedPids: [Int32] = []

    /// True when a newer session already owns the system state: some connection
    /// is open, or a *different* client pid was seen recently and is still alive.
    ///
    /// Both cleanup paths must consult this. Previously only the watchdog did,
    /// so the connection-invalidation path could run a dead session's teardown
    /// after the replacement app had already connected — disabling the system
    /// proxy the *live* session had just enabled (observed in helper.log:
    /// `armClientWatch: watching pid 40860` at 15:12:27, then cleanup for the
    /// dead pid 40101 disabling the proxy twice at 15:12:30/31).
    private static func newerSessionOwnsState(deadPid: Int32) -> Bool {
        connLock.lock()
        let hasActive = !activeConnections.isEmpty
        let recent = lastSeenClient
        connLock.unlock()
        if hasActive {
            log("cleanup: active connection present — newer session owns state")
            return true
        }
        if recent.pid != deadPid, recent.pid > 0,
           Date().timeIntervalSince(recent.at) < 15, kill(recent.pid, 0) == 0 {
            log("cleanup: newer live client pid \(recent.pid) seen — skip")
            return true
        }
        return false
    }

    /// Whether a root-owned `mihomo` is running. Only this helper can spawn one
    /// (root start goes exclusively through `startMihomo`), so a root-owned
    /// kernel surviving its dead client is by definition our orphan — the
    /// reality-based counterpart to the `stateMihomoStarted` session flag.
    private static func isRootMihomoRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-u", "root", "-x", "mihomo"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    fileprivate static func handleClientExit(pid: Int32) {
        // Guard 1 — once per pid. Every connection of a dying client invalidates
        // independently, so this is otherwise entered several times per exit.
        connLock.lock()
        let alreadyCleaned = cleanedPids.contains(pid)
        if !alreadyCleaned {
            cleanedPids.append(pid)
            if cleanedPids.count > 32 { cleanedPids.removeFirst(cleanedPids.count - 32) }
        }
        connLock.unlock()
        guard !alreadyCleaned else {
            log("handleClientExit for pid \(pid): already cleaned — skip")
            return
        }

        // Guard 2 — never tear down state a newer, live session owns.
        guard !newerSessionOwnsState(deadPid: pid) else {
            log("handleClientExit for pid \(pid): newer session active — skip")
            return
        }

        // Snapshot + clear session state atomically: cleanup runs at most once
        // per session (both the watchdog and the invalidation path funnel here),
        // and only reverts what this helper actually set — a session that never
        // enabled anything must not clobber user DNS / proxy / foreign kernels.
        Helper.stateLock.lock()
        let hadMihomo = Helper.stateMihomoStarted
        let hadProxy = Helper.stateProxyOn
        let hadGateway = Helper.stateGatewayOn
        Helper.stateMihomoStarted = false
        Helper.stateProxyOn = false
        Helper.stateGatewayOn = false
        Helper.stateLock.unlock()

        connLock.lock()
        clientWatch?.cancel()
        clientWatch = nil
        watchedPid = 0
        connLock.unlock()

        // Reality checks (v1.0.21). The in-memory session flags above are per
        // helper *process* — they are lost whenever the helper restarts, most
        // notably right after its own upgrade, mid-user-session. Relying on them
        // alone meant a force-quit after such a restart left a stale loopback
        // system proxy pointing at a dead kernel (total blackout) and an orphan
        // root mihomo. So each destructive step is additionally gated on an
        // observable fact that can only be true if we (or a dead local proxy)
        // caused it — never on user-owned configuration.
        Helper.stateLock.lock()
        let rememberedPort = Helper.stateLastProxyPort
        Helper.stateLock.unlock()
        // Port-scoped reality check: a loopback proxy is "ours to clear" only
        // when it points at the port we last wrote. The unscoped any-loopback
        // match would also wipe a co-resident proxy app's settings (Surge /
        // ClashX on their own port) when only OUR client died — the same
        // unasserted-ownership class as the fake-ip DNS incident. Unscoped
        // remains only as the amnesiac fallback (helper restarted, forgot the
        // port), where the anti-blackout guarantee takes priority.
        let loopbackProxyLive = ProxyManager.anyServiceProxiesToLoopback(
            port: rememberedPort > 0 ? rememberedPort : nil)
        let orphanRootKernel = isRootMihomoRunning()
        let cleanProxy = hadProxy || loopbackProxyLive
        let cleanKernel = hadMihomo || orphanRootKernel

        guard cleanKernel || cleanProxy || hadGateway else {
            log("handleClientExit for pid \(pid): no helper-owned state — nothing to clean")
            return
        }

        // Re-check takeover *after* the reality probes above: those fork
        // networksetup per service plus pgrep and take hundreds of ms — a
        // window in which a replacement app can connect. Observed live: a
        // quit+relaunch cycle lost the 2 s grace by 0.2 s (dead pid's cleanup
        // passed Guard 2 at 12:40:07.6; the relaunched app's first XPC landed
        // 12:40:07.8), and the killall safety net below then reaped the new
        // client's freshly-spawned root kernel ~2 s after it came up. Any
        // connection, or a recent *live* different client, at this point owns
        // the state the steps below would destroy — stand down entirely.
        guard !newerSessionOwnsState(deadPid: pid) else {
            log("handleClientExit for pid \(pid): newer session appeared during cleanup — stand down")
            return
        }

        log("handleClientExit for pid \(pid): cleaning (mihomo=\(hadMihomo)/orphanRoot=\(orphanRootKernel) proxy=\(hadProxy)/loopbackLive=\(loopbackProxyLive) gateway=\(hadGateway))")

        // 1. Stop mihomo process first (fast, reliable, and does not depend on system configuration locks)
        if cleanKernel {
            Helper.stopMihomoInternal()
        }

        // 1.5. Cleanup static routes (internal no-op when none were injected)
        Helper.routesLock.lock()
        Helper.cleanupAllExcludeRoutesInternal()
        Helper.routesLock.unlock()

        // 2. Disable system proxy. A loopback proxy with no kernel behind it is
        //    the blackout condition — clear it regardless of session memory.
        if cleanProxy {
            let proxyReset = ProxyManager.setSystemProxy(enabled: false, port: 7890)
            log("handleClientExit: system proxy disabled (\(proxyReset))")
        }

        // 3./4. Both of these are self-gating no-ops when there is nothing to
        //       undo (cleanupTUNResidual finds no DOWNED 198.18 utun;
        //       restoreDNSIfTunnelPinned finds no tunnel-pinned resolver), so
        //       run them unconditionally rather than behind session memory —
        //       that is exactly the state a restarted helper cannot remember.
        //       downedOnly spares healthy co-resident VPN tunnels (Shadowrocket
        //       etc.) that share the 198.18.x range.
        Thread.sleep(forTimeInterval: 0.3)   // let the kernel reap the utun first
        Helper.routesLock.lock()
        _ = ProxyManager.cleanupTUNResidual(downedOnly: true)
        Helper.routesLock.unlock()
        let dnsReset = ProxyManager.restoreDNSIfTunnelPinned()
        log("handleClientExit: tunnel-pinned DNS restored (\(dnsReset))")

        // 5. Disable IP Forwarding
        if hadGateway {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
            t.arguments = ["-w", "net.inet.ip.forwarding=0"]
            try? t.run()
            log("handleClientExit: IP forwarding disabled")
        }
    }
}

log("Helper starting up (v\(kHelperVersion))...")
let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: "com.clashhalo.helper")
listener.delegate = delegate
log("Listener resuming...")
listener.resume()
log("Helper entering main loop.")
RunLoop.main.run()
