import Foundation
import Combine
import SwiftUI

@MainActor final class AppModel: ObservableObject {
    let api = MihomoClient.shared
    let engine = EngineControl.shared
    let store = ConfigStore()
    let history = TrafficHistory()

    /// Switch the active config profile: persist as engine config + hot-apply.
    func activateProfile(_ id: String) {
        guard let content = store.makeActiveContent(id) else { showToast("配置为空"); return }
        let name = store.profiles.first { $0.id == id }?.name ?? ""
        Task {
            let (ok, err) = await engine.setConfig(content)
            showToast(ok ? "已切换配置「\(name)」" : "配置错误：\(err ?? "")，已回滚")
            if ok { await reconnect() }
        }
    }

    // Navigation + theme
    @Published var route = "dashboard"
    @AppStorage("ui.dark") var dark = true
    @AppStorage("ui.accent") var accentRaw = "green"
    var accent: Color {
        let colors: [String: Color] = [
            "green": Color(hex: "19c37d"),
            "blue": .blue,
            "purple": .purple,
            "orange": .orange
        ]
        return colors[accentRaw] ?? Color(hex: "19c37d")
    }

    // Connection status
    @Published var reachable = false
    @Published var version = "?"
    @Published var mode = "rule"          // rule / global / direct
    @Published var memory: Int64 = 0
    @Published var uploadTotal: Int64 = 0
    @Published var downloadTotal: Int64 = 0

    // Proxies
    @Published var groups: [ProxyGroup] = []
    @Published var nodes: [String: Node] = [:]    // name → node
    @Published var testing: Set<String> = []

    // Connections
    @Published var conns: [Conn] = []
    @Published var dash = DashStats()   // precomputed once per snapshot (perf)
    private var prevConnBytes: [String: (up: Int64, down: Int64)] = [:]

    // Logs
    @Published var logs: [Log] = []
    private var logBuffer: [Log] = []
    private var logFlushTimer: Timer?
    private var logSeq = 0

    // Traffic chart (rolling window of download bytes/s)
    @Published var downSeries: [Double] = Array(repeating: 0, count: 120)
    @Published var upSeries: [Double] = Array(repeating: 0, count: 120)
    @Published var curDown: Int64 = 0
    @Published var curUp: Int64 = 0

    // Config
    @Published var configs: [String: Any] = [:]

    // Master switches
    @Published var systemProxyOn = false
    @Published var tunOn = false

    // Dashboard session aggregates
    @Published var closedConns = 0
    @Published var appMemoryMB = 0.0
    private var seenConnIDs = Set<String>()
    private var lastDownTotal: Int64 = 0

    // Toast
    @Published var toast: String?

    private var trafficWS: WSHandle?
    private var connWS: WSHandle?
    private var logWS: WSHandle?
    private var pollTask: Task<Void, Never>?

    // MARK: Lifecycle

    func start() {
        engine.ensureInstalled()   // first-run: install bundled engine + LaunchAgent
        store.load()
        history.load()
        logFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushLogs() }
        }
        Task { await reconnect() }
    }

    @Published var engineManaged = false   // true when our launchd engine is hosting the kernel
    @Published var engineUptime: Int64 = 0

    func reconnect() async {
        stopStreams()

        // Prefer the ClashPow engine: discover its embedded controller endpoint.
        if let ctl = await engine.refresh() {
            engineManaged = true
            engineUptime = engine.uptimeSec
            let parts = ctl.addr.split(separator: ":")
            if parts.count == 2 { api.host = String(parts[0]); api.port = Int(parts[1]) ?? api.port }
            api.secret = ctl.secret
        } else {
            engineManaged = false
        }

        await api.probe()
        reachable = api.reachable
        version = api.version
        guard reachable else {
            Task { try? await Task.sleep(nanoseconds: 3_000_000_000); await reconnect() }
            return
        }
        startStreams()
        startPolling()
    }

    private func startStreams() {
        trafficWS = api.stream("/traffic", type: TrafficTick.self) { [weak self] t in
            self?.onTraffic(t)
        }
        connWS = api.stream("/connections", type: ConnectionsSnapshot.self) { [weak self] s in
            self?.onConnections(s)
        }
        logWS = api.stream("/logs?level=info", type: LogTick.self) { [weak self] l in
            self?.onLog(l)
        }
    }

    private func stopStreams() {
        trafficWS?.cancel(); connWS?.cancel(); logWS?.cancel()
        trafficWS = nil; connWS = nil; logWS = nil
        pollTask?.cancel(); pollTask = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.reachable {
                await self.refreshProxies()
                await self.refreshConfigs()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // MARK: Stream handlers

    private func onTraffic(_ t: TrafficTick) {
        // Only publish when the rounded rate actually changes, to avoid churning
        // the whole view tree every tick. The chart itself reads the mmap file.
        if t.up != curUp { curUp = t.up }
        if t.down != curDown { curDown = t.down }
    }

    private func onConnections(_ s: ConnectionsSnapshot) {
        uploadTotal = s.uploadTotal; downloadTotal = s.downloadTotal
        if let m = s.memory { memory = m }
        let items = s.connections ?? []
        var next: [Conn] = []
        var bytes: [String: (up: Int64, down: Int64)] = [:]
        var activeIDs = Set<String>()
        let hour = Calendar.current.component(.hour, from: Date())
        for c in items {
            activeIDs.insert(c.id); seenConnIDs.insert(c.id)
            let prev = prevConnBytes[c.id]
            let upRate = prev.map { max(0, c.upload - $0.up) } ?? 0
            let downRate = prev.map { max(0, c.download - $0.down) } ?? 0
            bytes[c.id] = (c.upload, c.download)
            // attribute this connection's byte delta to its category → history
            let cat = (c.chains.first == "DIRECT" || c.chains.contains("DIRECT")) ? "direct"
                    : (c.chains.first == "REJECT" || c.chains.contains("REJECT")) ? "reject" : "proxy"
            history.record(category: cat, down: Int64(downRate), up: Int64(upRate), hour: hour)
            next.append(Conn(
                id: c.id,
                host: c.metadata.host?.isEmpty == false ? c.metadata.host! : (c.metadata.destinationIP ?? "?"),
                dstIP: c.metadata.destinationIP ?? "?",
                srcIP: c.metadata.sourceIP ?? "?",
                port: c.metadata.destinationPort ?? "",
                network: c.metadata.network.uppercased(),
                process: c.metadata.process ?? "—",
                chain: c.chains.reversed().joined(separator: " → "),
                group: c.chains.last ?? "?",
                node: c.chains.first ?? "?",
                rule: c.rulePayload.isEmpty ? c.rule : "\(c.rule),\(c.rulePayload)",
                ruleType: c.rule,
                up: c.upload, down: c.download,
                upRate: upRate, downRate: downRate,
                start: c.start
            ))
        }
        prevConnBytes = bytes
        conns = next.sorted { $0.downRate + $0.upRate > $1.downRate + $1.upRate }
        dash = Self.computeDash(next)   // single pass, once per snapshot

        // closed-connection count (this session) = seen − currently-active
        closedConns = max(0, seenConnIDs.count - activeIDs.count)
        history.flushIfNeeded()
        lastDownTotal = s.downloadTotal
        // app RSS
        appMemoryMB = Double(Self.residentMemoryBytes()) / 1_000_000
    }

    /// Single-pass dashboard aggregation (runs once per connections snapshot,
    /// not per SwiftUI render — the key fix for dashboard stutter).
    static func computeDash(_ conns: [Conn]) -> DashStats {
        var pg = [String: Double](), hosts = [String: Double](), nodes = [String: Double]()
        var srcs = [String: Double](), procs = [String: Double](), rules = [String: Double]()
        var targets = [String: Double]()
        var direct = 0.0, proxy = 0.0, reject = 0.0
        var hostSet = Set<String>()
        func isPrivate(_ ip: String) -> Bool {
            ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.hasPrefix("172.16.") ||
            ip.hasPrefix("198.18.") || ip.hasPrefix("127.") || ip.hasPrefix("fd") || ip == "?"
        }
        for c in conns {
            let b = Double(c.up + c.down)
            if c.group != "?" && !c.group.isEmpty { pg[c.group, default: 0] += b }
            if c.host != "?" { hosts[c.host, default: 0] += b; hostSet.insert(c.host) }
            if c.node != "?" { nodes[c.node, default: 0] += b }
            if c.srcIP != "?" { srcs[c.srcIP, default: 0] += b }
            if c.process != "—" { procs[c.process, default: 0] += b }
            rules[c.ruleType, default: 0] += 1
            switch c.category { case "direct": direct += b; case "reject": reject += b; default: proxy += b }
            let tk = c.category == "reject" ? "拦截" : (isPrivate(c.dstIP) ? "内网" : "公网")
            targets[tk, default: 0] += b
        }
        func top(_ m: [String: Double]) -> [Rank] {
            m.sorted { $0.value > $1.value }.prefix(5).map { Rank(name: $0.key, value: $0.value) }
        }
        var d = DashStats()
        d.policyGroups = top(pg); d.hosts = top(hosts); d.nodes = top(nodes)
        d.sources = top(srcs); d.procs = top(procs); d.rules = top(rules); d.targets = top(targets)
        d.directBytes = direct; d.proxyBytes = proxy; d.rejectBytes = reject
        d.uniqueHosts = hostSet.count
        return d
    }

    /// Resident set size of this process (bytes) via mach task_info.
    static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    private static let logDF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    private func onLog(_ l: LogTick) {
        // Buffer; a 0.5s timer flushes to @Published in one batch so a chatty
        // log stream doesn't re-render the whole UI on every line.
        logSeq += 1
        logBuffer.append(Log(id: logSeq, time: Self.logDF.string(from: Date()), level: l.type, text: l.payload))
    }
    private func flushLogs() {
        guard !logBuffer.isEmpty else { return }
        logs.append(contentsOf: logBuffer)
        logBuffer.removeAll(keepingCapacity: true)
        if logs.count > 500 { logs = Array(logs.suffix(500)) }
    }

    // MARK: Polling

    /// Parse the order of proxy-groups from the active profile's YAML text.
    private func parseProxyGroupsOrder(from yaml: String) -> [String] {
        var order: [String] = []
        guard let range = yaml.range(of: #"(?m)^proxy-groups:\s*$"#, options: .regularExpression) else {
            return []
        }
        let sub = yaml[range.upperBound...]
        var groupBlock = ""
        if let endRange = sub.range(of: #"(?m)^\S+:"#, options: .regularExpression) {
            groupBlock = String(sub[..<endRange.lowerBound])
        } else {
            groupBlock = String(sub)
        }
        let pattern = #"-\s*name:\s*["']?([^"'\n\r]+)["']?"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let ns = groupBlock as NSString
            let matches = regex.matches(in: groupBlock, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches {
                if m.numberOfRanges >= 2 {
                    let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    order.append(name)
                }
            }
        }
        return order
    }

    func refreshProxies() async {
        guard let p = try? await api.fetchProxies() else { return }
        var gs: [ProxyGroup] = []
        var ns: [String: Node] = [:]
        for (name, e) in p.proxies {
            if let all = e.all {
                gs.append(ProxyGroup(id: name, name: name, type: e.type, now: e.now ?? "", all: all))
            } else {
                let delay = e.history?.last?.delay ?? 0
                ns[name] = Node(id: name, name: name, type: e.type, delay: delay)
            }
        }
        // Preserve existing measured delays for nodes that report 0 now
        for (k, v) in nodes where ns[k]?.delay == 0 && v.delay > 0 { ns[k]?.delay = v.delay }
        
        // Retrieve order from current active profile configuration file
        let yaml = store.content(store.activeID)
        let order = parseProxyGroupsOrder(from: yaml)
        
        // Sort groups strictly according to YAML order; unrecognized/GLOBAL go last
        groups = gs.sorted { a, b in
            let idxA = order.firstIndex(of: a.name) ?? 999
            let idxB = order.firstIndex(of: b.name) ?? 999
            if idxA != idxB {
                return idxA < idxB
            }
            if a.name == "GLOBAL" { return false }
            if b.name == "GLOBAL" { return true }
            return a.name < b.name
        }
        nodes = ns
    }

    func refreshConfigs() async {
        guard var c = try? await api.fetchConfigs() else { return }

        // Strictly enforce CDN GEO defaults if missing or empty
        var geo: [String: String] = [:]
        if let rawGeo = c["geox-url"] as? [String: Any] {
            for (k, v) in rawGeo { geo[k] = "\(v)" }
        }

        let defaults = [
            "mmdb": "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/country.mmdb",
            "asn": "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb",
            "geosite": "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat",
            "geoip": "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
        ]
        var changed = false
        for (k, v) in defaults {
            if (geo[k] ?? "").isEmpty || (geo[k] ?? "").contains("geodata.kelee.one") || (geo[k] ?? "").contains("github.com") {
                geo[k] = v
                changed = true
            }
        }
        if changed {
            c["geox-url"] = geo
            Task { await patch(["geox-url": geo]) }
        }
        configs = c
        if let m = c["mode"] as? String { mode = m }
        if let tun = c["tun"] as? [String: Any] { tunOn = (tun["enable"] as? Bool) == true }
    }

    // Master switches
    func toggleSystemProxy() {
        let on = !systemProxyOn
        let port = (configs["mixed-port"] as? Int) ?? (configs["port"] as? Int) ?? 7890
        Task {
            if !engine.isRoot {
                showToast("设置系统代理需要管理员授权以安装特权服务…")
                let installOk = await engine.installPrivileged()
                if installOk {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)   // let root daemon boot
                    await reconnect()
                } else {
                    showToast("授权失败，系统代理未启用")
                    return
                }
            }
            
            guard engine.isRoot else {
                showToast("特权服务未运行，系统代理设置失败")
                return
            }
            
            let ok = await engine.setSystemProxy(enabled: on, port: port)
            if ok {
                systemProxyOn = on
                showToast(on ? "系统代理已开启" : "系统代理已关闭")
            } else {
                showToast("特权服务响应失败，尝试备用提权方式…")
                let fallbackOk = await Self.setSystemProxyFallback(enabled: on, port: port)
                if fallbackOk {
                    systemProxyOn = on
                    showToast(on ? "系统代理已开启 (备用)" : "系统代理已关闭 (备用)")
                } else {
                    showToast("系统代理设置失败")
                }
            }
        }
    }

    /// Set/clear the macOS system HTTP/HTTPS/SOCKS proxy on the primary network
    /// service. Uses networksetup under one administrator-auth prompt (osascript),
    /// so no separately-signed privileged Helper is required.
    static func setSystemProxyFallback(enabled: Bool, port: Int) async -> Bool {
        let shell: String
        if enabled {
            shell = """
            dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}'); \
            svc=$(networksetup -listnetworkserviceorder | grep -B1 \\"Device: $dev)\\" | head -1 | sed -E 's/^\\\\([0-9]+\\\\) //'); \
            networksetup -setwebproxy \\"$svc\\" 127.0.0.1 \(port); \
            networksetup -setsecurewebproxy \\"$svc\\" 127.0.0.1 \(port); \
            networksetup -setsocksfirewallproxy \\"$svc\\" 127.0.0.1 \(port)
            """
        } else {
            shell = """
            dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}'); \
            svc=$(networksetup -listnetworkserviceorder | grep -B1 \\"Device: $dev)\\" | head -1 | sed -E 's/^\\\\([0-9]+\\\\) //'); \
            networksetup -setwebproxystate \\"$svc\\" off; \
            networksetup -setsecurewebproxystate \\"$svc\\" off; \
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
    func toggleTUN() {
        let want = !tunOn
        Task {
            if want && !engine.isRoot {
                // TUN needs the engine running as root. Promote via one admin prompt.
                showToast("启用 TUN 需要管理员授权…")
                let ok = await engine.installPrivileged()
                guard ok else { showToast("授权失败，TUN 未启用"); return }
                try? await Task.sleep(nanoseconds: 3_500_000_000)   // let root daemon boot
                await reconnect()
            }
            
            if want && !engine.isRoot {
                showToast("特权服务加载失败，TUN 未启用")
                return
            }
            
            let overrides: [String: Any] = [
                "tun": [
                    "enable": want,
                    "stack": (configs["tun"] as? [String:Any])?["stack"] ?? "gvisor",
                    "auto-route": true,
                    "auto-detect-interface": true
                ]
            ]
            let ok = await engine.patchConfig(overrides)
            if ok {
                await refreshConfigs()
                tunOn = want
                showToast(want ? "TUN 模式已开启" : "TUN 模式已关闭")
            } else {
                showToast(want ? "TUN 模式开启失败，请检查网络或端口冲突" : "TUN 模式关闭失败")
            }
        }
    }

    /// Deep-merge config overrides into the running config via the engine
    /// (validate + rollback). The primitive behind all settings forms.
    func patch(_ overrides: [String: Any]) async {
        let ok = await engine.patchConfig(overrides)
        if ok { await refreshConfigs() } else { showToast("配置写入失败") }
    }

    func toggleEngine() {
        let want = !reachable
        Task {
            if want {
                // start engine
                engine.ensureInstalled()
                let t = Process(); t.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                t.arguments = ["start", "com.clashpow.engine"]
                try? t.run(); t.waitUntilExit()
                showToast("正在启动核心...")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await reconnect()
            } else {
                // stop engine
                let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                t.arguments = ["-9", "clashpow-engine"]
                try? t.run(); t.waitUntilExit()
                
                // If it is running as root, we also need to kill it via admin or it won't die,
                // but since killall -9 clashpow-engine only kills user processes, 
                // we might need to use the EngineControl uninstall API if it's root.
                if engine.isRoot {
                    showToast("停止系统核心需要授权...")
                    let ok = await engine.uninstallPrivileged()
                    if !ok { showToast("停止失败") }
                }
                
                reachable = false
                showToast("核心已停止")
            }
        }
    }

    // Rules editing (operates on the config's inline `rules` list)
    @AppStorage("rules.disabled") private var disabledRulesJSON = "[]"
    var disabledRules: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(disabledRulesJSON.utf8))) ?? [] }
        set { disabledRulesJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8) ?? "[]") ?? "[]" }
    }
    var inlineRules: [String] { (configs["rules"] as? [Any])?.map { "\($0)" } ?? [] }

    func applyRules(_ rules: [String]) async {
        await patch(["rules": rules])
        showToast("规则已更新并热重载")
    }
    func disableRule(_ rule: String) async {
        var d = disabledRules; if !d.contains(rule) { d.append(rule) }; disabledRules = d
        await applyRules(inlineRules.filter { $0 != rule })
    }
    func enableRule(_ rule: String) async {
        disabledRules = disabledRules.filter { $0 != rule }
        await applyRules(inlineRules + [rule])
    }

    // MARK: Actions

    func select(group: String, name: String) {
        // optimistic
        if let i = groups.firstIndex(where: { $0.id == group }) { groups[i].now = name }
        Task {
            try? await api.selectProxy(group: group, name: name)
            await refreshProxies()
        }
    }

    func testGroup(_ group: ProxyGroup) {
        let targets = group.all.filter { nodes[$0] != nil }
        test(names: targets)
    }

    func testAll() {
        test(names: Array(nodes.keys))
    }

    private func test(names: [String]) {
        testing.formUnion(names)
        for name in names {
            Task {
                if let d = try? await api.testDelay(name: name) {
                    nodes[name]?.delay = d
                }
                testing.remove(name)
            }
        }
    }

    func setMode(_ m: String) {
        mode = m
        Task { try? await api.patchConfig(["mode": m]); showToast("已切换至\(modeLabel(m))模式") }
    }

    func showToast(_ s: String) {
        toast = s
        Task { try? await Task.sleep(nanoseconds: 2_400_000_000); toast = nil }
    }

    func currentProxyName() -> String {
        // Follow GLOBAL or the primary selector chain to a leaf node
        let primary = groups.first(where: { $0.name == "默认代理" || $0.name == "GLOBAL" || $0.selectable })
        guard var cur = primary?.now else { return "—" }
        var guard0 = 0
        while let g = groups.first(where: { $0.id == cur }), guard0 < 6 { cur = g.now; guard0 += 1 }
        if cur == "DIRECT" { return "直连" }
        if cur == "REJECT" { return "拒绝" }
        return cur
    }

    // MARK: Connection management

    func closeAllConnections() {
        Task {
            do { try await api.closeAllConnections(); showToast("已断开所有连接") }
            catch { showToast("断开连接失败") }
        }
    }

    func closeConnection(id: String) {
        Task {
            try? await api.closeConnection(id: id)
        }
    }

    // MARK: DNS cache management

    func flushDnsCache() {
        Task {
            do { try await api.flushDnsCache(); showToast("DNS 缓存已刷新") }
            catch { showToast("刷新 DNS 缓存失败") }
        }
    }

    func clearAllCache() {
        Task {
            do {
                try await api.flushDnsCache()
                try await api.flushFakeIpCache()
                showToast("DNS 及 Fake‑IP 缓存已清空")
            } catch {
                showToast("清空缓存失败")
            }
        }
    }
}
