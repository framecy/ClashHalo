
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
}
struct DelayHistory: Decodable { let time: String; let delay: Int }

struct RulesPayload: Decodable { let rules: [RuleEntry] }
struct RuleEntry: Decodable { let type: String; let payload: String; let proxy: String; let size: Int? }

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
struct MemoryTick: Decodable { let inuse: Int64 }
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
}
struct ConnMeta: Decodable {
    let network: String
    let type: String?
    let host: String?
    let process: String?
    let sourceIP: String?
    let destinationIP: String?
    let destinationPort: String?
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









