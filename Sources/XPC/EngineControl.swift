import Foundation
import Combine
import SwiftUI

@MainActor final class EngineControl: ObservableObject {
    static let shared = EngineControl()
    /// Expected version of the installed helper. When the running helper reports a
    /// different version the app auto-reinstalls it (new binary = new permissions fix).
    static let kExpectedHelperVersion = "1.0.6"
    let api = MihomoClient.shared

    @Published var present = false
    @Published var uptimeSec: Int64 = 0
    @Published var engineVersion = "?"
    @Published var helperVersion = "?"
    @Published var isRoot = false          // helper is installed
    @Published var runningAsRoot = false   // current process was started via helper
    /// A kernel-lifecycle operation (toggle TUN/engine, restart, activate) is in
    /// progress. UI entry points guard on this to prevent interleaving the long
    /// multi-await flows (e.g. TUN root-switch) with another start/stop/swap.
    @Published var isBusy = false

    /// Injected log sink (set by AppModel) — avoids referencing AppModel here.
    var onLog: ((String) -> Void)?

    private let appSupport = NSHomeDirectory() + "/Library/Application Support/ClashPow"
    /// Config file the running mihomo reads (`mihomo -d <appSupport>` → config.yaml).
    /// Used as the source of truth for controller endpoint discovery (B1).
    var configFilePath: String { appSupport + "/config.yaml" }
    private var binDir: String { appSupport + "/bin" }
    private var kernelPath: String { binDir + "/mihomo" }
    private let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.clashpow.mihomo.plist"
    private let rootPlistPath = "/Library/LaunchDaemons/com.clashpow.mihomo.plist"

    init() {
        // Poll helper status — 5s is sufficient since helper state changes are
        // rare (install/uninstall/upgrade) and verifyConnectivity creates a
        // throwaway XPC connection each cycle.
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollStatus() }
        }
    }

    func pollStatus() {
        // B3/B4: isRoot now means "helper installed AND reachable", verified by an
        // actual XPC handshake — not merely the plist existing on disk.
        Task { @MainActor in
            let active = await XPCManager.shared.verifyConnectivity()
            if isRoot != active { isRoot = active }

            // Sync runningAsRoot on app restart: if helper is active and mihomo is
            // reachable but the flag is false, check the actual process owner so the
            // UI reflects reality without requiring a TUN toggle to fix the state.
            if active && !runningAsRoot && api.reachable {
                syncRunningAsRootIfNeeded()
            }

            if active && (helperVersion == "?" || helperVersion.isEmpty) {
                if let helper = XPCManager.shared.helper() {
                    helper.getVersion { v in
                        Task { @MainActor in
                            if !v.isEmpty { self.helperVersion = v }
                        }
                    }
                }
            }
        }
    }

    /// Check via pgrep whether mihomo is owned by root and set the flag accordingly.
    /// Uses exact name match (-x) to avoid false positives from similarly named binaries.
    /// Blocks the calling thread briefly — only call from Tasks, not the main run loop.
    private func syncRunningAsRootIfNeeded() {
        guard !runningAsRoot else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-u", "root", "-x", "mihomo"]
        p.standardOutput = Pipe()
        try? p.run(); p.waitUntilExit()
        if p.terminationStatus == 0 { runningAsRoot = true }
    }

    /// Ensure the mihomo binary and configuration directory are set up.
    func ensureInstalled() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        
        // Setup initial bin if missing: prefer the bundled binary, else fall back
        // to a kernel the user already downloaded under kernels/ (B2 — avoids the
        // split where kernels/<tag>/mihomo exists but bin/mihomo stays empty).
        if !fm.fileExists(atPath: kernelPath) {
            if let bundled = Bundle.main.url(forResource: "mihomo", withExtension: nil) {
                try? fm.copyItem(at: bundled, to: URL(fileURLWithPath: kernelPath))
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kernelPath)
            } else if let fallback = installedKernelFallback() {
                try? fm.copyItem(atPath: fallback, toPath: kernelPath)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kernelPath)
            }
        }
        
        // Initial config if missing
        let configPath = appSupport + "/config.yaml"
        if !fm.fileExists(atPath: configPath) {
            let initial = """
            mixed-port: 7890
            allow-lan: true
            mode: rule
            log-level: info
            external-controller: 127.0.0.1:9092
            secret: clashpow
            dns:
              enable: true
              enhanced-mode: fake-ip
              nameserver:
                - 119.29.29.29
                - 223.5.5.5
            """
            try? initial.write(toFile: configPath, atomically: true, encoding: .utf8)
        }

        // Bundled geodata setup
        for f in ["GeoSite.dat", "geoip.metadb", "ASN.mmdb"] {
            if let g = Bundle.main.resourceURL?.appendingPathComponent(f), fm.fileExists(atPath: g.path) {
                let dst = appSupport + "/" + f
                if !fm.fileExists(atPath: dst) {
                    try? fm.copyItem(atPath: g.path, toPath: dst)
                }
            }
        }

        hardenControllerConfig()
        normalizeGeoxURL()
        forceTUNDisabled()   // TUN is runtime-only (root) — never auto-enable from disk
    }

    /// Force `tun.enable: false` in the on-disk config. TUN requires root and must
    /// only ever be turned on through `toggleTUN` (which performs the user→root
    /// kernel switch). If the persisted config carries `tun.enable: true`, a plain
    /// `ensureRunning` start — which is usually user-mode — brings TUN up without
    /// privilege: the utun device can't be created, traffic is black-holed, and the
    /// kernel is left half-dead. Editing only the `enable:` scalar inside the `tun:`
    /// block keeps the rest of the user's TUN settings (stack/dns-hijack/...) intact.
    func forceTUNDisabled() { setTunEnabled(false) }

    /// Set `tun.enable` on disk to a specific value (editing only the `enable:`
    /// scalar inside the `tun:` block). Used by `forceTUNDisabled()` at launch, and
    /// to *preserve* the current runtime TUN state across a config reload (a reload
    /// re-reads the file, so without this a reload would drop a running root TUN).
    func setTunEnabled(_ on: Bool) {
        let path = configFilePath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        var inTun = false, changed = false
        for i in lines.indices {
            let line = lines[i]
            // Top-level key (no leading whitespace) ends the previous block.
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inTun = line.hasPrefix("tun:")
                continue
            }
            guard inTun else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("enable:") {
                let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                let want = "\(indent)enable: \(on)"
                if line != want { lines[i] = want; changed = true }
                inTun = false   // only the first enable: under tun:
            }
        }
        if changed {
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Set/insert top-level scalar keys in the on-disk config (bool/int/string).
    /// For load-time-only settings (geodata-*, unified-delay, keep-alive…) that
    /// mihomo silently ignores on a runtime `/configs` PATCH — write + reload instead.
    func setTopLevelScalars(_ kv: [String: Any]) {
        let path = configFilePath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        func render(_ v: Any) -> String {
            if let b = v as? Bool { return b ? "true" : "false" }
            if let i = v as? Int { return "\(i)" }
            return "\(v)"
        }
        for (key, value) in kv {
            let val = render(value)
            var found = false
            for i in lines.indices {
                let line = lines[i]
                guard !line.hasPrefix(" "), !line.hasPrefix("\t"), line.hasPrefix(key) else { continue }
                if line.dropFirst(key.count).first == ":" {
                    lines[i] = "\(key): \(val)"; found = true; break
                }
            }
            if !found { lines.insert("\(key): \(val)", at: 0) }
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - proxy-providers (config.yaml editing)

    /// Parse the `proxy-providers:` block into (name, url) pairs. Only the
    /// provider's own 4-space `url:` is read (health-check's 6-space url ignored).
    func proxyProviders() -> [(name: String, url: String)] {
        guard let text = try? String(contentsOfFile: configFilePath, encoding: .utf8) else { return [] }
        var result: [(String, String)] = []
        var inBlock = false, curIdx = -1
        for line in text.components(separatedBy: "\n") {
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inBlock = line.hasPrefix("proxy-providers:"); curIdx = -1; continue
            }
            guard inBlock else { continue }
            if line.hasPrefix("  ") && !line.hasPrefix("   ") {       // 2-space provider name
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasSuffix(":") { result.append((String(t.dropLast()), "")); curIdx = result.count - 1 }
            } else if curIdx >= 0 && line.hasPrefix("    url:") {     // 4-space own url
                result[curIdx].1 = line.trimmingCharacters(in: .whitespaces).dropFirst(4).trimmingCharacters(in: .whitespaces)
            }
        }
        return result.map { (name: $0.0, url: $0.1) }
    }

    /// Rewrite the whole `proxy-providers:` block from the given list (HTTP type +
    /// standard health-check template), and sync the first `use:`-based group to
    /// reference exactly these providers. Returns false on read failure.
    @discardableResult
    func writeProxyProviders(_ providers: [(name: String, url: String)]) -> Bool {
        guard let text = try? String(contentsOfFile: configFilePath, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\n")

        // Build the new block.
        var block: [String] = []
        if !providers.isEmpty {
            block.append("proxy-providers:")
            for p in providers {
                block += [
                    "  \(p.name):",
                    "    type: http",
                    "    url: \(p.url)",
                    "    interval: 3600",
                    "    health-check:",
                    "      enable: true",
                    "      url: http://www.gstatic.com/generate_204",
                    "      interval: 300",
                    "      lazy: true",
                ]
            }
        }
        // Replace existing proxy-providers block, else insert before proxy-groups.
        if let start = lines.firstIndex(where: { $0.hasPrefix("proxy-providers:") }) {
            var end = start + 1
            while end < lines.count, lines[end].isEmpty || lines[end].hasPrefix(" ") || lines[end].hasPrefix("\t") { end += 1 }
            lines.replaceSubrange(start..<end, with: block)
        } else if !block.isEmpty {
            let at = lines.firstIndex(where: { $0.hasPrefix("proxy-groups:") }) ?? lines.count
            lines.insert(contentsOf: block + [""], at: at)
        }

        // Sync the first group that uses `use:` to reference all provider names.
        if let u = lines.firstIndex(where: { $0.hasPrefix("    use:") }) {
            var j = u + 1
            while j < lines.count, lines[j].hasPrefix("      ") { j += 1 }   // existing 6-space items
            lines.replaceSubrange((u + 1)..<j, with: providers.map { "      - \($0.name)" })
        }

        try? lines.joined(separator: "\n").write(toFile: configFilePath, atomically: true, encoding: .utf8)
        return true
    }

    /// The BSD name of the current default-route interface (e.g. `en0`), or nil.
    /// Used to pin mihomo's outbound `interface-name` when enabling TUN so proxy
    /// egress has a concrete physical NIC immediately, instead of relying solely on
    /// `auto-detect-interface` which loses a race at TUN startup (auto-route hijacks
    /// the default route before the monitor identifies the NIC → "interface not found").
    nonisolated static func defaultInterface() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/route")
        p.arguments = ["-n", "get", "default"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                let name = t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    // MARK: - System DNS (TUN fake-ip routing)

    /// The macOS network service name (e.g. "Wi-Fi"/"Ethernet") bound to the
    /// current default-route interface, or nil. Needed because `networksetup`
    /// DNS commands key off the *service* name, not the BSD device.
    nonisolated static func defaultNetworkService() -> String? {
        guard let dev = defaultInterface() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-listnetworkserviceorder"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        // Services come in line pairs: "(N) ServiceName" then
        // "(Hardware Port: ..., Device: enX)". Find the device line, take the name above.
        let lines = out.components(separatedBy: "\n")
        for i in lines.indices where lines[i].contains("Device: \(dev))") && i > 0 {
            let name = lines[i-1].replacingOccurrences(
                of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// Read the system DNS servers for the default service. Empty array means
    /// "no manual servers" (DHCP), which `networksetup` prints as a sentence.
    nonisolated static func currentSystemDNS() -> [String] {
        guard let svc = defaultNetworkService() else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-getdnsservers", svc]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        // A non-IP line ("There aren't any DNS Servers set on …") = DHCP.
        let ips = out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"^[0-9a-fA-F:.]+$"#, options: .regularExpression) != nil }
        return ips
    }

    /// Set the system DNS servers for the default service. An empty list resets
    /// to DHCP (`networksetup … Empty`). Runs `networksetup` directly (works for
    /// admin users without an auth prompt; sandbox is off). Returns success.
    @discardableResult
    nonisolated static func applySystemDNS(_ servers: [String]) -> Bool {
        guard let svc = defaultNetworkService() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-setdnsservers", svc] + (servers.isEmpty ? ["Empty"] : servers)
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    /// Replace the known-unreliable geodata.kelee.one geox-url entries with the
    /// jsdelivr/Loyalsoldier mirrors *before* the kernel starts (B12). The old
    /// source returns empty files, which makes mihomo fatal on geosite:cn rules;
    /// and the existing runtime PATCH fix can never run because the kernel never
    /// comes up — a deadlock. Rewriting the config file up front breaks it. Only
    /// kelee.one lines are touched, so a user's working geox-url is left intact.
    func normalizeGeoxURL() {
        let path = configFilePath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              text.contains("geodata.kelee.one") else { return }
        let replacements = [
            "mmdb": "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/country.mmdb",
            "asn": "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb",
            "geosite": "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat",
            "geoip": "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
        ]
        var lines = text.components(separatedBy: "\n")
        var inGeox = false, changed = false
        for i in lines.indices {
            let line = lines[i]
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inGeox = line.hasPrefix("geox-url:")
                continue
            }
            guard inGeox, line.contains("geodata.kelee.one") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for (k, v) in replacements where trimmed.hasPrefix("\(k):") {
                let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                lines[i] = "\(indent)\(k): \(v)"
                changed = true
            }
        }
        if changed {
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Force the kernel's REST control plane to bind loopback only, and replace a
    /// missing/known-weak secret with a strong random one — editing only the
    /// `external-controller`/`secret` scalar lines, never proxy/rule data (B6).
    func hardenControllerConfig() {
        let path = configFilePath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        let weak: Set<String> = ["", "clashpow", "caseqc", "123456", "admin", "password"]
        var hasController = false, hasSecret = false, changed = false

        func scalar(_ line: String, _ key: String) -> String? {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), line.hasPrefix(key) else { return nil }
            let after = line.dropFirst(key.count)
            guard after.first == ":" else { return nil }
            var v = after.dropFirst().trimmingCharacters(in: .whitespaces)
            if let h = v.firstIndex(of: "#") { v = String(v[..<h]).trimmingCharacters(in: .whitespaces) }
            return v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        for i in lines.indices {
            if let ec = scalar(lines[i], "external-controller") {
                hasController = true
                let port = ec.lastIndex(of: ":").map { String(ec[ec.index(after: $0)...]) } ?? "9090"
                let want = "127.0.0.1:\(port.trimmingCharacters(in: .whitespaces))"
                if ec != want { lines[i] = "external-controller: \(want)"; changed = true }
            }
            if let sec = scalar(lines[i], "secret") {
                hasSecret = true
                if weak.contains(sec) { lines[i] = "secret: \(Self.randomSecret())"; changed = true }
            }
        }
        if !hasController { lines.insert("external-controller: 127.0.0.1:9090", at: 0); changed = true }
        if !hasSecret { lines.insert("secret: \(Self.randomSecret())", at: 0); changed = true }

        if changed {
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Cryptographically-random, URL-safe secret for the control plane.
    static func randomSecret() -> String {
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Locate an already-downloaded kernel to seed bin/mihomo when no bundled
    /// binary exists. Prefers kernel.json's recorded `external` path, otherwise
    /// the newest binary under kernels/<tag>/mihomo.
    private func installedKernelFallback() -> String? {
        let fm = FileManager.default
        let jsonPath = appSupport + "/kernel.json"
        if let data = fm.contents(atPath: jsonPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ext = obj["external"] as? String, fm.fileExists(atPath: ext) {
            return ext
        }
        let kernelsDir = appSupport + "/kernels"
        let tags = (try? fm.contentsOfDirectory(atPath: kernelsDir))?.sorted() ?? []
        for tag in tags.reversed() {
            let p = kernelsDir + "/\(tag)/mihomo"
            if fm.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// Try to start the kernel if it's not responding
    func ensureRunning() {
        Task {
            await api.probe()
            
            // If reachable, check if we need to upgrade to root
            if api.reachable {
                if isRoot && !runningAsRoot {
                    // Before killing a working kernel, check the real process owner.
                    // If it's already root (e.g. app restarted after a root session),
                    // just set the flag instead of doing a needless restart.
                    syncRunningAsRootIfNeeded()
                    if !runningAsRoot {
                        print("ensureRunning: Upgrading to root process...")
                        await restart()
                    }
                }
                return
            }
            
            let fm = FileManager.default
            guard fm.fileExists(atPath: kernelPath) else {
                onLog?("错误：未找到内核二进制 (\(kernelPath))。请在「内核管理」下载并启用内核。")
                return
            }

            if isRoot {
                if let helper = XPCManager.shared.helper() {
                    helper.startMihomo(binPath: kernelPath, homeDir: appSupport) { success in
                        Task { @MainActor in if success { self.runningAsRoot = true } }
                    }
                }
            } else {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: kernelPath)
                process.arguments = ["-d", appSupport]
                do {
                    try process.run()
                    runningAsRoot = false
                } catch {
                    print("ensureRunning: failed to start: \(error)")
                }
            }
        }
    }

    /// Check whether the installed helper is outdated and upgrade it automatically.
    /// Returns true if helper is at the expected version (already up to date or just upgraded).
    @discardableResult
    func checkAndUpgradeHelperIfNeeded() async -> Bool {
        // isRoot is set by pollStatus (every 5s); this check fires at 4s, before
        // the first poll, so it would skip on every fresh launch. Actively verify
        // connectivity here so the guard reflects reality, not poll timing.
        if !isRoot {
            isRoot = await XPCManager.shared.verifyConnectivity()
        }
        guard isRoot else { return true }
        // The version may not be fetched yet (pollStatus runs every 5s; this check
        // fires at 4s). Actively fetch it first so a needed upgrade isn't skipped
        // by the "?" guard and silently deferred forever.
        if helperVersion == "?" || helperVersion.isEmpty {
            if let v = await fetchHelperVersion() { helperVersion = v }
        }
        guard helperVersion != "?", !helperVersion.isEmpty else { return true }
        guard helperVersion != Self.kExpectedHelperVersion else { return true }
        onLog?("特权服务 v\(helperVersion) 低于预期 v\(Self.kExpectedHelperVersion)，开始自动升级（卸载→安装）…")
        let ok = await XPCManager.shared.upgradeDaemon()
        if ok {
            isRoot = true
            // Wait for new helper to come up and fetch fresh version
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if await XPCManager.shared.verifyConnectivity() { break }
            }
            refreshHelperVersion()
            onLog?("特权服务已升级至 v\(Self.kExpectedHelperVersion)")
        } else {
            onLog?("特权服务自动升级失败，请前往「设置→权限」手动更新")
        }
        return ok
    }

    /// Refresh status via REST API
    @discardableResult
    func refresh() async -> (addr: String, secret: String)? {
        await api.probe()
        if api.reachable {
            present = true
            engineVersion = api.version
            // We assume it's root if TUN is enabled and working, or check via other means.
            // For now, we'll use a property to track if we started it as root.
            return ("\(api.host):\(api.port)", api.secret)
        }
        present = false
        return nil
    }

    /// Install mihomo as a root LaunchDaemon.
    @discardableResult
    func installPrivileged() async -> Bool {
        // We use XPCManager to install the daemon which points to the official mihomo binary
        let ok = await XPCManager.shared.installDaemon()
        if ok { isRoot = true }
        return ok
    }

    @discardableResult
    func uninstallPrivileged() async -> Bool {
        let ok = await XPCManager.shared.uninstallDaemon()
        if ok { isRoot = false }
        return ok
    }

    /// Patch config via REST API
    @discardableResult
    func patchConfig(_ overrides: [String: Any]) async -> Bool {
        do {
            try await api.patchConfig(overrides)
            return true
        } catch {
            print("patchConfig error: \(error)")
            return false
        }
    }

    /// Set config via REST API (reload from path or direct patch)
    /// Validate the on-disk config via `mihomo -d <dir> -t`. Returns the first
    /// error message (e.g. a bad proxy-group reference) or nil if valid. Lets the
    /// app surface the *real* reason a kernel won't start instead of a generic
    /// "timeout / permission" message.
    func validateConfig() async -> String? {
        let bin = kernelPath, dir = appSupport
        guard FileManager.default.fileExists(atPath: bin) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = ["-d", dir, "-t"]
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 { cont.resume(returning: nil); return }
                let out = String(data: data, encoding: .utf8) ?? ""
                let errLine = out.split(separator: "\n").last { $0.contains("level=error") }
                if let line = errLine,
                   let r = line.range(of: #"msg="[^"]+""#, options: .regularExpression) {
                    cont.resume(returning: String(line[r].dropFirst(5).dropLast()))
                } else {
                    cont.resume(returning: errLine.map(String.init) ?? "配置校验失败")
                }
            }
        }
    }

    func setConfig(_ yaml: String) async -> (ok: Bool, error: String?) {
        let path = configFilePath
        do {
            try yaml.write(toFile: path, atomically: true, encoding: .utf8)
            hardenControllerConfig()   // ensure controller binds loopback + strong secret
            forceTUNDisabled()         // TUN is runtime-only — don't let a profile auto-enable it
            try await api.reloadConfig(path: path)
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Stop the running kernel: graceful REST shutdown, then helper/killall fallback.
    /// Exposed so callers (e.g. KernelManager.activate) can release bin/mihomo
    /// before overwriting it, avoiding "file busy" when a kernel is running.
    func stopKernel() async {
        // Attempt graceful shutdown via REST API if reachable
        if api.reachable, let url = URL(string: "http://\(api.host):\(api.port)/shutdown") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            if !api.secret.isEmpty { req.setValue("Bearer \(api.secret)", forHTTPHeaderField: "Authorization") }
            _ = try? await URLSession.shared.data(for: req)
        }

        // A root kernel can only be stopped by the helper; but when upgrading
        // user→root the *old* kernel was started by the app via Process (the
        // helper never managed it, so stopMihomo can't kill it). So always run
        // killall as a fallback — otherwise the old user-mode kernel survives,
        // ensureRunning sees it reachable and early-returns, and the root upgrade
        // silently never happens (then TUN can't be created).
        if isRoot, let helper = XPCManager.shared.helper() {
            _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                helper.stopMihomo { ok in cont.resume(returning: ok) }
            }
        }
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        t.arguments = ["-9", "mihomo"]
        try? t.run(); t.waitUntilExit()

        // Give it a moment to release ports / the binary
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    /// Stop and restart the kernel.
    func restart() async {
        await stopKernel()
        ensureRunning()
    }

    /// Start the kernel without stopping first (caller already stopped + swapped
    /// the binary, e.g. KernelManager.activate).
    func launch() async { ensureRunning() }

    /// Re-probe the helper for its version (manual "检查" button feedback).
    func refreshHelperVersion() {
        Task { @MainActor in if let v = await fetchHelperVersion() { self.helperVersion = v } }
    }

    /// Fetch the helper version over a fresh connection (reliable, unlike the
    /// cached helper() proxy). Returns nil if unreachable / timed out.
    func fetchHelperVersion(timeout: TimeInterval = 2.0) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            Task {
                let conn = NSXPCConnection(machServiceName: "com.clashpow.helper", options: .privileged)
                conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
                conn.resume()
                let lock = NSLock(); var done = false
                let finish: (String?) -> Void = { v in
                    lock.lock(); defer { lock.unlock() }
                    if !done { done = true; cont.resume(returning: v); conn.invalidate() }
                }
                guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in finish(nil) }) as? HelperProtocol else {
                    finish(nil); return
                }
                proxy.getVersion { v in finish(v.isEmpty ? nil : v) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
            }
        }
    }

    /// Run a shell snippet with administrator privileges via one osascript prompt.
    static func runAdmin(_ shell: String) async -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                do { try p.run(); p.waitUntilExit(); cont.resume(returning: p.terminationStatus == 0) }
                catch { cont.resume(returning: false) }
            }
        }
    }

    @discardableResult
    func setSystemProxy(enabled: Bool, port: Int) async -> Bool {
        // Go through a fresh helper connection (callSystemProxy). The cached
        // helper() proxy silently dropped these calls — the helper never logged
        // them — so the toggle reported "系统代理设置失败". A nil result means the
        // helper was unreachable / errored / timed out; fall back to osascript.
        if let ok = await XPCManager.shared.callSystemProxy(enabled: enabled, port: port) {
            return ok
        }
        return await Self.setSystemProxyFallback(enabled: enabled, port: port)
    }

    /// Set/clear the macOS system HTTP/HTTPS/SOCKS proxy via osascript fallback.
    static func setSystemProxyFallback(enabled: Bool, port: Int) async -> Bool {
        let shell: String
        if enabled {
            shell = """
            dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}'); \\
            svc=$(networksetup -listnetworkserviceorder | grep -B1 \\"Device: $dev)\\" | head -1 | sed -E 's/^\\\\([0-9]+\\\\) //'); \\
            networksetup -setwebproxy \\"$svc\\" 127.0.0.1 \(port); \\
            networksetup -setsecurewebproxy \\"$svc\\" 127.0.0.1 \(port); \\
            networksetup -setsocksfirewallproxy \\"$svc\\" 127.0.0.1 \(port)
            """
        } else {
            shell = """
            dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}'); \\
            svc=$(networksetup -listnetworkserviceorder | grep -B1 \\"Device: $dev)\\" | head -1 | sed -E 's/^\\\\([0-9]+\\\\) //'); \\
            networksetup -setwebproxystate \\"$svc\\" off; \\
            networksetup -setsecurewebproxystate \\"$svc\\" off; \\
            networksetup -setsocksfirewallproxystate \\"$svc\\" off
            """
        }
        let script = "do shell script \"\(shell)\" with administrator privileges"
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                do { try p.run(); p.waitUntilExit(); cont.resume(returning: p.terminationStatus == 0) }
                catch { cont.resume(returning: false) }
            }
        }
    }
}
