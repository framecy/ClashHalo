import Foundation

var checks = 0, failures = 0
func check(_ value: Bool, _ label: String) {
    checks += 1
    if value { print("✓ \(label)") } else { failures += 1; print("✗ \(label)") }
}
func rejects(_ yaml: String, providers: [(name: String, url: String)], memberships: [String: Set<String>] = [:], renamed: [String: String] = [:]) -> Bool {
    do { _ = try ProviderDocument.rewrite(yaml, providers: providers, memberships: memberships, renamed: renamed); return false }
    catch { return true }
}
let source = """
# profile title
mixed-port: 7890
proxy-providers: # providers
    'A,b': # primary
        type: http
        url: 'https://example.com/old'  # source
        interval: 14400
        header:
            User-Agent: [example-client]
        filter: 'region: .+'
        exclude-filter: 'bad'
        override:
            type: file
            skip-cert-verify: true
        health-check:
            enable: true
            url: https://example.com/health
            interval: 180
    'it''s':
        type: file
        path: ./provider-files/local.yaml
        filter: local
# groups title
proxy-groups:
    - name: '组,一'
      type: select
      use: ['A,b'] # use note
      proxies: [] # empty
    - type: select
      name: secondary
      use:
      - 'A,b'
      - 'it''s'
    - name: empty-before
      type: select
    - name: node-only
      type: select
      proxies: ['A,b']
    - name: all
      type: select
      include-all-providers: true
proxies:
  - name: 'A,b'
    type: direct
rules:
  - DOMAIN,example.com,A,b
  - MATCH,DIRECT
"""
let providers: [(name: String, url: String)] = [("A,b", "https://example.com/old"), ("it's", "")]
check((try? ProviderDocument.rewrite(source, providers: providers)) == source, "无变化逐字节保留整个文档")
check((try? ProviderDocument.rewrite(source, providers: providers.reversed())) == source, "输入顺序变化不重排 provider")
let changed = try! ProviderDocument.rewrite(source, providers: [("A,b", "https://example.com/new"), ("it's", "")])
let expected = source.replacingOccurrences(of: "url: 'https://example.com/old'", with: "url: \"https://example.com/new\"")
check(changed == expected, "URL只替换标量，header/filter/interval/嵌套type/注释完整保留")
check(ProviderConfiguration.entries(in: changed).first?.type == "http", "嵌套type:file不能误判HTTP")
check(ProviderConfiguration.entries(in: changed).last?.path == "./provider-files/local.yaml", "file类型与路径保留")
let renamed = try! ProviderDocument.rewrite(source, providers: [("new,\"name", "https://example.com/old"), ("it's", "")], renamed: ["A,b": "new,\"name"])
check(ProviderConfiguration.entries(in: renamed).map(\.name) == ["new,\"name", "it's"], "provider改名使用同一decoder")
check(ProviderGroupBinding.membership(in: renamed)["new,\"name"] == ["组,一", "secondary"], "改名同时更新全部use且归属不丢失")
check(renamed.contains("proxies: ['A,b']") && renamed.contains("- name: 'A,b'") && renamed.contains("DOMAIN,example.com,A,b"), "同名节点与规则不随provider改名")
let deleted = try! ProviderDocument.rewrite(source, providers: [("it's", "")])
check(ProviderConfiguration.entries(in: deleted).map(\.name) == ["it's"], "删除只移除目标provider块")
check(ProviderGroupBinding.membership(in: deleted)["A,b"] == nil, "删除由唯一归属入口清理use")
check(deleted.contains("      proxies: [DIRECT] # empty"), "本次被删空组在已有空proxies原位补DIRECT")
check(deleted.contains("name: empty-before\n      type: select\n"), "既有空组不被误补DIRECT")
check(deleted.contains("name: node-only\n      type: select\n      proxies: ['A,b']"), "同名组节点来源不被删")
check(deleted.contains("# groups title\nproxy-groups:"), "删除不吞块间标题注释")
check(deleted.components(separatedBy: "proxies:\n").last == source.components(separatedBy: "proxies:\n").last, "proxies与rules整段字节不变")
let groupsOnly = try! ProviderDocument.rewrite(source, providers: providers, memberships: ["A,b": ["secondary"]])
check(groupsOnly.components(separatedBy: "proxy-groups:").first == source.components(separatedBy: "proxy-groups:").first, "只改分组provider原块零改动")
check(ProviderGroupBinding.membership(in: groupsOnly)["A,b"] == ["secondary"], "任意缩进和indentless use正确收敛")
let newSource = try! ProviderDocument.rewrite(source, providers: providers + [("C", "https://example.com/c")], memberships: ["C": ["secondary"]])
check(ProviderConfiguration.entries(in: newSource).count == 3, "新增provider模板可读取")
check(newSource.contains("        interval: 14400\n        header:"), "新增不重建已有provider")
let emptied = try! ProviderDocument.rewrite("proxy-providers:\n  A:\n    type: http\n    url: https://example.com/a\nproxy-groups: []\nrules: []\n", providers: [])
check(emptied.contains("proxy-providers: {}\n"), "删空provider块使用空映射而非null")
let refilled = try! ProviderDocument.rewrite(emptied, providers: [("B", "https://example.com/b")])
check(ProviderConfiguration.entries(in: refilled).first?.name == "B", "空映射可再次添加")
let absent = try! ProviderDocument.rewrite("dns:\n  enable: true\n", providers: [("B", "https://example.com/b")])
check(absent.hasPrefix("dns:\n  enable: true\n"), "没有provider块时添加不破坏原字段")
check(rejects(source, providers: [("it's", "https://example.com/local")]), "普通编辑拒绝把file悄悄变HTTP")
check(rejects(source, providers: [("X", ""), ("X", "")]), "重复目标名拒绝而非崩溃")
check(rejects(source, providers: providers, memberships: ["A,b": ["unknown"]]), "未知策略组拒绝而非静默丢归属")
check(rejects(source, providers: providers, renamed: ["missing": "it's"]), "不存在的改名源拒绝")

let complex = """
defaults: &d {type: http, url: https://example.com/a}
proxy-providers:
  A: {<<: *d, filter: 'x'}
proxy-groups:
  - name: one
    type: select
    use: [A]
  - name: two
    type: select
    proxies: [DIRECT]
rules: []
"""
check((try? ProviderDocument.rewrite(complex, providers: [("A", "https://example.com/a")])) == complex, "模板/flow无变化保持逐字节")
let complexGroup = try! ProviderDocument.rewrite(complex, providers: [("A", "https://example.com/a")], memberships: ["A": ["one", "two"]])
check(complexGroup.hasPrefix(complex.components(separatedBy: "proxy-groups:")[0]), "模板/flow只组变时provider保持原始字节")
check(rejects(complex, providers: [("A", "https://example.com/new")]), "模板/flow结构修改显式拒绝")
check(rejects(complex, providers: []), "模板/flow删除显式拒绝不产出半份")
let flowGroup = "proxy-providers:\n  A:\n    type: http\n    url: https://example.com/a\nproxy-groups:\n  - {name: 'G,1', type: select, use: [A]}\n"
check(rejects(flowGroup, providers: []), "flow组无法安全清理use时整个provider删除拒绝")
check((try? ProviderDocument.rewrite(flowGroup, providers: [("A", "https://example.com/a")], memberships: ["A": ["G,1"]])) == flowGroup, "flow组无实际归属变化可以原样保存")
let aliasGroup = flowGroup.replacingOccurrences(of: "- {name: 'G,1', type: select, use: [A]}", with: "- *group")
check(rejects(aliasGroup, providers: []), "未知alias组不得遗留悬空use")
let sharedScalar = "proxy-providers:\n  A:\n    type: http\n    url: &source https://example.com/a\nx-url: *source\n"
check(rejects(sharedScalar, providers: [("A", "https://example.com/new")]), "共享scalar anchor拒绝修改")
let sharedFlow = "proxy-providers:\n  A:\n    type: http\n    url: https://example.com/a\n    header: {User-Agent: &ua [example]}\nx-ua: *ua\n"
check(rejects(sharedFlow, providers: []), "嵌套flow内anchor也不能随provider删除")
let multiline = "proxy-providers:\n  A:\n    type: http\n    url: >-\n      https://example.com/a\n"
check(rejects(multiline, providers: [("A", "https://example.com/new")]), "多行URL拒绝半改写")
let duplicate = "proxy-providers:\n  A:\n    type: http\n    url: https://example.com/a\nproxy-providers:\n  B:\n    type: file\n"
check(rejects(duplicate, providers: []), "重复顶层provider块显式拒绝")

let profile = """
# profile
mixed-port: 7890
dns: {enable: false}
proxy-providers:
  old: {type: http, url: https://example.com/old}

# profile groups
proxy-groups:
  - name: old
    type: select
    use: [old]
# profile tunnel
tun: {enable: false}
rules:
  - MATCH,DIRECT
"""
let runtime = """
mixed-port: 9999
dns: {enable: true, listen: 'example.com:53'}
proxy-providers:
  current: {type: http, url: https://example.com/new}
proxy-groups:
  - name: current
    type: select
    use: [current]
tun: {enable: true}
rules:
  - MATCH,REJECT
"""
let synced = try! ProviderDocument.synchronize(runtime: runtime, into: profile)
check(synced.contains("current: {type: http, url: https://example.com/new}"), "同步runtime完整provider定义")
check(synced.contains("    use: [current]"), "同步runtime归属组块")
check(synced.contains("mixed-port: 7890\ndns: {enable: false}"), "runtime端口DNS不得写回profile")
check(synced.contains("# profile tunnel\ntun: {enable: false}\nrules:\n  - MATCH,DIRECT"), "profile的TUN规则与注释逐字节保留")
check(synced.contains("\n\n# profile groups\n"), "profile块外空行和标题保留")
check((try? ProviderDocument.synchronize(runtime: runtime, into: synced)) == synced, "重复同步幂等")
let crlf = source.replacingOccurrences(of: "\n", with: "\r\n")
let crlfUpdated = try! ProviderDocument.rewrite(crlf, providers: providers, memberships: ["A,b": ["组,一", "secondary", "node-only"]])
check(!crlfUpdated.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "CRLF新写组行保持原行尾")
check((try? ProviderDocument.rewrite(crlf, providers: providers)) == crlf, "CRLF无变化逐字节")
let crlfBlock = "proxy-providers:\r\n  A:\r\n    type: http\r\n    url: https://example.com/a\r\nproxy-groups:\r\n  - name: G\r\n    use:\r\n      - A\r\n\r\n      - B\r\nrules: []\r\n"
let crlfBlockDeleted = try! ProviderDocument.rewrite(crlfBlock, providers: [])
check(!crlfBlockDeleted.contains("- A") && crlfBlockDeleted.contains("- B"), "CRLF空行不能提前终止use删除")
check(rejects(source, providers: [("A,b", "https://example.com/old"), ("local-new", "")], renamed: ["it's": "local-new"]), "file名称改动不能绕过source store迁移")
func syncRejects(_ runtime: String, _ profile: String) -> Bool {
    do { _ = try ProviderDocument.synchronize(runtime: runtime, into: profile); return false }
    catch { return true }
}
check(syncRejects(complex, profile), "外部anchor依赖不能只拷两块造悬空alias")
let driftRuntime = "defaults: &d {type: http, url: https://example.com/new, header: {User-Agent: [new]}}\nproxy-providers:\n  A: *d\n"
let driftProfile = driftRuntime.replacingOccurrences(of: "example.com/new", with: "example.com/old")
check(syncRejects(driftRuntime, driftProfile), "两块相同但外部模板URL漂移也拒绝")
let closed = "proxy-providers:\n  A: &local {type: http, url: https://example.com/a}\n  B: *local\nproxy-groups:\n  - name: G\n    use: [A, B]\n"
let closedSynced = try? ProviderDocument.synchronize(runtime: closed, into: profile)
check(closedSynced.map { ProviderConfiguration.entries(in: $0) == ProviderConfiguration.entries(in: closed) } == true, "片段内部闭合anchor可原样同步")
let outgoingAlias = "proxy-providers:\n  A: &shared {type: http, url: https://example.com/a}\nx-copy: *shared\n"
check(syncRejects(runtime, outgoingAlias), "profile外部alias依赖被替换块时拒绝")
check((try? ProviderDocument.synchronize(runtime: complex, into: complex)) == complex, "完全无变化的复杂配置保留")
let sameNameGroups = "proxy-providers:\n  A:\n    type: http\n    url: https://example.com/a\nproxy-groups:\n  - name: G\n    use: [A]\n  - name: G\n    type: select\n"
let sameNameDeleted = try! ProviderDocument.rewrite(sameNameGroups, providers: [])
check(sameNameDeleted.components(separatedBy: "proxies: [DIRECT]").count == 2
      && sameNameDeleted.hasSuffix("  - name: G\n    type: select\n"), "DIRECT兜底按文档位置配对，同名既有空组不误伤")
let plainQuotes = """
proxy-providers:
  O'Brien: # primary
    type: http
    url: https://example.com/it's # source
  B:
    type: http
    url: https://example.com/b
proxy-groups:
  - name: 组"名 # group
    use: [O'Brien, B] # refs
"""
let plainUpdated = try! ProviderDocument.rewrite(plainQuotes, providers: [("O'Brien", "https://example.com/new"), ("B", "https://example.com/b")])
check(ProviderConfiguration.entries(in: plainUpdated).map(\.name) == ["O'Brien", "B"], "plain引号名称更新不重复添加provider")
check(plainUpdated.contains("url: \"https://example.com/new\" # source"), "plain引号URL更新保留注释")
let plainDeleted = try! ProviderDocument.rewrite(plainQuotes, providers: [("B", "https://example.com/b")])
check(ProviderGroupBinding.membership(in: plainDeleted) == ["B": ["组\"名"]], "删除plain引号provider不遗留合并后的悬空引用")
check(plainDeleted.contains("use: [\"B\"] # refs"), "引用清理保留后续成员及注释")
for value in ["*all", "!!bool true", "&all true"] {
    let unknownBool = plainQuotes.replacingOccurrences(of: "    use: [O'Brien, B] # refs", with: "    use: [O'Brien, B]\n    include-all-providers: \(value)")
    check(rejects(unknownBool, providers: []), "未知include-all \(value)删除拒绝而非注入DIRECT")
}
let crossBlockRuntime = "proxy-providers:\n  P:\n    type: http\n    url: https://example.com/p\n    filter: &pattern node\nproxy-groups:\n  - name: G\n    use: [P]\n    filter: *pattern\n"
let reversedProfile = "proxy-groups:\n  - name: old\n    use: [old]\nproxy-providers:\n  old:\n    type: http\n    url: https://example.com/old\n"
check(syncRejects(crossBlockRuntime, reversedProfile), "反序profile不能把跨块依赖变为forward alias")
check((try? ProviderDocument.synchronize(runtime: crossBlockRuntime, into: profile)) != nil, "原依赖顺序安全的跨块anchor仍可同步")
// 块标量是文本，不是 alias/anchor。含引用形状的字面量不得阻止无关订阅保存。
let scalarRuntime = """
proxy-providers:
  P: &provider {type: http, url: https://example.com/new}
proxy-groups:
  - name: G
    use: [P]
"""
let scalarProfile = """
notes: |+
  *provider
  &provider
  # literal comment

proxy-providers:
  old: {type: http, url: https://example.com/old}
proxy-groups:
  - name: old
    use: [old]
"""
let scalarSynced = try? ProviderDocument.synchronize(runtime: scalarRuntime, into: scalarProfile)
check(scalarSynced?.hasPrefix("notes: |+\n  *provider\n  &provider\n  # literal comment\n\n") == true,
      "profile块标量中的引用形状文本不误拒绝且逐字节保留")
let providerNote = "proxy-providers:\n  P:\n    type: http\n    url: https://example.com/old\n    notes: >-\n      *outside\n      &fake\n      <<: *fake\n      # text\nproxy-groups:\n  - name: G\n    use: [P]\n"
let noteUpdated = try? ProviderDocument.rewrite(providerNote, providers: [("P", "https://example.com/new")])
check(noteUpdated == providerNote.replacingOccurrences(of: "url: https://example.com/old", with: "url: \"https://example.com/new\""),
      "provider块标量内容不当结构或共享引用，URL最小更新")
let sourceNote = "proxy-providers:\n  P:\n    type: http\n    url: https://example.com/new\n    notes: |+\n      actual\n      # literal tail\n\nproxy-groups:\n  - name: G\n    use: [P]\n"
let sourceNoteSynced = try? ProviderDocument.synchronize(runtime: sourceNote, into: profile)
check(sourceNoteSynced?.contains("    notes: |+\n      actual\n      # literal tail\n\n") == true,
      "同步provider不能trim掉块标量末尾井号文本和空行")
for indicator in ["|", "|-", "|+", ">-", ">2+", "|-2"] {
    let body = "    notes: \(indicator)\n      *external\n      &provider\n      <<: *literal\n      # trailing text\n\n"
    let scalarSource = "proxy-providers:\n  P:\n    type: http\n    url: https://example.com/new\n" + body
    let syncedBody = try? ProviderDocument.synchronize(runtime: scalarSource, into: "proxy-providers: {}\nrules: []\n")
    check(syncedBody == scalarSource + "rules: []\n", "\(indicator)正文、尾注和尾空行同步逐字节保真，EOF不多插行")
}
let anchoredScalar = "proxy-providers:\n  P:\n    type: http\n    url: https://example.com/new\n    notes: &real !!str |\n      *literal\ncopy: *real\n"
check(syncRejects(scalarRuntime, anchoredScalar), "块头真实anchor仍保护profile外部alias")
let externalInProvider = providerNote.replacingOccurrences(of: "proxy-groups:", with: "    actual: *outside\nproxy-groups:")
check(syncRejects("outside: &outside literal\n" + externalInProvider, profile), "块结束后的真实外部alias不能屏蔽")
let falseHeader = "x-external: &external value\nproxy-providers:\n  P:\n    type: http\n    url: https://example.com/new\n    x-note: \"first\n  note: |\n   last\"\n    x-other: *external\n"
check(syncRejects(falseHeader, profile), "跨行引号中的伪块头不能隐藏真实外部alias")
let scalarGroup = providerNote.replacingOccurrences(of: "    use: [P]", with: "    use: [P]\n    description: |\n      first\n      \t*payload\n      - name: fake\n      # payload")
let scalarGroupSynced = try? ProviderDocument.synchronize(runtime: scalarGroup, into: profile)
check(scalarGroupSynced?.contains("      \t*payload\n      - name: fake\n      # payload") == true, "group未知块文本含tab和伪组行可同步")
check(ProviderGroupBinding.groups(in: scalarGroup).first?.canRewrite == true, "group正文tab不是YAML缩进tab")
let scalarCRLF = sourceNote.replacingOccurrences(of: "\n", with: "\r\n")
let scalarCRLFSynced = try? ProviderDocument.synchronize(runtime: scalarCRLF, into: "proxy-providers: {}\r\nproxy-groups: []\r\nrules: []\r\n")
check(scalarCRLFSynced?.contains("    notes: |+\r\n      actual\r\n      # literal tail\r\n\r\n") == true, "CRLF块标量尾部保持原样")
print("ProviderDocument: \(checks) 断言，失败 \(failures)")
exit(failures == 0 ? 0 : 1)
