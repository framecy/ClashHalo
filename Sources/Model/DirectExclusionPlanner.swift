import Foundation

// MARK: - 直连网段排除（建议器）
//
// 目的：把「规则判 DIRECT」的 IP 段编译进 `tun.route-exclude-address`，让这些
// 目标根本不进用户态协议栈。
//
// 为什么值得做（2026-11-01 实测，见 Docs/PerfRoadmap.md）：每一条新建连接经 TUN
// 比 native 多付「1 × 目标 RTT（代理拨号）+ 5~8 ms（用户态栈）」。同一个 4 ms 的
// 邻居差 10.5 ms，同一个 22 ms 的国内站点差约 28 ms——这就是「直连也要 80 ms」的来源。
//
// 为什么只做「建议」不做自动注入：`route-exclude-address` **强于所有规则**。某网段
// 一旦被排除，域名规则、进程规则、端口规则对它全部失效——包根本不进 mihomo。这是一条
// 会悄悄改变代理行为的系统级写入，必须由用户逐条采纳，且必须留下归属记录。
//
// 本文件是纯逻辑：无 SwiftUI、无 MainActor、无进程管理，回归套件直接编译它。

/// 一条可被采纳的候选网段。
public struct DirectExclusionProposal: Equatable {
    public let cidr: String
    /// 产出它的规则原文（`TYPE,match,target`），用于在 UI 里说清"为什么是它"。
    public let rule: String
    /// 规则在 `rules:` 里的序号，用于稳定排序与展示。
    public let order: Int
    public init(cidr: String, rule: String, order: Int) {
        self.cidr = cidr; self.rule = rule; self.order = order
    }
}

/// 被安全闸门拦下的候选，连同原因。
public struct DirectExclusionRejection: Equatable {
    public enum Reason: String, Equatable {
        /// 目标不是 DIRECT——不是直连，排除它等于把代理流量改直连。
        case notDirect
        /// `/0`：排除它等于关掉 TUN。
        case defaultRoute
        /// 与 fake-ip 段相交：排除它等于当场断网（198.18.x 不可路由）。
        case fakeIPRange
        /// 链路专用前缀（回环/多播/链路本地）：排除它们没有收益，还会掩盖共存逻辑。
        case linkOnly
        /// 与本机直连网段相交：本来就直连，排除只会让路由表多一条假象。
        case localSubnet
        /// 更早的 IP 型规则以非 DIRECT 动作覆盖了它——first-match 下它根本不会走 DIRECT。
        case shadowed
        /// 地址解析不出来。
        case unparsable
        /// 超过条目上限。
        case overCap
    }
    public let cidr: String
    public let rule: String
    public let reason: Reason
    public init(cidr: String, rule: String, reason: Reason) {
        self.cidr = cidr; self.rule = rule; self.reason = reason
    }
}

public struct DirectExclusionPlan: Equatable {
    public var proposals: [DirectExclusionProposal]
    public var rejections: [DirectExclusionRejection]
    /// 排除生效后，这些网段上**不再被应用**的非 DIRECT 规则条数。
    /// 域名/进程/端口规则依赖连接内容，无法静态判定具体命中哪条，只能给出规模。
    public var blastRadius: Int
    public init(proposals: [DirectExclusionProposal] = [],
                rejections: [DirectExclusionRejection] = [],
                blastRadius: Int = 0) {
        self.proposals = proposals; self.rejections = rejections; self.blastRadius = blastRadius
    }
}

public enum DirectExclusionPlanner {

    /// 条目上限。`route-exclude-address` 的每一条都会被 mihomo 装成一条路由；
    /// 无上限地灌进去，最后是路由表膨胀换几毫秒，不划算。
    public static let maxEntries = 256

    /// 产出候选。
    /// - Parameters:
    ///   - rules: 有序规则（`YamlRuleASTEngine.extractRules` 的输出，first-match 顺序）。
    ///   - localSubnets: 本机直连网段（`PeerRouteGuard.localSubnetOwners()` 的键）。
    ///   - ipRuleSetNames: `behavior: ipcidr` 的 rule-provider 名。这类 RULE-SET 能按 IP
    ///     匹配但内容不在规则行里，无法求交，只能保守视为「整段遮蔽」。
    ///   - cap: 条目上限。
    public static func plan(rules: [RuleNode],
                            localSubnets: [String] = [],
                            ipRuleSetNames: Set<String> = [],
                            cap: Int = maxEntries) -> DirectExclusionPlan {

        var proposals: [DirectExclusionProposal] = []
        var rejections: [DirectExclusionRejection] = []
        var seen = Set<String>()
        var blast = 0
        // 更早的、能按 IP 匹配且非 DIRECT 的规则。求不出交集的一律记为「遮蔽一切」。
        var shadows: [String] = []
        // 遮蔽生效的规则序号：first-match 下，只有「排在我前面」的遮蔽规则才算数。
        var blanketShadowOrder: Int? = nil

        func ruleText(_ r: RuleNode) -> String {
            let target = r.proxyGroup ?? r.action.rawValue
            return r.type == .match ? "\(r.type.rawValue),\(target)"
                                   : "\(r.type.rawValue),\(r.match),\(target)"
        }

        for (idx, rule) in rules.enumerated() where rule.isEnabled {
            if rule.action != .direct { blast += 1 }

            switch rule.type {
            case .ipCidr, .ipCidr6:
                guard rule.action == .direct else {
                    // 非 DIRECT 的 IP 规则：后续任何落在它里面的 DIRECT 段都不成立。
                    shadows.append(rule.match)
                    continue
                }
                let cidr = rule.match.trimmingCharacters(in: .whitespaces)
                guard RouteTable.IPPrefix(cidr) != nil else {
                    rejections.append(.init(cidr: cidr, rule: ruleText(rule), reason: .unparsable))
                    continue
                }
                if let reason = hardRejection(cidr, localSubnets: localSubnets) {
                    rejections.append(.init(cidr: cidr, rule: ruleText(rule), reason: reason))
                    continue
                }
                if let shadowAt = blanketShadowOrder, shadowAt < idx {
                    rejections.append(.init(cidr: cidr, rule: ruleText(rule), reason: .shadowed))
                    continue
                }
                if shadows.contains(where: { RouteTable.overlaps($0, cidr) }) {
                    rejections.append(.init(cidr: cidr, rule: ruleText(rule), reason: .shadowed))
                    continue
                }
                guard !seen.contains(cidr) else { continue }
                if proposals.count >= cap {
                    rejections.append(.init(cidr: cidr, rule: ruleText(rule), reason: .overCap))
                    continue
                }
                seen.insert(cidr)
                proposals.append(.init(cidr: cidr, rule: ruleText(rule), order: idx))

            case .ipSuffix, .ipAsn, .geoip, .srcIpCidr:
                // 这些规则能按 IP 命中，但 `match` 不是 CIDR（`CN`、`AS12345`、`1.2.3`），
                // 静态求不出交集。非 DIRECT 时按「遮蔽一切」处理：宁可一条建议都不给，
                // 也不能给出一个会改变代理行为的建议。
                if rule.action != .direct { blanketShadowOrder = blanketShadowOrder ?? idx }

            case .ruleSet:
                // 只有 ipcidr 型 rule-provider 能按 IP 匹配；名字不在集合里时视为域名型，
                // 只计入爆炸半径（它在排除生效后同样不再作用于这些网段）。
                if rule.action != .direct, ipRuleSetNames.contains(rule.match) {
                    blanketShadowOrder = blanketShadowOrder ?? idx
                }

            default:
                break
            }
        }

        return DirectExclusionPlan(proposals: proposals.sorted { $0.order < $1.order },
                                   rejections: rejections,
                                   blastRadius: blast)
    }

    /// 与规则顺序无关、只看地址本身的硬闸门。
    public static func hardRejection(_ cidr: String, localSubnets: [String]) -> DirectExclusionRejection.Reason? {
        guard let prefix = RouteTable.IPPrefix(cidr) else { return .unparsable }
        if prefix.length == 0 { return .defaultRoute }
        if RouteTable.overlaps(cidr, "198.18.0.0/15") { return .fakeIPRange }
        if CoexistenceProvenance.isProtectiveExclusion(cidr) { return .linkOnly }
        if localSubnets.contains(where: { RouteTable.overlaps($0, cidr) }) { return .localSubnet }
        return nil
    }

    /// `behavior: ipcidr` 的 rule-provider 名字。
    ///
    /// 这类 RULE-SET 能按 IP 匹配，但具体网段在 provider 文件里，规则行上拿不到，
    /// 静态求不出交集。它们若以非 DIRECT 动作排在前面，只能保守地视为「遮蔽一切」。
    /// 域名型 provider 不受影响——那是爆炸半径的事，不是遮蔽。
    public static func ipRuleSetNames(inYAML text: String) -> Set<String> {
        var names = Set<String>()
        var inBlock = false
        var current: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            let isTopLevel = indent == 0 && !trimmed.hasPrefix("-")
            if isTopLevel {
                inBlock = trimmed.hasPrefix("rule-providers:")
                current = nil
                continue
            }
            guard inBlock else { continue }
            if indent == 2, trimmed.hasSuffix(":") {
                current = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            if indent >= 4, let name = current, trimmed.hasPrefix("behavior:") {
                let value = trimmed.dropFirst("behavior:".count).trimmingCharacters(in: .whitespaces)
                if value == "ipcidr" { names.insert(name) }
            }
        }
        return names
    }

    /// 采纳集合在当前规则下是否仍然成立：规则改了、或某条被别的规则遮住了，
    /// 就不能继续按旧决定排除它——否则用户改了规则，路由却还按老样子走。
    public static func effective(accepted: [String], plan: DirectExclusionPlan) -> [String] {
        let allowed = Set(plan.proposals.map(\.cidr))
        return accepted.filter { allowed.contains($0) }.sorted()
    }
}
