import Foundation

/// One row in the tailnet device list returned by the Tailscale API
/// (`GET /api/v2/tailnet/-/devices`). Only fields surfaced in the UI.
struct TailscaleDevice: Identifiable, Hashable {
    let id: String           // node ID (stable)
    let hostname: String
    let ips: [String]        // tailnet + subnet addresses (IPv4 only for now)
    let online: Bool
    let os: String
    let expiresAt: String?   // raw ISO; formatted on demand
    let lastSeen: String?
    let ephemeral: Bool
    /// Subnet routes this node advertises (from `fields=all`). IPv4 only.
    let advertisedRoutes: [String]
    /// Subnet routes the tailnet has approved for this node.
    let enabledRoutes: [String]
}

// Tailscale control-plane REST client for the device panel.
//
// Pure enough to compile under `Scripts/run-tests.sh` (no UI, no AppModel, no
// Keychain). The caller supplies the token and a URLSession that already
// bypasses the system proxy — otherwise, with system proxy ON, the request
// would loop into our own mixed-port and hang for the full timeout.

enum TailscaleAPI {

    enum Error: Swift.Error, Equatable {
        case noToken
        case badURL
        case http(Int)
        case decode
        case transport(String)
    }

    /// Decode the official devices list into the UI-facing model.
    ///
    /// Kept free of networking so the regression suite can feed it fixture
    /// JSON without spinning up a session. Only IPv4 addresses are kept —
    /// the current UI and the auto-rule generator are IPv4-first.
    static func decodeDevices(_ data: Data) throws -> [TailscaleDevice] {
        try sortDevices(mapDevices(data))
    }

    /// 单页映射（不排序）。decodeDevices 与分页合并（fetchAllPages 的调用方）
    /// 共用同一映射，避免两处各写一份字段需求。
    private static func mapDevices(_ data: Data) throws -> [TailscaleDevice] {
        let root: DevicesRoot
        do {
            root = try JSONDecoder().decode(DevicesRoot.self, from: data)
        } catch {
            throw Error.decode
        }
        return root.devices.map { d in
            let ipv4 = d.addresses.filter { !$0.contains(":") }
            // Prefer the short hostname for display; fall back to the FQDN
            // (`name`) when hostname is empty. The FQDN is retained on the
            // side for MagicDNS-suffix inference (see `inferMagicDNSSuffix`).
            let host = d.hostname.isEmpty ? d.name : d.hostname
            return TailscaleDevice(
                id: d.id,
                hostname: host,
                ips: ipv4,
                online: d.online ?? false,
                os: d.os ?? "",
                expiresAt: d.keyExpiry,
                lastSeen: d.lastSeen,
                ephemeral: d.isEphemeral ?? false,
                advertisedRoutes: ipv4CIDRs(d.advertisedRoutes ?? []),
                enabledRoutes: ipv4CIDRs(d.enabledRoutes ?? [])
            )
        }
    }

    /// 在线优先，其次主机名（与旧 decodeDevices 内联排序同口径）。
    /// 排序放在**合并全部分页之后**做一次，而不是每页各排各的。
    private static func sortDevices(_ devices: [TailscaleDevice]) -> [TailscaleDevice] {
        devices.sorted { a, b in
            if a.online != b.online { return a.online && !b.online }
            return a.hostname.localizedCaseInsensitiveCompare(b.hostname) == .orderedAscending
        }
    }

    /// Best-effort MagicDNS suffix from a device FQDN like `mac.tail1234.ts.net`.
    /// Returns `tail1234.ts.net` (no leading dot). Nil when nothing looks like
    /// a tailnet FQDN — Headscale custom domains are left alone.
    static func inferMagicDNSSuffix(fromFQDNs names: [String]) -> String? {
        for raw in names {
            let n = raw.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
            guard n.hasSuffix(".ts.net") else { continue }
            let labels = n.split(separator: ".").map(String.init)
            // Official MagicDNS FQDN is `<host>.<tailnet>.ts.net` → 4 labels.
            // Three labels (`<tailnet>.ts.net`) is already the suffix — dropping
            // one more would collapse it to the useless bare `ts.net`.
            // Two labels is just `ts.net` itself and is not informative.
            if labels.count >= 4 {
                return labels.dropFirst().joined(separator: ".")
            }
            if labels.count == 3 { return n }
        }
        return nil
    }

    /// IPv4 CIDRs only. Drops IPv6 and non-CIDR noise from the routes arrays.
    /// F24：严格校验——四段十进制 IPv4 + 前缀 0...32（ASCII 数字，拒 `+8`/`1_0`）。
    /// 旧实现见到 `/` 就原样放行，`1.2.3/8`、`999.1.1.1/8` 这类坏段会一路进
    /// 设备面板与子网建议。输出统一为规范形 `a.b.c.d/n`。
    static func ipv4CIDRs(_ raw: [String]) -> [String] {
        raw.compactMap { entry in
            let t = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !t.contains(":") else { return nil }
            if let slash = t.firstIndex(of: "/") {
                let ip = String(t[..<slash])
                let pref = String(t[t.index(after: slash)...])
                guard isIPv4(ip), !pref.isEmpty,
                      pref.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let n = Int(pref), (0...32).contains(n) else { return nil }
                return "\(ip)/\(n)"
            }
            // Bare IP from a sloppy payload → /32.
            return isIPv4(t) ? "\(t)/32" : nil
        }
    }

    /// 严格四段十进制 IPv4（F24 配套）。本文件独立编译进 tailscale-api-tests
    /// （编译集只有本文件），不能引用 TailscaleOverlay / DeviceIdentity 的同名
    /// 判定，故自带一份同口径实现：ASCII 数字、每段 0...255。
    private static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3
                && p.allSatisfy { $0.isASCII && $0.isNumber }
                && Int(p).map { (0...255).contains($0) } == true
        }
    }

    /// Union of enabled (preferred) then advertised IPv4 routes across devices,
    /// excluding the CGNAT aggregate and default routes. Ready to merge into
    /// `extraCIDRs` after the user confirms.
    ///
    /// TS-1：`isForbidden` 是调用方注入的安全闸门（生产侧 = PeerRouteGuard
    /// 链路专用/本机直连段 + fake-ip 段 + 默认路由）。本文件必须保持纯逻辑、
    /// 可独立编译（tailscale-api-tests 编译集只有本文件），不能直接引用
    /// HelperProtocol 的 PeerRouteGuard，所以闸门以谓词传入；默认放行仅用于
    /// 回归套件的形状断言，生产调用点必须传真实闸门。
    static func suggestedSubnetRoutes(from devices: [TailscaleDevice],
                                      isForbidden: (String) -> Bool = { _ in false }) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for d in devices {
            // Enabled first — those are the ones the control plane actually
            // delivers. Advertised-but-not-enabled are still useful hints.
            for cidr in d.enabledRoutes + d.advertisedRoutes {
                let n = cidr.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty,
                      n != "0.0.0.0/0",
                      n != "100.64.0.0/10",
                      !n.hasSuffix("/32") || !n.hasPrefix("100."), // peer /32s belong elsewhere
                      !isForbidden(n)
                else { continue }
                // Keep peer-shaped /32s out of "subnet" suggestions when they
                // are clearly tailnet node addresses (100.x/32). Broader 100.x
                // subnets (rare) still pass.
                if n.hasPrefix("100."), n.hasSuffix("/32") { continue }
                if seen.insert(n).inserted { out.append(n) }
            }
        }
        return out.sorted()
    }

    /// Extract FQDNs from the raw devices payload without re-decoding the
    /// whole list. Used only for suffix inference.
    static func fqdns(from data: Data) -> [String] {
        guard let root = try? JSONDecoder().decode(DevicesRoot.self, from: data) else { return [] }
        return root.devices.compactMap { d in
            let n = d.name.trimmingCharacters(in: .whitespaces)
            return n.contains(".") ? n : nil
        }
    }

    /// `GET /api/v2/tailnet/{tailnet}/devices` 的单页请求构造与执行。
    ///
    /// URL / Bearer / 超时的**唯一拼装点**：原先 `fetchDevices` 与
    /// AppModel+Tailscale 的 `fetchDevicesWithSuffix` 各复制一份（字段需求一致
    /// ——`fields=all` 才有 advertisedRoutes / enabledRoutes），口径漂移只能
    /// 靠撞见。返回原始 body，设备解码与 FQDN 后缀推断共用同一次网络往返。
    ///
    /// `tailnet` defaults to `-` (the caller's default tailnet). The token is
    /// sent as a Bearer header; Basic-with-empty-password is also accepted by
    /// the server but Bearer is the clearer form.
    static func fetchDevicesPage(token: String,
                                 tailnet: String = "-",
                                 cursor: String? = nil,
                                 session: URLSession) async -> Result<Data, Error> {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.noToken) }
        let enc = tailnet.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tailnet
        var query = "fields=all"
        // 游标值全量百分号编码（只放行字母数字）：游标是服务端 opaque token，
        // 直接拼进 query 串可能注入额外的参数。
        if let cursor, !cursor.isEmpty,
           let encCursor = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            query += "&cursor=\(encCursor)"
        }
        guard let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/\(enc)/devices?\(query)") else {
            return .failure(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        req.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await session.data(for: req)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                return .failure(.http(h.statusCode))
            }
            return .success(data)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    /// 分页上限：API 异常地反复回传同一游标时，最多 20 页就停，防失控。
    private static let maxFetchPages = 20

    /// 跟随响应 `cursor` 续拉全部分页，返回每页原始 body。
    ///
    /// 停止条件：响应缺 `cursor` 字段、游标为空、或达到 20 页上限。响应体解析
    /// 失败时不在这里报错（调用方解码时如实抛 decode），游标按「没有」处理，
    /// 单页停——行为与不支持分页的响应完全一致。
    private static func fetchAllPages(token: String,
                                      tailnet: String,
                                      session: URLSession) async -> Result<[Data], Error> {
        var pages: [Data] = []
        var cursor: String? = nil
        for _ in 0..<maxFetchPages {
            let page: Data
            switch await fetchDevicesPage(token: token, tailnet: tailnet, cursor: cursor, session: session) {
            case .failure(let e):
                return .failure(e)
            case .success(let d):
                page = d
            }
            pages.append(page)
            let next = (try? JSONDecoder().decode(DevicesRoot.self, from: page))?.cursor
            guard let next, !next.isEmpty else { break }
            cursor = next
        }
        return .success(pages)
    }

    /// `GET /api/v2/tailnet/{tailnet}/devices`（分页续拉合并）。
    ///
    /// 设备量大的 tailnet 响应带 `cursor` 时只解一页会**静默丢设备**——面板少
    /// 一台机器、子网建议漏一条，用户看到的还是「成功」。旧版单页即停。
    static func fetchDevices(token: String,
                             tailnet: String = "-",
                             session: URLSession) async -> Result<[TailscaleDevice], Error> {
        switch await fetchAllPages(token: token, tailnet: tailnet, session: session) {
        case .failure(let e):
            return .failure(e)
        case .success(let pages):
            do {
                var all: [TailscaleDevice] = []
                for page in pages { all += try mapDevices(page) }
                return .success(sortDevices(all))
            } catch let e as Error {
                return .failure(e)
            } catch {
                return .failure(.transport(error.localizedDescription))
            }
        }
    }

    /// One request, two products: the device list and an optional MagicDNS
    /// suffix inferred from the FQDNs of every fetched page.
    ///
    /// 原先整份复制在 AppModel+Tailscale（URL/Bearer/超时各一份），收敛到这里
    /// 与 fetchDevices 单一来源；suffix 过滤的独立语义保留——FQDN 从全部分页
    /// 收集，翻页后后缀推断不再只看第一页。
    static func fetchDevicesWithSuffix(token: String,
                                       tailnet: String = "-",
                                       session: URLSession) async -> Result<([TailscaleDevice], String?), Error> {
        switch await fetchAllPages(token: token, tailnet: tailnet, session: session) {
        case .failure(let e):
            return .failure(e)
        case .success(let pages):
            do {
                var all: [TailscaleDevice] = []
                var names: [String] = []
                for page in pages {
                    all += try mapDevices(page)
                    names += fqdns(from: page)
                }
                return .success((sortDevices(all), inferMagicDNSSuffix(fromFQDNs: names)))
            } catch let e as Error {
                return .failure(e)
            } catch {
                return .failure(.transport(error.localizedDescription))
            }
        }
    }

    /// Human-readable form of an API failure for toasts / the device panel.
    static func describe(_ error: Error) -> String {
        switch error {
        case .noToken: return "未配置 API Token"
        case .badURL: return "API 地址无效"
        case .http(401), .http(403): return "API Token 无效或权限不足（需要 devices 读取权限）"
        case .http(let code): return "Tailscale API 返回 HTTP \(code)"
        case .decode: return "设备列表解析失败"
        case .transport(let s): return "网络错误：\(s)"
        }
    }

    // MARK: Wire models

    private struct DevicesRoot: Decodable {
        let devices: [Device]
        /// 分页游标（官方 API 分页响应字段名即 `cursor`，续拉时回传为
        /// `?cursor=` 查询参数）。缺字段 / 空串都按「没有下一页」处理，
        /// 不支持分页的响应解码结果不受影响。
        let cursor: String?
    }

    private struct Device: Decodable {
        let id: String
        let hostname: String
        let name: String
        let addresses: [String]
        let online: Bool?
        let os: String?
        let keyExpiry: String?
        let lastSeen: String?
        let isEphemeral: Bool?
        let advertisedRoutes: [String]?
        let enabledRoutes: [String]?

        enum CodingKeys: String, CodingKey {
            case id, hostname, name, addresses, online, os
            case keyExpiry = "keyExpiry"
            case lastSeen = "lastSeen"
            case isEphemeral = "isEphemeral"
            case advertisedRoutes = "advertisedRoutes"
            case enabledRoutes = "enabledRoutes"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // The API uses a stable node id; fall back to name if somehow absent.
            id = (try? c.decode(String.self, forKey: .id))
                ?? (try? c.decode(String.self, forKey: .name))
                ?? UUID().uuidString
            hostname = (try? c.decode(String.self, forKey: .hostname)) ?? ""
            name = (try? c.decode(String.self, forKey: .name)) ?? hostname
            addresses = (try? c.decode([String].self, forKey: .addresses)) ?? []
            online = try? c.decode(Bool.self, forKey: .online)
            os = try? c.decode(String.self, forKey: .os)
            keyExpiry = try? c.decode(String.self, forKey: .keyExpiry)
            lastSeen = try? c.decode(String.self, forKey: .lastSeen)
            isEphemeral = try? c.decode(Bool.self, forKey: .isEphemeral)
            advertisedRoutes = try? c.decode([String].self, forKey: .advertisedRoutes)
            enabledRoutes = try? c.decode([String].self, forKey: .enabledRoutes)
        }
    }
}

// MARK: - Latency classification

enum TailscaleLatency {

    /// Whether a public URL delay test is meaningful for this node.
    ///
    /// Without an exit node (and without a broader route covering the test
    /// URL), mihomo fails the dial outright and does **not** fall back to
    /// direct. Running the regular group test against such a node paints it
    /// red forever — which is noise, not a signal. With an exit node the
    /// public URL is the right probe.
    static func usesPublicURLTest(nodeType: String, exitNode: String) -> Bool {
        guard nodeType.caseInsensitiveCompare("Tailscale") == .orderedSame
                || nodeType.caseInsensitiveCompare("tailscale") == .orderedSame else {
            return true   // not our concern
        }
        return !exitNode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sentinel written into `Node.delay` for a peer-only tailscale node so the
    /// UI can render "对等" instead of a red dash. Distinct from 0 (untested)
    /// and from any real RTT.
    static let peerOnlySentinel = -2
}
