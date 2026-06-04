import Foundation
import Combine
import SwiftUI

@MainActor final class EngineControl: ObservableObject {
    static let shared = EngineControl()
    /// Expected version of the installed helper. When the running helper reports a
    /// different version the app auto-reinstalls it (new binary = new permissions fix).
    static let kExpectedHelperVersion = "1.0.5"
    let api = MihomoClient.shared

    @Published var present = false
    @Published var uptimeSec: Int64 = 0
    @Published var engineVersion = "?"
    @Published var helperVersion = "?"
    @Published var isRoot = false          // helper is installed
    @Published var runningAsRoot = false   // current process was started via helper

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
        // Start polling helper status
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
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
        guard isRoot else { return true }
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
    func setConfig(_ yaml: String) async -> (ok: Bool, error: String?) {
        let path = appSupport + "/active_config.yaml"
        do {
            try yaml.write(toFile: path, atomically: true, encoding: .utf8)
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
        XPCManager.shared.helper()?.getVersion { v in
            Task { @MainActor in if !v.isEmpty { self.helperVersion = v } }
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
        guard let helper = XPCManager.shared.helper() else {
            // Fallback to osascript if helper not available
            return await Self.setSystemProxyFallback(enabled: enabled, port: port)
        }
        return await withCheckedContinuation { cont in
            helper.setSystemProxy(enabled: enabled, port: port) { ok in
                cont.resume(returning: ok)
            }
        }
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
