// MihomoClient — REST + WebSocket client for the mihomo external controller.
//
// Talks directly to a running mihomo kernel's RESTful API. No custom engine
// layer: this is a thin, correct client over mihomo's documented endpoints.
//
//   REST:  GET /version, /proxies, /rules, /configs
//          PUT /proxies/:name           (switch selection)
//          GET /proxies/:name/delay      (latency test)
//          PUT /configs?force=true       (patch running config / mode)
//   WS:    /traffic, /memory, /logs, /connections  (server pushes ~1/s)
//
// Auth: REST uses `Authorization: Bearer <secret>`. WebSockets use `?token=<secret>`.

import Foundation
import SwiftUI

// MARK: - Wire types (match mihomo JSON exactly)

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

// MARK: - Errors

enum MihomoError: LocalizedError {
    case badURL, http(Int), notRunning
    var errorDescription: String? {
        switch self {
        case .badURL: return "无效的 API 地址"
        case .http(let c): return "HTTP \(c)"
        case .notRunning: return "内核未运行或地址错误"
        }
    }
}

// MARK: - Client

@MainActor
final class MihomoClient: ObservableObject {
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

    /// Reload config from a file path (force).
    func reloadConfig(path: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["path": path])
        guard let req = request("/configs?force=true", method: "PUT", body: data) else { throw MihomoError.badURL }
        _ = try await session.data(for: req)
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

    func probe() async {
        do { let v = try await fetchVersion(); version = v.version; reachable = true }
        catch { reachable = false }
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
    func stream<T: Decodable>(_ path: String, type: T.Type, onValue: @escaping (T) -> Void) -> WSHandle {
        let handle = WSHandle()
        connectStream(path, type: type, handle: handle, onValue: onValue)
        return handle
    }

    private func connectStream<T: Decodable>(_ path: String, type: T.Type, handle: WSHandle, onValue: @escaping (T) -> Void) {
        guard let url = wsURL(path) else { return }
        let task = session.webSocketTask(with: url)
        handle.task = task
        task.resume()

        func receive() {
            task.receive { [weak self] result in
                guard let self, !handle.cancelled else { return }
                switch result {
                case .success(let msg):
                    if case .string(let s) = msg, let data = s.data(using: .utf8),
                       let v = try? JSONDecoder().decode(T.self, from: data) {
                        Task { @MainActor in onValue(v) }
                    }
                    receive()
                case .failure:
                    // Reconnect after a short delay
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        if !handle.cancelled { self.connectStream(path, type: type, handle: handle, onValue: onValue) }
                    }
                }
            }
        }
        receive()
    }
}

/// Cancellable handle for a WebSocket stream.
final class WSHandle {
    var task: URLSessionWebSocketTask?
    var cancelled = false
    func cancel() { cancelled = true; task?.cancel(with: .goingAway, reason: nil) }
}

// MARK: - EngineControl (UDS typed-RPC control plane)
//
// Talks to the ClashPow engine over its Unix Domain Socket. Used for control
// operations mihomo's REST cannot do (managed lifecycle, mmap rule compile,
// TUN with our extensions) and to discover the embedded controller endpoint.

struct EngineStatusRPC: Decodable {
    let running: Bool
    let tunEnabled: Bool
    let connections: Int
    let uptimeSec: Int64
    let version: String
    let controllerAddr: String
    let controllerSecret: String
    let isRoot: Bool
    enum CodingKeys: String, CodingKey {
        case running, tunEnabled = "tun_enabled", connections
        case uptimeSec = "uptime_sec", version
        case controllerAddr = "controller_addr", controllerSecret = "controller_secret"
        case isRoot = "is_root"
    }
}

@MainActor
final class EngineControl: ObservableObject {
    static let shared = EngineControl()
    let socketPath = "/tmp/clashpow-engine.sock"

    @Published var present = false
    @Published var uptimeSec: Int64 = 0
    @Published var engineVersion = "?"
    @Published var isRoot = false          // engine running as root LaunchDaemon (TUN-capable)

    private let appSupport = NSHomeDirectory() + "/Library/Application Support/ClashPow"
    private let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.clashpow.engine.plist"
    private let rootPlistPath = "/Library/LaunchDaemons/com.clashpow.engine.plist"

    /// First-run bootstrap: install the bundled engine + geodata and the
    /// LaunchAgent so the kernel runs without any manual setup. Idempotent.
    func ensureInstalled() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        let engineDst = appSupport + "/clashpow-engine"

        let bundled = Bundle.main.resourceURL?.appendingPathComponent("clashpow-engine")
        if let bundled = bundled, fm.fileExists(atPath: bundled.path) {
            var needsCopy = false
            if !fm.fileExists(atPath: engineDst) {
                needsCopy = true
            } else {
                let bundledAttr = try? fm.attributesOfItem(atPath: bundled.path)
                let installedAttr = try? fm.attributesOfItem(atPath: engineDst)
                let bundledSize = bundledAttr?[.size] as? UInt64 ?? 0
                let installedSize = installedAttr?[.size] as? UInt64 ?? 0
                if bundledSize != installedSize {
                    needsCopy = true
                }
            }
            
            if needsCopy {
                try? fm.removeItem(atPath: engineDst)
                try? fm.copyItem(atPath: bundled.path, toPath: engineDst)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engineDst)
            }
        }

        // bundled geodata (optional)
        for f in ["GeoSite.dat", "geoip.metadb", "ASN.mmdb"] {
            if let g = Bundle.main.resourceURL?.appendingPathComponent(f), fm.fileExists(atPath: g.path) {
                let dst = appSupport + "/" + f
                var needsCopy = false
                if !fm.fileExists(atPath: dst) {
                    needsCopy = true
                } else {
                    let srcSize = (try? fm.attributesOfItem(atPath: g.path))?[.size] as? UInt64 ?? 0
                    let dstSize = (try? fm.attributesOfItem(atPath: dst))?[.size] as? UInt64 ?? 0
                    if srcSize != dstSize {
                        needsCopy = true
                    }
                }
                if needsCopy {
                    try? fm.removeItem(atPath: dst)
                    try? fm.copyItem(atPath: g.path, toPath: dst)
                }
            }
        }

        // Install + load the LaunchAgent if absent.
        if !fm.fileExists(atPath: plistPath), fm.fileExists(atPath: engineDst) {
            let logDir = NSHomeDirectory() + "/Library/Logs/ClashPow"
            try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>com.clashpow.engine</string>
              <key>ProgramArguments</key><array><string>\(engineDst)</string></array>
              <key>RunAtLoad</key><true/>
              <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/><key>Crashed</key><true/></dict>
              <key>ThrottleInterval</key><integer>3</integer>
              <key>ProcessType</key><string>Adaptive</string>
              <key>StandardOutPath</key><string>\(logDir)/clashpow-engine.log</string>
              <key>StandardErrorPath</key><string>\(logDir)/clashpow-engine.log</string>
            </dict></plist>
            """
            try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["load", plistPath]
            try? task.run(); task.waitUntilExit()
        }
    }

    /// One-shot newline-delimited JSON-RPC call over the UDS.
    private func call(_ method: String, params: String = "{}") async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global().async {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { cont.resume(returning: nil); return }
                defer { close(fd) }
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                _ = self.socketPath.withCString { src in
                    withUnsafeMutablePointer(to: &addr.sun_path) {
                        $0.withMemoryRebound(to: CChar.self, capacity: 104) { dst in strcpy(dst, src) }
                    }
                }
                let len = socklen_t(MemoryLayout<sockaddr_un>.size)
                let ok = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
                }
                guard ok == 0 else { cont.resume(returning: nil); return }

                // Set 10s receive timeout
                var tv = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                let payload = #"{"jsonrpc":"2.0","method":"\#(method)","params":\#(params),"id":1}"# + "\n"
                guard let payloadData = payload.data(using: .utf8) else { cont.resume(returning: nil); return }
                var sent = 0
                let total = payloadData.count
                var failed = false
                payloadData.withUnsafeBytes { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    while sent < total {
                        let n = send(fd, baseAddress + sent, total - sent, 0)
                        if n <= 0 { failed = true; break }
                        sent += n
                    }
                }
                guard !failed else { cont.resume(returning: nil); return }
                
                var data = Data()
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = recv(fd, &buf, buf.count, 0)
                    if n <= 0 { break }
                    data.append(contentsOf: buf[0..<n])
                    if buf[0..<n].contains(10) { break } // 10 is '\n'
                }
                cont.resume(returning: data.isEmpty ? nil : data)
            }
        }
    }

    private struct Envelope<T: Decodable>: Decodable { let result: T? }

    /// Probe engine + discover controller. Returns (addr, secret) when present.
    @discardableResult
    func refresh() async -> (addr: String, secret: String)? {
        guard let data = await call("get_status"),
              let env = try? JSONDecoder().decode(Envelope<EngineStatusRPC>.self, from: data),
              let s = env.result else {
            present = false
            isRoot = false
            engineVersion = "?"
            return nil
        }
        present = true
        uptimeSec = s.uptimeSec
        engineVersion = s.version
        isRoot = s.isRoot
        guard !s.controllerAddr.isEmpty else { return nil }
        return (s.controllerAddr, s.controllerSecret)
    }

    /// Promote the engine to a root LaunchDaemon so TUN works. Requires one
    /// administrator-auth prompt (osascript). Installs the engine + geodata to a
    /// system path, unloads the user LaunchAgent, writes /Library/LaunchDaemons,
    /// and bootstraps it as root. Returns true on success.
    @discardableResult
    func installPrivileged() async -> Bool {
        let engineBin = appSupport + "/clashpow-engine"
        guard FileManager.default.fileExists(atPath: engineBin) else { return false }
        let logDir = NSHomeDirectory() + "/Library/Logs/ClashPow"
        // The root daemon runs the engine binary copied to /Library/PrivilegedHelperTools but as root,
        // with the same app-support home so config/geodata/controller are unchanged.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>com.clashpow.engine</string>
          <key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/clashpow-engine</string></array>
          <key>EnvironmentVariables</key><dict><key>CLASHPOW_CONFIG</key><string>\(appSupport)/config.yaml</string></dict>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/><key>Crashed</key><true/></dict>
          <key>ThrottleInterval</key><integer>3</integer>
          <key>Umask</key><integer>0</integer>
          <key>StandardOutPath</key><string>\(logDir)/clashpow-engine.log</string>
          <key>StandardErrorPath</key><string>\(logDir)/clashpow-engine.log</string>
        </dict></plist>
        """
        // Write the plist to a temp file the privileged shell will move into place.
        let tmpPlist = NSTemporaryDirectory() + "com.clashpow.engine.plist"
        guard (try? plist.write(toFile: tmpPlist, atomically: true, encoding: .utf8)) != nil else { return false }

        // One privileged shell: stop user agent, copy engine to secure path & chmod, install root daemon, bootstrap it.
        let uid = getuid()
        let shell = [
            "/usr/bin/killall -9 mihomo clashpow-engine 2>/dev/null || true",
            "if /usr/sbin/lsof -t -iTCP:7890 -sTCP:LISTEN >/dev/null; then /bin/kill -9 $(/usr/sbin/lsof -t -iTCP:7890 -sTCP:LISTEN) 2>/dev/null || true; fi",
            "if /usr/sbin/lsof -t -iTCP:9092 -sTCP:LISTEN >/dev/null; then /bin/kill -9 $(/usr/sbin/lsof -t -iTCP:9092 -sTCP:LISTEN) 2>/dev/null || true; fi",
            "/sbin/route -n delete -net 1.0.0.0/8 2>/dev/null || true",
            "/sbin/route -n delete -net 198.18.0.0/15 2>/dev/null || true",
            "/bin/launchctl bootout gui/\(uid)/com.clashpow.engine 2>/dev/null || true",
            "/bin/launchctl unload '\(plistPath)' 2>/dev/null || true",
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/cp '\(engineBin)' /Library/PrivilegedHelperTools/clashpow-engine",
            "/usr/sbin/chown root:wheel /Library/PrivilegedHelperTools/clashpow-engine",
            "/bin/chmod 755 /Library/PrivilegedHelperTools/clashpow-engine",
            "/bin/cp '\(tmpPlist)' '\(rootPlistPath)'",
            "/usr/sbin/chown root:wheel '\(rootPlistPath)'",
            "/bin/chmod 644 '\(rootPlistPath)'",
            "/bin/launchctl bootout system/com.clashpow.engine 2>/dev/null || true",
            "/bin/launchctl bootstrap system '\(rootPlistPath)'",
        ].joined(separator: "; ")
        let ok = await Self.runAdmin(shell)
        if ok { isRoot = true }
        return ok
    }

    /// Demote back to the user LaunchAgent (removes the root daemon). Admin auth.
    @discardableResult
    func uninstallPrivileged() async -> Bool {
        let shell = [
            "/bin/launchctl bootout system/com.clashpow.engine 2>/dev/null || true",
            "/bin/rm -f '\(rootPlistPath)'",
            "/bin/rm -f /Library/PrivilegedHelperTools/clashpow-engine",
            "/usr/bin/killall -9 mihomo clashpow-engine 2>/dev/null || true",
            "if /usr/sbin/lsof -t -iTCP:7890 -sTCP:LISTEN >/dev/null; then /bin/kill -9 $(/usr/sbin/lsof -t -iTCP:7890 -sTCP:LISTEN) 2>/dev/null || true; fi",
            "if /usr/sbin/lsof -t -iTCP:9092 -sTCP:LISTEN >/dev/null; then /bin/kill -9 $(/usr/sbin/lsof -t -iTCP:9092 -sTCP:LISTEN) 2>/dev/null || true; fi",
            "/sbin/route -n delete -net 1.0.0.0/8 2>/dev/null || true",
            "/sbin/route -n delete -net 198.18.0.0/15 2>/dev/null || true",
        ].joined(separator: "; ")
        let ok = await Self.runAdmin(shell)
        if ok {
            isRoot = false
            // bring the user LaunchAgent back
            let t = Process(); t.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            t.arguments = ["load", plistPath]; try? t.run(); t.waitUntilExit()
        }
        return ok
    }

    /// Run a shell snippet with administrator privileges via one osascript prompt.
    static func runAdmin(_ shell: String) async -> Bool {
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

    /// Deep-merge config overrides into the running config (validate + rollback).
    @discardableResult
    func patchConfig(_ overrides: [String: Any]) async -> Bool {
        guard let pd = try? JSONSerialization.data(withJSONObject: overrides),
              let params = String(data: pd, encoding: .utf8) else {
            print("patchConfig: serialization failed")
            return false
        }
        print("patchConfig: sending overrides: \(params)")
        guard let data = await call("patch_config", params: params) else {
            print("patchConfig: UDS call returned nil")
            return false
        }
        if let str = String(data: data, encoding: .utf8) {
            print("patchConfig: received raw response: \(str)")
        }
        
        do {
            struct Resp: Decodable { struct R: Decodable { let ok: Bool? }; let result: R? }
            let resp = try JSONDecoder().decode(Resp.self, from: data)
            let ok = resp.result?.ok == true
            print("patchConfig: decoded success: \(ok)")
            return ok
        } catch {
            print("patchConfig: decode error: \(error)")
            if let str = String(data: data, encoding: .utf8) {
                print("patchConfig: raw data was: \(str)")
            }
            return false
        }
    }

    func restart() async { _ = await call("shutdown") }   // launchd KeepAlive respawns
    func startTUN() async { _ = await call("start_tun") }
    func stopTUN() async { _ = await call("stop_tun") }

    /// Ask the root engine daemon to set/clear the macOS system HTTP/HTTPS/SOCKS proxy.
    /// Since the engine runs as root, this does not pop up any authorization dialogs.
    @discardableResult
    func setSystemProxy(enabled: Bool, port: Int) async -> Bool {
        let params = #"{"enabled":\#(enabled),"port":\#(port)}"#
        guard let data = await call("set_system_proxy", params: params) else { return false }
        struct Resp: Decodable { struct R: Decodable { let ok: Bool? }; let result: R? }
        return (try? JSONDecoder().decode(Resp.self, from: data))?.result?.ok == true
    }

    /// Apply a full YAML config. The engine validates + applies with rollback;
    /// returns (ok, errorMessage). A non-nil error means validation failed and
    /// the engine kept the previous good config.
    func setConfig(_ yaml: String) async -> (ok: Bool, error: String?) {
        let pd = try? JSONSerialization.data(withJSONObject: ["config_yaml": yaml])
        let params = pd.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        guard let data = await call("set_config", params: params) else { return (false, "引擎无响应") }
        struct Resp: Decodable {
            struct R: Decodable { let ok: Bool? }
            struct E: Decodable { let message: String }
            let result: R?; let error: E?
        }
        guard let r = try? JSONDecoder().decode(Resp.self, from: data) else { return (false, "解析失败") }
        if let e = r.error { return (false, e.message) }
        return (r.result?.ok == true, nil)
    }
}


// MARK: - KernelManager (mihomo core version + stable/alpha download)
//
// Fetches available mihomo cores from MetaCubeX/mihomo GitHub releases and
// downloads the darwin-arm64 binary into kernels/<tag>/. The running core is
// embedded in the engine today; downloaded cores prepare a future supervisor
// (external-exec) switch and let users pin a stable/alpha build.

@MainActor
final class KernelManager: ObservableObject {
    static let shared = KernelManager()
    @AppStorage("kernel.channel") var channel = "stable"   // stable | alpha
    @Published var latestTag = ""
    @Published var assetURL = ""
    @Published var checking = false
    @Published var downloading = false
    @Published var progress = 0.0
    @Published var installedTags: [String] = []
    @Published var note = ""

    private let dir = NSHomeDirectory() + "/Library/Application Support/ClashPow/kernels"
    private var kernelJSONPath: String { NSHomeDirectory() + "/Library/Application Support/ClashPow/kernel.json" }
    @AppStorage("kernel.active") var activeTag = ""   // "" = embedded

    /// Switch to a downloaded kernel: write kernel.json + restart the engine,
    /// which respawns in supervisor mode running the external binary.
    func activate(_ tag: String) async {
        let bin = dir + "/\(tag)/mihomo"
        guard FileManager.default.fileExists(atPath: bin) else { note = "内核文件缺失"; return }
        let obj: [String: String] = ["external": bin, "tag": tag]
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            try? d.write(to: URL(fileURLWithPath: kernelJSONPath))
        }
        activeTag = tag
        note = "正在切换到 \(tag)…"
        await EngineControl.shared.restart()
    }

    /// Revert to the embedded kernel: remove kernel.json + restart the engine.
    func useEmbedded() async {
        try? FileManager.default.removeItem(atPath: kernelJSONPath)
        activeTag = ""
        note = "正在切回内嵌内核…"
        await EngineControl.shared.restart()
    }

    func scanInstalled() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        installedTags = (try? fm.contentsOfDirectory(atPath: dir))?.sorted() ?? []
    }

    func check() async {
        checking = true; note = ""; defer { checking = false }
        let api = channel == "alpha"
            ? "https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha"
            : "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
        guard let url = URL(string: api) else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ClashPow", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { note = "网络错误"; return }
        if let h = resp as? HTTPURLResponse, h.statusCode == 403 { note = "GitHub API 限流，请稍后再试"; return }
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct Release: Decodable { let tag_name: String; let assets: [Asset] }
        guard let r = try? JSONDecoder().decode(Release.self, from: data) else { note = "解析失败"; return }
        latestTag = r.tag_name
        // darwin-arm64, prefer non-"compatible"/non-go120 variant, .gz
        if let a = r.assets.first(where: { $0.name.contains("darwin-arm64") && $0.name.hasSuffix(".gz") && !$0.name.contains("compatible") && !$0.name.contains("go1") })
            ?? r.assets.first(where: { $0.name.contains("darwin-arm64") && $0.name.hasSuffix(".gz") }) {
            assetURL = a.browser_download_url
        } else { note = "未找到 darwin-arm64 资源" }
    }

    func download() async {
        guard let url = URL(string: assetURL), !latestTag.isEmpty else { return }
        downloading = true; progress = 0; note = ""; defer { downloading = false }
        guard let (tmp, _) = try? await URLSession.shared.download(from: url) else { note = "下载失败"; return }
        let fm = FileManager.default
        let tagDir = dir + "/\(latestTag)"
        try? fm.createDirectory(atPath: tagDir, withIntermediateDirectories: true)
        // decompress .gz → mihomo
        let out = tagDir + "/mihomo"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c", tmp.path]
        let outFile = FileManager.default.createFile(atPath: out, contents: nil)
        guard outFile, let fh = FileHandle(forWritingAtPath: out) else { note = "写入失败"; return }
        p.standardOutput = fh
        do { try p.run(); p.waitUntilExit(); try? fh.close() } catch { note = "解压失败"; return }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out)
        progress = 1; scanInstalled()
        note = "已下载 \(latestTag)（\(channel == "alpha" ? "Alpha" : "正式版")）"
    }
}
