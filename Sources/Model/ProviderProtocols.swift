import Foundation

// MARK: - 订阅协议分布
//
// 纯逻辑：无 SwiftUI、无网络、无内核交互，可单独编译进回归套件
// （`Tests/ProviderProtocols`，登记在 `Scripts/run-tests.sh`）。
//
// 目的：让订阅卡一眼看出「这份订阅是什么货色」——`VLESS 61 · HYSTERIA2 25 · SS 2`，
// 而不是只给一个节点总数。数据来自 `/providers/proxies` 里每个节点的 `type`，
// 不需要新接口、不需要新权限。

struct ProtocolCount: Equatable {
    let label: String
    let count: Int
}

struct ProtocolSummary: Equatable {
    /// 展示项，按节点数降序（同数按字母序，保证同一份数据每次渲染一致）。
    let items: [ProtocolCount]
    /// 被折叠掉的协议**种类数**（不是节点数）。
    let hiddenKinds: Int
    /// 参与统计的节点总数，等于 `items` 与折叠项的节点数之和。
    let total: Int

    var isEmpty: Bool { total == 0 }

    /// 一行摘要：`VLESS 61 · HYSTERIA2 25 · SS 2 +1`。
    var text: String {
        guard !items.isEmpty else { return "" }
        var parts = items.map { "\($0.label) \($0.count)" }
        if hiddenKinds > 0 { parts.append("+\(hiddenKinds)") }
        return parts.joined(separator: " · ")
    }
}

enum ProviderProtocols {

    /// mihomo 的协议名 → 行业惯用短名。未收录的原样大写，不猜。
    static func shortLabel(_ type: String) -> String {
        let raw = type.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return "未知" }
        if let known = knownLabels[raw.uppercased()] { return known }
        return raw.uppercased()
    }

    private static let knownLabels: [String: String] = [
        "VLESS": "VLESS",
        "VMESS": "VMESS",
        "SHADOWSOCKS": "SS",
        "SS": "SS",
        "SHADOWSOCKSR": "SSR",
        "SSR": "SSR",
        "HYSTERIA": "HYSTERIA",
        "HYSTERIA2": "HYSTERIA2",
        "TROJAN": "TROJAN",
        "SNELL": "SNELL",
        "TUIC": "TUIC",
        "WIREGUARD": "WIREGUARD",
        "HTTP": "HTTP",
        "SOCKS5": "SOCKS5",
        "ANYTLS": "ANYTLS",
        "SSH": "SSH",
        "MIERU": "MIERU",
        "DIRECT": "DIRECT",
        "REJECT": "REJECT",
        "REJECTDROP": "REJECT",
        "DNS": "DNS",
    ]

    /// 聚合协议分布。
    /// - Parameters:
    ///   - types: 每个节点的 `type`（缺失/空串按「未知」计）。
    ///   - maxShown: 最多展示几种；超过 `maxShown + 1` 种时折叠为前 `maxShown` 种 + `+N`。
    static func summarize(_ types: [String], maxShown: Int = 3) -> ProtocolSummary {
        guard !types.isEmpty else {
            return ProtocolSummary(items: [], hiddenKinds: 0, total: 0)
        }
        var counts: [String: Int] = [:]
        counts.reserveCapacity(min(types.count, 16))
        for t in types { counts[shortLabel(t), default: 0] += 1 }

        let sorted = counts
            .map { ProtocolCount(label: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : lhs.label < rhs.label
            }

        let limit = max(1, maxShown)
        if sorted.count > limit + 1 {
            return ProtocolSummary(items: Array(sorted.prefix(limit)),
                                   hiddenKinds: sorted.count - limit,
                                   total: types.count)
        }
        return ProtocolSummary(items: sorted, hiddenKinds: 0, total: types.count)
    }
}
