// EngineClient.swift — JSON-RPC + Mihomo REST client.
// Fetches real config, proxies, connections, rules from the engine.
import Foundation
import Network

// ── Types ────────────────────────────────────────────────────

struct EngineStatus: Decodable {
    let running: Bool; let tunEnabled: Bool; let connections: Int
    let uptimeSec: Int64; let version: String; let iosurfaceID: Int32
    let logSocketPath: String
    enum CodingKeys: String, CodingKey {
        case running, tunEnabled="tun_enabled", connections
        case uptimeSec="uptime_sec", version, iosurfaceID="iosurface_id"
        case logSocketPath="log_socket_path"
    }
}
struct CompileResult: Decodable { let ok: Bool; let binaryPath: String?; let error: String? }
struct OKResult: Decodable { let ok: Bool }

struct MihomoProxiesResponse: Decodable { let proxies: [String: MihomoProxy] }
struct MihomoProxy: Decodable {
    let name: String; let type: String; let now: String?; let all: [String]?
    let history: [MihomoDelayHist]?; let alive: Bool?; let udp: Bool?
}
struct MihomoDelayHist: Decodable { let time: String; let delay: Int }

struct MihomoConnectionsResponse: Decodable {
    let downloadTotal: Int64; let uploadTotal: Int64
    let connections: [MihomoConnection]?; let memory: Int64?
}
struct MihomoConnection: Decodable {
    let metadata: MihomoMeta; let upload: Int64; let download: Int64
    let start: String; let chains: [String]; let rule: String; let rulePayload: String
}
struct MihomoMeta: Decodable {
    let network: String; let process: String?; let host: String?
    let destinationIP: String?; let destinationPort: String?
}
struct MihomoRulesResponse: Decodable { let rules: [MihomoRule] }
struct MihomoRule: Decodable { let type: String; let payload: String; let proxy: String }
struct MihomoDelayResponse: Decodable { let delay: Int }
struct MihomoTrafficResponse: Decodable { let up: Int64; let down: Int64 }

// Mihomo /configs endpoint returns the full RawConfig
typealias MihomoConfig = [String: AnyJSON]
struct AnyJSON: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let a = try? c.decode([AnyJSON].self) { value = a.map(\.value) }
        else if let o = try? c.decode([String:AnyJSON].self) { value = o.mapValues(\.value) }
        else { value = "null" }
    }
}

struct RPCEnvelope<T: Decodable>: Decodable {
    let result: T?; let error: RPCErr?
    struct RPCErr: Decodable { let code: Int; let message: String }
}
struct RPCID: Decodable { let id: Int64 }

// ── Client ────────────────────────────────────────────────────

@MainActor
final class EngineClient: ObservableObject {
    @Published var isConnected = false
    @Published var lastStatus: EngineStatus?
    static let shared = EngineClient()
    let socketPath = "/tmp/clashpow-engine.sock"
    private var conn: NWConnection?
    private var reqID: Int64 = 0
    private var pending: [Int64: (Data) -> Void] = [:]
    private var recvBuf = Data()
    private let apiBase = "http://127.0.0.1:9090"
    private let apiSecret = "" // set from user config

    func connect() {
        conn?.cancel()
        conn = NWConnection(to: .unix(path: socketPath), using: .tcp)
        conn?.stateUpdateHandler = { [weak self] s in
            Task { @MainActor in
                switch s {
                case .ready: self?.isConnected = true; self?.startRead()
                case .failed, .cancelled: self?.isConnected = false
                default: break
                }
            }
        }
        conn?.start(queue: .main)
    }
    func disconnect() { conn?.cancel(); conn = nil; isConnected = false }

    // ── JSON-RPC over UDS ──────────────────────────────────────

    func rpcCall<T: Decodable>(_ method: String, params: String = "{}") async throws -> T {
        guard let c = conn, isConnected else { throw EngineError.notConnected }
        reqID += 1; let id = reqID
        let payload = #"{"jsonrpc":"2.0","method":"\#(method)","params":\#(params),"id":\#(id)}"# + "\n"
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            pending[id] = { data in
                if let env = try? JSONDecoder().decode(RPCEnvelope<T>.self, from: data), let r = env.result {
                    cont.resume(returning: r)
                } else if let env = try? JSONDecoder().decode(RPCEnvelope<T>.self, from: data), let e = env.error {
                    cont.resume(throwing: EngineError.rpcError(e.code, e.message))
                } else { cont.resume(throwing: EngineError.rpcError(-1, "decode")) }
            }
            c.send(content: payload.data(using: .utf8)!, completion: .contentProcessed { _ in })
        }
    }

    func fetchStatus() async throws -> EngineStatus { try await rpcCall("get_status") }
    func setConfig(yaml: String) async throws -> Bool {
        let esc = yaml.replacingOccurrences(of: "\n", with: "\\n")
        let r: OKResult = try await rpcCall("set_config", params: #"{"config_yaml":"\#(esc)"}"#)
        return r.ok
    }
    func compileRules(yaml: String, dir: String) async throws -> CompileResult {
        let esc = yaml.replacingOccurrences(of: "\n", with: "\\n")
        return try await rpcCall("compile_rules", params: #"{"rules_yaml":"\#(esc)","output_dir":"\#(dir)"}"#)
    }
    func reloadRules(path: String) async throws -> Bool {
        let r: OKResult = try await rpcCall("reload_rules", params: #"{"binary_path":"\#(path)}"#)
        return r.ok
    }
    func shutdownEngine() async throws { let _: OKResult = try await rpcCall("shutdown") }

    // ── Mihomo REST ────────────────────────────────────────────

    func fetchProxies() async throws -> MihomoProxiesResponse { try await restGET("/proxies") }
    func fetchConnections() async throws -> MihomoConnectionsResponse { try await restGET("/connections") }
    func fetchRules() async throws -> MihomoRulesResponse { try await restGET("/rules") }
    func fetchConfig() async throws -> [String: Any] {
        guard let url = URL(string: "\(apiBase)/configs") else { throw EngineError.invalidURL }
        var r = URLRequest(url: url)
        r.setValue("Bearer \(apiSecret)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: r)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    func fetchTraffic() async throws -> MihomoTrafficResponse { try await restGET("/traffic") }
    func testDelay(name: String) async throws -> MihomoDelayResponse {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return try await restGET("/proxies/\(enc)/delay?url=https://www.gstatic.com/generate_204&timeout=5000")
    }
    func selectProxy(group: String, proxy: String) async throws {
        let enc = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        guard let url = URL(string: "\(apiBase)/proxies/\(enc)") else { throw EngineError.invalidURL }
        var r = URLRequest(url: url); r.httpMethod = "PUT"
        r.setValue("Bearer \(apiSecret)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["name": proxy])
        let (_, _) = try await URLSession.shared.data(for: r)
    }

    // ── Internals ──────────────────────────────────────────────

    private func restGET<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "\(apiBase)\(path)") else { throw EngineError.invalidURL }
        var r = URLRequest(url: url)
        r.setValue("Bearer \(apiSecret)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: r)
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func startRead() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, _, e in
            guard let self, let d, e == nil else { return }
            Task { @MainActor in
                self.recvBuf.append(d)
                while let i = self.recvBuf.firstIndex(of: 0x0A) {
                    let line = Data(self.recvBuf[..<i]); self.recvBuf.removeSubrange(...i)
                    if let idObj = try? JSONDecoder().decode(RPCID.self, from: line),
                       let h = self.pending.removeValue(forKey: idObj.id) { h(line) }
                }
                self.startRead()
            }
        }
    }
}

enum EngineError: Error, LocalizedError {
    case notConnected, invalidURL, rpcError(Int, String)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "引擎未连接"
        case .invalidURL: return "无效URL"
        case .rpcError(let c, let m): return "RPC错误(\(c)): \(m)"
        }
    }
}
