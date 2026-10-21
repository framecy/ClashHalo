import Foundation

// MARK: - 连接页「一键独立制裁」的规则决策
//
// 纯逻辑：无 SwiftUI、无磁盘写、无内核调用，可单独编译进回归套件
// （`Tests/QuickRule`，登记在 `Scripts/run-tests.sh`）。
//
// 为什么要把「该写哪条规则」抽出来：这一键直接改用户的 config.yaml。写错一个
// 字段（把 IP 当域名、把内置策略名当策略组、把注释当规则参数）在界面上看不出来，
// 要等 reload 失败或流量走错才暴露。所以决策放这里被断言钉住，UI 只负责把
// 结果交给既有的「备份 → 校验 → reload → 失败回滚」事务。

/// 三种快捷动作。
enum QuickRuleKind: String, CaseIterable {
    /// 让该目标直连。
    case direct
    /// 拉黑该目标。
    case reject
    /// 让触发该连接的 App 走某个策略组。
    case processGroup
}

/// 一条连接里可用于生成规则的证据。
///
/// `host` 是展示用主机名（可能是 `?`），`dstIP` / `remoteDestination` 是兜底地址：
/// fake-ip 下域名连接的 `destinationIP` 常为空（实测同一刻 74 条里 59 条为空），
/// 真实地址在 `remoteDestination`。
struct QuickRuleContext: Equatable {
    var host: String
    var dstIP: String
    var remoteDestination: String
    var process: String
    /// 该连接当前命中的策略组（`chains.last`）。
    var group: String
    /// 当前配置里真实存在的策略组名，用于拒绝写出指向不存在组的规则。
    var availableGroups: [String]
}

/// 决策结果。
struct QuickRulePlan: Equatable {
    let type: MihomoRuleType
    let match: String
    let action: RuleAction
    let proxyGroup: String?
    /// 同类型同匹配、行为不同、应被本次操作替换掉的旧规则 id。
    /// 替换（而不是并列）是为了让新规则落在 index 0 时不留一条永远不生效的副本。
    let replaceIDs: [UUID]
    /// 已有等价规则：不写盘、只断开连接。
    let isNoop: Bool
}

enum QuickRule {

    /// 与 `Chains.last` 同源的内置项，不是策略组。
    static let builtinActions: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"]

    /// 该目标能不能做「直连 / 拉黑」。
    static func target(_ c: QuickRuleContext) -> (type: MihomoRuleType, match: String)? {
        let host = c.host.trimmingCharacters(in: .whitespaces)
        let dst = c.dstIP.trimmingCharacters(in: .whitespaces)
        let remote = c.remoteDestination.trimmingCharacters(in: .whitespaces)

        // `?` 是字段缺失占位，`—` 是进程占位——都不是可写进规则的目标。
        let plausibleHost = !host.isEmpty && host != "?" && host != "—"

        // host 本身是 IP（无域名）：同样必须写 IP-CIDR，不能写域名后缀。
        if plausibleHost, isIPAddress(host) { return ipRule(host) }

        // 域名连接：host 与 dstIP 不同才说明这是解析出来的域名。
        if plausibleHost, host != dst { return (.domainSuffix, host) }

        // 兜底：裸 IP 连接。fake-ip 下 destinationIP 常为空，真实地址在 remoteDestination。
        for ip in [dst, remote] where !ip.isEmpty && ip != "?" && isIPAddress(ip) {
            return ipRule(ip)
        }
        return nil
    }

    /// v4 必须写 `IP-CIDR`，v6 才写 `IP-CIDR6`：写反了整条规则无效。
    private static func ipRule(_ ip: String) -> (type: MihomoRuleType, match: String) {
        ip.contains(":")
            ? (.ipCidr6, ip)
            : (.ipCidr, "\(ip)/32")
    }

    /// 该 App 能不能做「走某个策略组」。
    static func processTarget(_ c: QuickRuleContext) -> (match: String, group: String)? {
        let raw = c.process.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, raw != "—" else { return nil }
        // PROCESS-NAME 匹配的是可执行文件名；`process` 有时是带路径的全名。
        let name = (raw as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }

        let group = c.group.trimmingCharacters(in: .whitespaces)
        guard !group.isEmpty, group != "?",
              !builtinActions.contains(group.uppercased()),
              c.availableGroups.contains(group) else { return nil }
        return (name, group)
    }

    /// 生成决策；`nil` 表示这一键在界面上应当置灰。
    static func plan(_ kind: QuickRuleKind,
                     context c: QuickRuleContext,
                     existing: [RuleNode]) -> QuickRulePlan? {
        let type: MihomoRuleType
        let match: String
        let action: RuleAction
        let group: String?

        switch kind {
        case .direct, .reject:
            guard let t = target(c) else { return nil }
            type = t.type
            match = t.match
            action = (kind == .direct) ? .direct : .reject
            group = nil
        case .processGroup:
            guard let p = processTarget(c) else { return nil }
            type = .processName
            match = p.match
            action = .proxy
            group = p.group
        }

        // 同类型同匹配的既有规则
        let same = existing.filter { $0.type == type && $0.match == match }
        let equivalent = same.first {
            $0.isEnabled && $0.action == action && normalizedGroup($0) == group
        }
        if equivalent != nil {
            return QuickRulePlan(type: type, match: match, action: action, proxyGroup: group,
                                 replaceIDs: [], isNoop: true)
        }
        return QuickRulePlan(type: type, match: match, action: action, proxyGroup: group,
                             replaceIDs: same.map(\.id), isNoop: false)
    }

    /// 反向解析一条连接当前命中的规则对本次操作是否已经是目标状态。
    /// 用于「同一键连点两次」时不重复写盘。
    static func normalizedGroup(_ node: RuleNode) -> String? {
        node.action == .proxy ? node.proxyGroup : nil
    }

    static func isIPAddress(_ s: String) -> Bool {
        if s.contains(":") { return s.contains("::") || s.filter { $0 == ":" }.count >= 2 }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in !p.isEmpty && Int(p).map { (0...255).contains($0) } == true }
    }
}
