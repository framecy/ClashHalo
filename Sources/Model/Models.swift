// AppModel — central app state. Owns the MihomoClient, manages live data.
//
// Data sources:
//   - WebSocket /traffic     → live up/down (chart)
//   - WebSocket /connections → live connection list + totals + memory
//   - WebSocket /logs        → live log stream
//   - Poll /proxies (3s)     → groups, nodes, selections, latencies
//   - Poll /configs (5s)     → mode, ports, dns, tun

import Foundation
import SwiftUI

// MARK: - View models

struct ProxyGroup: Identifiable, Equatable {
    let id: String        // group name
    let name: String
    let type: String      // Selector / URLTest / Fallback / LoadBalance
    var now: String
    let all: [String]
    var selectable: Bool { type == "Selector" || type == "Fallback" }
}

struct Node: Identifiable, Equatable {
    let id: String        // proxy name
    let name: String
    let type: String      // Shadowsocks / Vmess / Direct / ...
    var delay: Int        // ms, 0 = untested/timeout
}

struct Conn: Identifiable {
    let id: String
    let host: String
    let dstIP: String
    let srcIP: String
    let port: String
    let network: String   // tcp / udp
    let process: String
    let chain: String     // "GroupA → node"
    let group: String     // first chain element (policy group)
    let node: String      // last chain element (leaf proxy)
    let rule: String
    let ruleType: String
    var up: Int64
    var down: Int64
    var upRate: Int64     // bytes/s (diffed)
    var downRate: Int64
    let start: String
    var category: String {  // direct / proxy / reject
        if node == "DIRECT" || chain.contains("DIRECT") { return "direct" }
        if node == "REJECT" || chain.contains("REJECT") { return "reject" }
        return "proxy"
    }
}

struct Log: Identifiable {
    let id: Int
    let time: String
    let level: String     // info / warning / error / debug
    let text: String
}

// MARK: - AppModel

@MainActor
final class AppModel: ObservableObject {
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
    var accent: Color { ["green":.green,"blue":.blue,"purple":.purple,"orange":.orange][accentRaw] ?? .green }

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
        // Sort groups: GLOBAL last, others alphabetical-ish by original order
        groups = gs.sorted { a, b in
            if a.name == "GLOBAL" { return false }
            if b.name == "GLOBAL" { return true }
            return a.name < b.name
        }
        nodes = ns
    }

    func refreshConfigs() async {
        guard let c = try? await api.fetchConfigs() else { return }
        configs = c
        if let m = c["mode"] as? String { mode = m }
        if let tun = c["tun"] as? [String: Any] { tunOn = (tun["enable"] as? Bool) == true }
    }

    // Master switches
    func toggleSystemProxy() {
        let on = !systemProxyOn
        let port = (configs["mixed-port"] as? Int) ?? (configs["port"] as? Int) ?? 7890
        Task {
            let ok = await Self.setSystemProxy(enabled: on, port: port)
            systemProxyOn = ok ? on : systemProxyOn
            showToast(ok ? (on ? "系统代理已开启" : "系统代理已关闭") : "系统代理设置失败（需管理员授权）")
        }
    }

    /// Set/clear the macOS system HTTP/HTTPS/SOCKS proxy on the primary network
    /// service. Uses networksetup under one administrator-auth prompt (osascript),
    /// so no separately-signed privileged Helper is required.
    static func setSystemProxy(enabled: Bool, port: Int) async -> Bool {
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
            tunOn = want
            await patch(["tun": ["enable": want, "stack": (configs["tun"] as? [String:Any])?["stack"] ?? "gvisor", "auto-route": true, "auto-detect-interface": true]])
            showToast(want ? "TUN 模式已开启" : "TUN 模式已关闭")
        }
    }

    /// Deep-merge config overrides into the running config via the engine
    /// (validate + rollback). The primitive behind all settings forms.
    func patch(_ overrides: [String: Any]) async {
        let ok = await engine.patchConfig(overrides)
        if ok { await refreshConfigs() } else { showToast("配置写入失败") }
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
}

// MARK: - Config profiles (multi-config management)

struct Profile: Identifiable, Codable {
    let id: String
    var name: String
    var source: String       // "local" | "remote"
    var url: String?
    var importedAt: Date
    var updatedAt: Date
}

@MainActor
final class ConfigStore: ObservableObject {
    @Published var profiles: [Profile] = []
    @AppStorage("config.active") var activeID = ""

    private let dir = NSHomeDirectory() + "/Library/Application Support/ClashPow/profiles"
    private let configPath = NSHomeDirectory() + "/Library/Application Support/ClashPow/config.yaml"
    private var manifestPath: String { dir + "/manifest.json" }
    private let fm = FileManager.default

    func path(_ id: String) -> String { dir + "/\(id).yaml" }

    func load() {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = fm.contents(atPath: manifestPath),
           let list = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = list
        }
        // Seed from the existing config.yaml on first run.
        if profiles.isEmpty, let content = try? String(contentsOfFile: configPath, encoding: .utf8) {
            let id = UUID().uuidString
            try? content.write(toFile: path(id), atomically: true, encoding: .utf8)
            let p = Profile(id: id, name: "默认配置", source: "local", url: nil, importedAt: Date(), updatedAt: Date())
            profiles = [p]; activeID = id; save()
        }
        if activeID.isEmpty { activeID = profiles.first?.id ?? "" }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) { try? data.write(to: URL(fileURLWithPath: manifestPath)) }
    }

    func content(_ id: String) -> String { (try? String(contentsOfFile: path(id), encoding: .utf8)) ?? "" }
    func saveContent(_ id: String, _ text: String) { try? text.write(toFile: path(id), atomically: true, encoding: .utf8); touch(id) }
    private func touch(_ id: String) { if let i = profiles.firstIndex(where: { $0.id == id }) { profiles[i].updatedAt = Date(); save() } }

    func addLocal(name: String, content: String) -> String {
        let id = UUID().uuidString
        try? content.write(toFile: path(id), atomically: true, encoding: .utf8)
        profiles.append(Profile(id: id, name: name, source: "local", url: nil, importedAt: Date(), updatedAt: Date()))
        save(); return id
    }

    func importRemote(name: String, url: String) async -> String? {
        guard let u = URL(string: url) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: u),
              let content = String(data: data, encoding: .utf8), content.contains(":") else { return nil }
        let id = UUID().uuidString
        try? content.write(toFile: path(id), atomically: true, encoding: .utf8)
        profiles.append(Profile(id: id, name: name, source: "remote", url: url, importedAt: Date(), updatedAt: Date()))
        save(); return id
    }

    func updateRemote(_ id: String) async -> Bool {
        guard let p = profiles.first(where: { $0.id == id }), let url = p.url, let u = URL(string: url),
              let (data, _) = try? await URLSession.shared.data(from: u),
              let content = String(data: data, encoding: .utf8) else { return false }
        try? content.write(toFile: path(id), atomically: true, encoding: .utf8); touch(id); return true
    }

    func remove(_ id: String) {
        try? fm.removeItem(atPath: path(id))
        profiles.removeAll { $0.id == id }; save()
        if activeID == id { activeID = profiles.first?.id ?? "" }
    }

    /// Persist the selected profile as the engine's config.yaml (engine reloads it).
    func makeActiveContent(_ id: String) -> String? {
        let c = content(id); guard !c.isEmpty else { return nil }
        try? c.write(toFile: configPath, atomically: true, encoding: .utf8)
        activeID = id; return c
    }
}

// MARK: - Traffic history (persisted per-day category + hourly totals)

@MainActor
final class TrafficHistory: ObservableObject {
    struct Day: Codable {
        var direct = 0.0, proxy = 0.0, reject = 0.0
        var hourlyDown = [Double](repeating: 0, count: 24)
        var total: Double { direct + proxy + reject }
    }
    @Published var days: [String: Day] = [:]   // key "yyyy-MM-dd"

    private let path = NSHomeDirectory() + "/Library/Application Support/ClashPow/traffic-history.json"
    private var dirty = false
    private var lastSave = Date.distantPast

    private var todayKey: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    func load() {
        if let data = FileManager.default.contents(atPath: path),
           let d = try? JSONDecoder().decode([String: Day].self, from: data) {
            // keep only last 60 days
            let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: Date())!
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            days = d.filter { (f.date(from: $0.key) ?? .distantPast) >= cutoff }
        }
    }

    func record(category: String, down: Int64, up: Int64, hour: Int) {
        let bytes = Double(down + up)
        guard bytes > 0 else { return }
        var day = days[todayKey] ?? Day()
        switch category {
        case "direct": day.direct += bytes
        case "reject": day.reject += bytes
        default: day.proxy += bytes
        }
        if hour >= 0 && hour < 24 { day.hourlyDown[hour] += Double(down) }
        days[todayKey] = day
        dirty = true
    }

    func flushIfNeeded() {
        guard dirty, Date().timeIntervalSince(lastSave) > 5 else { return }
        save()
    }
    func save() {
        dirty = false; lastSave = Date()
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: URL(fileURLWithPath: path)) }
    }

    // Aggregates for the dashboard
    var today: Day { days[todayKey] ?? Day() }
    var month: Day {
        let prefix = String(todayKey.prefix(7))  // yyyy-MM
        var m = Day()
        for (k, d) in days where k.hasPrefix(prefix) {
            m.direct += d.direct; m.proxy += d.proxy; m.reject += d.reject
            for i in 0..<24 { m.hourlyDown[i] += d.hourlyDown[i] }
        }
        return m
    }
    /// Daily totals for the current month, oldest→newest (for the month timeline).
    var monthDailyTotals: [Double] {
        let prefix = String(todayKey.prefix(7))
        return days.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }.map { $0.value.total }
    }
}

// MARK: - SD-WAN network scanning (read-only, no root)

enum IfaceKind: String {
    case physical = "物理网卡", proxyTun = "代理 TUN", tailscale = "Tailscale"
    case zerotier = "ZeroTier", oray = "蒲公英", otherTun = "虚拟接口", loopback = "环回"
    var sdwan: Bool { self == .tailscale || self == .zerotier || self == .oray }
}

struct NetIface: Identifiable {
    let id: String          // interface name
    var name: String { id }
    let ipv4: [String]
    let isUp: Bool
    let kind: IfaceKind
    var primaryIP: String { ipv4.first ?? "—" }
}

enum NetScanner {
    /// Enumerate IPv4 interfaces via getifaddrs (no shell, no privileges).
    static func interfaces() -> [NetIface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var ips: [String: [String]] = [:]
        var flags: [String: Int32] = [:]
        var order: [String] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let nm = String(cString: cur.pointee.ifa_name)
            if flags[nm] == nil { flags[nm] = Int32(cur.pointee.ifa_flags); order.append(nm) }
            if let a = cur.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                ips[nm, default: []].append(String(cString: host))
            }
            p = cur.pointee.ifa_next
        }
        return order.compactMap { nm -> NetIface? in
            let f = flags[nm] ?? 0
            let up = (f & Int32(IFF_UP)) != 0 && (f & Int32(IFF_RUNNING)) != 0
            let addrs = ips[nm] ?? []
            let kind = classify(name: nm, flags: f, ips: addrs)
            // hide empty bridge/thunderbolt ports and loopback
            if kind == .loopback { return nil }
            if addrs.isEmpty && !nm.hasPrefix("utun") { return nil }
            return NetIface(id: nm, ipv4: addrs, isUp: up, kind: kind)
        }
    }

    private static func classify(name: String, flags: Int32, ips: [String]) -> IfaceKind {
        if (flags & Int32(IFF_LOOPBACK)) != 0 { return .loopback }
        let isTun = name.hasPrefix("utun") || (flags & Int32(IFF_POINTOPOINT)) != 0
        if isTun {
            for ip in ips {
                if ip.hasPrefix("198.18.") || ip.hasPrefix("198.19.") { return .proxyTun }
                if isCGNAT(ip) { return .tailscale }
                if ip.hasPrefix("10.147.") { return .zerotier }
            }
            return .otherTun
        }
        if name.hasPrefix("en") || name.hasPrefix("bridge") { return .physical }
        return .otherTun
    }

    /// 100.64.0.0/10 carrier-grade NAT (Tailscale).
    private static func isCGNAT(_ ip: String) -> Bool {
        let p = ip.split(separator: ".")
        guard p.count == 4, p[0] == "100", let o2 = Int(p[1]) else { return false }
        return o2 >= 64 && o2 <= 127
    }

    /// Routes touching utun interfaces (netstat, no root). Returns (dest, iface).
    static func tunRoutes() -> [(dest: String, iface: String)] {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-rn", "-f", "inet"]
        let pipe = Pipe(); task.standardOutput = pipe
        try? task.run(); task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var rows: [(String, String)] = []
        for line in out.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 4 else { continue }
            let iface = cols.last ?? ""
            if iface.hasPrefix("utun") { rows.append((cols[0], iface)) }
        }
        return rows
    }
}

// MARK: - Formatting helpers (single source of truth)

func fmtRate(_ b: Double) -> String {
    if b >= 1_000_000 { return String(format: "%.1f MB/s", b / 1_000_000) }
    if b >= 1_000 { return String(format: "%.0f KB/s", b / 1_000) }
    return String(format: "%.0f B/s", b)
}
func fmtBytes(_ b: Double) -> String {
    if b >= 1_000_000_000 { return String(format: "%.2f GB", b / 1_000_000_000) }
    if b >= 1_000_000 { return String(format: "%.1f MB", b / 1_000_000) }
    if b >= 1_000 { return String(format: "%.0f KB", b / 1_000) }
    return "\(Int(b)) B"
}
func fmtDelay(_ ms: Int) -> String { ms > 0 ? "\(ms)" : "—" }
func delayColor(_ ms: Int) -> Color { ms <= 0 ? .secondary : ms < 100 ? .green : ms < 250 ? .orange : .red }
func modeLabel(_ m: String) -> String { ["rule":"规则","global":"全局","direct":"直连"][m] ?? m }
