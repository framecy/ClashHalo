import Foundation

// 直接编译生产源码（ProviderRewrite.swift + YamlScalar.swift）。
//
// 钉住的现场：配置里 `proxy-providers` 的 http provider 指向 base64 编码的
// `.txt` 订阅。mihomo 只接受 `proxies:` 结构的 YAML，拉下来解析失败 → provider
// 永远 0 节点 → `use:` 引用它的策略组全空。修法是把这条 provider 改写成本地
// 文件（App 下载并转换），provider 名与 `use:` 引用都不变。
//
// 最危险的相邻字段是 health-check 块里的 `url:`：按行删除「url:」时若不分缩进，
// 会把健康检查地址一起删掉（症状是节点永远「不可用」而订阅本身正常）。

var failures = 0, checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  ✗ FAIL: \(what)") } else { print("  ✓ \(what)") }
}
func section(_ s: String) { print("\n── \(s) ──") }

let source = """
mixed-port: 7890
proxy-providers:
  "US-BWH":
    type: http
    url: "https://a.example.com/sub"
    interval: 3600
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
  US-LH:
    type: http
    url: "https://b.example.com/sub.txt"
    interval: 3600
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
proxy-groups:
  - name: PROXY
    type: select
    use:
      - US-BWH
      - US-LH
rules:
  - MATCH,PROXY
"""

section("改写为本地 file provider")
let converted = ProviderRewrite.convertToFile(source, name: "US-LH", filePath: "./provider-files/us-lh.yaml")
expect(converted != nil, "找到并改写了 US-LH")
let out = converted?.yaml ?? ""

expect(out.contains("    type: file"), "type 改成 file")
expect(out.contains("    path: ./provider-files/us-lh.yaml"), "写入文件路径")
expect(!out.contains("https://b.example.com/sub.txt"), "源 URL 被移除")
expect(out.contains("https://www.gstatic.com/generate_204"), "health-check 的 url 必须保留")
expect(out.components(separatedBy: "interval: 3600").count - 1 == 1,
       "只删掉被转换 provider 的 interval（US-BWH 的保留），实得 \(out.components(separatedBy: "interval: 3600").count - 1)")
expect(out.contains("  \"US-BWH\":"), "另一个 provider 仍在")
expect(out.contains("    url: \"https://a.example.com/sub\""), "另一个 provider 的 url 未被动")
expect(out.contains("    type: http"), "另一个 provider 仍是 http")
expect(out.contains("      - US-LH"), "use: 引用保持原样（组不用改）")
expect(out.contains("  - MATCH,PROXY"), "规则未被动")
expect(out.contains("mixed-port: 7890"), "其它顶层键未被动")

section("幂等与状态查询")
expect(ProviderRewrite.isFileProvider(out, name: "US-LH"), "改写后 isFileProvider 为真")
expect(!ProviderRewrite.isFileProvider(source, name: "US-LH"), "改写前为假")
expect(!ProviderRewrite.isFileProvider(source, name: "US-BWH"), "同块另一个 provider 不受影响")
let again = ProviderRewrite.convertToFile(out, name: "US-LH", filePath: "./provider-files/us-lh.yaml")?.yaml ?? ""
expect(again.components(separatedBy: "path: ./provider-files/us-lh.yaml").count - 1 == 1,
       "重复转换不会写出第二个 path")
expect(!again.contains("type: http\n    path:"), "不会同时出现 http 与 file 组合")

section("源地址读取")
expect(ProviderRewrite.httpURL(source, name: "US-LH") == "https://b.example.com/sub.txt", "读回 US-LH 的源")
expect(ProviderRewrite.httpURL(source, name: "US-BWH") == "https://a.example.com/sub", "读回 US-BWH 的源")
expect(ProviderRewrite.httpURL(out, name: "US-LH") == nil, "转换后不再有 http 源")
expect(ProviderRewrite.httpURL(source, name: "不存在") == nil, "未知 provider 返回 nil")

section("边界")
expect(ProviderRewrite.convertToFile(source, name: "不存在", filePath: "./x.yaml") == nil, "未知 provider 返回 nil")
expect(ProviderRewrite.convertToFile("mixed-port: 7890\n", name: "US-LH", filePath: "./x.yaml") == nil,
       "没有 proxy-providers 块")
let flow = "proxy-providers:\n  US-LH: {type: http, url: \"https://c.example.com/x\"}\n"
expect(ProviderRewrite.convertToFile(flow, name: "US-LH", filePath: "./x.yaml") == nil,
       "flow 映射如实拒绝（不产出半改配置）")
let noType = "proxy-providers:\n  US-LH:\n    url: \"https://d.example.com/x\"\n    health-check:\n      enable: true\n"
let filled = ProviderRewrite.convertToFile(noType, name: "US-LH", filePath: "./provider-files/us-lh.yaml")?.yaml ?? ""
expect(filled.contains("type: file") && filled.contains("path: ./provider-files/us-lh.yaml"),
       "字段缺失时补齐 type/path")
expect(!filled.contains("https://d.example.com/x"), "源 URL 被移除")
expect(filled.contains("health-check:"), "嵌套块保留")

section("缩进与引号")
let indented = """
proxy-providers:
    "deep name":
        type: http
        url: "https://e.example.com/x"
        interval: 600
"""
let deep = ProviderRewrite.convertToFile(indented, name: "deep name", filePath: "./provider-files/deep.yaml")?.yaml ?? ""
expect(deep.contains("        type: file"), "保持原缩进")
expect(deep.contains("        path: ./provider-files/deep.yaml"), "path 与原缩进对齐")
expect(!deep.contains("interval: 600"), "interval 删除")

let singleQuoted = "proxy-providers:\n  'US-LH2':\n    type: http\n    url: 'https://f.example.com/x'\n"
let sq = ProviderRewrite.convertToFile(singleQuoted, name: "US-LH2", filePath: "./p.yaml")?.yaml ?? ""
expect(sq.contains("type: file"), "单引号键名也能识别")
expect(ProviderRewrite.unquote("\"a\"") == "a" && ProviderRewrite.unquote("'b'") == "b", "去引号")

section("导入配置读取与改写安全")
expect(ProviderRewrite.httpURL(flow, name: "US-LH") == "https://c.example.com/x", "flow 可读源地址，改写仍保守拒绝")
let collision = "proxy-providers:\n  A:\n    type: http\n    health-check:\n      url: https://example.com/check\n  health-check:\n    type: http\n    url: https://example.com/sub\n"
expect(ProviderRewrite.httpURL(collision, name: "health-check") == "https://example.com/sub", "同名嵌套字段不是 provider")
let safe = ProviderRewrite.convertToFile(collision, name: "health-check", filePath: "./x.yaml")?.yaml ?? ""
expect(safe.contains("      url: https://example.com/check"), "改写不能误伤前项健康检查")
let pathFirst = "proxy-providers:\n  A:\n    path: ./old.yaml\n    type: http\n    url: https://example.com/sub\n"
let pathOut = ProviderRewrite.convertToFile(pathFirst, name: "A", filePath: "./x.yaml")?.yaml ?? ""
expect(pathOut.components(separatedBy: "path:").count - 1 == 1, "path 先于 type 也不能重复写入")
let shared = "proxy-providers:\n  A: &template\n    type: http\n    url: https://example.com/sub\n  B: *template\n"
expect(ProviderRewrite.httpURL(shared, name: "B") == "https://example.com/sub", "alias 地址可读")
expect(ProviderRewrite.convertToFile(shared, name: "A", filePath: "./x.yaml") == nil, "不得改写其他项依赖的共享 anchor")
let merge = "template: &t {type: http, url: https://example.com/sub}\nproxy-providers:\n  A:\n    <<: *t\n"
expect(ProviderRewrite.convertToFile(merge, name: "A", filePath: "./x.yaml") == nil, "不得保留继承的 HTTP 字段做半改写")
let parentAnchor = "proxy-providers: &all\n  A:\n    type: http\n    url: https://example.com/sub\nx-copy: *all\n"
expect(ProviderRewrite.convertToFile(parentAnchor, name: "A", filePath: "./x.yaml") == nil, "不得就地修改父块共享 anchor")
let crlf = "proxy-providers:\r\n  A:\r\n    health-check:\r\n      url: https://example.com/check\r\n\r\n    type: http\r\n    url: https://example.com/sub\r\n"
let crlfOut = ProviderRewrite.convertToFile(crlf, name: "A", filePath: "./x.yaml")?.yaml ?? ""
expect(!crlfOut.contains("type: http") && !crlfOut.contains("https://example.com/sub") && crlfOut.contains("type: file"), "CRLF 空行不能截断 provider 改写")

section("写入前能力预检与纯转换")
expect(ProviderRewrite.canConvertToFile(source, name: "US-LH"), "普通HTTP转换可事先预检")
for unsupported in [flow, shared, merge, parentAnchor] {
    let entry = ProviderConfiguration.entries(in: unsupported).first
    expect(entry.map { !ProviderRewrite.canConvertToFile(unsupported, name: $0.name) } ?? false, "unsupported在下载前拒绝")
}
let escapedName = #"proxy-providers:"# + "\n    'it''s':\n        type: http\n        url: https://example.com/a\n        header:\n            User-Agent: [example-client]\n        filter: 'x'\n"
let escapedOut = ProviderRewrite.convertToFile(escapedName, name: "it's", filePath: "./provider-files/example.yaml")?.yaml ?? ""
expect(escapedOut.contains("type: file") && escapedOut.contains("filter: 'x'") && !escapedOut.contains("User-Agent"), "转义provider名同decoder，HTTP header整块移除而非残留")
let movedFile = ProviderRewrite.convertToFile(escapedOut, name: "it's", filePath: "./provider-files/other.yaml")
expect(movedFile?.changed == true && movedFile?.yaml.contains("path: ./provider-files/other.yaml") == true, "已有file可原位更新path")
expect(ProviderRewrite.convertToFile(movedFile?.yaml ?? "", name: "it's", filePath: "./provider-files/other.yaml")?.changed == false, "重复转换changed准确为false")
let scalarURL = "proxy-providers:\n  A:\n    type: http\n    url: >-\n      https://example.com/a\n"
expect(!ProviderRewrite.canConvertToFile(scalarURL, name: "A") && ProviderRewrite.convertToFile(scalarURL, name: "A", filePath: "./x.yaml") == nil, "多行URL提前拒绝不能留下后半段")
let flowAnchor = "proxy-providers:\n  A:\n    type: http\n    url: https://example.com/a\n    header: {User-Agent: &agent [example-client]}\nx-agent: *agent\n"
expect(!ProviderRewrite.canConvertToFile(flowAnchor, name: "A"), "嵌套flow anchor也必须提前拒绝")
expect(!crlfOut.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "转换保持CRLF格式")
expect(!ProviderRewrite.canConvertToFile(source + "\nproxy-providers:\n  duplicate:\n    type: file\n", name: "US-LH"), "重复顶层provider块提前拒绝")

let headerScalar = "proxy-providers:\n  A:\n    type: http\n    url: https://example.com/a\n    notes: |+\n      keep\n    header:\n      X-Example: |+\n        *payload\n        # header-text\n\n    health-check:\n      enable: false\n"
let headerConverted = ProviderRewrite.convertToFile(headerScalar, name: "A", filePath: "./local.yaml")?.yaml ?? ""
expect(!headerConverted.isEmpty && !headerConverted.contains("# header-text") && !headerConverted.contains("*payload"), "转换移除header时正文注释和空行一并删除")
expect(headerConverted.contains("    notes: |+\n      keep\n    health-check:"), "header正文不会残留并被前一个块标量吸收")
let noteScalar = "proxy-providers:\n  A:\n    type: http\n    url: https://example.com/a\n    filter: |-\n      *literal &literal\n      # regex-text\n"
let noteConverted = ProviderRewrite.convertToFile(noteScalar, name: "A", filePath: "./local.yaml")?.yaml
expect(noteConverted?.hasSuffix("    filter: |-\n      *literal &literal\n      # regex-text\n") == true, "转换原样保留不需改写的多行字段")

print("\n════════════════════════════════════════════════")
if failures == 0 {
    print("ProviderRewrite: PASS \(checks) 断言")
    exit(0)
} else {
    print("ProviderRewrite: FAIL \(failures)/\(checks)")
    exit(1)
}
