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

    func getVersion(withReply reply: @escaping (String) -> Void) {
        log("getVersion called")
        reply(kHelperVersion)
    }

    func setSystemProxy(enabled: Bool, port: Int, withReply reply: @escaping (Bool) -> Void) {
        log("setSystemProxy(enabled: \(enabled), port: \(port))")
        let ok = ProxyManager.setSystemProxy(enabled: enabled, port: port)
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

        // Terminate any tracked process first
        if let existing = Self.mihomoProcess, existing.isRunning {
            existing.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if existing.isRunning { kill(existing.processIdentifier, SIGKILL) }
        }
        Self.mihomoProcess = nil

        // Kill ALL mihomo processes (handles untracked processes from previous
        // helper instances or session remnants that would block the port)
        let killAll = Process()
        killAll.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killAll.arguments = ["-9", "mihomo"]
        killAll.standardOutput = Pipe(); killAll.standardError = Pipe()
        try? killAll.run(); killAll.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.3)

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
            log("startMihomo: started pid \(process.processIdentifier)")
            reply(true)
        } catch {
            log("startMihomo: failed to start: \(error)")
            reply(false)
        }
    }

    static func stopMihomoInternal() {
        log("stopMihomoInternal called")
        processLock.lock()
        defer { processLock.unlock() }
        if let process = mihomoProcess, process.isRunning {
            process.terminate()
            // Wait up to 1.5s for graceful exit, then SIGKILL
            let deadline = Date().addingTimeInterval(1.5)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
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
        Self.stopMihomoInternal()
        reply(true)
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
        reply(ok)
    }

    private static var addedRoutes = [String: String]()
    fileprivate static let routesLock = NSLock()

    fileprivate static func cleanupAllExcludeRoutesInternal() {
        let routesToClean = addedRoutes
        addedRoutes.removeAll()
        
        for (dest, iface) in routesToClean {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/route")
            let isHost = !dest.contains("/") || dest.hasSuffix("/32")
            let destClean = dest.replacingOccurrences(of: "/32", with: "")
            if isHost {
                process.arguments = ["-n", "delete", "-host", destClean, "-interface", iface]
            } else {
                process.arguments = ["-n", "delete", "-net", dest, "-interface", iface]
            }
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                log("cleanupAllExcludeRoutesInternal: exec route delete failed for \(dest) -> \(iface): \(error)")
            }
        }
    }

    func setupExcludeRoutes(_ routes: [String: String], withReply reply: @escaping (Bool) -> Void) {
        log("setupExcludeRoutes called: \(routes)")
        Self.routesLock.lock()
        Self.cleanupAllExcludeRoutesInternal()
        
        Self.addedRoutes = routes
        let routesToApply = Self.addedRoutes
        Self.routesLock.unlock()
        
        var allOk = true
        for (dest, iface) in routesToApply {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/route")
            let isHost = !dest.contains("/") || dest.hasSuffix("/32")
            let destClean = dest.replacingOccurrences(of: "/32", with: "")
            if isHost {
                process.arguments = ["-n", "add", "-host", destClean, "-interface", iface]
            } else {
                process.arguments = ["-n", "add", "-net", dest, "-interface", iface]
            }
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    log("setupExcludeRoutes: route add \(dest) -> \(iface) status \(process.terminationStatus)")
                }
            } catch {
                log("setupExcludeRoutes: exec route add failed for \(dest) -> \(iface): \(error)")
                allOk = false
            }
        }
        reply(allOk)
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
        Self.connLock.unlock()

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

    private static func handleClientExit(pid: Int32) {
        log("handleClientExit for pid \(pid): restoring settings to prevent DNS/proxy leaks")
        
        // 1. Stop mihomo process first (fast, reliable, and does not depend on system configuration locks)
        Helper.stopMihomoInternal()
        
        // 1.5. Cleanup static routes
        Helper.routesLock.lock()
        Helper.cleanupAllExcludeRoutesInternal()
        Helper.routesLock.unlock()
        
        // 2. Disable system proxy
        let proxyReset = ProxyManager.setSystemProxy(enabled: false, port: 7890)
        log("handleClientExit: system proxy disabled (\(proxyReset))")
        
        // 3. Restore DNS (networksetup layer only — mihomo's utun and its
        //    Supplemental DNS resolver are auto-destroyed by the kernel when
        //    the process exits; do NOT touch utun interfaces, as other VPN
        //    apps like Shadowrocket share the same 198.18.x.x address space)
        let dnsReset = ProxyManager.restoreDNS()
        log("handleClientExit: DNS restored (\(dnsReset))")

        // 4. Disable IP Forwarding
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        t.arguments = ["-w", "net.inet.ip.forwarding=0"]
        try? t.run()
        log("handleClientExit: IP forwarding disabled")
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
