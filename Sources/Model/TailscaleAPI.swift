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
        .sorted { a, b in
            // Online first, then hostname.
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
    static func ipv4CIDRs(_ raw: [String]) -> [String] {
        raw.compactMap { entry in
            let t = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !t.contains(":") else { return nil }
            if t.contains("/") { return t }
            // Bare IP from a sloppy payload → /32.
            return t.contains(".") ? "\(t)/32" : nil
        }
    }

    /// Union of enabled (preferred) then advertised IPv4 routes across devices,
    /// excluding the CGNAT aggregate and default routes. Ready to merge into
    /// `extraCIDRs` after the user confirms.
    static func suggestedSubnetRoutes(from devices: [TailscaleDevice]) -> [String] {
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
                      !n.hasSuffix("/32") || !n.hasPrefix("100.") // peer /32s belong elsewhere
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

    /// `GET /api/v2/tailnet/{tailnet}/devices`.
    ///
    /// `tailnet` defaults to `-` (the caller's default tailnet). The token is
    /// sent as a Bearer header; Basic-with-empty-password is also accepted by
    /// the server but Bearer is the clearer form.
    static func fetchDevices(token: String,
                             tailnet: String = "-",
                             session: URLSession) async -> Result<[TailscaleDevice], Error> {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.noToken) }
        let enc = tailnet.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tailnet
        // `fields=all` is required for advertisedRoutes / enabledRoutes; the
        // default field set omits them.
        guard let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/\(enc)/devices?fields=all") else {
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
            return .success(try decodeDevices(data))
        } catch let e as Error {
            return .failure(e)
        } catch {
            return .failure(.transport(error.localizedDescription))
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
