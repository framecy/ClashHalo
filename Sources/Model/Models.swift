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
    private var prevConnBytes: [String: (up: Int64, down: Int64)] = [:]

    // Logs
    @Published var logs: [Log] = []
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
    @Published var hourly: [Double] = Array(repeating: 0, count: 24)  // download bytes per hour-of-day
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
        curUp = t.up; curDown = t.down
        downSeries.append(Double(t.down)); upSeries.append(Double(t.up))
        if downSeries.count > 120 { downSeries = Array(downSeries.suffix(120)) }
        if upSeries.count > 120 { upSeries = Array(upSeries.suffix(120)) }
    }

    private func onConnections(_ s: ConnectionsSnapshot) {
        uploadTotal = s.uploadTotal; downloadTotal = s.downloadTotal
        if let m = s.memory { memory = m }
        let items = s.connections ?? []
        var next: [Conn] = []
        var bytes: [String: (up: Int64, down: Int64)] = [:]
        var activeIDs = Set<String>()
        for c in items {
            activeIDs.insert(c.id); seenConnIDs.insert(c.id)
            let prev = prevConnBytes[c.id]
            let upRate = prev.map { max(0, c.upload - $0.up) } ?? 0
            let downRate = prev.map { max(0, c.download - $0.down) } ?? 0
            bytes[c.id] = (c.upload, c.download)
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

        // closed-connection count (this session) = seen − currently-active
        closedConns = max(0, seenConnIDs.count - activeIDs.count)
        // hourly download accumulation (delta of cumulative total into current hour bucket)
        if lastDownTotal > 0, s.downloadTotal >= lastDownTotal {
            let h = Calendar.current.component(.hour, from: Date())
            hourly[h] += Double(s.downloadTotal - lastDownTotal)
        }
        lastDownTotal = s.downloadTotal
        // app RSS
        appMemoryMB = Double(Self.residentMemoryBytes()) / 1_000_000
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

    private func onLog(_ l: LogTick) {
        logSeq += 1
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        logs.append(Log(id: logSeq, time: df.string(from: Date()), level: l.type, text: l.payload))
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

    // Master switches (full Helper-backed actuation lands in stage J)
    func toggleSystemProxy() {
        systemProxyOn.toggle()
        showToast(systemProxyOn ? "系统代理已开启" : "系统代理已关闭")
    }
    func toggleTUN() {
        tunOn.toggle()
        Task { await patch(["tun": ["enable": tunOn]]) }
        showToast(tunOn ? "TUN 模式已开启" : "TUN 模式已关闭")
    }

    /// Deep-merge config overrides into the running config via the engine
    /// (validate + rollback). The primitive behind all settings forms.
    func patch(_ overrides: [String: Any]) async {
        let ok = await engine.patchConfig(overrides)
        if ok { await refreshConfigs() } else { showToast("配置写入失败") }
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
