import Foundation

var checks = 0, failures = 0
func expect(_ ok: Bool, _ label: String) {
    checks += 1
    if ok { print("✓ \(label)") } else { failures += 1; print("✗ \(label)") }
}
func entries(_ text: String) -> [ProviderConfiguration.Entry] { ProviderConfiguration.entries(in: text) }

let block = """
proxy-providers: # 订阅
    '订阅: A/香港': # 合法键名
        type: http
        health-check:
            url: https://example.com/health
        url: 'https://example.com/sub?a=1,b=2#part' # 备注

# provider 之间的顶层注释
    B:
        type: file
        path: ./providers/b.yaml
rule-providers:
    hidden:
        url: https://example.com/rules
"""
expect(entries(block).map(\.name) == ["订阅: A/香港", "B"], "非标准缩进、注释、顶层块边界")
expect(entries(block).first?.url == "https://example.com/sub?a=1,b=2#part", "只读直接 URL，保留逗号与 fragment")
expect(entries(block).last?.type == "file" && entries(block).last?.url == "", "file 不继承前项 URL")
let flow = #"proxy-providers: {"A: one": {type: http, url: "https://example.com/sub?a=1,b=2#part", health-check: {url: "https://example.com/check"}}, B: {type: file, path: ./b.yaml}}"#
expect(entries(flow).map(\.name) == ["A: one", "B"], "顶层 flow 与嵌套 flow")
expect(entries(flow).first?.url == "https://example.com/sub?a=1,b=2#part", "flow 源 URL 不被逗号拆散")
expect(entries("proxy-providers:\n  A: {type: http, health-check: {url: https://example.com/check}}\n").first?.url == "", "无源 URL 不得拿健康检查冒充")
let multiline = """
proxy-providers:
  A: {type: http,
    url: 'https://example.com/sub',
    health-check: {url: 'https://example.com/check'}}
  B: {type: file, path: ./b.yaml}
"""
expect(entries(multiline).count == 2 && entries(multiline).first?.url == "https://example.com/sub", "跨行 flow")
let templates = """
source: &url 'https://example.com/default'
defaults: &defaults
  type: http
  url: *url
  health-check:
    url: https://example.com/check
other: &other {url: https://example.com/other, type: file}
proxy-providers:
  A:
    url: https://example.com/explicit
    <<: *defaults
  B: {<<: [*defaults, *other]}
  C: *defaults
  D:
    <<:
      - *other
      - *defaults
"""
expect(entries(templates).map(\.name) == ["A", "B", "C", "D"], "块/flow 模板及整项 alias")
expect(entries(templates)[0].url == "https://example.com/explicit", "显式值优先，merge 先后不影响")
expect(entries(templates)[1].url == "https://example.com/default" && entries(templates)[1].type == "http", "merge 序列前项优先、scalar alias")
expect(entries(templates)[2].url == "https://example.com/default", "整项 alias 解析")
expect(entries(templates)[3].type == "file", "块状 merge 序列")
let cycle = "x: &x {<<: *x, type: http}\nproxy-providers:\n  A: {<<: *x, url: https://example.com/sub}\n  B: *missing"
expect(entries(cycle).count == 1 && entries(cycle).first?.url == "https://example.com/sub", "循环引用与缺失 alias 不挂死")
let escaped = #"proxy-providers: {'it''s': {type: http, url: 'https://example.com/it''s'}, "a\"b": {type: http, url: "https:\/\/example.com\/sub?x=\"q\""}}"#
expect(entries(escaped).first?.name == "it's" && entries(escaped).first?.url == "https://example.com/it's", "单引号转义，不删除数据里的引号")
expect(entries(escaped).last?.name == "a\"b" && entries(escaped).last?.url == "https://example.com/sub?x=\"q\"", "双引号与斜线转义")
expect(entries("\u{feff}" + block.replacingOccurrences(of: "\n", with: "\r\n")) == entries(block), "BOM 与 CRLF")
expect(entries("proxies:\n  - name: A\n    url: https://example.com/node\n").isEmpty, "不能从节点/rule provider 提取订阅")
expect(entries("proxy-providers:\n  A:\n    type: http\n    url: {broken\n  B: {type: http, url: https://example.com/b}\n").last?.name == "B", "未闭合 flow 不吞掉下一项")
expect(entries("proxy-providers:\n  A: {type: http, url: \"https://example.com/x # literal\"} # comment").first?.url == "https://example.com/x # literal", "引号内 # 不是注释")
let standard = "proxy-providers:\n  A:\n    type: http\n    url: https://example.com/sub\n"
expect(ProviderConfiguration.supportsLegacyRewrite(in: standard), "标准块允许旧写入器")
expect(!ProviderConfiguration.supportsLegacyRewrite(in: block), "深缩进 file 拒绝破坏性重建")
expect(!ProviderConfiguration.supportsLegacyRewrite(in: flow), "flow 拒绝破坏性重建")
expect(!ProviderConfiguration.supportsLegacyRewrite(in: templates), "模板拒绝破坏性重建")
expect(!ProviderConfiguration.supportsLegacyRewrite(in: "proxy-providers:\n  A:\n    'type': file\n    path: ./a.yaml\n"), "旧写入器无法识别的带引号 type 不放行")
expect(!ProviderConfiguration.supportsLegacyRewrite(in: "proxy-providers:\n  'it''s':\n    type: http\n"), "旧写入器不能去除名字中的引号")
let indentless = "defaults: &d {type: file, path: ./x.yaml}\nproxy-providers:\n  A:\n    <<:\n    - *d\n    url: https://example.com/sub\n"
expect(entries(indentless).first?.type == "file", "等缩进 merge 序列继承类型")
var expansion = "t0: &t0 {type: http}\n"
for i in 1...25 { expansion += "t\(i): &t\(i) {<<: [*t\(i-1), *t\(i-1)]}\n" }
expansion += "proxy-providers:\n  A: *t25\n"
expect(entries(expansion).isEmpty, "指数 merge 展开超预算时不返回半份清单")
expect(entries(block).last?.path == "./providers/b.yaml", "file path在同一parser读取")
expect(entries(#"proxy-providers: {"A\x2CB": {type: http, url: "https://example.com/a"}}"#).first?.name == "A,B", "YAML十六进制名称转义")
let plainQuotes = """
proxy-providers:
  O'Brien: # provider comment
    type: http
    url: https://example.com/it's # source comment
  组"名:
    type: file
    path: ./providers/local.yaml
"""
expect(entries(plainQuotes).map(\.name) == ["O'Brien", "组\"名"], "plain名称内嵌引号不启动quote扫描")
expect(entries(plainQuotes).first?.url == "https://example.com/it's", "plain URL引号不吞行尾注释")
expect(ProviderConfiguration.splitComment("  O'Brien: # note").comment == " # note", "plain键内引号不吞注释后缀")
expect(ProviderConfiguration.clean("name: O' Brien # note") == "name: O' Brien", "plain标量空格不重启引号")
expect(ProviderConfiguration.clean("name: O 'Brien # note") == "name: O 'Brien", "plain标量空格后引号仍为数据")
expect(ProviderConfiguration.clean("name: 'it''s # literal' # note") == "name: 'it''s # literal'", "单引号双写转义仍保护内部注释符")
expect(ProviderConfiguration.clean("url: &source 'it''s # literal' # note") == "url: &source 'it''s # literal'", "anchor后的引号仍从标量起点触发")
expect(entries(#"proxy-providers: {O'Brien: {type: http, url: https://example.com/it's}, 组"名: {type: file}}"#).map(\.name) == ["O'Brien", "组\"名"], "flow内plain引号不吞后续成员")
for header in ["|", ">", "|-", "|+", ">2-", "|-2", "&note |+", "!!str >-", "!<tag:yaml.org,2002:str> &note |2+"] {
    let lines = ["notes: \(header)", "  *literal", "  # literal", "", "next: *real"]
    expect(ProviderConfiguration.blockScalarContentLines(in: lines) == Set([1, 2, 3]), "块标量头 \(header) 的内容范围及结束边界")
}
let scalarSequence = ["items:", "  - |2", "    *literal", "  - notes: >2-", "      &literal", "    value: *real"]
expect(ProviderConfiguration.blockScalarContentLines(in: scalarSequence) == Set([2, 4]), "序列标量和紧凑映射使用正确缩进基准")
let leadingHash = ["notes: |", "  # content establishes indentation", "    *indented-literal", "next: *real"]
expect(ProviderConfiguration.blockScalarContentLines(in: leadingHash) == Set([1, 2]), "块标量首行井号不是注释，参与自动缩进")
let explicitBoundary = ["notes: |4", "    *literal", "  value: *real"]
expect(ProviderConfiguration.blockScalarContentLines(in: explicitBoundary) == Set([1]), "显式缩进去缩进后必须恢复结构识别")
expect(ProviderConfiguration.blockScalarContentLines(in: ["notes: '|2'", "  value: *real"]).isEmpty, "引号里的块标量形状不激活内容屏蔽")
expect(ProviderConfiguration.blockScalarContentLines(in: ["notes: |+", "  text", "", ""]) == Set([1, 2]), "文件末尾换行哨兵不算额外空行")
expect(ProviderConfiguration.blockScalarContentLines(in: ["notes: |+\r", "  text\r", "\r", ""]) == Set([1, 2]), "CRLF内容空行与EOF哨兵一致")
print("ProviderConfiguration: \(checks) 断言，失败 \(failures)")
exit(failures == 0 ? 0 : 1)
