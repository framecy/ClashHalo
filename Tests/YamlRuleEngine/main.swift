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

// ── 手术式写入：只动目标行，块内注释与空行必须原样 ──
// 连接页一键「直连/拉黑」走这条路径。injectRules 是「按节点重建整块」，会丢掉
// 块内注释（真实配置实测 925→875 行）；一键加一行规则不能顺带删用户的注释。
print("== 手术式插入/删除 ==")
let commented = """
proxies: []
rules:
  # 证据注释：某域名被墙，2026-10 实测
  - DOMAIN-SUFFIX,keep.example,DIRECT

  - DOMAIN-SUFFIX,replace.example,油管视频
  \(fenceBegin)
  - DOMAIN-SUFFIX,ts.net,CLASHHALO-TS
  \(fenceEnd)
  - MATCH,兜底流量
"""
let inserted = YamlRuleASTEngine.insertRuleLine("- DOMAIN-SUFFIX,new.example,REJECT", into: commented)
check(inserted != nil, "insertRuleLine 成功")
check(inserted?.contains("  # 证据注释：某域名被墙，2026-10 实测") == true, "块内注释保留")
check(inserted?.contains("\n\n  - DOMAIN-SUFFIX,replace.example") == true, "块内空行保留")
if let ins = inserted {
    let lines = ins.components(separatedBy: "\n")
    let rulesIdx = lines.firstIndex(of: "rules:") ?? -1
    check(lines[rulesIdx + 1] == "  - DOMAIN-SUFFIX,new.example,REJECT", "新规则插在 rules: 之后第一行")
    check(fencedRegion(ins) == fencedRegion(commented), "fence 区不受影响")
    let reNodes = YamlRuleASTEngine.extractRules(from: ins)
    check(reNodes.first?.match == "new.example", "回读首条即新规则")
    check(reNodes.firstIndex { $0.type == .match }! == reNodes.count - 1, "MATCH 仍在最后")
}

let removed = YamlRuleASTEngine.removeRuleLines(type: .domainSuffix, match: "replace.example", from: commented)
check(!removed.contains("replace.example"), "目标规则被删除")
check(removed.contains("# 证据注释"), "删除规则不动注释")
check(removed.contains("kept") == false && removed.contains("keep.example"), "其它规则不受影响")
check(fencedRegion(removed) == fencedRegion(commented), "删除规则不动 fence 区")
check(YamlRuleASTEngine.removeRuleLines(type: .domainSuffix, match: "nope.example", from: commented) == commented,
      "无匹配时不改动任何字节")

// 块状写法的各种形态都要认：行尾注释、多余空格、空数组
let commentKey = YamlRuleASTEngine.insertRuleLine("- DOMAIN,a.com,DIRECT", into: "rules: # 我的规则\n  - MATCH,DIRECT\n")
check(commentKey?.contains("rules: # 我的规则") == true, "rules: 行尾注释保留")
check(commentKey?.contains("rules: # 我的规则\n  - DOMAIN,a.com,DIRECT") == true, "新规则插在带注释的 rules: 之后")
let spacedKey = YamlRuleASTEngine.insertRuleLine("- DOMAIN,a.com,DIRECT", into: "rules:   \n  - MATCH,DIRECT\n")
check(spacedKey?.contains("  - DOMAIN,a.com,DIRECT") == true, "rules: 后有多余空格也认")
let emptyArray = YamlRuleASTEngine.insertRuleLine("- DOMAIN,a.com,DIRECT", into: "rules: []\n")
check(emptyArray == "rules:\n  - DOMAIN,a.com,DIRECT\n", "空数组展开为块（\(emptyArray ?? "nil")）")
let emptyArrayNoSpace = YamlRuleASTEngine.insertRuleLine("- DOMAIN,a.com,DIRECT", into: "rules:[]\n")
check(emptyArrayNoSpace?.contains("- DOMAIN,a.com,DIRECT") == true, "rules:[] 无空格也认")

// 内联数组写法不做手术：如实返回 nil（调用方报错），不写出坏 YAML
check(YamlRuleASTEngine.insertRuleLine("- DOMAIN,a.com,DIRECT", into: "rules: [{type: DOMAIN}]\n") == nil,
      "内联 rules 数组 → nil，不猜")
// 没有 rules: 块时末尾补一个
let norules = YamlRuleASTEngine.insertRuleLine("- DOMAIN,a.com,DIRECT", into: "proxies: []\n")
check(norules?.hasSuffix("rules:\n  - DOMAIN,a.com,DIRECT") == true, "缺 rules 块时末尾补建")

// ── 规则页保存：注释跟随规则，任何操作都不丢注释 ──
// 旧版 save() 走 injectRules（按节点重建整块），块内注释每次保存都被清掉：
// 真实 config.yaml 空往返实测 925→875 行、含 # 行 161→119。
print("== 保留注释的重写 ==")
let commentedYaml = """
proxies: []
rules:
  # 段落横幅
  - DOMAIN-SUFFIX,keep.example,DIRECT
  # 证据：12 次 i/o timeout
  - DOMAIN-SUFFIX,move.example,油管视频

  # 尾部注释
  - MATCH,兜底流量
proxy-groups: []
"""
let loaded = YamlRuleASTEngine.extractRules(from: commentedYaml)
check(loaded.count == 3, "解析出 3 条规则")

func rewrite(_ nodes: [RuleNode]) -> String {
    (try? YamlRuleASTEngine.injectRulesPreservingComments(nodes, into: commentedYaml, loadedNodes: loaded)) ?? ""
}

// 最关键：不做任何修改的保存必须逐字节一致（否则打开规则页就有写入风险）
check(rewrite(loaded) == commentedYaml, "空往返逐字节一致")

// 改动作只动那一行
var editedNodes = loaded
editedNodes[0].action = .reject
let editedYaml = rewrite(editedNodes)
let before = commentedYaml.components(separatedBy: "\n")
let after = editedYaml.components(separatedBy: "\n")
check(zip(before, after).filter { $0 != $1 }.count == 1, "改一条规则只产生 1 行差异")
check(editedYaml.contains("- DOMAIN-SUFFIX,keep.example,REJECT"), "动作已改")
check(editedYaml.contains("# 段落横幅") && editedYaml.contains("# 证据：12 次 i/o timeout")
      && editedYaml.contains("# 尾部注释"), "三处注释全部保留")

// 删除带注释的规则：注释转交给下一条存活规则，不丢
var deletedNodes = loaded
deletedNodes.remove(at: 1)
let deletedYaml = rewrite(deletedNodes)
check(!deletedYaml.contains("move.example"), "规则已删除")
check(deletedYaml.contains("# 证据：12 次 i/o timeout"), "被删规则的注释没有丢")

// 重排：注释跟随它的规则
var reordered = loaded
let moved = reordered.remove(at: 1)
reordered.insert(moved, at: 0)
let reorderedYaml = rewrite(reordered)
let reorderedLines = reorderedYaml.components(separatedBy: "\n")
let commentIdx = reorderedLines.firstIndex { $0.contains("# 证据：12 次") } ?? -1
let ruleIdx = reorderedLines.firstIndex { $0.contains("move.example") } ?? -1
check(commentIdx >= 0 && ruleIdx > commentIdx && ruleIdx - commentIdx == 1, "注释紧跟其规则")

// 新增规则
var addedNodes = loaded
addedNodes.insert(RuleNode(type: .domainSuffix, match: "new.example", action: .reject, sort: 0), at: 0)
let addedYaml = rewrite(addedNodes)
check(addedYaml.contains("- DOMAIN-SUFFIX,new.example,REJECT"), "新规则写入")
check(addedYaml.contains("# 段落横幅") && addedYaml.contains("# 尾部注释"), "新增不影响注释")
check(YamlRuleASTEngine.extractRules(from: addedYaml).count == 4, "回读条数正确")

// ── 备注不再当第 4 字段（参数槽） ──
// 4th field 是 mihomo 的规则参数位（no-resolve/src）。把「公司内网」这类散文写进去，
// `-t` 不会报错（2026-10-20 实测），但语义错误，且与真实选项名撞车会静默改行为。
print("== 备注写法定向 ==")
let withProse = RuleNode(type: .domainSuffix, match: "a.com", action: .direct, sort: 0,
                         note: "公司内网")
let proseLine = YamlRuleASTEngine.serialize(node: withProse)
check(proseLine == "- DOMAIN-SUFFIX,a.com,DIRECT # 公司内网", "散文备注写成行尾注释（\(proseLine)）")
check(!proseLine.contains(",公司内网"), "散文备注不占第 4 字段")

let withParam = RuleNode(type: .ipCidr, match: "10.0.0.0/8", action: .direct, sort: 0,
                         note: "no-resolve")
let paramLine = YamlRuleASTEngine.serialize(node: withParam)
check(paramLine == "- IP-CIDR,10.0.0.0/8,DIRECT,no-resolve", "真实参数仍是第 4 字段（\(paramLine)）")
check(!paramLine.contains("#"), "参数形式不额外加注释")

let collision = RuleNode(type: .ipCidr, match: "10.0.0.0/8", action: .proxy, sort: 0,
                         proxyGroup: "默认代理", note: "src")
check(YamlRuleASTEngine.serialize(node: collision).hasSuffix(",src"), "参数名大小写归一后仍按参数写")

// 往返：注释形式要把备注读回来，否则用户填的备注保存一次就没了
let roundProse = YamlRuleASTEngine.parseLine(proseLine)
check(roundProse?.note == "公司内网", "注释形式可读回备注（\(roundProse?.note ?? "nil")）")
check(roundProse?.match == "a.com" && roundProse?.action == .direct, "规则本体不变")
let roundParam = YamlRuleASTEngine.parseLine(paramLine)
check(roundParam?.note == "no-resolve", "参数形式可读回参数")

// 禁用规则 + 写法叠加
let disabledProse = RuleNode(type: .domainSuffix, match: "b.com", action: .reject, sort: 0,
                             isEnabled: false, note: "临时拉黑")
let disabledLine = YamlRuleASTEngine.serialize(node: disabledProse)
check(disabledLine.hasPrefix("# - "), "禁用规则仍带注释前缀（\(disabledLine)）")
check(disabledLine.hasSuffix("# 临时拉黑"), "禁用规则也能带备注")
check(YamlRuleASTEngine.parseLine(disabledLine)?.note == "临时拉黑", "禁用规则备注可读回")
check(YamlRuleASTEngine.parseLine(disabledLine)?.isEnabled == false, "禁用状态不丢")

// MATCH 规则：参数位没有意义，备注只能是注释
let matchNode = RuleNode(type: .match, match: "", action: .proxy, sort: 0,
                         proxyGroup: "默认代理", note: "兜底")
check(YamlRuleASTEngine.serialize(node: matchNode) == "- MATCH,默认代理 # 兜底",
      "MATCH 的备注也是注释")

// ── CRLF 文件与 LF 同口径 ──
// components(separatedBy: .newlines) 把 \r\n 当两个分隔符在行间垫空行，保留注释
// 的重写会原样写回；裸 \n 分割则让 \r 残留行尾。统一先归一再按 \n 分割。
let lfYaml = "proxies: []\nrules:\n  - DOMAIN,a.com,DIRECT\n  - MATCH,DIRECT\nproxy-groups: []\n"
let crlfYaml = lfYaml.replacingOccurrences(of: "\n", with: "\r\n")
let lfNodes = YamlRuleASTEngine.extractRules(from: lfYaml)
let crlfNodes = YamlRuleASTEngine.extractRules(from: crlfYaml)
func shape(_ nodes: [RuleNode]) -> String {
    nodes.map { "\($0.type.rawValue)|\($0.match)|\($0.action.rawValue)|\($0.isEnabled)" }
        .joined(separator: "\n")
}
check(lfNodes.count == 2, "LF 基线解析出 2 条规则")
check(shape(crlfNodes) == shape(lfNodes), "CRLF 输入的规则提取与 LF 一致")
let crlfRound = (try? YamlRuleASTEngine.injectRulesPreservingComments(lfNodes, into: crlfYaml, loadedNodes: lfNodes)) ?? ""
check(!crlfRound.contains("\r"), "CRLF 文件保存归一为 LF、不垫空行（实得 \(crlfRound.contains("\r") ? "含\\r" : "干净")）")
check(crlfRound == lfYaml, "CRLF 空往返结果与 LF 空往返一致")
let crlfInsert = YamlRuleASTEngine.insertRuleLine("- DOMAIN,new.com,REJECT", into: crlfYaml) ?? ""
check(!crlfInsert.contains("\r") && crlfInsert.contains("  - DOMAIN,new.com,REJECT"),
      "CRLF 文件插入规则同样干净（旧版 \r 残留行尾）")

print("\n\(total - failed)/\(total) 通过")
exit(failed == 0 ? 0 : 1)
