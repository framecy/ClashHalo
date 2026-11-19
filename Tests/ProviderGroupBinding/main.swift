// Tests/ProviderGroupBinding —— 直接编译生产源码
// Sources/Model/ProviderGroupBinding.swift + ProviderUsage.swift +
// Sources/Core/YamlEditor/YamlScalar.swift。
//
// 钉住订阅 → 策略组归属的写盘口径：
//   1. 块状 use: / 内联 use: 两种写法的增删；
//   2. 没有 use: 的组按组内缩进插入；
//   3. 改名原位替换、删除清理，其他 provider 与注释不动；
//   4. include-all-providers 组不写 use:；
//   5. 未受影响的区域逐字节不变（幂等）；
//   6. membership 与 ProviderUsage.groupReferences 的口径一致。
import Foundation

var failures: [String] = []
func check(_ cond: Bool, _ name: String) {
    if cond { print("  ✓ \(name)") } else { failures.append(name); print("  ✗ \(name)") }
}

func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }

// MARK: - 1. 块状 use: 追加

let blockYAML = """
mixed-port: 7890
proxy-providers:
  "US-LH":
    type: http
    url: "https://example.com/lh"
proxy-groups:
  - name: 自动选择
    type: fallback
    use:
      - "US-LH"   # 主订阅
    url: http://www.gstatic.com/generate_204
  - name: 直连修复
    type: select
    proxies:
      - DIRECT
rules:
  - MATCH,自动选择
"""

let added = ProviderGroupBinding.rewrite(blockYAML,
                                         desired: ["US-LH": ["自动选择", "直连修复"]],
                                         removed: [],
                                         renamed: [:])
check(added.contains("      - \"US-LH\"   # 主订阅"), "块状：原有条目与行尾注释保留")
check(added.contains("      - \"US-LH\""), "块状：目标组追加成功")
check(added.components(separatedBy: "      - \"US-LH\"").count == 3, "块状：新增组也拿到条目")
check(lines(added).filter { $0.contains("- \"US-LH\"") }.count == 2, "块状：条目总数 = 原有 1 + 新增 1")
check(added.contains("  - name: 直连修复\n    type: select\n    use:\n      - \"US-LH\"\n    proxies:"),
      "无 use 的组：插在 type 之后、proxies 之前")
check(added.contains("proxies:\n      - DIRECT"), "proxies 块原样保留")

// 幂等：同一 plan 再跑一次，结果不变
let addedTwice = ProviderGroupBinding.rewrite(added,
                                              desired: ["US-LH": ["自动选择", "直连修复"]],
                                              removed: [],
                                              renamed: [:])
check(addedTwice == added, "幂等：同一 plan 连跑两次输出一致")

// 无关区域零改动：去掉目标组范围内的行，其余逐行一致
let before = lines(blockYAML)
let after = lines(added)
let fixedBefore = before.filter { !$0.contains("US-LH") && !$0.contains("use:") && !$0.contains("自动选择") && !$0.contains("直连修复") }
let fixedAfter = after.filter { !$0.contains("US-LH") && !$0.contains("use:") && !$0.contains("自动选择") && !$0.contains("直连修复") }
check(fixedBefore == fixedAfter, "无关区域零改动（providers/rules/顶层键）")

// MARK: - 2. 块状删到 0 → 整块 use: 移除

let removedAll = ProviderGroupBinding.rewrite(blockYAML,
                                             desired: ["US-LH": []],
                                             removed: [],
                                             renamed: [:])
check(!removedAll.contains("use:"), "块状删到 0：use: 整块移除")
check(removedAll.contains("    url: http://www.gstatic.com/generate_204"), "删空后组内其他字段保留")

// MARK: - 3. 内联 use: 加/删 + 行尾注释

let inlineYAML = """
proxy-groups:
  - name: 自动选择
    type: select
    use: ["US-LH", 'US-BWH']   # 内联
  - name: 手动
    type: select
    use: []
rules:
  - MATCH,自动选择
"""

let inlineAdded = ProviderGroupBinding.rewrite(inlineYAML,
                                               desired: ["US-LH": ["自动选择"], "US-BWH": ["自动选择"], "NEW": ["自动选择", "手动"]],
                                               removed: [],
                                               renamed: [:])
check(inlineAdded.contains("use: [\"US-LH\", \"US-BWH\", \"NEW\"]   # 内联"),
      "内联：保留顺序与行尾注释，新条目追加")
check(inlineAdded.contains("    use: [\"NEW\"]"), "use: [] 追加为单元素内联")

let inlineRemoved = ProviderGroupBinding.rewrite(inlineYAML,
                                                 desired: ["US-LH": [], "US-BWH": []],
                                                 removed: [],
                                                 renamed: [:])
check(!inlineRemoved.contains("use: [\"US-LH\""), "内联删空后整行移除")
let inlineUntouched = ProviderGroupBinding.rewrite(inlineYAML,
                                                  desired: ["US-LH": ["自动选择"], "US-BWH": ["自动选择"]],
                                                  removed: [],
                                                  renamed: [:])
check(inlineUntouched.contains("    use: []"), "use: [] 未受影响的组原样保留")

// MARK: - 4. 改名：原位替换，其他 provider 不动

let renamedYAML = """
proxy-groups:
  - name: 自动选择
    type: select
    use:
      - "OLD"    # 备注
      - "OTHER"
  - name: 手动
    type: select
    use: ["OLD"]
rules:
  - MATCH,自动选择
"""

let renamed = ProviderGroupBinding.rewrite(renamedYAML,
                                           desired: ["NEW": ["自动选择", "手动"]],
                                           removed: [],
                                           renamed: ["OLD": "NEW"])
check(renamed.contains("      - \"NEW\"    # 备注"), "改名：块状条目原位换名并保留注释")
check(renamed.contains("      - \"OTHER\""), "改名：同组其他 provider 不动")
check(renamed.contains("use: [\"NEW\"]"), "改名：内联写法同步换名")
check(!renamed.contains("OLD"), "改名：旧名不残留")
check(renamed.contains("  - MATCH,自动选择"), "改名：规则里的文本不受影响")

// MARK: - 5. 删除 provider

let deleted = ProviderGroupBinding.rewrite(blockYAML,
                                           desired: [:],
                                           removed: ["US-LH"],
                                           renamed: [:])
check(!deleted.contains("- \"US-LH\""), "删除：所有 use: 引用清干净")
check(!deleted.contains("    use:"), "删除：只有删空来源的 use: 被移除")
check(deleted.contains("    proxies:\n      - DIRECT"), "删除：其他组的 proxies 不受影响")

// MARK: - 6. include-all-providers 跳过

let includeAllYAML = """
proxy-groups:
  - name: 全部订阅
    type: select
    include-all-providers: true
  - name: 手动
    type: select
    use: ["US-LH"]
"""

let includeAll = ProviderGroupBinding.rewrite(includeAllYAML,
                                              desired: ["US-LH": ["全部订阅"]],
                                              removed: ["US-LH"],
                                              renamed: [:])
check(!includeAll.contains("include-all-providers: true\n    use:"), "include-all-providers 组不写 use:")
check(includeAll.contains("include-all-providers: true"), "include-all-providers 组本身保留")
check(!includeAll.contains("use: [\"US-LH\"]"), "其他组的引用照常清理")

// include-all-providers 组里的显式 use（少见但合法）遇到改名前也必须换名，
// 否则旧名悬空，mihomo -t 会拒绝整份配置。
let includeAllRenameYAML = """
proxy-groups:
  - name: 全部订阅
    type: select
    include-all-providers: true
    use: ["OLD"]
"""
let includeAllRenamed = ProviderGroupBinding.rewrite(includeAllRenameYAML,
                                                    desired: [:],
                                                    removed: [],
                                                    renamed: ["OLD": "NEW"])
check(includeAllRenamed.contains("use: [\"NEW\"]"), "include-all-providers 组：改名仍原位替换")
check(!includeAllRenamed.contains("OLD"), "include-all-providers 组：旧名不残留")

// MARK: - 7. membership 与 ProviderUsage.groupReferences 口径一致

let membership = ProviderGroupBinding.membership(in: blockYAML)
check(membership["US-LH"] == ["自动选择"], "membership：块状 use 反查正确")
let counts = ProviderUsage.groupReferences(in: blockYAML)
check(counts["US-LH"] == 1, "交叉校验：ProviderUsage 计数一致")

let inlineMembership = ProviderGroupBinding.membership(in: inlineYAML)
check(inlineMembership["US-LH"] == ["自动选择"], "membership：内联 use 反查正确")

// MARK: - 8. F24：type: 在前、name: 在后的组也能改

let nameLaterYAML = """
proxy-groups:
  - type: select
    name: 晚点名
    use: ["US-LH"]
"""

let nameLater = ProviderGroupBinding.rewrite(nameLaterYAML,
                                             desired: ["US-LH": []],
                                             removed: [],
                                             renamed: [:])
check(!nameLater.contains("use:"), "name 后置的组：删空后 use: 移除")
check(nameLater.contains("    name: 晚点名"), "name 后置的组：name 字段保留")

// MARK: - 9. 真实结构形态：15 个组只动 2 个带 use: 的组

var realYAML = "proxy-groups:\n"
for i in 0..<13 {
    realYAML += "  - name: 组\(i)\n    type: select\n    proxies:\n      - DIRECT\n"
}
realYAML += """
  - name: 订阅组A
    type: select
    use:
      - "US-LH"
  - name: 订阅组B
    type: select
    use: ["US-LH"]
rules:
  - MATCH,订阅组A
"""
let realOut = ProviderGroupBinding.rewrite(realYAML,
                                           desired: ["US-LH": ["订阅组B"]],
                                           removed: [],
                                           renamed: [:])
check(realOut.contains("  - name: 订阅组A\n    type: select\n    proxies:\n      - DIRECT") == false
      || !realOut.contains("订阅组A\n    type: select\n    use:"),
      "真实结构：取消最后一个组后不再写 use:")
check(realOut.contains("use: [\"US-LH\"]"), "真实结构：保留组的引用不变")
check(realOut.components(separatedBy: "  - name: 组0\n").count == 2, "真实结构：无关组原样保留")

// MARK: - 10. 任意缩进、转义名和能力拒绝
let deep = "proxy-groups:\n    - name: 'G,1'\n      type: select\n      use:\n      - 'it''s' # keep\n      - 'a,b'\n    - name: G2\n      use: [\"a,b\"]\n      proxies: [DIRECT]\nrules: []\n"
check(ProviderGroupBinding.groups(in: deep).map(\.name) == ProviderUsage.groupNames(in: deep), "唯一组名scanner一致")
let deepOut = ProviderGroupBinding.rewrite(deep, desired: ["a,b": ["G2"]], removed: [], renamed: ["it's": "new,\"name"])
check(ProviderGroupBinding.membership(in: deepOut)["new,\"name"] == ["G,1"], "deep/indentless use转义名原位更新")
check(deepOut.contains("      - \"new,\\\"name\" # keep"), "转义改名保留注释")
check(ProviderGroupBinding.membership(in: deepOut)["a,b"] == ["G2"], "带逗号provider不拆分")
let opaque = "proxy-groups:\n  - name: anchored\n    use: *uses\n"
check(!ProviderGroupBinding.supportsRewrite(opaque, desired: [:], removed: ["A"], renamed: [:]), "alias归属提前拒绝")
check(ProviderGroupBinding.rewrite(opaque, desired: [:], removed: ["A"], renamed: [:]) == opaque, "旧非throw入口unsupported原文不动")
let flowSafe = "proxy-groups:\n  - {name: 'G,1', type: select, use: ['a,b']}\n"
check(ProviderGroupBinding.supportsRewrite(flowSafe, desired: ["a,b": ["G,1"]], removed: [], renamed: [:]), "flow组无实际改动允许保留")
check(!ProviderGroupBinding.supportsRewrite(flowSafe, desired: [:], removed: ["a,b"], renamed: [:]), "flow组真实删除拒绝而不半改写")
let duplicates = "proxy-groups:\n  - name: G\n    use: [A, A]\n  - name: G2\n    use: [B]\n"
check(ProviderGroupBinding.rewrite(duplicates, desired: ["B": ["G2"]], removed: [], renamed: [:]) == duplicates, "无关组重复项也不能被顺手格式化")

// MARK: - 结果

if failures.isEmpty {
    print("\n全部通过")
    exit(0)
} else {
    print("\n失败 \(failures.count) 项：")
    for f in failures { print("  - \(f)") }
    exit(1)
}
