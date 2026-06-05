import Foundation
import Combine
import SwiftUI

@MainActor final class MihomoClient: ObservableObject {
    static let shared = MihomoClient()

    // Connection settings (persisted). Defaults target the ClashPow engine's
    // managed mihomo controller; auto-discovered from the engine at launch.
    @AppStorage("mihomo.host") var host: String = "127.0.0.1"
    @AppStorage("mihomo.port") var port: Int = 9092
    @AppStorage("mihomo.secret") var secret: String = "clashpow"

    @Published var reachable = false
    @Published var version = "?"

    private var session = URLSession(configuration: .default)

    private var apiBase: String { "http://\(host):\(port)" }
    private var wsBase: String { "ws://\(host):\(port)" }

    // MARK: Controller discovery (B1)

    /// Discover the controller endpoint/secret from the kernel's config file, so the
    /// client always talks to whatever the *running* config actually exposes instead
    /// of stale hardcoded defaults. A bind address of 0.0.0.0/:: is normalized to the
    /// loopback (you cannot connect to 0.0.0.0).
    func applyController(fromConfigAt path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        if let ec = Self.yamlScalar("external-controller", in: text),
           let colon = ec.lastIndex(of: ":") {
            var h = String(ec[..<colon]).trimmingCharacters(in: .whitespaces)
            if h.isEmpty || h == "0.0.0.0" || h == "::" || h == "[::]" { h = "127.0.0.1" }
            host = h
            if let p = Int(ec[ec.index(after: colon)...].trimmingCharacters(in: .whitespaces)) { port = p }
        }
        // secret may be absent (no auth) → reflect that faithfully
        secret = Self.yamlScalar("secret", in: text) ?? ""
    }

    /// Minimal reader for a top-level `key: value` YAML scalar. Ignores indented
    /// (nested) keys, inline comments, and surrounding quotes. Sufficient for the
    /// flat controller/secret fields; not a general YAML parser.
    private static func yamlScalar(_ key: String, in text: String) -> String? {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), line.hasPrefix(key) else { continue }
            let after = line.dropFirst(key.count)
            guard after.first == ":" else { continue }
            var val = after.dropFirst().trimmingCharacters(in: .whitespaces)
            if let hash = val.firstIndex(of: "#") { val = String(val[..<hash]).trimmingCharacters(in: .whitespaces) }
            val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return val.isEmpty ? nil : val
        }
        return nil
    }

    // MARK: REST

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest? {
        guard let url = URL(string: apiBase + path) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 6
        if !secret.isEmpty { r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let req = request(path) else { throw MihomoError.badURL }
        let (data, resp) = try await session.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw MihomoError.http(h.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func fetchVersion() async throws -> MihomoVersion { try await get("/version") }
    func fetchProxies() async throws -> ProxiesPayload { try await get("/proxies") }
    func fetchRules() async throws -> RulesPayload { try await get("/rules") }
    func fetchProviders() async throws -> ProvidersPayload { try await get("/providers/proxies") }

    /// Force-update a subscription (proxy provider).
    func updateProvider(_ name: String) async throws {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let req = request("/providers/proxies/\(enc)", method: "PUT") else { throw MihomoError.badURL }
        _ = try await session.data(for: req)
    }

    /// Health-check a subscription (triggers delay test for all its nodes).
    func healthCheckProvider(_ name: String) async throws {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let req = request("/providers/proxies/\(enc)/healthcheck") else { throw MihomoError.badURL }
        _ = try await session.data(for: req)
    }

    /// Resolve a name via the kernel's DNS (returns raw JSON).
    func dnsQuery(name: String, type: String = "A") async throws -> [String: Any] {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        guard let req = request("/dns/query?name=\(enc)&type=\(type)") else { throw MihomoError.badURL }
        let (data, _) = try await session.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func fetchConfigs() async throws -> [String: Any] {
        guard let req = request("/configs") else { throw MihomoError.badURL }
        let (data, _) = try await session.data(for: req)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Switch a Selector group's active proxy.
    func selectProxy(group: String, name: String) async throws {
        let enc = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        let body = try JSONEncoder().encode(["name": name])
        guard let req = request("/proxies/\(enc)", method: "PUT", body: body) else { throw MihomoError.badURL }
        _ = try await session.data(for: req)
    }

    /// Latency test for a single proxy/node.
    func testDelay(name: String) async throws -> Int {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let path = "/proxies/\(enc)/delay?timeout=5000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"
        let r: DelayResult = try await get(path)
        return r.delay
    }

    /// Patch running config (e.g. change mode).
    func patchConfig(_ patch: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: patch)
        guard let req = request("/configs", method: "PATCH", body: data) else { throw MihomoError.badURL }
        _ = try await session.data(for: req)
    }

    /// Reload config from a file path (force). Surfaces mihomo's error message
    /// (e.g. a bad proxy-group reference) instead of silently "succeeding".
    func reloadConfig(path: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["path": path])
        guard let req = request("/configs?force=true", method: "PUT", body: data) else { throw MihomoError.badURL }
        let (respData, resp) = try await session.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: respData) as? [String: Any])?["message"] as? String
            throw MihomoError.reload(msg ?? "HTTP \(h.statusCode)")
        }
    }

    /// Close all active connections.
    func closeAllConnections() async throws {
        guard let req = request("/connections", method: "DELETE") else { throw MihomoError.badURL }
        _ = try await session.data(for: req)
    }

    /// Close a single connection by ID.
    func closeConnection(id: String) async throws {
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let req = request("/connections/\(enc)", method: "DELETE") else { throw MihomoError.badURL }
        _ = try await session.data(for: req)
    }

    /// Flush the kernel's DNS resolver cache.
    func flushDnsCache() async throws {
        guard let req = request("/cache/dns/flush", method: "POST") else { throw MihomoError.badURL }
        _ = try await session.data(for: req)
    }

    /// Flush the Fake-IP allocation cache.
    func flushFakeIpCache() async throws {
        guard let req = request("/cache/fakeip/flush", method: "POST") else { throw MihomoError.badURL }
        _ = try await session.data(for: req)
    }

    func probe(timeout: TimeInterval = 1.0) async {
        guard let url = URL(string: apiBase + "/version") else { reachable = false; return }
        var r = URLRequest(url: url)
        r.timeoutInterval = timeout
        if !secret.isEmpty { r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        
        do {
            let (data, _) = try await session.data(for: r)
            let v = try JSONDecoder().decode(MihomoVersion.self, from: data)
            version = v.version
            reachable = true
        } catch {
            reachable = false
        }
    }

    func probe() async {
        await probe(timeout: 1.0)
    }

    // MARK: WebSocket streams

    private func wsURL(_ path: String) -> URL? {
        var s = wsBase + path
        if !secret.isEmpty {
            s += (path.contains("?") ? "&" : "?") + "token=\(secret)"
        }
        return URL(string: s)
    }

    /// Generic line-delimited JSON WebSocket stream. Reconnects on drop.
    func stream<T: Decodable>(_ path: String, type: T.Type, onValue: @escaping @Sendable (T) -> Void) -> WSHandle {
        let handle = WSHandle()
        connectStream(path, type: type, handle: handle, onValue: onValue)
        return handle
    }

    private func connectStream<T: Decodable>(_ path: String, type: T.Type, handle: WSHandle, onValue: @escaping @Sendable (T) -> Void) {
        guard let url = wsURL(path) else { return }
        let task = session.webSocketTask(with: url)
        handle.task = task
        task.resume()
        receiveLoop(task: task, path: path, type: T.self, handle: handle, onValue: onValue)
    }

    /// nonisolated receive loop so the WebSocket completion handler (which runs
    /// off the main actor) can recurse without main-actor isolation warnings.
    private nonisolated func receiveLoop<T: Decodable>(task: URLSessionWebSocketTask, path: String, type: T.Type, handle: WSHandle, onValue: @escaping @Sendable (T) -> Void) {
        task.receive { [weak self] result in
            guard let self, !handle.cancelled else { return }
            switch result {
            case .success(let msg):
                if case .string(let s) = msg, let data = s.data(using: .utf8),
                   let v = try? JSONDecoder().decode(T.self, from: data) {
                    onValue(v)   // onValue hops to @MainActor itself
                }
                self.receiveLoop(task: task, path: path, type: T.self, handle: handle, onValue: onValue)
            case .failure:
                // Reconnect after a short delay
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !handle.cancelled { self.connectStream(path, type: T.self, handle: handle, onValue: onValue) }
                }
            }
        }
    }
}

final class WSHandle: @unchecked Sendable {
    var task: URLSessionWebSocketTask?
    var cancelled = false
    func cancel() { cancelled = true; task?.cancel(with: .goingAway, reason: nil) }
}
