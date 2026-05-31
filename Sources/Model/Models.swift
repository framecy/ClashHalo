// Models.swift — ClashPow data models + AppState
import Foundation; import SwiftUI

// ── Data Types ─────────────────────────────────────────────────
struct ProxyNode: Identifiable { let id: String; let name: String; let type: String; let latency: Int }
struct ProxyGroup: Identifiable { let id: String; let name: String; let kind: String; var now: String; let members: [String] }
struct ConnectionInfo: Identifiable { let id: String; let host: String; let ip: String; let port: Int; let node: String; let chain: String; let rule: String; let proc: String; let network: String; let dlSpeed: Int64; let ulSpeed: Int64; let up: Int64; let down: Int64 }
struct LogLine: Identifiable { let id: Int; let time: String; let level: LogLevel; let msg: String; enum LogLevel: String, CaseIterable { case debug, info, warning, error } }
struct DNSEntry: Identifiable { let id = UUID(); let host: String; let fakeIP: String; let realIP: String; let type: String; let source: String; var ttl: Int; let hits: Int; let direct: Bool }
struct ConfigProfile: Identifiable { let id: String; let name: String; let from: String }

// ── Traffic Model ──────────────────────────────────────────────
final class TrafficModel: ObservableObject {
    @Published var down: [Double] = Array(repeating: 0, count: 120)
    @Published var up: [Double] = Array(repeating: 0, count: 120)
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let t = try? await EngineClient.shared.fetchTraffic() else { return }
                let limit = 120; self.down.append(Double(t.down)); self.up.append(Double(t.up))
                if self.down.count > limit { self.down.removeFirst(self.down.count - limit) }
                if self.up.count > limit { self.up.removeFirst(self.up.count - limit) }
            }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
}

// ── App State ──────────────────────────────────────────────────
@MainActor final class AppState: ObservableObject {
    @Published var route = "dashboard"
    @Published var running = true; @Published var mode = "rule"
    @Published var toastMessage: String?
    @Published var isDark = true; @Published var accentColor = Color.green

    // Live data from engine
    @Published var nodes: [ProxyNode] = []; @Published var groups: [ProxyGroup] = []
    @Published var selectedNodes: [String: String] = [:]; @Published var latencies: [String: Int] = [:]
    @Published var testingNodes: Set<String> = []
    @Published var connections: [ConnectionInfo] = []; @Published var dnsCache: [DNSEntry] = []
    @Published var stats = (uptime: "—", connections: 0, version: "?")
    @Published var realConfig: [String: Any] = [:]; @Published var configYAML: String = ""
    @Published var subscriptions: [String] = []; @Published var profiles: [ConfigProfile] = []

    let traffic = TrafficModel(); let engineClient = EngineClient.shared

    func connectToEngine() { engineClient.connect(); startPolling() }

    private func startPolling() {
        Task {
            while !Task.isCancelled {
                // status
                if let s = try? await engineClient.fetchStatus() {
                    let h = s.uptimeSec / 3600; let m = (s.uptimeSec % 3600) / 60
                    stats.uptime = h > 0 ? "\(h)h \(m)m" : "\(m)m"
                    stats.connections = s.connections; stats.version = s.version; running = s.running
                }
                // proxies
                if let p = try? await engineClient.fetchProxies() {
                    var ng: [ProxyGroup] = []; var nn: [ProxyNode] = []
                    for (name, px) in p.proxies {
                        let isG = px.all != nil || ["Selector","URLTest","Fallback","LoadBalance","Compatible","Pass"].contains(px.type)
                        if isG { ng.append(ProxyGroup(id: name, name: name, kind: px.type, now: px.now ?? name, members: px.all ?? [])) }
                        if (px.history?.isEmpty == false) && !["Direct","Reject","RejectDrop"].contains(px.type) {
                            nn.append(ProxyNode(id: name, name: name, type: px.type, latency: px.history?.last?.delay ?? 0))
                        }
                    }
                    nn.append(contentsOf: [ProxyNode(id: "DIRECT", name: "直连", type: "Direct", latency: 1)])
                    var sel = selectedNodes; for g in ng { if sel[g.id] == nil { sel[g.id] = g.now } }
                    var lat = latencies; for n in nn where lat[n.id] == nil { lat[n.id] = n.latency }
                    nodes = nn; groups = ng; selectedNodes = sel; latencies = lat
                }
                // config
                if let cfg = try? await engineClient.fetchConfig() {
                    realConfig = cfg; mode = (cfg["mode"] as? String) ?? "rule"
                    configYAML = configToYAML(cfg)
                }
                // connections
                if let c = try? await engineClient.fetchConnections(), let raw = c.connections {
                    connections = raw.map { x in
                        ConnectionInfo(id: "\(x.metadata.host ?? "?")-\(x.start)", host: x.metadata.host ?? "?", ip: x.metadata.destinationIP ?? "?", port: Int(x.metadata.destinationPort ?? "0") ?? 0, node: x.chains.last ?? "?", chain: x.chains.joined(separator: " → "), rule: "\(x.rule):\(x.rulePayload)", proc: x.metadata.process ?? "?", network: x.metadata.network, dlSpeed: x.download, ulSpeed: x.upload, up: x.upload, down: x.download)
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // ── Actions ─────────────────────────────────────────────────
    func togglePause() { running.toggle(); if running { traffic.start(); Task { _ = try? await engineClient.setConfig(yaml: "mode: rule") } } else { traffic.stop(); Task { _ = try? await engineClient.setConfig(yaml: "mode: direct") } }; toast(running ? "代理已恢复" : "代理已暂停") }
    func repairNet() { Task { _ = try? await engineClient.shutdownEngine(); try? await Task.sleep(nanoseconds: 3_000_000_000); toast("引擎已重启") } }
    func selectNode(groupID: String, nodeID: String) { selectedNodes[groupID] = nodeID; Task { try? await engineClient.selectProxy(group: groupID, proxy: nodeID) } }
    func testNodes(_ ids: [String]) { testingNodes.formUnion(ids); for (i, id) in ids.enumerated() { Task { try? await Task.sleep(nanoseconds: UInt64(250 + i * 90) * 1_000_000); if let r = try? await engineClient.testDelay(name: id) { latencies[id] = r.delay }; testingNodes.remove(id) } } }
    func resolveProxy(_ id: String) -> ProxyNode? { nodes.first(where: { $0.id == id }) ?? ProxyNode(id: id, name: id, type: "?", latency: 0) }
    func toast(_ msg: String) { toastMessage = msg; Task { try? await Task.sleep(nanoseconds: 2_600_000_000); toastMessage = nil } }
}

// ── YAML serializer ────────────────────────────────────────────
func configToYAML(_ cfg: [String: Any], indent: Int = 0) -> String {
    var out = ""; let pre = String(repeating: "  ", count: indent)
    for (k, v) in cfg.sorted(by: { $0.key < $1.key }) {
        if let d = v as? [String: Any] { out += "\(pre)\(k):\n" + configToYAML(d, indent: indent + 1) }
        else if let a = v as? [Any] { out += "\(pre)\(k):\n"; for i in a { if let sd = i as? [String: Any] { out += "\(pre)  -\n" + configToYAML(sd, indent: indent + 2) } else { out += "\(pre)  - \(i)\n" } } }
        else { out += "\(pre)\(k): \(v)\n" }
    }
    return out
}
