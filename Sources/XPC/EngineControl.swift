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
    /// Clearing it also clears `busyStep` so a stale progress line can never
    /// survive into the next (possibly background self-heal) busy episode.
    @Published var isBusy = false {
        didSet { if !isBusy { busyStep = nil } }
    }

    /// Human-readable current step of the in-flight busy operation, surfaced as
    /// a persistent banner in the main content. Seeded by `withEngineBusy` and
    /// refined by progress (`.info`) toasts; auto-cleared when `isBusy` falls
    /// (see the didSet above), so its lifecycle is inseparable from `isBusy`.
    @Published var busyStep: String?

    /// True when the helper is installed and reachable but reports a version
    /// below the one this app expects — i.e. a forced upgrade is pending. Single
    /// source for the settings action and the sidebar attention badge.
    var helperNeedsUpdate: Bool {
        isRoot && helperVersion != "?" && !helperVersion.isEmpty
            && helperVersion != Self.kExpectedHelperVersion
    }
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
    func syncRunningAsRootIfNeeded() async {
        guard !runningAsRoot else { return }
        let isRootOwned = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                p.arguments = ["-u", "root", "-x", "mihomo"]
                p.standardOutput = Pipe()
                try? p.run(); p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
        if isRootOwned { runningAsRoot = true }
    }

    /// Ensure the mihomo binary and configuration directory are set up.
    ///
    /// Returns the secret `hardenControllerConfig()` just replaced, if any —
    /// see that function's doc for why the caller needs it.
    @discardableResult
    func ensureInstalled() -> String? {
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

        // These four each read, line-scan and rewrite the whole config — four full
        // read/parse/write cycles of a multi-KB file on the main thread during
        // launch. They are all idempotent and almost always no-ops after the
        // first run, so skip the work entirely when the file is already
        // normalized: one read decides it, instead of four read+write passes.
        var replacedSecret: String?
        if configNeedsNormalizing() {
            replacedSecret = hardenControllerConfig()
            normalizeGeoxURL()
            forceTUNDisabled()   // TUN is runtime-only (root) — never auto-enable from disk
            injectMemoryOptimization()
        }
        return replacedSecret
    }

    /// Cheap single-read precondition for the launch-time config normalizers.
    /// Returns false only when every invariant they enforce already holds, which
    /// is the steady state after the first launch.
    private func configNeedsNormalizing() -> Bool {
        guard let text = try? String(contentsOfFile: configFilePath, encoding: .utf8) else {
            return true   // unreadable: let the normalizers deal with it
        }
        // Any of these means at least one normalizer has work to do.
        if text.contains("geodata.kelee.one") { return true }
        if !text.contains("geodata-mode") { return true }

        var hasController = false, hasOwnSecret = false, tunDisabled = false
        var inTun = false, dnsHasSize = false, dnsHasCacheAlg = false, inDns = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inTun = line.hasPrefix("tun:")
                inDns = line.hasPrefix("dns:")
                if line.hasPrefix("external-controller:") {
                    hasController = line.contains("127.0.0.1:")
                }
                if line.hasPrefix("secret:") {
                    let v = line.dropFirst("secret:".count)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    // Must mirror hardenControllerConfig's replace condition, or a
                    // secret it would leave alone still reports "needs normalizing"
                    // and re-runs the whole read/rewrite pass on every launch.
                    hasOwnSecret = !Self.isReplaceableSecret(v)
                }
                continue
            }
            let t = line.trimmingCharacters(in: .whitespaces)
            if inTun, t.hasPrefix("enable:") { tunDisabled = t.contains("false") }
            if inDns, t.hasPrefix("size:") { dnsHasSize = true }
            if inDns, t.hasPrefix("cache-algorithm:") { dnsHasCacheAlg = true }
        }
        return !(hasController && hasOwnSecret && tunDisabled && dnsHasSize && dnsHasCacheAlg)
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

    /// Write (or clear) `tun.device` on disk so a kernel that starts from the file
    /// takes the same utun name the runtime PATCH asks for.
    ///
    /// TUN is normally a runtime-only PATCH, but the root bring-up path
    /// deliberately persists `tun.enable` and restarts (see `applyTUNState`), and
    /// that start reads the file — not the PATCH. Without the name here, a
    /// PATCH-started TUN and a restart-started TUN would land on different
    /// interfaces, which is exactly the ambiguity the pin exists to remove.
    /// `nil` deletes the key: the fallback path must leave the kernel free to
    /// assign a name again, not merely stop mentioning one.
    func setTunDevice(_ name: String?) {
        let path = configFilePath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        var inTun = false, changed = false, tunIdx = -1
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inTun = line.hasPrefix("tun:")
                if inTun { tunIdx = i }
                i += 1
                continue
            }
            guard inTun, line.trimmingCharacters(in: .whitespaces).hasPrefix("device:") else {
                i += 1
                continue
            }
            if let name {
                let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                let want = "\(indent)device: \(name)"
                if line != want { lines[i] = want; changed = true }
                i += 1
            } else {
                lines.remove(at: i); changed = true
            }
            inTun = false   // only the first device: under tun:
        }
        // No `device:` under `tun:` yet — insert one when a name is wanted.
        if let name, !changed, tunIdx >= 0,
           !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "device: \(name)" }) {
            lines.insert("  device: \(name)", at: tunIdx + 1)
            changed = true
        }
        if changed {
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - DNS resolver interface pins (config.yaml editing)

    /// Every `<address>#<utunN>` resolver binding in the on-disk config.
    ///
    /// mihomo's `server#interface` form is the only way to dial a peer's resolver
    /// over the peer's own tunnel once TUN has pinned egress to the physical NIC,
    /// so these pins are load-bearing — and they name an interface whose index the
    /// kernel may hand out differently after any reboot. Read-only; see
    /// `rebindDNSResolvers` for the repair.
    func dnsResolverBindings() -> [(resolver: String, iface: String)] {
        guard let text = try? String(contentsOfFile: configFilePath, encoding: .utf8) else { return [] }
        var out: [(String, String)] = []
        for match in Self.resolverPinPattern.matches(
            in: text, range: NSRange(text.startIndex..., in: text)
        ) {
            guard let r = Range(match.range(at: 1), in: text),
                  let i = Range(match.range(at: 2), in: text) else { continue }
            out.append((String(text[r]), String(text[i])))
        }
        return out
    }

    /// Repoint `<address>#<utunN>` pins at the interfaces in `map` (resolver →
    /// interface). Returns the number of pins rewritten; 0 means nothing to do.
    /// Callers own backup/validate/reload — this only edits the text.
    @discardableResult
    func rebindDNSResolvers(_ map: [String: String]) -> Int {
        let path = configFilePath
        guard !map.isEmpty,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        var changed = 0
        var out = text
        // Walk matches back-to-front so earlier ranges stay valid as we splice.
        let matches = Self.resolverPinPattern.matches(
            in: text, range: NSRange(text.startIndex..., in: text)
        )
        for match in matches.reversed() {
            guard let full = Range(match.range, in: out),
                  let r = Range(match.range(at: 1), in: text),
                  let i = Range(match.range(at: 2), in: text) else { continue }
            let resolver = String(text[r]), iface = String(text[i])
            guard let want = map[resolver], want != iface else { continue }
            out.replaceSubrange(full, with: "\(resolver)#\(want)")
            changed += 1
        }
        guard changed > 0 else { return 0 }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
        return changed
    }

    /// `<IPv4 address>#<utunN>`. Deliberately narrow: only utun pins rot with
    /// interface renumbering, and only addresses can be re-pinned without knowing
    /// the peer's naming scheme.
    private static let resolverPinPattern = try! NSRegularExpression(
        pattern: #"(\d{1,3}(?:\.\d{1,3}){3})#(utun\d+)"#
    )

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
        var inBlock = false
        var curIdx = -1
        var curNameIndent = -1

        func leadingSpaces(_ s: Substring) -> Int {
            var n = 0
            for c in s { if c == " " { n += 1 } else { break } }
            return n
        }
        func unquoted(_ s: Substring) -> String {
            String(s).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            // 空行不改变缩进状态。此前用 `!line.hasPrefix(" ")` 判断"是否退出
            // 缩进块"，但空行本身没有前导空格，会被误判为回到顶层——proxy-providers
            // 块内任意一个空行之后的 provider 就整体丢失（包括它的 url），
            // 只要该 provider 的 YAML 块里有一行空行分隔（很常见的手写习惯）就会踩到。
            if trimmed.isEmpty { continue }

            let indent = leadingSpaces(rawLine[rawLine.startIndex...])
            if indent == 0 {
                inBlock = rawLine.hasPrefix("proxy-providers:")
                curIdx = -1
                curNameIndent = -1
                continue
            }
            guard inBlock else { continue }

            if trimmed.hasSuffix(":"), curNameIndent == -1 || indent <= curNameIndent {
                // provider 名称行：块内第一层缩进，且不深于当前 provider 名称
                // （用相对层级而非写死的 "2 空格"，兼容手改文件的缩进宽度）。
                let name = unquoted(Substring(trimmed.dropLast()))
                if !name.isEmpty {
                    result.append((name, ""))
                    curIdx = result.count - 1
                    curNameIndent = indent
                }
            } else if curIdx >= 0, indent == curNameIndent + 2, trimmed.hasPrefix("url:") {
                // 只认"provider 名称缩进 + 1 层"的 url —— 排除 health-check 内嵌
                // 的 url（缩进 +2 层），不再靠写死的 "line.hasPrefix(\"    url:\")"。
                let url = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
                result[curIdx].1 = unquoted(Substring(url))
            }
        }
        return result.map { (name: $0.0, url: $0.1) }
    }

    /// 从 `proxy-groups:` 的 `use:`/`proxies:`（含内联 `[A, B]` 与逐行 `- A` 两种写法）
    /// 以及 `rules:` 里清除对 `names` 的所有引用。节点/订阅被删除后必须做这一步，
    /// 否则残留的悬空引用会让 `mihomo -t` 校验直接失败。
    ///
    /// 从 `writeProxyProviders()` 抽出来的独立函数——订阅删除和本地节点删除都要
    /// 用同一套清理逻辑，原先只有订阅那一份，本地节点直接复制一份出来只会两边
    /// 慢慢改出行为差异。
    static func stripReferences(to names: Set<String>, from lines: inout [String]) {
        guard !names.isEmpty else { return }
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
                    for d in names {
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
                    if names.contains(name) {
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
                        if names.contains(last) {
                            lines.remove(at: i)
                            continue
                        }
                    }
                }
            }
            i += 1
        }
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
        Self.stripReferences(to: deleted, from: &lines)

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

    // MARK: - proxies (顶层手动/本地节点, config.yaml editing)
    //
    // mihomo 原生的顶层 `proxies:` 数组——手动添加/粘贴分享链接/从订阅分叉出来的
    // 节点存在这里，与 `proxy-providers:`（订阅拉取）是完全独立的两个顶层键，互不
    // 覆盖。写入用"只改动目标条目所在的行区间"的定点 splice，而不是像
    // `writeProxyProviders` 那样整块重建——`proxies:` 里每一项的字段个数和结构
    // 因协议而异，整块重建必须先能完整还原任意结构才安全，成本远高于收益；定点
    // splice 只需要知道"这一项从哪一行开始、到哪一行结束"，不动的条目原样保留。
    //
    // 范围限定：只认识本 App 自己的新增/编辑表单会写出的 flat scalar 字段
    // （`localProxyKnownKeys`）。任何这个 App 不认识的内容——不管是未知的 flat
    // key，还是像 `ws-opts:` 这样的嵌套传输层配置——原样整行保留进 `extraLines`，
    // 编辑时原样写回，不解析也不丢弃。v1 表单本身不提供编辑 ws-opts/grpc-opts
    // 的入口（先只覆盖 TCP/TLS 直连的 vmess/vless/trojan/ss/hysteria2）。

    /// 顶层 `proxies:` 数组里的一项。
    struct LocalProxyEntry: Equatable {
        var name: String
        /// 本 App 认识的 flat scalar 字段，值已去掉包裹引号。
        var fields: [String: String]
        /// VLESS REALITY 的 `reality-opts:` 子块——目前唯一单独识别的嵌套结构。
        /// REALITY 在真实订阅里相当常见（"分叉订阅节点"这个功能本身就是为了处理
        /// 它），值得单独承载，不然编辑表单没法回显 public-key/short-id，
        /// 只能眼睁睁看着它们躺在不透明的 extraLines 里改不了。
        var realityPublicKey: String? = nil
        var realityShortId: String? = nil
        /// 这一项里本 App 不解析的原始行（未知 flat key + 除 reality-opts 外的
        /// 任意嵌套块，如 ws-opts），按文件中原始顺序保留，写回时原样追加。
        var extraLines: [String]
    }

    /// 手动节点表单目前覆盖的 flat 字段全集（vmess/vless/trojan/ss/hysteria2 的
    /// 并集）。不在这个集合里的 key 一律进 `extraLines`，不会被表单静默吞掉。
    static let localProxyKnownKeys: Set<String> = [
        "type", "server", "port", "uuid", "password", "cipher", "alterId",
        "flow", "sni", "servername", "tls", "skip-cert-verify", "udp", "alpn",
        "obfs", "obfs-password", "up", "down", "client-fingerprint",
    ]

    /// 解析顶层 `proxies:` 块。跳过空行的原因同 `proxyProviders()`——空行没有
    /// 前导空格，用 `!hasPrefix(" ")` 判断"是否退出缩进块"会被空行误判为回到顶层。
    func localProxies() -> [LocalProxyEntry] {
        guard let text = try? String(contentsOfFile: configFilePath, encoding: .utf8) else { return [] }
        var result: [LocalProxyEntry] = []
        var inBlock = false
        var cur: LocalProxyEntry? = nil
        var inRealityOpts = false

        func leadingSpaces(_ s: Substring) -> Int {
            var n = 0
            for c in s { if c == " " { n += 1 } else { break } }
            return n
        }
        // 空格必须和引号一起纳入 trim 字符集：`- name: "X"` 冒号后是 ` "X"`，
        // 只 trim 引号的话，最外层的空格会挡住 trim 从两端往内推进，引号永远
        // 剥不掉——这个 bug 用真实文件跑过一遍才发现，之前只看编译通过。
        func unquoted(_ s: Substring) -> String {
            String(s).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        func flush() {
            if let c = cur, !c.name.isEmpty { result.append(c) }
            cur = nil
        }
        func assign(_ key: String, _ value: String, _ rawLine: String) {
            if key == "name" { cur?.name = value }
            else if Self.localProxyKnownKeys.contains(key) { cur?.fields[key] = value }
            else { cur?.extraLines.append(rawLine) }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let indent = leadingSpaces(rawLine[rawLine.startIndex...])
            if indent == 0 {
                if inBlock { flush() }
                inBlock = rawLine.hasPrefix("proxies:")
                continue
            }
            guard inBlock else { continue }

            if indent == 2, trimmed.hasPrefix("- ") {
                flush()
                cur = LocalProxyEntry(name: "", fields: [:], extraLines: [])
                let rest = trimmed.dropFirst(2)
                if let colon = rest.firstIndex(of: ":") {
                    let key = String(rest[rest.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = unquoted(rest[rest.index(after: colon)...])
                    assign(key, value, rawLine)
                }
                inRealityOpts = false
            } else if indent == 4, trimmed == "reality-opts:" {
                // 只识别这一个嵌套 key；进入后接下来 indent==6 的两行单独处理。
                inRealityOpts = true
            } else if indent == 6, inRealityOpts, let colon = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let value = unquoted(Substring(trimmed[trimmed.index(after: colon)...]))
                if key == "public-key" { cur?.realityPublicKey = value }
                else if key == "short-id" { cur?.realityShortId = value }
                else { cur?.extraLines.append(rawLine) }   // reality-opts 下的未知子键，原样保留
            } else if indent == 4, cur != nil, let colon = trimmed.firstIndex(of: ":") {
                inRealityOpts = false
                let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let value = unquoted(Substring(trimmed[trimmed.index(after: colon)...]))
                assign(key, value, rawLine)
            } else if indent > 4, cur != nil {
                inRealityOpts = false
                // 未识别的嵌套内容（如 ws-opts 的子字段）—— 原样保留。
                cur?.extraLines.append(rawLine)
            }
        }
        if inBlock { flush() }
        return result
    }

    /// 把已知字段渲染成一行 `key: value`；纯数字/布尔不加引号，其余加引号，
    /// 避免特殊字符（`:`、`#`、前导 0 等）被 YAML 误当成语法解析。
    private func yamlScalar(_ raw: String) -> String {
        if raw == "true" || raw == "false" || Int(raw) != nil { return raw }
        return "\"\(raw.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func entryLines(_ e: LocalProxyEntry) -> [String] {
        var lines = ["  - name: \(yamlScalar(e.name))"]
        // 固定顺序输出，方便人工比对 diff；顺序本身对 mihomo 无意义。
        let order = ["type", "server", "port", "uuid", "password", "cipher",
                     "alterId", "flow", "sni", "servername", "tls",
                     "skip-cert-verify", "udp", "alpn", "obfs", "obfs-password",
                     "up", "down", "client-fingerprint"]
        for key in order {
            guard let v = e.fields[key] else { continue }
            lines.append("    \(key): \(yamlScalar(v))")
        }
        // reality-opts 是唯一单独承载的嵌套块，两个字段都有值才发——只给
        // public-key 不给 short-id（反之亦然）对 REALITY 握手没有意义，写出去
        // 只会让 mihomo -t 校验失败，不如干脆不写，让节点退化成普通 TLS。
        if let pk = e.realityPublicKey, !pk.isEmpty,
           let sid = e.realityShortId, !sid.isEmpty {
            lines.append("    reality-opts:")
            lines.append("      public-key: \(yamlScalar(pk))")
            lines.append("      short-id: \(yamlScalar(sid))")
        }
        lines.append(contentsOf: e.extraLines)
        return lines
    }

    /// 定位顶层 `proxies:` 块里名为 `name` 的那一项的行区间
    /// （含 `- ` 起始行，到下一项 `- ` 起始行或本块结束之前，不含）。
    private func findProxyItemRange(_ lines: [String], name: String) -> Range<Int>? {
        guard let blockStart = lines.firstIndex(where: { $0.hasPrefix("proxies:") }) else { return nil }
        var i = blockStart + 1
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            let indent = lines[i].prefix(while: { $0 == " " }).count
            if indent == 0 { break }
            if indent == 2, trimmed.hasPrefix("- ") {
                var itemName: String? = nil
                let rest = trimmed.dropFirst(2)
                if rest.hasPrefix("name:") {
                    itemName = String(rest.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                }
                var end = i + 1
                while end < lines.count {
                    let t2 = lines[end].trimmingCharacters(in: .whitespaces)
                    if t2.isEmpty { end += 1; continue }
                    let ind2 = lines[end].prefix(while: { $0 == " " }).count
                    if ind2 <= 2 { break }
                    if itemName == nil, ind2 == 4, t2.hasPrefix("name:") {
                        itemName = String(t2.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    }
                    end += 1
                }
                if itemName == name { return i..<end }
                i = end
                continue
            }
            i += 1
        }
        return nil
    }

    /// 新增或原地替换（按 name 匹配）一个本地节点条目，定点 splice，不影响其它条目。
    @discardableResult
    func upsertLocalProxy(_ entry: LocalProxyEntry) -> Bool {
        guard let text = try? String(contentsOfFile: configFilePath, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\n")
        let newLines = entryLines(entry)

        if let range = findProxyItemRange(lines, name: entry.name) {
            lines.replaceSubrange(range, with: newLines)
        } else if let blockStart = lines.firstIndex(where: { $0.hasPrefix("proxies:") }) {
            var end = blockStart + 1
            while end < lines.count {
                let t = lines[end].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { end += 1; continue }
                if lines[end].prefix(while: { $0 == " " }).count == 0 { break }
                end += 1
            }
            lines.insert(contentsOf: newLines, at: end)
        } else {
            // 顶层还没有 proxies: 块 —— 插在 proxy-providers:（如果有）之后，
            // 否则插在 proxy-groups: 之前，与 writeProxyProviders 的插入策略一致。
            let insertAt: Int
            if let ppStart = lines.firstIndex(where: { $0.hasPrefix("proxy-providers:") }) {
                var end = ppStart + 1
                while end < lines.count {
                    let t = lines[end].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || lines[end].hasPrefix(" ") || lines[end].hasPrefix("\t") { end += 1; continue }
                    break
                }
                insertAt = end
            } else {
                insertAt = lines.firstIndex(where: { $0.hasPrefix("proxy-groups:") }) ?? lines.count
            }
            lines.insert(contentsOf: ["proxies:"] + newLines + [""], at: insertAt)
        }

        return (try? lines.joined(separator: "\n").write(toFile: configFilePath, atomically: true, encoding: .utf8)) != nil
    }

    /// 删除一个本地节点条目（定点 splice），并清理所有策略组 / rules 对它的引用，
    /// 避免删完节点后组里留下悬空引用导致 `mihomo -t` 校验失败。
    @discardableResult
    func removeLocalProxy(named name: String) -> Bool {
        guard let text = try? String(contentsOfFile: configFilePath, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\n")
        if let range = findProxyItemRange(lines, name: name) {
            lines.removeSubrange(range)
            // proxies: 块因此变空的话，把空块本身也删掉，避免留下裸 "proxies:"。
            if let blockStart = lines.firstIndex(where: { $0.hasPrefix("proxies:") }) {
                var end = blockStart + 1
                var hasContent = false
                while end < lines.count {
                    let t = lines[end].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { end += 1; continue }
                    if lines[end].prefix(while: { $0 == " " }).count == 0 { break }
                    hasContent = true
                    end += 1
                }
                if !hasContent { lines.removeSubrange(blockStart..<end) }
            }
        }
        Self.stripReferences(to: [name], from: &lines)
        return (try? lines.joined(separator: "\n").write(toFile: configFilePath, atomically: true, encoding: .utf8)) != nil
    }

    /// 把 `name` 加进指定策略组的 `proxies:` 列表（block 语法 `- name`）。
    /// 已经引用过就不重复添加；找不到目标组返回 false。
    @discardableResult
    func addProxyToGroup(_ name: String, group: String) -> Bool {
        guard let text = try? String(contentsOfFile: configFilePath, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\n")
        guard let pgIdx = lines.firstIndex(where: { $0.hasPrefix("proxy-groups:") }) else { return false }

        var i = pgIdx + 1
        var groupStart: Int? = nil
        var groupEnd = lines.count
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            let indent = lines[i].prefix(while: { $0 == " " }).count
            if indent == 0 { break }
            if trimmed.hasPrefix("- name:") {
                let gname = trimmed.dropFirst(7).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if groupStart != nil { groupEnd = i; break }
                if gname == group { groupStart = i }
            }
            i += 1
        }
        guard let gs = groupStart else { return false }
        if groupEnd == lines.count {
            var end = gs + 1
            while end < lines.count {
                let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { end += 1; continue }
                if lines[end].prefix(while: { $0 == " " }).count == 0 { break }
                end += 1
            }
            groupEnd = end
        }

        for j in gs..<groupEnd {
            let t = lines[j].trimmingCharacters(in: .whitespaces)
            if t == "- \(name)" || t == "- \"\(name)\"" { return true }
        }

        if let proxiesIdx = lines[gs..<groupEnd].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "proxies:" }) {
            // 不能直接用循环 break 时的下标插入：组与组之间常有空行分隔，
            // "跳过空行→在下一行判断缩进"会一路跳过本组子列表的空行分隔符，
            // 停在下一个组的边界上，把新节点插到空行*之后*而不是紧跟在最后一个
            // 已有条目之后。改为记录"最后一次仍在子列表缩进内的真实行"，插它后面。
            let pIndent = lines[proxiesIdx].prefix(while: { $0 == " " }).count
            var lastInScope = proxiesIdx
            var scan = proxiesIdx + 1
            while scan < groupEnd {
                let t = lines[scan].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { scan += 1; continue }
                if lines[scan].prefix(while: { $0 == " " }).count <= pIndent { break }
                lastInScope = scan
                scan += 1
            }
            lines.insert("\(String(repeating: " ", count: pIndent + 2))- \(name)", at: lastInScope + 1)
        } else {
            var baseIndent = "    "
            for k in gs..<groupEnd {
                if lines[k].trimmingCharacters(in: .whitespaces).hasPrefix("- name:") {
                    baseIndent = String(lines[k].prefix(while: { $0 == " " }))
                }
            }
            lines.insert(contentsOf: ["\(baseIndent)proxies:", "\(baseIndent)  - \(name)"], at: groupEnd)
        }

        return (try? lines.joined(separator: "\n").write(toFile: configFilePath, atomically: true, encoding: .utf8)) != nil
    }

    /// 第一个 `type: select` 策略组的名字——本地节点默认接入这里，而不是
    /// `proxy-groups[0]`（通常是 url-test 类型，按延迟自动轮换；用户手动加的
    /// 节点应该是"我明确要选它"，只有 select 类型的组才是用户真正能挑它的地方）。
    /// 没有 select 类型的组时返回 nil，调用方回落到 `proxy-groups[0]`。
    func firstSelectGroupName() -> String? {
        guard let text = try? String(contentsOfFile: configFilePath, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let pgIdx = lines.firstIndex(where: { $0.hasPrefix("proxy-groups:") }) else { return nil }

        var i = pgIdx + 1
        var pendingName: String? = nil
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            if lines[i].prefix(while: { $0 == " " }).count == 0 { break }
            if trimmed.hasPrefix("- name:") {
                pendingName = trimmed.dropFirst(7).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            } else if trimmed.hasPrefix("type:"), trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces) == "select" {
                return pendingName
            }
            i += 1
        }
        return nil
    }

    /// 在某个 proxy-provider 的本地缓存文件（`./providers/<name>.yaml`）里，找到
    /// 名字匹配 `nodeName` 的那条原始分享链接——fork-on-edit 用它重建完整连接参数。
    ///
    /// 这个缓存文件通常不是 mihomo 原生的 `proxies:` YAML：大多数订阅服务器返回
    /// 的是 base64 编码、换行分隔的分享链接列表（v2rayN 惯例），mihomo 在内部转换
    /// 成自己的结构，但落盘缓存就是原始响应体，没有转换过。这里按同样的约定解码；
    /// 如果响应本身就是明文链接（少数订阅服务器不做 base64），原样按行处理也一样
    /// 能工作，不需要区分对待。
    func shareLinkForProviderNode(providerName: String, nodeName: String) -> String? {
        let path = appSupport + "/providers/\(providerName).yaml"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = Self.looseBase64Decode(trimmed) ?? trimmed
        for line in text.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, let hashIdx = l.firstIndex(of: "#") else { continue }
            let fragRaw = String(l[l.index(after: hashIdx)...])
            let frag = fragRaw.removingPercentEncoding ?? fragRaw
            if frag == nodeName { return l }
        }
        return nil
    }

    /// URL-safe / 标准 base64 都试，并补齐缺失的 padding。整个文件按一坨 base64
    /// 尝试解码——不是任意字符串都能撞上有效 base64，解不出来就是 nil，调用方
    /// 据此判断"这不是 base64 包装，按明文处理"。
    private static func looseBase64Decode(_ s: String) -> String? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = t.count % 4
        if padding > 0 { t += String(repeating: "=", count: 4 - padding) }
        guard let data = Data(base64Encoded: t) else { return nil }
        return String(data: data, encoding: .utf8)
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
    ///
    /// Returns the previous value when an existing *non-empty* secret was
    /// replaced (as opposed to one being newly added where none existed).
    /// Callers use this to push the rewritten file to a kernel that may
    /// already be running under the old secret (crash / force-quit / a root
    /// TUN kernel outliving a plain user-mode quit) — rewriting the file
    /// alone never reaches that live process, so the app and kernel would
    /// otherwise permanently disagree on which secret is correct.
    @discardableResult
    func hardenControllerConfig() -> String? {
        let path = configFilePath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        var hasController = false, hasSecret = false, changed = false
        var replacedSecret: String?

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
                if Self.isReplaceableSecret(sec) {
                    lines[i] = "secret: \(Self.randomSecret())"; changed = true
                    if !sec.isEmpty { replacedSecret = sec }
                } else if Self.isWeakSecret(sec) {
                    onLog?("控制面密钥强度较低，建议在「网络 → 内核 → API 控制」中更换（不会自动替换）")
                }
            }
        }

        if !hasController { lines.insert("external-controller: 127.0.0.1:9090", at: 0); changed = true }
        if !hasSecret { lines.insert("secret: \(Self.randomSecret())", at: 0); changed = true }

        if changed {
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        return replacedSecret
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

    /// Whether a control-plane secret is one *we* put there and may therefore
    /// replace on the user's behalf.
    ///
    /// The controller binds loopback, so the threat model is any local process:
    /// a secret that ships as a known constant lets anything on the machine
    /// drive the kernel (switch nodes, rewrite config, read every connection).
    /// That is worth fixing automatically — nobody chose `clashhalo`, it is just
    /// what the initial config template writes.
    ///
    /// What is NOT worth fixing automatically is a secret the user deliberately
    /// configured. A shape-based "too short / too few character classes" rule
    /// ran on every launch and silently rewrote such secrets, so any external
    /// client that had stored one (Zashboard, a bookmark, another dashboard)
    /// broke after every single app restart with no indication why. Judging the
    /// user's own choice is not this function's job; only the placeholder is.
    static func isReplaceableSecret(_ s: String) -> Bool {
        let v = s.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return true }
        // Exact matches only — a substring rule would catch user secrets that
        // merely happen to contain one of these words.
        let shipped = ["clashhalo", "clash", "meta", "mihomo", "123456", "password", "admin"]
        return shipped.contains(v.lowercased())
    }

    /// Advisory-only shape check: reported in the log so a user who picked a
    /// guessable secret finds out, without the app overriding their choice.
    static func isWeakSecret(_ s: String) -> Bool {
        let v = s.trimmingCharacters(in: .whitespaces)
        if v.count < 16 { return true }

        let lower = v.lowercased()
        let known = ["clashhalo", "clash", "meta", "mihomo", "admin", "password",
                     "secret", "qwer", "asdf", "zxcv", "1234", "abcd", "test"]
        if known.contains(where: { lower.contains($0) }) { return true }

        // Require a mix: an all-digit or all-letter string of any length is a
        // poor secret even when it is long.
        var classes = 0
        if v.rangeOfCharacter(from: .decimalDigits) != nil { classes += 1 }
        if v.rangeOfCharacter(from: CharacterSet.lowercaseLetters) != nil { classes += 1 }
        if v.rangeOfCharacter(from: CharacterSet.uppercaseLetters) != nil { classes += 1 }
        if v.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { classes += 1 }
        return classes < 3
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
    /// Pass `preferRoot: false` for system-proxy-only starts that must not pay
    /// the root-upgrade restart cost.
    func ensureRunning(preferRoot: Bool = true) {
        Task { await ensureRunningAsync(preferRoot: preferRoot) }
    }

    /// Start the kernel if it's not responding.
    /// - Parameter preferRoot: When false, skip "reachable user-mode → restart as
    ///   root" and root-first spawn. System proxy only needs mixed-port/API;
    ///   forcing a root restart made the toggle feel multi-second dead and raced
    ///   helper XPC under load.
    ///
    /// Root start goes through a fresh XPC connection (`callStartMihomo`); the
    /// cached `helper()` proxy is known to silently drop start calls after
    /// long-lived use. Awaitable so TUN / restart paths can wait for the helper
    /// reply instead of racing a detached Task and timing out with a false
    /// "权限不足".
    /// - Parameter allowRootUpgradeRestart: whether an *already running* user-mode
    ///   kernel may be restarted to gain root. Starting fresh as root is cheap and
    ///   is what keeps the data directory under a single owner; tearing down a
    ///   working kernel just to change identity is not — it costs a full reload
    ///   and made the system-proxy toggle feel dead (v1.1.4). TUN/gateway pass
    ///   true because root is a hard requirement for them; the system proxy,
    ///   which only needs a listening mixed-port, passes false.
    func ensureRunningAsync(preferRoot: Bool = true, allowRootUpgradeRestart: Bool = true) async {
        await api.probe()

        // If reachable, optionally upgrade to root (TUN/gateway paths only).
        if api.reachable {
            if preferRoot && allowRootUpgradeRestart && isRoot && !runningAsRoot {
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

        // Prefer root only when the caller wants it AND the helper is reachable.
        // A stale isRoot=true after stop/cascade used to make the start path a
        // silent no-op when the cached XPC proxy dropped the call.
        if preferRoot && isRoot {
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

        // User-mode start (primary for system proxy, or fallback).
        if userProcess?.isRunning == true {
            return
        }
        // Another session may already own mihomo; re-probe before spawning so we
        // don't fail on a busy mixed-port.
        await api.probe(timeout: 0.3)
        if api.reachable { return }

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
    ///
    /// Shows a Chinese pre-auth explanation dialog before the system password
    /// sheet so the user understands *why* elevation is needed. Upgrade is a
    /// single in-place replace (one password prompt), not uninstall+install.
    @discardableResult
    func checkAndUpgradeHelperIfNeeded() async -> Bool {
        if !isRoot {
            isRoot = await XPCManager.shared.verifyConnectivity()
        }
        if !isRoot {
            // Missing binary in the app bundle is a build packaging issue, not a
            // permission denial — surface that before prompting for admin.
            let helperSrc = Bundle.main.bundlePath + "/Contents/MacOS/com.clashhalo.helper"
            if !FileManager.default.fileExists(atPath: helperSrc) {
                onLog?("App 内未嵌入 Helper 二进制，无法安装特权服务。请用 Scripts/build-debug.sh 或 make.sh 构建后再试。")
                return false
            }
            onLog?("未检测到特权服务，开始自动安装…")
            let ok = await installPrivileged(prompt: XPCManager.defaultInstallPrompt)
            if ok {
                isRoot = await waitForHelperConnectivity()
                if isRoot {
                    onLog?("特权服务安装成功 ✓")
                    refreshHelperVersion()
                } else {
                    onLog?("特权服务已安装但尚未连通，稍后重试")
                }
            } else {
                // installDaemon returns false for auth cancel, missing source
                // (already guarded above), or launchctl bootstrap failure.
                onLog?("特权服务安装失败（授权取消、bootstrap 失败，或 Helper 二进制不可用）")
            }
            return isRoot
        }
        // The version may not be fetched yet (pollStatus runs every 5s; this check
        // fires at startup). Actively fetch it first so a needed upgrade isn't
        // skipped by the "?" guard and silently deferred forever.
        if helperVersion == "?" || helperVersion.isEmpty {
            if let v = await fetchHelperVersion() { helperVersion = v }
        }
        guard helperVersion != "?", !helperVersion.isEmpty else { return true }
        guard helperVersion != Self.kExpectedHelperVersion else { return true }

        let from = helperVersion
        let to = Self.kExpectedHelperVersion
        onLog?("特权服务 v\(from) 低于预期 v\(to)，开始自动更新…")
        let prompt = XPCManager.upgradePrompt(from: from, to: to)
        let ok = await XPCManager.shared.upgradeDaemon(prompt: prompt)
        if ok {
            isRoot = await waitForHelperConnectivity()
            if isRoot {
                refreshHelperVersion()
                onLog?("特权服务已更新至 v\(to)")
            } else {
                onLog?("特权服务已替换但尚未连通，稍后重试")
            }
        } else {
            onLog?("特权服务自动更新失败或已取消，请前往「设置→权限」手动更新")
        }
        return ok && isRoot
    }

    /// Wait up to ~4s for the freshly installed helper to accept XPC.
    private func waitForHelperConnectivity(attempts: Int = 8) async -> Bool {
        for _ in 0..<attempts {
            if await XPCManager.shared.verifyConnectivity() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
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

    /// Install the privileged helper LaunchDaemon.
    /// - Parameter prompt: Optional pre-auth explanation. Defaults to the
    ///   shared install prompt when nil.
    @discardableResult
    func installPrivileged(prompt: PrivilegedPromptContent? = nil) async -> Bool {
        let ok = await XPCManager.shared.installDaemon(prompt: prompt)
        if ok { isRoot = true }
        return ok
    }

    @discardableResult
    func uninstallPrivileged(prompt: PrivilegedPromptContent? = nil) async -> Bool {
        let ok = await XPCManager.shared.uninstallDaemon(prompt: prompt)
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
    ///
    /// All privilege/process work is bounded: REST shutdown uses a short
    /// URLSession timeout, Helper stop uses `callStopMihomo` (hard XPC timeout),
    /// and killall runs detached. Never block MainActor on an unbounded XPC reply
    /// — that was the kernel-switch hang that left system proxy pointing at a
    /// dead 127.0.0.1 and black-holed the whole Mac.
    ///
    /// Fast path: REST shutdown / SIGTERM usually kills the process within a few
    /// hundred ms. Confirm the exit via pgrep and skip the helper XPC round-trip
    /// + killall entirely — this also covers "kernel already dead" callers
    /// (restart after crash, kernel switch) that used to pay the full stop cost.
    func stopKernel() async {
        var gracefulAttempted = false
        if let proc = userProcess, proc.isRunning {
            proc.terminate()
            gracefulAttempted = true
        }
        userProcess = nil

        // Attempt graceful shutdown via REST API if reachable (hard 1.5s budget).
        if api.reachable, let url = URL(string: "http://\(api.host):\(api.port)/shutdown") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 1.5
            if !api.secret.isEmpty { req.setValue("Bearer \(api.secret)", forHTTPHeaderField: "Authorization") }
            _ = try? await URLSession.shared.data(for: req)
            gracefulAttempted = true
        }

        // With a graceful channel (SIGTERM / REST shutdown) the exit lands within
        // a few hundred ms — worth polling for. Without one, either nothing is
        // running (single quick pgrep confirms) or the process needs the helper
        // force-stop anyway — don't stall in front of it.
        let gone = await Self.waitForMihomoExit(deadline: gracefulAttempted ? 1.2 : 0.15)
        if !gone {
            // Helper stop with hard timeout, then killall safety net — both off MainActor.
            await Task.detached(priority: .userInitiated) {
                _ = await XPCManager.shared.callStopMihomo(timeout: 4.0)
                let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                t.arguments = ["-9", "mihomo"]
                t.standardOutput = Pipe(); t.standardError = Pipe()
                try? t.run(); t.waitUntilExit()
            }.value
        }

        // Kernel is gone — clear the root-mode ownership flag. Leaving it true
        // after stop makes refreshConfigs re-arm tunOn from a stale in-flight
        // /configs response (enable && runningAsRoot && hasInterface).
        runningAsRoot = false
        api.reachable = false

        // Give it a moment to release ports / the binary. On the fast path the
        // confirmed process exit already released them — no extra wait needed.
        if !gone {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Poll (100ms steps) until no `mihomo` process remains, any owner.
    /// Returns true once pgrep confirms the process table is clear; false when
    /// the deadline passes with the kernel still alive (caller falls back to
    /// the helper-stop + killall path). Only pgrep status 1 ("no match") counts
    /// as gone — exec/usage errors keep polling so we never skip the safety net
    /// on a false negative.
    nonisolated static func waitForMihomoExit(deadline: TimeInterval) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let end = Date().addingTimeInterval(deadline)
            while true {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                p.arguments = ["-x", "mihomo"]
                p.standardOutput = Pipe(); p.standardError = Pipe()
                if (try? p.run()) != nil {
                    p.waitUntilExit()
                    if p.terminationStatus == 1 { return true }
                }
                if Date() >= end { return false }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }.value
    }

    /// Stop and restart the kernel. Awaits the start attempt so callers that
    /// immediately `waitForKernelReady` do not race a fire-and-forget Task.
    ///
    /// - Parameter preferRoot: defaults to true because the internal callers
    ///   (TUN enable, the root-upgrade path in `ensureRunningAsync`) restart
    ///   precisely *in order to* obtain a root kernel. A plain user-facing
    ///   "restart kernel" with TUN/gateway off should pass false — otherwise the
    ///   restart silently escalates a perfectly good user-mode kernel to root,
    ///   paying the helper round-trip and running the proxy with privileges the
    ///   current mode does not need.
    func restart(preferRoot: Bool = true) async {
        await stopKernel()
        await ensureRunningAsync(preferRoot: preferRoot)
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

    /// Run a shell snippet with administrator privileges.
    ///
    /// - Parameter prompt: Optional explanation presented in a **native** pre-auth
    ///   dialog (`PrivilegedPrompt`) *before* the system password sheet. The OS
    ///   password dialog cannot carry a custom body, so the install/upgrade
    ///   reason is surfaced here first. Declining aborts without elevating —
    ///   osascript is only reached after an explicit confirm.
    ///
    ///   The dialog used to be an AppleScript `display dialog`, whose generic
    ///   caution styling clashed with the rest of the app; the explanation is now
    ///   SwiftUI built from design tokens, and the only remaining AppleScript is
    ///   the privileged `do shell script` itself (no user text is interpolated
    ///   into it any more, removing that escaping surface entirely).
    static func runAdmin(_ shell: String, prompt: PrivilegedPromptContent? = nil) async -> Bool {
        if let prompt {
            let confirmed = await PrivilegedPrompt.confirm(prompt)
            guard confirmed else { return false }
        }

        let escapedShell = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escapedShell)\" with administrator privileges"

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
