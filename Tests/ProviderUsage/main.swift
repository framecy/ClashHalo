// Tests/ProviderUsage —— 直接编译生产源码 Sources/Model/ProviderUsage.swift +
// Sources/Core/YamlEditor/YamlScalar.swift。
//
// 钉住「订阅被几个策略组引用」的统计口径：
//   1. `use:` 的两种写法（块状列表 / 内联数组）都要认——真实 config.yaml 两种都在用；
//   2. 只统计 `proxy-groups:` 块；`rules:`、`proxies:` 里的同名文本不算；
//   3. 同一个组里重复写同一个 provider 只算一次；没有 `use:` 的组不算；
//   4. 引号、行尾注释、`#` 开头的注释行都不能把名称带进来。
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ✓ \(msg)") }
    else { print("  ✗ \(msg)"); failures += 1 }
}

let yaml = """
mixed-port: 7890
proxy-providers:
  US-LH:
    type: http
    url: "https://example.com/lh"
  US-BWH:
    type: http
    url: "https://example.com/bwh"
  unused:
    type: http
    url: "https://example.com/unused"

proxy-groups:
  # 注释里的 use: [comment-only] 不算
  - name: 自动选择
    type: fallback
    use:
      - "US-LH"
      - "US-BWH"
    url: https://www.gstatic.com/generate_204

  - name: 默认代理
    type: select
    use: ["US-LH", 'US-BWH']   # 内联数组 + 行尾注释

  - name: 直连修复
    type: select
    proxies:
      - DIRECT

  - name: 油管视频
    type: select
    use:
      - US-LH
      - US-LH
    proxies:
      - 自动选择

rules:
  - DOMAIN-SUFFIX,unused.example,DIRECT
  - MATCH,默认代理
"""

// ── 1. 基本统计 ───────────────────────────────────────────────────────
print("== 基本统计 ==")
let counts = ProviderUsage.groupReferences(in: yaml)
check(counts["US-LH"] == 3, "US-LH 被 3 个组引用（\(counts["US-LH"] ?? -1)）")
check(counts["US-BWH"] == 2, "US-BWH 被 2 个组引用")
check(counts["unused"] == nil, "没有 use: 引用的 provider 不在结果里")
check(counts.keys.count == 2, "只统计被引用的（\(counts.keys.sorted())）")
check(!counts.keys.contains("comment-only"), "注释行里的 use 不被解析")
check(!counts.keys.contains("默认代理"), "rules 段里的组名不算引用")

// 同一组重复写同一个 provider 只算一次
check(counts["US-LH"] == 3, "重复项去重后仍为 3（油管视频里写了两次）")

// ── 2. 两种写法一致性 ─────────────────────────────────────────────────
print("== 写法一致性 ==")
let blockForm = """
proxy-groups:
  - name: g1
    use:
      - A
      - B
"""
let inlineForm = """
proxy-groups:
  - name: g1
    use: [A, B]
"""
check(ProviderUsage.groupReferences(in: blockForm) == ProviderUsage.groupReferences(in: inlineForm),
      "块状与内联写法结果一致")

let emptyUse = """
proxy-groups:
  - name: g1
    type: select
    use: []
    proxies: [DIRECT]
"""
check(ProviderUsage.groupReferences(in: emptyUse).isEmpty, "use: [] 不计入")

let noGroups = "mixed-port: 7890\nrules:\n  - MATCH,DIRECT\n"
check(ProviderUsage.groupReferences(in: noGroups).isEmpty, "没有 proxy-groups 块 → 空")

// ── 3. 边界：块结束、缩进、引号 ──────────────────────────────────────
print("== 边界 ==")
let tail = """
proxy-groups:
  - name: g1
    use:
      - A
  - name: g2
    type: select
    use:
      - B
rules:
  - MATCH,g1
"""
let tailCounts = ProviderUsage.groupReferences(in: tail)
check(tailCounts["A"] == 1 && tailCounts["B"] == 1, "多组各自统计正确（\(tailCounts)）")

// use 列表之后出现同缩进的其它字段：列表必须结束
let followed = """
proxy-groups:
  - name: g1
    use:
      - A
    url: https://example.com/health
    interval: 300
"""
check(ProviderUsage.groupReferences(in: followed)["A"] == 1, "use 列表后的同缩进字段结束列表")

// 引号与注释
check(ProviderUsage.scalar("\"US-LH\"") == "US-LH", "去双引号")
check(ProviderUsage.scalar("'US-LH'") == "US-LH", "去单引号")
check(ProviderUsage.scalar("\"US\"LH\"") == "US\"LH", "中间引号是数据（只剥首尾一对，旧版全局替换会吃掉）")
check(ProviderUsage.scalar("\"'US'\"") == "'US'", "只剥一层（双引号内的单引号保留）")
check(ProviderUsage.scalar("US-LH # 备注") == "US-LH", "去行尾注释")
check(ProviderUsage.scalar("# 纯注释") == nil, "纯注释 → nil")
check(ProviderUsage.scalar("") == nil, "空串 → nil")

// 值里的 `#` 不是注释（与 YamlScalar 同口径）
check(ProviderUsage.scalar("A#1") == "A#1", "值内 # 保留")

// ── 4. 内联数组解析 ──────────────────────────────────────────────────
print("== 内联数组 ==")
check(ProviderUsage.parseInlineList("[\"A\", \"B\"]") == ["A", "B"], "标准内联数组")
check(ProviderUsage.parseInlineList("[A]") == ["A"], "单元素")
check(ProviderUsage.parseInlineList("A") == ["A"], "裸标量")
check(ProviderUsage.parseInlineList("[]").isEmpty, "空数组")

// ── 5. 展示文案 ──────────────────────────────────────────────────────
print("== 文案 ==")
check(ProviderUsage.summary(count: 0) == "未被任何策略组引用", "0 的文案")
check(ProviderUsage.summary(count: 2) == "被 2 个策略组引用", "N 的文案")

// ── 6. 策略组名扫描（规则表单「目标还在不在」） ──────────────────────
// 这份解析同时给「策略组排序」和「规则表单目标存在性校验」用，所以必须钉住：
// 只认 proxy-groups 块里 2 空格缩进的 `- name:`，别把 proxy-providers 里的同名
// 键、rules 里的目标、组内 `proxies:` 列表项当成策略组。
print("== 策略组名 ==")
let fullConfig = """
mixed-port: 7890
proxy-providers:
  - name: 不是策略组
    type: http
proxy-groups:
  - name: 默认代理
    type: select
    use:
      - US-LH
  - name: "广告拦截"   # 手工加的
    type: select
    proxies:
      - DIRECT
rules:
  - DOMAIN-SUFFIX,example.com,默认代理
"""
let groupNames = ProviderUsage.groupNames(in: fullConfig)
check(groupNames == ["默认代理", "广告拦截"], "只取 proxy-groups 的组名（\(groupNames)）")
check(!groupNames.contains("不是策略组"), "proxy-providers 里的 name 不算")
check(!groupNames.contains("DIRECT"), "组内 proxies 列表项不算")
check(!groupNames.contains("example.com"), "rules 里的目标不算")

check(ProviderUsage.groupNames(in: noGroups).isEmpty, "没有 proxy-groups 块 → 空")
check(ProviderUsage.groupNames(in: "").isEmpty, "空文本 → 空")
// 单行 flow 组可读名字与来源；写入另有 capability gate。
let inlineMapping = """
proxy-groups:
  - {name: 内联组, type: select}
"""
check(ProviderUsage.groupNames(in: inlineMapping) == ["内联组"], "单行flow组读取名称，写能力独立判定")
check(ProviderUsage.scanGroups(in: inlineMapping).first?.canRewrite == false, "flow组可读但不允许有损改写")
let deepNames = """
proxy-groups:
    - type: select
      name: '组,一'
      use: ['a,b', 'it''s', "a\\\"b", "c # d"] # note
      health-check:
          name: not-a-group
          use: [not-a-provider]
    - name: second
      proxies: [DIRECT]
proxies:
    - name: not-a-group-either
"""
check(ProviderUsage.groupNames(in: deepNames) == ["组,一", "second"], "深缩进/后置组名不混入嵌套name")
check(ProviderUsage.groupReferences(in: deepNames) == ["a,b": 1, "it's": 1, "a\"b": 1, "c # d": 1], "逗号/单双引号转义/注释与provider decoder一致")
check(ProviderUsage.scalar(#""A\x2CB\u4e2d""#) == "A,B中", "YAML双引号十六进制转义统一解码")
let dashOnly = "proxy-groups:\n -\n     name: wide\n     use:\n       - a\n"
check(ProviderUsage.groupNames(in: dashOnly) == ["wide"] && ProviderUsage.groupReferences(in: dashOnly)["a"] == 1, "独立短横与任意字段缩进")
let spacedDash = "proxy-groups:\n -   name: spaced\n     use: [a]\n"
check(ProviderUsage.groupReferences(in: spacedDash)["a"] == 1, "短横后多个空格遵循映射字段列位置")
let unknownSource = "proxy-groups:\n  - name: anchored\n    use: *providers\n  - name: complex\n    proxies: [\n      DIRECT\n    ]\n"
check(ProviderUsage.groupsMissingMembers(in: unknownSource).isEmpty, "未知成员来源不能误报空组")
let zeroIndent = "proxy-groups:\n- name: root-sequence\n  use:\n  - 'a,b'\nrules: []\n"
check(ProviderUsage.groupReferences(in: zeroIndent)["a,b"] == 1, "零缩进组序列与等缩进use列表")

let plainQuotes = "proxy-groups:\n  - name: O'Brien # note\n    use: [O'Brien, 组\"名, B] # refs\n"
check(ProviderUsage.groupNames(in: plainQuotes) == ["O'Brien"], "plain组名内引号不吞注释")
check(ProviderUsage.groupReferences(in: plainQuotes) == ["O'Brien": 1, "组\"名": 1, "B": 1], "plain引用内引号不吞逗号及后续成员")
check(ProviderUsage.parseInlineList("[O 'Brien, 'A,B', B]") == ["O 'Brien", "A,B", "B"], "plain空格后内嵌引号与下一quoted成员分开")
for key in ["include-all-providers", "include-all-proxies", "include-all"] {
    for value in ["*all", "!!bool true", "&all true", "unknown"] {
        let input = "proxy-groups:\n  - name: unknown\n    \(key): \(value)\n"
        let group = ProviderUsage.scanGroups(in: input).first
        check(group?.hasUnknownMembers == true && group?.canRewrite == false, "\(key)未知布尔\(value)保守拒绝")
        check(ProviderUsage.groupsMissingMembers(in: input).isEmpty, "\(key)未知布尔不能判空")
    }
    let falseInput = "proxy-groups:\n  - name: empty\n    \(key): false\n"
    check(ProviderUsage.groupsMissingMembers(in: falseInput) == ["empty"], "\(key)显式false仍正确判空")
}
print("")
if failures == 0 { print("ProviderUsage: 全部通过"); exit(0) }
print("ProviderUsage: \(failures) 处失败"); exit(1)
