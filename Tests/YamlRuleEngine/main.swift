// 规则编辑器引擎回归：钉住 2026-08-29 的两个修复。
//
// A1 旧版在任意 `#` 处截断——值含 `#` 的规则在编辑器里凭空消失，
//    保存即从 config.yaml 物理删除。
// A2 旧版丢弃 rules 块内全部注释行——打断 Tailscale overlay 的
//    strip∘apply 幂等（fence 失效 → 重复注入 → 关闭功能清不干净）。
import Foundation

var failed = 0
var total = 0
func check(_ cond: Bool, _ name: String) {
    total += 1
    print(cond ? "  ✓ \(name)" : "  ✗ FAIL: \(name)")
    if !cond { failed += 1 }
}

// ── A1: 值内 `#` 是数据，不是注释 ──
let node = YamlRuleASTEngine.parseLine("- DOMAIN-SUFFIX,api.example.com#v2,PROXY")
check(node != nil, "值含 # 的规则可解析（旧版返回 nil）")
check(node?.match == "api.example.com#v2", "# 后内容归入 match")
check(node?.proxyGroup == "PROXY", "PROXY 组保留")

let withComment = YamlRuleASTEngine.parseLine("- DOMAIN,a.com,DIRECT # 说明")
check(withComment?.match == "a.com", "空白前导 # 仍按注释剥离")

if let n = node {
    let roundTrip = YamlRuleASTEngine.parseLine(YamlRuleASTEngine.serialize(node: n))
    check(roundTrip?.match == "api.example.com#v2" && roundTrip?.proxyGroup == "PROXY",
          "序列化→反序列化往返保留 # 值")
}

// ── A2: fence 区（overlay 托管）原样保留 ──
let fenceBegin = TailscaleOverlay.fenceBegin
let fenceEnd = TailscaleOverlay.fenceEnd
let yaml = """
port: 7890
rules:
  \(fenceBegin)
  - DOMAIN-SUFFIX,ts.net,CLASHHALO-TS
  - IP-CIDR,100.64.0.0/10,CLASHHALO-TS,no-resolve
  \(fenceEnd)
  - DOMAIN-SUFFIX,example.com,DIRECT
  - MATCH,DIRECT
"""

let nodes = YamlRuleASTEngine.extractRules(from: yaml)
check(nodes.count == 2, "fence 内 overlay 规则不进编辑器节点（仅 2 条用户规则）")
check(!nodes.contains { $0.match.contains("ts.net") || $0.match.contains("100.64") },
      "overlay 规则不出现在可编辑列表")

func fencedRegion(_ text: String) -> [String] {
    var out: [String] = []
    var inside = false
    for l in text.components(separatedBy: "\n") {
        let t = l.trimmingCharacters(in: .whitespaces)
        if t == fenceBegin { inside = true; continue }
        if t == fenceEnd { inside = false; continue }
        if inside { out.append(t) }
    }
    return out
}

let edited = (try? YamlRuleASTEngine.injectRules(nodes, into: yaml)) ?? ""
check(!edited.isEmpty, "injectRules 成功")
check(edited.contains(fenceBegin) && edited.contains(fenceEnd), "fence 标记在注入后保留")
check(fencedRegion(edited) == fencedRegion(yaml), "fence 区内容逐行保序不变")
check(edited.contains("- DOMAIN-SUFFIX,example.com,DIRECT"), "用户规则正常重序列化")

// 编辑器增删用户规则不影响 fence 区
var mutated = nodes
mutated.removeLast()
mutated.insert(RuleNode(type: .domain, match: "added.example", action: .direct, sort: 0, isEnabled: true, proxyGroup: nil), at: 0)
let edited2 = (try? YamlRuleASTEngine.injectRules(mutated, into: yaml)) ?? ""
check(fencedRegion(edited2) == fencedRegion(yaml), "编辑用户规则后 fence 区仍不变")
check(edited2.contains("added.example") && !edited2.contains("MATCH,DIRECT"),
      "用户规则增删生效")

// ── 禁用规则往返（回归旧能力）──
let disabledYaml = "rules:\n  - DOMAIN,a.com,DIRECT\n  # - DOMAIN,b.com,REJECT\n"
let dnodes = YamlRuleASTEngine.extractRules(from: disabledYaml)
check(dnodes.count == 2 && dnodes.contains { !$0.isEnabled }, "禁用规则被解析并标记禁用")
let dedited = (try? YamlRuleASTEngine.injectRules(dnodes, into: disabledYaml)) ?? ""
check(dedited.contains("# - DOMAIN,b.com,REJECT"), "禁用规则序列化保留 # 前缀")

print("\n\(total - failed)/\(total) 通过")
exit(failed == 0 ? 0 : 1)
