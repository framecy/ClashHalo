// Tests/RuleValidator —— 直接编译生产源码 Sources/Core/RuleValidator/RuleValidator.swift
// + Sources/Model/RuleNode.swift（后者只依赖 Foundation）。
//
// 这套钉住的是「编辑规则弹窗」保存前的最后一道门：
//   1. PROXY 动作必须有目标（既有契约，别在改存在性校验时弄丢）；
//   2. 目标不存在于当前配置 → 拦住并给中文原因。否则会写出引用已删策略组的规则，
//      内核 reload 拒绝整份配置、事务回滚，用户只看到一条英文报错；
//   3. **拿不到配置时不得误判**：`knownTargets` 为 nil / 空 = 内核未运行，
//      此时必须放行——把「没有数据」当成「所有目标都不存在」会让用户连改都不能改；
//   4. 目标可以是节点名（mihomo 允许规则直接指向节点），所以判定只看集合成员，
//      不假设它一定是策略组；
//   5. 只有 PROXY 动作需要目标，DIRECT/REJECT 不受存在性校验影响。
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ✓ \(msg)") }
    else { print("  ✗ \(msg)"); failures += 1 }
}

func node(_ type: MihomoRuleType = .domainSuffix,
          _ match: String = "example.com",
          _ action: RuleAction = .proxy,
          group: String? = "默认代理") -> RuleNode {
    RuleNode(type: type, match: match, action: action, sort: 0, proxyGroup: group)
}

let svc = ValidationService.shared
let configTargets: Set<String> = ["默认代理", "自动选择", "我的节点", "DIRECT", "REJECT"]

// ── 1. 基础字段校验仍然有效 ────────────────────────────────────────────
print("== 基础校验 ==")
check(svc.validate(node: node(.domain, "exa mple.com")).isValid == false, "非法域名被拒")
check(svc.validate(node: node(.ipCidr, "1.2.3.0/24"), knownTargets: configTargets).isValid,
      "合法 CIDR + 存在的组 → 通过")
check(svc.validate(node: node(.match, ""), knownTargets: configTargets).isValid,
      "MATCH 兜底规则不需要匹配值与目标")

// ── 2. PROXY 必须有目标 ────────────────────────────────────────────────
print("== PROXY 必须有目标 ==")
let noGroup = svc.validate(node: node(group: ""))
check(!noGroup.isValid, "空目标被拒")
check(noGroup.errorMsg == "策略为 PROXY 时，必须关联目标代理组", "空目标的提示没丢")

// ── 3. 存在性校验 ──────────────────────────────────────────────────────
print("== 存在性校验 ==")
check(svc.validate(node: node(group: "默认代理"), knownTargets: configTargets).isValid,
      "目标存在 → 通过")
check(svc.validate(node: node(group: "我的节点"), knownTargets: configTargets).isValid,
      "目标是节点名也通过（mihomo 允许直接指向节点）")

let stale = svc.validate(node: node(group: "已删除的组"), knownTargets: configTargets)
check(!stale.isValid, "目标不存在 → 拦住")
check((stale.errorMsg ?? "").contains("已不存在"), "提示说清「已不存在」（\(stale.errorMsg ?? "nil")）")
check((stale.errorMsg ?? "").contains("已删除的组"), "提示带上原目标名，用户知道要换哪一个")

// ── 4. 拿不到配置时不得误判 ────────────────────────────────────────────
print("== 拿不到配置时不误判 ==")
check(svc.validate(node: node(group: "任何组")).isValid, "knownTargets = nil（未传）→ 放行")
check(svc.validate(node: node(group: "任何组"), knownTargets: []).isValid,
      "knownTargets 为空（内核未运行）→ 放行")

// ── 5. 只有 PROXY 需要目标 ────────────────────────────────────────────
print("== 非 PROXY 动作 ==")
check(svc.validate(node: node(.domainSuffix, "ads.example.com", .reject, group: "已删除的组"),
                   knownTargets: configTargets).isValid,
      "REJECT 不受存在性校验影响（组名只是残留字段）")
check(svc.validate(node: node(.domainSuffix, "intra.example.com", .direct, group: nil),
                   knownTargets: configTargets).isValid,
      "DIRECT 无需目标")

// ── 6. 首尾空格不改变判定 ─────────────────────────────────────────────
print("== 空格 ==")
check(svc.validate(node: node(group: "  默认代理  "), knownTargets: configTargets).isValid,
      "目标两端空格不影响存在性判定")

print("")
if failures == 0 { print("RuleValidator: 全部通过"); exit(0) }
print("RuleValidator: \(failures) 处失败"); exit(1)
