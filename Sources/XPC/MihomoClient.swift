import Foundation
import Combine
import SwiftUI

private struct SafeDecoder: @unchecked Sendable {
    static let shared = JSONDecoder()
}

@MainActor final class MihomoClient: ObservableObject {
    static let shared = MihomoClient()

    // Connection settings (persisted). Defaults target the ClashHalo engine's
    // managed mihomo controller; auto-discovered from the engine at launch.
    @AppStorage("mihomo.host") var host: String = "127.0.0.1"
    @AppStorage("mihomo.port") var port: Int = 9092
    @AppStorage("mihomo.secret") var secret: String = "clashhalo"

    @Published var reachable = false
    @Published var version = "?"

    private var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldUsePipelining = true
        // 直连强制（P1-6）：与 KernelManager 同口径，内核控制面请求一律不经
        // 系统代理——系统代理开着时它正指向 mihomo 自己：经 mixed-port 代理
        // 访问控制器会把管理请求当代理流量转发（语义完全不同），内核死后还会
        // 黑洞到代理超时。
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    /// 测试可注入隔离的 URLProtocol session，生产仍使用上面的直连配置。
    init(session: URLSession? = nil) {
        if let session { self.session = session }
    }

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
    /// (nested) keys; comment stripping and unquoting go through `YamlScalar`
    /// (C2/CFG-15：`#` 前须空白才是注释，引号内的 `#` 是数据——旧「第一个 # 截断」
    /// 口径会把含 # 的自定义 secret 截短，401 且无法自愈). Sufficient for the
    /// flat controller/secret fields; not a general YAML parser.
    private static func yamlScalar(_ key: String, in text: String) -> String? {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), line.hasPrefix(key) else { continue }
            let after = line.dropFirst(key.count)
            guard after.first == ":" else { continue }
            let val = after.dropFirst().trimmingCharacters(in: .whitespaces)
            let parsed = YamlScalar.parse(val)
            let str: String
            switch parsed {
            case let s as String: str = s
            case let i as Int: str = String(i)      // 纯数字 secret 也是合法字符串
            case let b as Bool: str = String(b)
            default: str = YamlScalar.stripInlineComment(val)
            }
            return str.isEmpty ? nil : str
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
        return try autoreleasepool {
            try SafeDecoder.shared.decode(T.self, from: data)
        }
    }

    func fetchVersion() async throws -> MihomoVersion { try await get("/version") }
    func fetchProxies() async throws -> ProxiesPayload { try await get("/proxies") }
    func fetchRules() async throws -> RulesPayload { try await get("/rules") }
    func fetchProviders() async throws -> ProvidersPayload { try await get("/providers/proxies") }

    /// Force-update a subscription (proxy provider).
    ///
    /// 必须检查状态码：mihomo 在上游订阅拉取失败时回的**不是**连接错误，而是一个
    /// 5xx 响应体。旧实现 `_ = try await session.data(for: req)` 把响应丢掉，于是
    /// “上游拉不到订阅”走成成功路径 —— 界面弹绿条、节点一个没变（P0-6 的另一半）。
    func updateProvider(_ name: String) async throws {
        // 名称是单个 path segment；urlPathAllowed 会保留 /，把导入名称拆成路由。
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard let enc = name.addingPercentEncoding(withAllowedCharacters: allowed),
              var req = request("/providers/proxies/\(enc)", method: "PUT") else { throw MihomoError.badURL }
        // 更新会等待远端订阅下载，不能沿用本地状态轮询的 6 秒超时。
        req.timeoutInterval = 60
        let (_, resp) = try await session.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw MihomoError.http(h.statusCode)
        }
    }

    /// Health-check a subscription (triggers delay test for all its nodes).
    func healthCheckProvider(_ name: String) async throws {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let req = request("/providers/proxies/\(enc)/healthcheck") else { throw MihomoError.badURL }
        let (_, resp) = try await session.data(for: req)
        // C3：401/404 等失败必须可分辨，不能把错误响应当「已触发」。
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw MihomoError.http(h.statusCode)
        }
    }

    /// Resolve a name via the kernel's DNS (returns raw JSON).
    func dnsQuery(name: String, type: String = "A") async throws -> [String: Any] {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        guard let req = request("/dns/query?name=\(enc)&type=\(type)") else { throw MihomoError.badURL }
        let (data, _) = try await session.data(for: req)
        return autoreleasepool {
            (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
    }

    func fetchConfigs() async throws -> [String: Any] {
        guard let req = request("/configs") else { throw MihomoError.badURL }
        let (data, resp) = try await session.data(for: req)
        // 非 200（典型：secret 不匹配的 401）的 body 是错误 JSON，旧实现会把它
        // 当成“一份没有 tun/dns 键的配置”返回 —— 于是 refreshConfigs 看起来
        // “成功但什么都没发生”，P0-3 的失败分支永远进不去。这里如实判错。
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw MihomoError.http(h.statusCode)
        }
        return autoreleasepool {
            (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
    }

    /// Switch a Selector group's active proxy.
    func selectProxy(group: String, name: String) async throws {
        let enc = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        let body = try JSONEncoder().encode(["name": name])
        guard let req = request("/proxies/\(enc)", method: "PUT", body: body) else { throw MihomoError.badURL }
        let (_, resp) = try await session.data(for: req)
        // C3：mihomo 成功回 204；401/400（节点不存在）必须抛错而不是假成功。
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw MihomoError.http(h.statusCode)
        }
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
        let (_, resp) = try await session.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw MihomoError.http(h.statusCode) }
    }

    /// Reload config from a file path (force). Surfaces mihomo's error message
    /// (e.g. a bad proxy-group reference) instead of silently "succeeding".
    func reloadConfig(path: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["path": path])
        guard var req = request("/configs?force=true", method: "PUT", body: data) else { throw MihomoError.badURL }
        // Force-reload may synchronously download geodata / rule-providers referenced by
        // the new profile. The shared 6s timeout (request(_:)) is far too short for that
        // and turns a slow first load into a false "apply failed" + rollback. Match the
        // 60s budget used by updateProvider(_:), which waits on the same kind of fetch.
        req.timeoutInterval = 60
        let (respData, resp) = try await session.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: respData) as? [String: Any])?["message"] as? String
            throw MihomoError.reload(msg ?? "HTTP \(h.statusCode)")
        }
    }

    /// Close all active connections.
    func closeAllConnections() async throws {
        guard let req = request("/connections", method: "DELETE") else { throw MihomoError.badURL }
        let (_, resp) = try await session.data(for: req)
        // C3：401 也回错误 JSON 而不是连接错误——旧实现照弹「已断开所有连接」。
        // 抛错后调用方（AppModel.closeAllConnections）走 catch 弹失败 toast。
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw MihomoError.http(h.statusCode)
        }
    }

    /// Close a single connection by ID.
    func closeConnection(id: String) async throws {
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let req = request("/connections/\(enc)", method: "DELETE") else { throw MihomoError.badURL }
        _ = try await session.data(for: req)
    }

    /// Fetch a single snapshot of active connections via HTTP GET.
    func fetchConnectionsSnapshot() async throws -> ConnectionsSnapshot {
        guard let req = request("/connections", method: "GET") else { throw MihomoError.badURL }
        let (data, resp) = try await session.data(for: req)
        // C3：非 200（典型 401）的 body 是错误 JSON，解码它只会得到一条含糊的
        // DecodingError；先判状态码，让调用方能分辨「密钥不匹配」与「数据坏了」。
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw MihomoError.http(h.statusCode)
        }
        // Largest and most frequent decode in the app (every 1.5 s, one object
        // per live connection). Pool it like the generic `get` path already does
        // so JSONDecoder's temporaries drain here instead of piling up in the
        // caller's run-loop pool.
        return try autoreleasepool {
            try SafeDecoder.shared.decode(ConnectionsSnapshot.self, from: data)
        }
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

    /// 最近一次探测失败的原因（超时 / 401 未授权 / 连接被拒…）。
    ///
    /// 普通属性而不是 `@Published`：探测在重连与巡检里是高频路径，而“为什么不可达”
    /// 只需要进日志。`secret` 不匹配（HTTP 401）是最常见的“内核活着但 App 说不可达”，
    /// 它和“内核没起来（连接被拒）”的处置完全不同，日志里必须能分辨。
    private(set) var lastProbeError: String?

    func probe(timeout: TimeInterval = 1.0) async {
        guard let url = URL(string: apiBase + "/version") else {
            reachable = false
            lastProbeError = "无效的 API 地址（\(apiBase)）"
            return
        }
        var r = URLRequest(url: url)
        r.timeoutInterval = timeout
        if !secret.isEmpty { r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }

        do {
            let (data, resp) = try await session.data(for: r)
            // 旧实现直接解码 body：401 的 body 是错误 JSON，解码失败只会得到一句
            // “不可达”，把“密钥不匹配”这个最需要动作的原因丢掉了。
            // 只在**确实是 HTTP 响应**且非 200 时判错（不该把“没有响应头”当 HTTP 0）。
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                throw MihomoError.http(h.statusCode)
            }
            let v = try SafeDecoder.shared.decode(MihomoVersion.self, from: data)
            version = v.version
            reachable = true
            lastProbeError = nil
        } catch {
            reachable = false
            lastProbeError = Self.probeFailureReason(error)
            // 内核退出后不能继续挂上一次的版本号 —— 那是“它还在跑”的假象。
            // 等值短路：version 已经是 "?" 时不触发 @Published 重绘。
            if version != "?" { version = "?" }
        }
    }

    /// 把探测失败压成一句可分辨的中文原因。
    private static func probeFailureReason(_ error: Error) -> String {
        if let m = error as? MihomoError {
            if case .http(let code) = m {
                if code == 401 || code == 403 {
                    return "HTTP \(code)（API 密钥不匹配 / 未授权）"
                }
                return "HTTP \(code)"
            }
            return m.errorDescription ?? "未知错误"
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch ns.code {
        case NSURLErrorTimedOut:                     return "请求超时（\(ns.code)）"
        case NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost:        return "连接被拒 / 内核未启动（\(ns.code)）"
        case NSURLErrorNotConnectedToInternet:       return "网络不可用（\(ns.code)）"
        case NSURLErrorCancelled:                    return "探测被取消（\(ns.code)）"
        default:                                     return "网络错误（\(ns.code)）"
        }
    }

    func probe() async {
        await probe(timeout: 1.0)
    }

    // MARK: WebSocket streams

    private func wsURL(_ path: String) -> URL? {
        var s = wsBase + path
        if !secret.isEmpty {
            // C2：token 必须百分号编码——裸 `#` 会被当成 URL fragment 截断，
            // WS 静默鉴权失败、连接页断流。在 urlQueryAllowed 基础上再排除
            // `&=+`：前两者会拆分查询参数，Go 的 query 解析把 `+` 读成空格。
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))
            let enc = secret.addingPercentEncoding(withAllowedCharacters: allowed) ?? secret
            s += (path.contains("?") ? "&" : "?") + "token=\(enc)"
        }
        return URL(string: s)
    }

    /// Generic line-delimited JSON WebSocket stream. Reconnects on drop.
    func stream<T: Decodable>(_ path: String, type: T.Type, onValue: @escaping @Sendable (T) -> Void) -> WSHandle {
        let handle = WSHandle()
        connectStream(path, type: type, handle: handle, onValue: onValue)
        return handle
    }

    /// Raw-Data WebSocket stream — lets the caller fingerprint the payload before
    /// decoding, so an unchanged snapshot (mihomo pushes the full list on every
    /// WS message, not just on change) can be skipped without paying for JSON
    /// decode of thousands of connection objects.
    func streamRaw(_ path: String, onValue: @escaping @Sendable (Data) -> Void) -> WSHandle {
        let handle = WSHandle()
        connectStreamRaw(path, handle: handle, onValue: onValue)
        return handle
    }

    private func connectStream<T: Decodable>(_ path: String, type: T.Type, handle: WSHandle, onValue: @escaping @Sendable (T) -> Void) {
        guard let url = wsURL(path) else { return }
        let task = session.webSocketTask(with: url)
        handle.task = task
        task.resume()
        handle.armHeartbeat()
        receiveLoop(task: task, path: path, type: T.self, handle: handle, onValue: onValue)
    }

    /// nonisolated receive loop so the WebSocket completion handler (which runs
    /// off the main actor) can recurse without main-actor isolation warnings.
    private nonisolated func receiveLoop<T: Decodable>(task: URLSessionWebSocketTask, path: String, type: T.Type, handle: WSHandle, onValue: @escaping @Sendable (T) -> Void) {
        task.receive { [weak self] result in
            guard let self, !handle.cancelled else { return }
            switch result {
            case .success(let msg):
                autoreleasepool {
                    if case .string(let s) = msg, let data = s.data(using: .utf8),
                       let v = try? SafeDecoder.shared.decode(T.self, from: data) {
                        onValue(v)   // onValue hops to @MainActor itself
                    }
                }
                self.receiveLoop(task: task, path: path, type: T.self, handle: handle, onValue: onValue)
            case .failure:
                // Reconnect after a short delay — but only if the API is
                // reachable. After sleep/wake all 4 streams fail at once;
                // blindly reconnecting creates a storm of parallel WebSocket
                // connections. The main `reconnect()` flow re-establishes
                // reachability and rebuilds its own streams; a stream whose
                // API is down now waits with backoff instead of dying forever
                // (C8：页面仍活跃时内核恢复后自动重建，不必切走再切回).
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !handle.cancelled else { return }
                    if self.reachable {
                        self.connectStream(path, type: T.self, handle: handle, onValue: onValue)
                    } else {
                        self.retryWhenReachable(handle: handle, delay: 5) {
                            self.connectStream(path, type: T.self, handle: handle, onValue: onValue)
                        }
                    }
                }
            }
        }
    }

    /// C8：指数退避等待内核恢复（5s 起步、翻倍、60s 封顶），恢复即重建流。
    /// 只在 handle 未取消时循环；`reconnect()` / 页面 `stop()` 重建或回收流时
    /// 会 cancel 旧 handle，本循环下一次醒来即退出，不会与新流叠加。
    private func retryWhenReachable(handle: WSHandle, delay: TimeInterval,
                                    reconnect: @escaping @MainActor () -> Void) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !handle.cancelled else { return }
            if self.reachable {
                reconnect()
            } else {
                self.retryWhenReachable(handle: handle, delay: min(delay * 2, 60),
                                        reconnect: reconnect)
            }
        }
    }

    private func connectStreamRaw(_ path: String, handle: WSHandle, onValue: @escaping @Sendable (Data) -> Void) {
        guard let url = wsURL(path) else { return }
        let task = session.webSocketTask(with: url)
        handle.task = task
        task.resume()
        handle.armHeartbeat()
        receiveLoopRaw(task: task, path: path, handle: handle, onValue: onValue)
    }

    private nonisolated func receiveLoopRaw(task: URLSessionWebSocketTask, path: String, handle: WSHandle, onValue: @escaping @Sendable (Data) -> Void) {
        task.receive { [weak self] result in
            guard let self, !handle.cancelled else { return }
            switch result {
            case .success(let msg):
                autoreleasepool {
                    switch msg {
                    case .string(let s):
                        if let d = s.data(using: .utf8) { onValue(d) }
                    case .data(let d):
                        onValue(d)
                    @unknown default:
                        break
                    }
                }
                self.receiveLoopRaw(task: task, path: path, handle: handle, onValue: onValue)
            case .failure:
                // C8：与 receiveLoop 同一形状——可达即重建，不可达退避等待，
                // 不再永久放弃（连接页的 raw 流正是「降级后无重建」的受害者）。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !handle.cancelled else { return }
                    if self.reachable {
                        self.connectStreamRaw(path, handle: handle, onValue: onValue)
                    } else {
                        self.retryWhenReachable(handle: handle, delay: 5) {
                            self.connectStreamRaw(path, handle: handle, onValue: onValue)
                        }
                    }
                }
            }
        }
    }
}

final class WSHandle: @unchecked Sendable {
    var task: URLSessionWebSocketTask?
    var cancelled = false {
        didSet { if cancelled { pingTimer?.invalidate(); pingTimer = nil } }
    }
    /// Heartbeat (D3): `URLSessionWebSocketTask.receive` has no timeout, so a
    /// half-open connection after sleep/wake neither delivers messages nor
    /// fails — the stream goes silently stale with no reconnect. A periodic
    /// ping turns "connection dead" into a send failure → task cancel → the
    /// normal failure/reconnect path. Created on the main runloop (stream()
    /// is only called from MainActor); drained by cancel().
    var pingTimer: Timer?
    private let pingInterval: TimeInterval = 20

    func armHeartbeat() {
        pingTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            guard let self, !self.cancelled, let task = self.task else { return }
            task.sendPing { [weak self] error in
                guard let self, !self.cancelled else { return }
                if error != nil {
                    // Dead connection: cancel so the pending receive fails and
                    // the standard reconnect logic takes over.
                    self.pingTimer?.invalidate()
                    task.cancel(with: .goingAway, reason: nil)
                }
            }
        }
        pingTimer = t
    }

    func cancel() {
        cancelled = true
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
    }
}
