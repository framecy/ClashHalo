// 直连网段排除 + 多源归属回归套件：
// 钉住 DirectExclusionPlanner 的顺序语义、硬闸门、稳定排序、cap、ipRuleSetNames、effective，
// 以及 RouteExclusionMerge 的多源合并与归属记账（不覆盖用户手写、第二轮不抹除认领）。
import Foundation

var total = 0
var failed = 0

func check(_ cond: Bool, _ name: String) {
    total += 1
    if cond {
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(name)")
    }
}

func checkEq<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    total += 1
    if got == want {
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(name) — got \(got), want \(want)")
    }
}

func makeRule(_ type: MihomoRuleType, _ match: String, _ action: RuleAction,
              sort: Int = 0, enabled: Bool = true, group: String? = nil) -> RuleNode {
    RuleNode(type: type, match: match, action: action, sort: sort, isEnabled: enabled, proxyGroup: group)
}

print("── 1. 硬闸门（hardRejection）：与顺序无关的安全边界 ──")
checkEq(DirectExclusionPlanner.hardRejection("0.0.0.0/0", localSubnets: []), .defaultRoute,
        "IPv4 /0 默认路由硬拒")
checkEq(DirectExclusionPlanner.hardRejection("::/0", localSubnets: []), .defaultRoute,
        "IPv6 /0 默认路由硬拒")
checkEq(DirectExclusionPlanner.hardRejection("198.18.0.0/15", localSubnets: []), .fakeIPRange,
        "IPv4 fake-ip 段硬拒")
checkEq(DirectExclusionPlanner.hardRejection("198.19.1.0/24", localSubnets: []), .fakeIPRange,
        "IPv4 fake-ip 子网硬拒")
checkEq(DirectExclusionPlanner.hardRejection("fdfe:dcba:9876::/64", localSubnets: []), .fakeIPRange,
        "TUN-5：IPv6 fake-ip 默认段硬拒")
checkEq(DirectExclusionPlanner.hardRejection("127.0.0.0/8", localSubnets: []), .linkOnly,
        "回环网段按 linkOnly 硬拒")
checkEq(DirectExclusionPlanner.hardRejection("169.254.0.0/16", localSubnets: []), .linkOnly,
        "链路本地网段按 linkOnly 硬拒")
checkEq(DirectExclusionPlanner.hardRejection("224.0.0.0/4", localSubnets: []), .linkOnly,
        "多播网段按 linkOnly 硬拒")
checkEq(DirectExclusionPlanner.hardRejection("192.168.1.0/24", localSubnets: ["192.168.1.0/24"]), .localSubnet,
        "本机直连网段硬拒")
checkEq(DirectExclusionPlanner.hardRejection("192.168.1.128/25", localSubnets: ["192.168.1.0/24"]), .localSubnet,
        "与本机直连网段重叠的子网硬拒")
checkEq(DirectExclusionPlanner.hardRejection("not-a-cidr", localSubnets: []), .unparsable,
        "非法 CIDR → unparsable")
checkEq(DirectExclusionPlanner.hardRejection("192.0.2.0/24", localSubnets: ["192.168.1.0/24"]), nil,
        "合法网段通过硬闸门")

print("── 2. 顺序语义（first-match）：更早的非 DIRECT 规则遮蔽 ──")
do {
    let rules = [
        makeRule(.ipCidr, "203.0.113.0/24", .proxy, group: "PROXY"),
        makeRule(.ipCidr, "203.0.113.128/25", .direct),
        makeRule(.ipCidr, "198.51.100.0/24", .direct),
        makeRule(.ipCidr, "198.51.100.0/24", .reject),
        makeRule(.domainSuffix, "example.invalid", .proxy, group: "PROXY")
    ]
    let plan = DirectExclusionPlanner.plan(rules: rules)
    checkEq(plan.proposals.map(\.cidr), ["198.51.100.0/24"],
            "仅放行未被更早非 DIRECT 规则遮蔽的 CIDR")
    check(plan.rejections.contains(where: { $0.cidr == "203.0.113.128/25" && $0.reason == .shadowed }),
          "被更早非 DIRECT IP 规则遮蔽的候选标记为 .shadowed")
    checkEq(plan.blastRadius, 3, "blastRadius 统计所有启用的非 DIRECT 规则")
}

print("── 3. Blanket shadow（GEOIP / ipcidr RULE-SET）与域名 RULE-SET 区分 ──")
do {
    let rules = [
        makeRule(.ipCidr, "198.51.100.0/24", .direct),
        makeRule(.ruleSet, "domain-proxy", .proxy, group: "PROXY"),
        makeRule(.ipCidr, "203.0.113.0/24", .direct),
        makeRule(.ruleSet, "ip-proxy", .proxy, group: "PROXY"),
        makeRule(.ipCidr, "192.0.2.0/24", .direct),
    ]
    let plan = DirectExclusionPlanner.plan(rules: rules, ipRuleSetNames: ["ip-proxy"])
    checkEq(plan.proposals.map(\.cidr), ["198.51.100.0/24", "203.0.113.0/24"],
            "域名型 RULE-SET 不遮蔽后续 IP-CIDR；ipcidr 型 RULE-SET 仅遮蔽排在它之后的规则")
    check(plan.rejections.contains(where: { $0.cidr == "192.0.2.0/24" && $0.reason == .shadowed }),
          "排在非 DIRECT ipcidr RULE-SET 之后的 DIRECT 网段被判 .shadowed")
}
do {
    let rules = [
        makeRule(.geoip, "US", .proxy, group: "PROXY"),
        makeRule(.ipCidr, "192.0.2.0/24", .direct),
    ]
    let plan = DirectExclusionPlanner.plan(rules: rules)
    check(plan.proposals.isEmpty, "排在非 DIRECT GEOIP 之后的 DIRECT IP-CIDR 被整体遮蔽")
    check(plan.rejections.first?.reason == .shadowed, "原因标记为 .shadowed")
}

print("── 4. 稳定排序、去重、禁用跳过与 cap 上限 ──")
do {
    let rules = [
        makeRule(.ipCidr, "203.0.113.0/24", .direct),
        makeRule(.ipCidr, "198.51.100.0/24", .direct, enabled: false),
        makeRule(.ipCidr, "203.0.113.0/24", .direct),
        makeRule(.ipCidr, "192.0.2.0/24", .direct),
        makeRule(.ipCidr, "198.51.101.0/24", .direct),
    ]
    let plan = DirectExclusionPlanner.plan(rules: rules, cap: 2)
    checkEq(plan.proposals.map(\.cidr), ["203.0.113.0/24", "192.0.2.0/24"],
            "按规则序号稳定排序、去重、跳过禁用，并遵守 cap=2")
    check(plan.rejections.contains(where: { $0.cidr == "198.51.101.0/24" && $0.reason == .overCap }),
          "超出 cap 的条目记为 .overCap")
}

print("── 5. ipRuleSetNames(inYAML:) 与 effective(accepted:plan:) ──")
do {
    let yaml = """
    rule-providers:
      cn_cidrs:
        type: file
        behavior: ipcidr
      proxy_domains:
        type: file
        behavior: domain
      mixed_rules:
        type: file
        behavior: classical
      corp_cidr:
        type: file
        behavior: ipcidr
    rules:
      - MATCH,DIRECT
    """
    let names = DirectExclusionPlanner.ipRuleSetNames(inYAML: yaml)
    checkEq(names, Set(["cn_cidrs", "corp_cidr"]),
            "ipRuleSetNames 只收 behavior: ipcidr，不收 domain/classical")

    let plan = DirectExclusionPlanner.plan(rules: [
        makeRule(.ipCidr, "192.0.2.0/24", .direct),
        makeRule(.ipCidr, "203.0.113.0/24", .direct),
    ])
    let eff = DirectExclusionPlanner.effective(
        accepted: ["203.0.113.0/24", "198.51.100.0/24", "192.0.2.0/24"],
        plan: plan
    )
    checkEq(eff, ["192.0.2.0/24", "203.0.113.0/24"],
            "effective 过滤掉已不在新计划里的旧采纳项，并稳定排序")
}

print("── 6. RouteExclusionMerge 多源合并与归属记账 ──")
do {
    let testField = "route-exclude-address-test-\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: "coexistence.injected." + testField) }

    let existing1 = ["10.0.0.0/8"]
    let r1 = RouteExclusionMerge.merge(
        sources: RouteExclusionSources(peer: ["100.64.0.0/10"], direct: ["192.0.2.0/24"]),
        existing: existing1,
        field: testField
    )
    checkEq(r1.merged, ["10.0.0.0/8", "100.64.0.0/10", "192.0.2.0/24"],
            "第 1 轮 merged 包含用户手写 + peer + direct")
    checkEq(r1.injected, ["100.64.0.0/10", "192.0.2.0/24"],
            "第 1 轮 injected 只认领新增项，绝不认领用户手写的 10.0.0.0/8")
    checkEq(r1.record, ["100.64.0.0/10", "192.0.2.0/24"],
            "第 1 轮 record 等于两源并集")
    CoexistenceProvenance.commitProvenance(field: testField, injected: r1.record)

    let r2 = RouteExclusionMerge.merge(
        sources: RouteExclusionSources(peer: ["100.64.0.0/10"], direct: ["192.0.2.0/24"]),
        existing: r1.merged,
        field: testField
    )
    check(r2.injected.isEmpty, "第 2 轮 newlyInjected 为空")
    checkEq(r2.record, ["100.64.0.0/10", "192.0.2.0/24"],
            "第 2 轮 record 保留上一轮认领，不被空 newlyInjected 抹除")
    CoexistenceProvenance.commitProvenance(field: testField, injected: r2.record)

    let r3 = RouteExclusionMerge.merge(
        sources: RouteExclusionSources(peer: [], direct: ["192.0.2.0/24"]),
        existing: r2.merged,
        field: testField
    )
    checkEq(r3.merged, ["10.0.0.0/8", "192.0.2.0/24"],
            "peer 断开后自动撤回 100.64.0.0/10，保留 direct 与用户手写 10.0.0.0/8")
    checkEq(r3.record, ["192.0.2.0/24"], "第 3 轮 record 收敛为仍想要的 192.0.2.0/24")
    CoexistenceProvenance.commitProvenance(field: testField, injected: r3.record)

    let kept = RouteExclusionMerge.withdraw(existing: r3.merged, field: testField)
    checkEq(kept, ["10.0.0.0/8"], "TUN 关闭 withdraw 精准撤回自动条目，用户手写条目完好保留")
}

print("")
if failed == 0 {
    print("全部通过（\(total) 项）")
} else {
    print("失败 \(failed)/\(total) 项")
    exit(1)
}
