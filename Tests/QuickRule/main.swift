// Tests/QuickRule —— 直接编译生产源码 Sources/Model/QuickRule.swift +
// Sources/Model/RuleNode.swift（后者只依赖 Foundation）。
//
// 这一键会直接改用户 config.yaml，所以决策必须被钉住：
//   1. 域名连接写 DOMAIN-SUFFIX，裸 IP 连接必须写 IP-CIDR/32（对 IP 写域名后缀不生效）；
//   2. fake-ip 下 destinationIP 为空时，用 remoteDestination 兜底；
//   3. 目标不明（`?`/空）时返回 nil → 界面置灰，绝不写出半截规则；
//   4. 指向不存在/内置策略组的「按进程分流」必须拒绝；
//   5. 已有等价规则 → isNoop（不写盘）；同匹配但行为不同 → replaceIDs 覆盖，
//      避免 index 0 插新规则后留下一条永远不生效的旧副本。
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ✓ \(msg)") }
    else { print("  ✗ \(msg)"); failures += 1 }
}

func ctx(host: String = "youtube.com", dstIP: String = "?",
         remote: String = "", process: String = "Google Chrome",
         group: String = "默认代理",
         groups: [String] = ["默认代理", "自动选择"]) -> QuickRuleContext {
    QuickRuleContext(host: host, dstIP: dstIP, remoteDestination: remote,
                     process: process, group: group, availableGroups: groups)
}

// ── 1. 域名连接 ────────────────────────────────────────────────────────
print("== 域名连接 ==")
let domainCtx = ctx(host: "youtube.com", dstIP: "?", remote: "142.250.1.1")
let direct = QuickRule.plan(.direct, context: domainCtx, existing: [])
check(direct?.type == .domainSuffix, "写 DOMAIN-SUFFIX")
check(direct?.match == "youtube.com", "匹配值是该域名")
check(direct?.action == .direct, "动作 DIRECT")
check(direct?.proxyGroup == nil, "DIRECT 不带策略组")
check(direct?.isNoop == false && direct?.replaceIDs.isEmpty == true, "全新规则：无替换")

let reject = QuickRule.plan(.reject, context: domainCtx, existing: [])
check(reject?.action == .reject, "拉黑动作 REJECT")

// ── 2. 裸 IP 连接必须写 IP-CIDR ────────────────────────────────────────
print("== 裸 IP 连接 ==")
let ipCtx = ctx(host: "1.2.3.4", dstIP: "1.2.3.4", remote: "1.2.3.4")
let ipDirect = QuickRule.plan(.direct, context: ipCtx, existing: [])
check(ipDirect?.type == .ipCidr, "v4 写 IP-CIDR（不是 DOMAIN-SUFFIX、也不是 IP-CIDR6）")
check(ipDirect?.match == "1.2.3.4/32", "匹配值带 /32（\(ipDirect?.match ?? "nil")）")

// host 是 IP 而 destinationIP 缺失：仍然必须写 IP-CIDR，不能因为「host 与 dstIP 不同」
// 就当成域名写 DOMAIN-SUFFIX。
let ipHostOnly = QuickRule.plan(.direct, context: ctx(host: "1.2.3.4", dstIP: "?"), existing: [])
check(ipHostOnly?.type == .ipCidr && ipHostOnly?.match == "1.2.3.4/32",
      "host 本身是 IP → IP-CIDR（\(ipHostOnly?.match ?? "nil")）")

let v6Ctx = ctx(host: "2001:db8::1", dstIP: "2001:db8::1")
let v6Direct = QuickRule.plan(.direct, context: v6Ctx, existing: [])
check(v6Direct?.type == .ipCidr6, "v6 也走 IP-CIDR6")
// v6 裸 IP 必须带显式 /128 前缀（CFG-5：不带前缀内核拒载，一键制裁不可用）。
check(v6Direct?.match == "2001:db8::1/128",
      "v6 补显式 /128 前缀（\(v6Direct?.match ?? "nil")）")

// ── 3. fake-ip 兜底与「目标不明」 ──────────────────────────────────────
print("== fake-ip 兜底 ==")
let fakeCtx = ctx(host: "?", dstIP: "?", remote: "142.250.1.1")
let fakeDirect = QuickRule.plan(.direct, context: fakeCtx, existing: [])
check(fakeDirect?.type == .ipCidr && fakeDirect?.match == "142.250.1.1/32",
      "destinationIP 为空时用 remoteDestination 兜底（\(fakeDirect?.match ?? "nil")）")

let unknown = QuickRule.plan(.direct, context: ctx(host: "?", dstIP: "?", remote: ""), existing: [])
check(unknown == nil, "目标不明 → nil（界面置灰，不写半截规则）")

let placeholder = QuickRule.plan(.reject, context: ctx(host: "—", dstIP: "?", remote: ""), existing: [])
check(placeholder == nil, "占位符不是目标 → nil")

// ── 4. 按进程分流 ──────────────────────────────────────────────────────
print("== 按进程分流 ==")
let proc = QuickRule.plan(.processGroup, context: ctx(), existing: [])
check(proc?.type == .processName && proc?.match == "Google Chrome", "PROCESS-NAME + 进程名")
check(proc?.action == .proxy && proc?.proxyGroup == "默认代理", "动作走当前策略组")

let pathProcess = QuickRule.plan(.processGroup,
    context: ctx(process: "/usr/libexec/nsurlsessiond"), existing: [])
check(pathProcess?.match == "nsurlsessiond", "带路径的进程名取可执行文件名")

check(QuickRule.plan(.processGroup, context: ctx(process: "—"), existing: []) == nil,
      "进程未知 → nil")
check(QuickRule.plan(.processGroup, context: ctx(process: ""), existing: []) == nil,
      "进程为空 → nil")
check(QuickRule.plan(.processGroup, context: ctx(group: "?"), existing: []) == nil,
      "没有当前策略组 → nil")
check(QuickRule.plan(.processGroup, context: ctx(group: "DIRECT"), existing: []) == nil,
      "内置动作 DIRECT 不能当策略组")
check(QuickRule.plan(.processGroup, context: ctx(group: "已删除的组"), existing: []) == nil,
      "指向配置里不存在的组 → nil（否则 reload 必失败）")

// ── 5. 幂等与替换 ──────────────────────────────────────────────────────
print("== 幂等与替换 ==")
let sameDomain = RuleNode(type: .domainSuffix, match: "youtube.com", action: .direct, sort: 3)
let again = QuickRule.plan(.direct, context: domainCtx, existing: [sameDomain])
check(again?.isNoop == true, "已有等价规则 → isNoop（不重复写盘）")
check(again?.replaceIDs.isEmpty == true, "isNoop 不带替换")

let conflicting = RuleNode(type: .domainSuffix, match: "youtube.com", action: .proxy,
                           sort: 3, proxyGroup: "自动选择")
let repoint = QuickRule.plan(.direct, context: domainCtx, existing: [conflicting])
check(repoint?.isNoop == false, "同匹配但策略不同 → 需要写盘")
check(repoint?.replaceIDs == [conflicting.id], "旧规则进入替换列表（不留永不生效的副本）")

let otherDomain = RuleNode(type: .domainSuffix, match: "google.com", action: .direct, sort: 1)
let untouched = QuickRule.plan(.direct, context: domainCtx, existing: [otherDomain])
check(untouched?.replaceIDs.isEmpty == true, "不相关的规则绝不动")

let disabledSame = RuleNode(type: .domainSuffix, match: "youtube.com", action: .direct,
                            sort: 2, isEnabled: false)
let reenable = QuickRule.plan(.direct, context: domainCtx, existing: [disabledSame])
check(reenable?.isNoop == false && reenable?.replaceIDs == [disabledSame.id],
      "被禁用的同匹配规则不算等价，替换它")

let processNoop = QuickRule.plan(.processGroup, context: ctx(),
    existing: [RuleNode(type: .processName, match: "Google Chrome", action: .proxy,
                        sort: 0, proxyGroup: "默认代理")])
check(processNoop?.isNoop == true, "同一 App 已走同一组 → isNoop")

let processRepoint = QuickRule.plan(.processGroup, context: ctx(),
    existing: [RuleNode(type: .processName, match: "Google Chrome", action: .proxy,
                        sort: 0, proxyGroup: "自动选择")])
check(processRepoint?.isNoop == false && processRepoint?.replaceIDs.count == 1,
      "同一 App 换组 → 替换旧规则")

// ── 6. 地址判定边界 ────────────────────────────────────────────────────
print("== 地址判定 ==")
check(QuickRule.isIPAddress("192.168.1.1"), "v4 合法")
check(!QuickRule.isIPAddress("192.168.1"), "缺段不算")
check(!QuickRule.isIPAddress("999.1.1.1"), "越界不算")
check(!QuickRule.isIPAddress("example.com"), "域名不算")
check(QuickRule.isIPAddress("2001:db8::1"), "v6 合法")

// 严格八位组：Int(p) 的宽松解析放行 "+1"/"01"，写出的规则内核拒载
check(QuickRule.isIPAddress("0.0.0.0"), "段值 0 合法（单个 0 无前导零问题）")
check(!QuickRule.isIPAddress("192.168.01.1"), "前导零（01）不算")
check(!QuickRule.isIPAddress("192.168.1.+2"), "带号（+2）不算")
check(!QuickRule.isIPAddress("192.168.1.1234"), "超长段（4 位）不算")
check(!QuickRule.isIPAddress("192.168.1.."), "空段不算")

print("")
if failures == 0 { print("QuickRule: 全部通过"); exit(0) }
print("QuickRule: \(failures) 处失败"); exit(1)
