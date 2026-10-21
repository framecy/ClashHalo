
import Foundation
import SwiftUI


struct MihomoVersion: Decodable { let version: String; let meta: Bool? }

struct ProxiesPayload: Decodable { let proxies: [String: ProxyEntry] }
struct ProxyEntry: Decodable {
    let name: String
    let type: String
    let now: String?
    let all: [String]?
    let history: [DelayHistory]?
    let udp: Bool?
    let alive: Bool?

    enum CodingKeys: String, CodingKey {
        case name, type, now, all, history, udp, alive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = (try? container.decode(String.self, forKey: .name)) ?? ""
        self.type = (try? container.decode(String.self, forKey: .type)) ?? "Unknown"
        self.now = try? container.decode(String.self, forKey: .now)
        self.all = try? container.decode([String].self, forKey: .all)
        self.history = try? container.decode([DelayHistory].self, forKey: .history)
        self.udp = try? container.decode(Bool.self, forKey: .udp)
        self.alive = try? container.decode(Bool.self, forKey: .alive)
    }
}
struct DelayHistory: Decodable {
    let time: String
    let delay: Int

    enum CodingKeys: String, CodingKey {
        case time, delay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.time = (try? container.decode(String.self, forKey: .time)) ?? ""
        self.delay = (try? container.decode(Int.self, forKey: .delay)) ?? 0
    }
}

struct RulesPayload: Decodable { let rules: [RuleEntry] }
struct RuleEntry: Decodable, Equatable { let type: String; let payload: String; let proxy: String; let size: Int? }

struct ProvidersPayload: Decodable { let providers: [String: ProviderEntry] }
struct ProviderEntry: Decodable {
    let name: String
    let type: String          // Proxy
    let vehicleType: String   // HTTP / File / Compatible
    let proxies: [ProxyEntry]?
    let updatedAt: String?
    let subscriptionInfo: SubInfo?
    struct SubInfo: Decodable { let Upload: Int64?; let Download: Int64?; let Total: Int64?; let Expire: Int64? }
}

struct TrafficTick: Decodable { let up: Int64; let down: Int64 }
struct DelayResult: Decodable { let delay: Int }

struct LogTick: Decodable { let type: String; let payload: String }

struct ConnectionsSnapshot: Decodable {
    let downloadTotal: Int64
    let uploadTotal: Int64
    let connections: [ConnectionItem]?
    let memory: Int64?
}
struct ConnectionItem: Decodable {
    let id: String
    let metadata: ConnMeta
    let upload: Int64
    let download: Int64
    let start: String
    let chains: [String]
    let rule: String
    let rulePayload: String
    /// 节点来自哪个 proxy-provider，形如 `["US-BWH", "", ""]`；老内核/本地节点为
    /// `[""]` 或缺失。可选是为了让缺字段的响应仍能整体解码。
    let providerChains: [String]?
}
struct ConnMeta: Decodable {
    let network: String
    let type: String?
    let host: String?
    let process: String?
    let processPath: String?
    let sourceIP: String?
    let destinationIP: String?
    let destinationPort: String?
    // 以下字段 mihomo 一直都在返回（实测 25 个关键字段），此前被整体丢弃。
    // 全部可选：老内核缺失时不能把整条连接解码成 nil。
    /// 流量从哪条入站进来：`DEFAULT-TUN` / `DEFAULT-MIXED` / listener 的 `name`。
    /// TUN 下 `sourceIP` 恒为 fake-ip 网关地址，只有它能区分本机与局域网设备。
    let inboundName: String?
    let inboundPort: String?
    /// `fake-ip` / `normal` / `redir-host`
    let dnsMode: String?
    /// 嗅探还原出的真实域名，未嗅探时为空串。
    let sniffHost: String?
    /// 目标真实地址；`host` 走域名解析时 `destinationIP` 可能为空，值在这里。
    let remoteDestination: String?
}


enum MihomoError: LocalizedError {
    case badURL, http(Int), notRunning, reload(String)
    var errorDescription: String? {
        switch self {
        case .badURL: return "无效的 API 地址"
        case .http(let c): return "HTTP \(c)"
        case .notRunning: return "内核未运行或地址错误"
        case .reload(let m): return m
        }
    }
}









