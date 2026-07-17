import Foundation
import Combine
import SwiftUI

@MainActor final class EngineControl: ObservableObject {
    static let shared = EngineControl()
    /// Expected version of the installed helper. When the running helper reports a
    /// different version the app auto-reinstalls it (new binary = new permissions fix).
    static let kExpectedHelperVersion = kSharedHelperVersion
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
    private var userProcess: Process?

    /// Injected log sink (set by AppModel) — avoids referencing AppModel here.
    var onLog: ((String) -> Void)?

    private let appSupport = NSHomeDirectory() + "/Library/Application Support/ClashHalo"
    /// Config file the running mihomo reads (`mihomo -d <appSupport>` → config.yaml).
    /// Used as the source of truth for controller endpoint discovery (B1).
    var configFilePath: String { appSupport + "/config.yaml" }
    private var binDir: String { appSupport + "/bin" }
    private var kernelPath: String { binDir + "/mihomo" }
    private let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.clashhalo.mihomo.plist"
    private let rootPlistPath = "/Library/LaunchDaemons/com.clashhalo.mihomo.plist"
    private var legacyAppSupport: String { NSHomeDirectory() + "/Library/Application Support/ClashPow" }

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
                await syncRunningAsRootIfNeeded()
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
    private func syncRunningAsRootIfNeeded() async {
        guard !runningAsRoot else { return }
        let isRoot = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                p.arguments = ["-u", "root", "-x", "mihomo"]
                p.standardOutput = Pipe()
                try? p.run(); p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
        if isRoot { runningAsRoot = true }
    }

    /// Ensure the mihomo binary and configuration directory are set up.
    func ensureInstalled() {
        let fm = FileManager.default
        migrateLegacyAppSupportIfNeeded()
        try? fm.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        
        // Setup initial bin if missing: prefer the bundled binary, else fall back
        // to a kernel the user already downloaded under kernels/ (B2 — avoids the
        // split where kernels/<tag>/mihomo exists but bin/mihomo stays empty).
        if !fm.fileExists(atPath: kernelPath) {
            let bundledExec = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mihomo")
            if fm.fileExists(atPath: bundledExec.path) {
                try? fm.copyItem(at: bundledExec, to: URL(fileURLWithPath: kernelPath))
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kernelPath)
            } else if let bundled = Bundle.main.url(forResource: "mihomo", withExtension: nil) {
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
            secret: clashhalo
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
        injectMemoryOptimization()
    }

    private func migrateLegacyAppSupportIfNeeded() {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: legacyAppSupport, isDirectory: &isDir), isDir.boolValue else { return }
        guard !fm.fileExists(atPath: appSupport) else { return }
        do {
            try fm.moveItem(atPath: legacyAppSupport, toPath: appSupport)
            onLog?("已迁移旧数据目录到 ClashHalo")
        } catch {
            onLog?("旧数据目录迁移失败：\(error.localizedDescription)")
        }
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
            if let d = v as? Double { return "\(Int(d))" }
            return "\(v)"
        }
        
        for (key, value) in kv {
            if let nested = value as? [String: Any] {
                // Handle one level of nesting for known blocks: tun, dns, sniffer
                setNestedScalars(parent: key, kv: nested, in: &lines)
            } else {
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
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func setNestedScalars(parent: String, kv: [String: Any], in lines: inout [String]) {
        func render(_ v: Any) -> String {
            if let b = v as? Bool { return b ? "true" : "false" }
            if let i = v as? Int { return "\(i)" }
            if let d = v as? Double { return "\(Int(d))" }
            if let arr = v as? [Any] {
                return "[" + arr.map { "\($0)" }.joined(separator: ", ") + "]"
            }
            return "\(v)"
        }

        var parentIdx = -1
        for i in lines.indices {
            let line = lines[i]
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && line.hasPrefix("\(parent):") {
                parentIdx = i; break
            }
        }

        if parentIdx == -1 {
            // Parent not found, add it to the top
            lines.insert("\(parent):", at: 0)
            for (k, v) in kv {
                lines.insert("  \(k): \(render(v))", at: 1)
            }
            return
        }

        for (k, v) in kv {
            var found = false
            let val = render(v)
            var i = parentIdx + 1
            while i < lines.count {
                let line = lines[i]
                if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.isEmpty { break }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("\(k):") {
                    let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                    lines[i] = "\(indent.isEmpty ? "  " : indent)\(k): \(val)"
                    found = true; break
                }
                i += 1
            }
            if !found {
                lines.insert("  \(k): \(val)", at: parentIdx + 1)
            }
        }
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
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasSuffix(":") { 
                    let name = String(t.dropLast()).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                    if !name.isEmpty {
                        result.append((name, ""))
                        curIdx = result.count - 1 
                    }
                }
            } else if curIdx >= 0 && line.hasPrefix("    url:") {     // 4-space own url
                let url = line.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
                result[curIdx].1 = url.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
            }
        }
        return result.map { (name: $0.0, url: $0.1) }
    }

    /// Rewrite the whole `proxy-providers:` block from the given list (HTTP type +
    /// standard health-check template), and sync the first `use:`-based group to
    /// reference exactly these providers. Returns false on read failure.
    @discardableResult
    func writeProxyProviders(_ providers: [(name: String, url: String)]) -> Bool {
        let oldNames = Set(proxyProviders().map { $0.name })
        let newNames = Set(providers.map { $0.name })
        let deleted = oldNames.subtracting(newNames)

        guard let text = try? String(contentsOfFile: configFilePath, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\n")

        // 1. Build the new proxy-providers block.
        var block: [String] = []
        if !providers.isEmpty {
            block.append("proxy-providers:")
            for p in providers {
                block += [
                    "  \"\(p.name)\":",
                    "    type: http",
                    "    url: \"\(p.url)\"",
                    "    interval: 3600",
                    "    health-check:",
                    "      enable: true",
                    "      url: http://www.gstatic.com/generate_204",
                    "      interval: 300",
                    "      lazy: true",
                ]
            }
        }

        // 2. Replace existing proxy-providers block, else insert before proxy-groups.
        if let start = lines.firstIndex(where: { $0.hasPrefix("proxy-providers:") }) {
            var end = start + 1
            while end < lines.count, lines[end].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lines[end].hasPrefix(" ") || lines[end].hasPrefix("\t") { end += 1 }
            lines.replaceSubrange(start..<end, with: block)
        } else if !block.isEmpty {
            let at = lines.firstIndex(where: { $0.hasPrefix("proxy-groups:") }) ?? lines.count
            lines.insert(contentsOf: block + [""], at: at)
        }

        // 3. Cleanup all references (use, proxies, rules)
        var insideProxyGroups = false
        var insideRules = false

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if line.hasPrefix("proxy-groups:") { insideProxyGroups = true; insideRules = false; i += 1; continue }
            if line.hasPrefix("rules:") { insideRules = true; insideProxyGroups = false; i += 1; continue }
            if !line.hasPrefix(" ") && !line.hasPrefix("-") && !trimmed.isEmpty { insideProxyGroups = false; insideRules = false }

            if insideProxyGroups {
                // Inline array use: [A, B] or proxies: [A, B]
                if (trimmed.hasPrefix("use:") || trimmed.hasPrefix("proxies:")) && trimmed.contains("[") {
                    var modified = line
                    for d in deleted {
                        modified = modified.replacingOccurrences(of: " \(d),", with: " ")
                        modified = modified.replacingOccurrences(of: " \"\(d)\",", with: " ")
                        modified = modified.replacingOccurrences(of: " \(d)]", with: "]")
                        modified = modified.replacingOccurrences(of: " \"\(d)\"]", with: "]")
                        modified = modified.replacingOccurrences(of: "[\(d), ", with: "[")
                        modified = modified.replacingOccurrences(of: "[\"\(d)\", ", with: "[")
                        modified = modified.replacingOccurrences(of: "[\(d)]", with: "[]")
                        modified = modified.replacingOccurrences(of: "[\"\(d)\"]", with: "[]")
                    }
                    if modified != line { lines[i] = modified }
                }
                
                // Block array: - ProviderName
                if trimmed.hasPrefix("- ") && !trimmed.hasPrefix("- name:") {
                    let rawName = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    let name = rawName.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                    if deleted.contains(name) {
                        lines.remove(at: i)
                        continue
                    }
                }
            }

            if insideRules {
                // Rule format: - MATCH,NodeOrProvider
                if trimmed.hasPrefix("- ") {
                    let parts = trimmed.dropFirst(2).components(separatedBy: ",")
                    if let lastRaw = parts.last?.trimmingCharacters(in: .whitespaces) {
                        let last = lastRaw.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                        if deleted.contains(last) {
                            lines.remove(at: i)
                            continue
                        }
                    }
                }
            }
            i += 1
        }

        // 4. Sync the primary group's use: block.
        if let pgIdx = lines.firstIndex(where: { $0.hasPrefix("proxy-groups:") }) {
            if let firstGroupIdx = lines[(pgIdx+1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- name:") }) {
                // Find where this group ends
                var nextGroupIdx = lines.count
                for idx in (firstGroupIdx+1)..<lines.count {
                    let trimmed = lines[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("- name:") || (!lines[idx].hasPrefix(" ") && !trimmed.isEmpty) {
                        nextGroupIdx = idx
                        break
                    }
                }
                
                // Remove existing `use:` in primary group
                if let useIdx = lines[firstGroupIdx..<nextGroupIdx].firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "use:" }) {
                    var endUseIdx = useIdx + 1
                    let useIndent = lines[useIdx].prefix(while: { $0 == " " }).count
                    while endUseIdx < nextGroupIdx {
                        let trimmed = lines[endUseIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty { endUseIdx += 1; continue }
                        let indent = lines[endUseIdx].prefix(while: { $0 == " " }).count
                        if indent > useIndent { 
                            endUseIdx += 1
                            continue 
                        }
                        if indent == useIndent && trimmed.hasPrefix("-") {
                            endUseIdx += 1
                            continue
                        }
                        break
                    }
                    lines.removeSubrange(useIdx..<endUseIdx)
                    nextGroupIdx -= (endUseIdx - useIdx)
                }
                
                // Inject new `use:`
                if !providers.isEmpty {
                    var insertAt = firstGroupIdx + 1
                    var baseIndent = "    "
                    while insertAt < nextGroupIdx {
                        let line = lines[insertAt]
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.hasPrefix("type:") && !trimmed.hasPrefix("name:") { break }
                        baseIndent = String(line.prefix(while: { $0 == " " }))
                        insertAt += 1
                    }
                    var useBlock = ["\(baseIndent)use:"]
                    useBlock.append(contentsOf: providers.map { "\(baseIndent)  - \"\($0.name)\"" })
                    lines.insert(contentsOf: useBlock, at: insertAt)
                }
            }
        }

        // 5. Cleanup any dangling empty use: or proxies: blocks in other groups
        var j = lines.count - 1
        while j >= 0 {
            let trimmed = lines[j].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "use:" || trimmed == "proxies:" {
                let indent = lines[j].prefix(while: { $0 == " " }).count
                var hasChildren = false
                var k = j + 1
                while k < lines.count {
                    let nextTrimmed = lines[k].trimmingCharacters(in: .whitespacesAndNewlines)
                    if nextTrimmed.isEmpty { k += 1; continue }
                    let nextIndent = lines[k].prefix(while: { $0 == " " }).count
                    if nextIndent > indent { 
                        hasChildren = true
                        break 
                    }
                    if nextIndent == indent && nextTrimmed.hasPrefix("-") {
                        hasChildren = true
                        break
                    }
                    break
                }
                if !hasChildren {
                    lines.remove(at: j)
                }
            }
            j -= 1
        }

        try? lines.joined(separator: "\n").write(toFile: configFilePath, atomically: true, encoding: .utf8)
        return true
    }

    /// The BSD name of the current default-route interface (e.g. `en0`), or nil.
    nonisolated static func defaultInterface() async -> String? {
        await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/route")
            p.arguments = ["-n", "get", "default"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let out = String(data: data, encoding: .utf8) else { return nil }
            var routeIface: String? = nil
            for line in out.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("interface:") {
                    let name = t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        routeIface = name
                        break
                    }
                }
            }
            if let iface = routeIface, !iface.hasPrefix("utun") {
                return iface
            }
            // Fallback: Scan physical interfaces if the default route points to a tunnel or is missing.
            let physicalIfaces = NetScanner.interfaces().filter {
                $0.kind == .physical && $0.isUp && !$0.ipv4.isEmpty
            }
            if physicalIfaces.contains(where: { $0.id == "en0" }) {
                return "en0"
            }
            return physicalIfaces.first?.id
        }.value
    }

    // MARK: - System DNS (TUN fake-ip routing)

    /// The macOS network service name (e.g. "Wi-Fi"/"Ethernet") bound to the
    /// current default-route interface, or nil.
    nonisolated static func defaultNetworkService() async -> String? {
        guard let dev = await defaultInterface() else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            p.arguments = ["-listnetworkserviceorder"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            guard let out = String(data: data, encoding: .utf8) else { return nil }
            let lines = out.components(separatedBy: "\n")
            for i in lines.indices where lines[i].contains("Device: \(dev))") && i > 0 {
                let name = lines[i-1].replacingOccurrences(
                    of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }.value
    }

    /// Read the system DNS servers for the default service.
    nonisolated static func currentSystemDNS() async -> [String] {
        guard let svc = await defaultNetworkService() else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            p.arguments = ["-getdnsservers", svc]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            do { try p.run() } catch { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            let ips = out.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.range(of: #"^[0-9a-fA-F:.]+$"#, options: .regularExpression) != nil }
            return ips
        }.value
    }

    /// Set the system DNS servers for the default service.
    @discardableResult
    nonisolated static func applySystemDNS(_ servers: [String]) async -> Bool {
        guard let svc = await defaultNetworkService() else { return false }
        return await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            p.arguments = ["-setdnsservers", svc] + (servers.isEmpty ? ["Empty"] : servers)
            p.standardOutput = Pipe(); p.standardError = Pipe()
            do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
            catch { return false }
        }.value
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
        let weak: Set<String> = ["", "clashhalo", "caseqc", "123456", "admin", "password"]
        var hasController = false, hasSecret = false, hasExtUI = false, hasExtUIName = false, changed = false

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
            } else if let sec = scalar(lines[i], "secret") {
                hasSecret = true
                if weak.contains(sec) { lines[i] = "secret: \(Self.randomSecret())"; changed = true }
            } else if scalar(lines[i], "external-ui") != nil {
                hasExtUI = true
            } else if scalar(lines[i], "external-ui-name") != nil {
                hasExtUIName = true
            }
        }
        
        if !hasController { lines.insert("external-controller: 127.0.0.1:9090", at: 0); changed = true }
        if !hasSecret { lines.insert("secret: \(Self.randomSecret())", at: 0); changed = true }

        if changed {
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Inject Kernel Memory Optimization: mmap for geodata & LRU Cache for DNS
    func injectMemoryOptimization() {
        let path = configFilePath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        var hasGeodataMode = false
        var inDns = false
        var hasDnsCacheAlg = false
        var hasDnsSize = false
        var dnsIndex = -1
        var changed = false
        
        func scalar(_ line: String, _ key: String) -> String? {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), line.hasPrefix(key) else { return nil }
            let after = line.dropFirst(key.count)
            guard after.first == ":" else { return nil }
            return after.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        
        for i in lines.indices {
            let line = lines[i]
            if scalar(line, "geodata-mode") != nil {
                hasGeodataMode = true
            }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inDns = line.hasPrefix("dns:")
                if inDns { dnsIndex = i }
                continue
            }
            if inDns {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("cache-algorithm:") {
                    hasDnsCacheAlg = true
                }
                if trimmed.hasPrefix("size:") {
                    hasDnsSize = true
                }
            }
        }
        
        if !hasGeodataMode {
            lines.insert("geodata-mode: true", at: 0)
            changed = true
            if dnsIndex != -1 { dnsIndex += 1 }
        }
        if dnsIndex != -1 {
            var insertPos = dnsIndex + 1
            if !hasDnsSize {
                lines.insert("  size: 1500", at: insertPos)
                insertPos += 1
                changed = true
            }
            if !hasDnsCacheAlg {
                lines.insert("  cache-algorithm: lru", at: insertPos)
                changed = true
            }
        }
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

    /// Fire-and-forget wrapper. Prefer `ensureRunningAsync()` when the caller
    /// needs to wait for the start attempt (TUN re-enable, toggle engine, etc.).
    func ensureRunning() {
        Task { await ensureRunningAsync() }
    }

    /// Start the kernel if it's not responding. Root start goes through a fresh
    /// XPC connection (`callStartMihomo`); the cached `helper()` proxy is known
    /// to silently drop start calls after long-lived use. Awaitable so TUN /
    /// restart paths can wait for the helper reply instead of racing a detached
    /// Task and timing out with a false "权限不足".
    func ensureRunningAsync() async {
        await api.probe()

        // If reachable, check if we need to upgrade to root
        if api.reachable {
            if isRoot && !runningAsRoot {
                // Before killing a working kernel, check the real process owner.
                // If it's already root (e.g. app restarted after a root session),
                // just set the flag instead of doing a needless restart.
                await syncRunningAsRootIfNeeded()
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

        // Prefer root only when the helper is actually reachable. A stale
        // isRoot=true after stop/cascade (or a dead LaunchDaemon) used to make
        // the start path a silent no-op when the cached XPC proxy dropped the call.
        if isRoot {
            let connected = await XPCManager.shared.verifyConnectivity()
            if !connected {
                onLog?("特权服务不可达，回退到用户模式启动")
                isRoot = false
            } else {
                let result = await XPCManager.shared.callStartMihomo(
                    binPath: kernelPath,
                    homeDir: appSupport
                )
                if result == true {
                    runningAsRoot = true
                    return
                }
                // Helper replied false (binPath reject / spawn fail) or timed out.
                // Do not permanently clear isRoot on a spawn failure — only when
                // the helper itself is unreachable (nil). Fall back to user-mode
                // so the app isn't stuck with a dead core.
                if result == nil {
                    onLog?("⚠️ Root 模式启动无响应，回退到用户模式")
                    isRoot = false
                } else {
                    onLog?("⚠️ Root 模式启动失败，回退到用户模式")
                }
                runningAsRoot = false
            }
        }

        // User-mode start (primary path when helper is absent, or fallback).
        if userProcess?.isRunning == true {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: kernelPath)
        process.arguments = ["-d", appSupport]
        var env = ProcessInfo.processInfo.environment
        env["GOGC"] = "50"
        env["GODEBUG"] = "madvdontneed=1"
        process.environment = env
        do {
            try process.run()
            userProcess = process
            runningAsRoot = false
        } catch {
            print("ensureRunning: failed to start: \(error)")
            onLog?("用户模式启动失败：\(error.localizedDescription)")
        }
    }

    /// Check whether the installed helper is outdated and upgrade it automatically.
    /// Returns true if helper is at the expected version (already up to date or just upgraded).
    @discardableResult
    func checkAndUpgradeHelperIfNeeded() async -> Bool {
        if !isRoot {
            isRoot = await XPCManager.shared.verifyConnectivity()
        }
        if !isRoot {
            onLog?("未检测到特权服务，开始自动安装…")
            let ok = await installPrivileged()
            if ok {
                isRoot = await XPCManager.shared.verifyConnectivity()
                if isRoot {
                    onLog?("特权服务安装成功 ✓")
                }
            } else {
                onLog?("特权服务授权被拒绝")
            }
        }
        guard isRoot else { return false }
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
            injectMemoryOptimization() // Apply kernel memory optimization settings
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
        if let proc = userProcess, proc.isRunning {
            proc.terminate()
        }
        userProcess = nil

        // Attempt graceful shutdown via REST API if reachable
        if api.reachable, let url = URL(string: "http://\(api.host):\(api.port)/shutdown") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            if !api.secret.isEmpty { req.setValue("Bearer \(api.secret)", forHTTPHeaderField: "Authorization") }
            _ = try? await URLSession.shared.data(for: req)
        }

        // Perform stopping on a background thread to avoid blocking the Main Actor
        await Task.detached(priority: .userInitiated) {
            if await XPCManager.shared.verifyConnectivity() {
                if let helper = XPCManager.shared.helper() {
                    _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                        helper.stopMihomo { ok in cont.resume(returning: ok) }
                    }
                }
            }
            let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            t.arguments = ["-9", "mihomo"]
            t.standardOutput = Pipe(); t.standardError = Pipe()
            try? t.run(); t.waitUntilExit()
        }.value

        // Kernel is gone — clear the root-mode ownership flag. Leaving it true
        // after stop makes refreshConfigs re-arm tunOn from a stale in-flight
        // /configs response (enable && runningAsRoot && hasInterface).
        runningAsRoot = false

        // Give it a moment to release ports / the binary
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    /// Stop and restart the kernel. Awaits the start attempt so callers that
    /// immediately `waitForKernelReady` do not race a fire-and-forget Task.
    func restart() async {
        await stopKernel()
        await ensureRunningAsync()
    }

    /// Start the kernel without stopping first (caller already stopped + swapped
    /// the binary, e.g. KernelManager.activate).
    func launch() async { await ensureRunningAsync() }

    /// Re-probe the helper for its version (manual "检查" button feedback).
    func refreshHelperVersion() {
        Task { @MainActor in if let v = await fetchHelperVersion() { self.helperVersion = v } }
    }

    /// Fetch the helper version over a fresh connection (reliable, unlike the
    /// cached helper() proxy). Returns nil if unreachable / timed out.
    func fetchHelperVersion(timeout: TimeInterval = 2.0) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            Task {
                let conn = NSXPCConnection(machServiceName: "com.clashhalo.helper", options: .privileged)
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
    func setGatewayMode(enabled: Bool) async -> Bool {
        if let ok = await XPCManager.shared.callGatewayMode(enabled: enabled) {
            return ok
        }
        return false
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

    /// Set/clear the macOS system HTTP/HTTPS/SOCKS proxy via service loop fallback.
    static func setSystemProxyFallback(enabled: Bool, port: Int) async -> Bool {
        let shell: String
        if enabled {
            // Bypass domains: the single-source `kProxyBypassDomains` (RFC1918 +
            // link-local + CGNAT) so this fallback stays in lockstep with the XPC
            // path and the GUI reconcile — no duplicated list to drift. See
            // ProxyManager.setSystemProxy for the rationale.
            let bypass = kProxyBypassDomains.joined(separator: " ")
            shell = """
            networksetup -listallnetworkservices | tail -n +2 | while read -r svc; do
                [[ "$svc" == \\** ]] && continue
                networksetup -setwebproxy "$svc" 127.0.0.1 \(port) 2>/dev/null || true
                networksetup -setsecurewebproxy "$svc" 127.0.0.1 \(port) 2>/dev/null || true
                networksetup -setsocksfirewallproxy "$svc" 127.0.0.1 \(port) 2>/dev/null || true
                networksetup -setproxybypassdomains "$svc" \(bypass) 2>/dev/null || true
                networksetup -setwebproxystate "$svc" on 2>/dev/null || true
                networksetup -setsecurewebproxystate "$svc" on 2>/dev/null || true
                networksetup -setsocksfirewallproxystate "$svc" on 2>/dev/null || true
            done
            """
        } else {
            shell = """
            networksetup -listallnetworkservices | tail -n +2 | while read -r svc; do
                [[ "$svc" == \\** ]] && continue
                networksetup -setwebproxystate "$svc" off 2>/dev/null || true
                networksetup -setsecurewebproxystate "$svc" off 2>/dev/null || true
                networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null || true
            done
            """
        }
        
        // Try running locally without admin prompt first
        if await runLocalShell(shell) {
            return true
        }
        
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

    private static func runLocalShell(_ shell: String) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", shell]
                p.standardOutput = Pipe()
                p.standardError = Pipe()
                do {
                    try p.run()
                    p.waitUntilExit()
                    cont.resume(returning: p.terminationStatus == 0)
                } catch {
                    cont.resume(returning: false)
                }
            }
        }
    }

    /// Read config.yaml and return a dictionary. Used to read fields that mihomo
    /// API doesn't expose (e.g. sniffer).
    func readConfigFile() -> [String: Any]? {
        guard let text = try? String(contentsOfFile: configFilePath, encoding: .utf8) else { return nil }
        var result: [String: Any] = [:]
        var currentSection: String? = nil
        var currentDict: [String: Any] = [:]
        var lastKey: String? = nil

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Top-level key
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && line.contains(":") {
                if let section = currentSection, !currentDict.isEmpty {
                    result[section] = currentDict
                    currentDict = [:]
                }
                lastKey = nil

                let parts = line.split(separator: ":", maxSplits: 1)
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                if parts.count > 1 {
                    let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    if value.isEmpty {
                        currentSection = key
                    } else {
                        result[key] = parseValue(value)
                    }
                } else {
                    currentSection = key
                }
            }
            // Nested key (2-space indent)
            else if (line.hasPrefix("  ") && !line.hasPrefix("    ")) && line.contains(":") {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                lastKey = key
                if parts.count > 1 {
                    let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    if value.isEmpty {
                        currentDict[key] = [] as [String]
                    } else {
                        currentDict[key] = parseValue(value)
                    }
                } else {
                    currentDict[key] = [] as [String]
                }
            }
            // Array items (4-space indent or - prefix)
            else if (line.hasPrefix("    ") || line.hasPrefix("  -") || line.hasPrefix("\t\t")) && trimmed.hasPrefix("-") {
                if let key = lastKey {
                    let value = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                    var arr = currentDict[key] as? [String] ?? []
                    if let parsedStr = parseValue(value) as? String {
                        arr.append(parsedStr)
                    } else {
                        arr.append(value)
                    }
                    currentDict[key] = arr
                }
            }
        }

        if let section = currentSection, !currentDict.isEmpty {
            result[section] = currentDict
        }

        return result
    }

    private func parseValue(_ value: String) -> Any {
        if value == "true" { return true }
        if value == "false" { return false }
        if let i = Int(value) { return i }
        // Remove quotes
        if value.hasPrefix("'") && value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        // Handle flow-style array
        if value.hasPrefix("[") && value.hasSuffix("]") {
            let inner = value.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return [] as [String] }
            return inner.components(separatedBy: ",").map { 
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return value
    }
}
