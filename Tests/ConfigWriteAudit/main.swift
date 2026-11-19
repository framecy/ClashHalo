// config.yaml 写入审计回归。
//
// 动机：config.yaml 被 11 个调用点就地改写，其中设置页的几个 persistent 键
// （geodata-mode / unified-delay / find-process-mode / disable-keep-alive…）
// 会**压过已激活的 profile**。此前没有任何记录，排查只能靠比对 config.yaml.bak-*
// 快照，而且连"是哪个键、什么时候、被谁改的"都答不出来。
//
// 这套钉三件事：
//   1. 顶层标量解析（缩进、注释行、行内 #、块键）与 readConfigFile 口径一致；
//   2. 差异计算是纯函数且正确，含「新增」「删除」「未变不产出」三种情形；
//   3. secret 之类凭据绝不以明文进日志，但必须留下"它变了"的痕迹。
import Foundation

var failed = 0
var total = 0
func check(_ cond: Bool, _ name: String) {
    total += 1
    print(cond ? "  ✓ \(name)" : "  ✗ FAIL: \(name)")
    if !cond { failed += 1 }
}
func checkEq<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    total += 1
    if got == want {
        print("  ✓ \(name)")
    } else {
        print("  ✗ FAIL: \(name) — got \(got), want \(want)")
        failed += 1
    }
}

print("── topLevelScalars：与 readConfigFile 同口径 ──")

let sample = """
# 顶部 banner 注释
disable-keep-alive: false
geodata-loader: standard
mode: rule
log-level: error        # 行内注释要被剥掉
dns:
  enable: false
  size: 1500
sniffer:
  enable: false
proxies: []
"""

let parsed = ConfigWriteAudit.topLevelScalars(in: sample)
checkEq(parsed["disable-keep-alive"], "false", "顶层 bool 被解析")
checkEq(parsed["geodata-loader"], "standard", "顶层字符串被解析")
checkEq(parsed["log-level"], "error", "行内 # 注释被剥离（不是 'error        # 行内注释要被剥掉'）")
checkEq(parsed["dns"], "(block)", "嵌套块以父键 + (block) 表示")
checkEq(parsed["sniffer"], "(block)", "第二个嵌套块同样表示")
checkEq(parsed["proxies"], "[]", "空数组值是 '[]' 而非空")
checkEq(parsed["# 顶部 banner 注释"], nil, "注释行不产出键")
checkEq(parsed["enable"], nil, "缩进的子键不产出顶层键（dns.enable 不会变成顶层 enable）")
checkEq(parsed["size"], nil, "缩进的子键不产出顶层键（dns.size 同理）")

print("── changes：新增 / 修改 / 未变 ──")

let old: [String: String] = [
    "geodata-mode": "true",
    "unified-delay": "true",
    "find-process-mode": "strict",
    "mode": "rule",
]
let new: [String: String] = [
    "geodata-mode": "false",
    "unified-delay": "true",          // 未变
    "find-process-mode": "always",
    "mode": "rule",                   // 未变
    "log-level": "error",             // 新增
]
let changes = ConfigWriteAudit.changes(from: old, to: new)
checkEq(changes.count, 3, "只有 3 个键真正变化（2 个未变的不产出）")
check(changes.contains("geodata-mode: true → false"), "true → false 被正确记录")
check(changes.contains("find-process-mode: strict → always"), "严格 → 总是 被正确记录")
check(changes.contains("log-level: (absent) → error"), "新增键显示 (absent) → 新值")
check(!changes.contains { $0.hasPrefix("unified-delay") }, "未变的 unified-delay 不产出记录")
check(!changes.contains { $0.hasPrefix("mode") }, "未变的 mode 不产出记录")

print("── changes：删除键 ──")
let removed = ConfigWriteAudit.changes(from: ["geodata-loader": "memconservative"], to: [:])
checkEq(removed, ["geodata-loader: memconservative → (absent)"], "删除键显示 旧值 → (absent)")

print("── changes：无变化 ──")
checkEq(ConfigWriteAudit.changes(from: old, to: old), [], "完全相同的两版 → 空数组（调用方渲染 (no changes)）")

print("── 凭据：永不明文，但轮换必须留痕（CFG-16） ──")

// 旧版把 secret 渲染成常量 <redacted> 且 changes() 整条丢弃——轮换控制面密钥
// 后日志零留痕，排查 401 无据可查。现在渲染成稳定指纹对：值本体不进日志，
// 「换过了」一眼可见，且同值指纹相同（未变 ≠ 轮换）。
let secretChanges = ConfigWriteAudit.changes(
    from: ["secret": "synthetic-secret-not-a-real-key-01"],
    to: ["secret": "1234qwer"])
checkEq(secretChanges.count, 1, "secret 变化产出一条记录（轮换留痕）")
check(secretChanges.first?.hasPrefix("secret: <#") == true && secretChanges.first?.contains(" → <#") == true,
      "secret 记录以指纹对呈现（实得 \(secretChanges.first ?? "nil")）")
check(!secretChanges.contains { $0.contains("synthetic-secret-not-a-real-key-01") || $0.contains("1234qwer") },
      "secret 明文不进日志")

checkEq(ConfigWriteAudit.changes(from: ["secret": "s"], to: ["secret": "s"]), [],
        "secret 未变不产出记录（同值指纹相同）")

let authChanges = ConfigWriteAudit.changes(from: ["authentication": "a:b"], to: ["authentication": "c:d"])
checkEq(authChanges.count, 1, "authentication 变化同样留痕")
check(authChanges.first?.hasPrefix("authentication: <#") == true,
      "authentication 以指纹呈现，不泄键值对（实得 \(authChanges.first ?? "nil")）")

// 但绝不能有任何路径把明文泄进日志
let fp = ConfigWriteAudit.redactedValue(for: "secret", "1234qwer")
check(fp.hasPrefix("<#") && fp.hasSuffix(">") && fp.count == 19,
      "redactedValue 返回全宽指纹 <#%016llx> 形态（实得 \(fp)）")
check(fp != ConfigWriteAudit.redactedValue(for: "secret", "另一个值"), "不同值指纹不同（轮换可辨）")
check(ConfigWriteAudit.redactedValue(for: "SECRET", "x") == ConfigWriteAudit.redactedValue(for: "secret", "x"),
      "大写 SECRET 同样脱敏（键大小写无关）")
check(ConfigWriteAudit.redactedValue(for: "mode", "rule") == "rule",
      "非凭据键不脱敏")

// 非凭据键必须仍然明文，否则日志失去价值
let plain = ConfigWriteAudit.changes(from: ["secret": "a"], to: ["secret": "b", "mode": "rule"])
check(plain.contains("mode: (absent) → rule"), "同一次写入里的非凭据键仍被记录（日志保有诊断价值）")

print("── 引号归一：profile 加引号不得算作变化 ──")

let quoteDiff = ConfigWriteAudit.changes(
    from: ["external-controller": "127.0.0.1:9090"],
    to: ["external-controller": "'127.0.0.1:9090'"])
checkEq(quoteDiff, [], "单引号包裹的同值不算变化（实测 profile 就是这种写法）")

let dqDiff = ConfigWriteAudit.changes(from: ["x": "abc"], to: ["x": "\"abc\""])
checkEq(dqDiff, [], "双引号包裹的同值不算变化")

let realDiff = ConfigWriteAudit.changes(from: ["x": "abc"], to: ["x": "'abd'"])
checkEq(realDiff, ["x: abc → 'abd'"], "引号内确有变化时仍然记录")

print("── 带引号的键与裸键归一（flattenedScalars） ──")
let quotedKeyA = "proxy-providers:\n  \"US-LH\":\n    path: ./a.yaml\n"
let bareKeyA = "proxy-providers:\n  US-LH:\n    path: ./a.yaml\n"
checkEq(ConfigWriteAudit.drift(before: quotedKeyA, profile: bareKeyA), [],
        "键的引号写法差异不是漂移（同一 provider，旧版会报幻影漂移）")
let quotedKeys = ConfigWriteAudit.flattenedScalars(in: quotedKeyA)
check(quotedKeys["proxy-providers.US-LH.path"] != nil,
      "带引号键入 path 后无引号（实得 \(quotedKeys.keys.sorted())）")
let colonKey = ConfigWriteAudit.flattenedScalars(in: "\"a:b\":\n  x: 1\n")
check(colonKey["a:b"] == "(block)" && colonKey["a:b.x"] == "1",
      "quoted key 内含冒号不截断成脏键，子键正确挂靠（实得 \(colonKey)）")
check(!colonKey.keys.contains { $0.contains("\"") }, "路径里不再残留引号字符")

print("── 订阅模板：scalar alias / flow 前缀不可泄露源凭据 ──")
let subscriptionURL = "https://example.com/sub?token=EXAMPLE_AUDIT_MARKER"
let scalarTemplate = """
source: &source \(subscriptionURL)
proxy-providers:
  A:
    type: http
    url: *source
mode: rule
"""
let scalarTemplateChanges = ConfigWriteAudit.changes(
    from: [:], to: ConfigWriteAudit.flattenedScalars(in: scalarTemplate))
check(!scalarTemplateChanges.joined().contains("EXAMPLE_AUDIT_MARKER"),
      "scalar anchor 的订阅源不以明文进入 changes")
check(scalarTemplateChanges.contains("source: (absent) → \(ConfigWriteAudit.fingerprint(subscriptionURL))"),
      "相同订阅 URL 在模板源和直接 url 字段使用相同指纹")
check(scalarTemplateChanges.contains("mode: (absent) → rule"), "同文档普通设置仍可读")

let flowTemplates = [
    "&d {type: http, url: \(subscriptionURL)}",
    "!!map &d {type: http, 'url' : '\(subscriptionURL)'}",
    "&d !!map {type: http, \"url\" : \"\(subscriptionURL)\"}",
    "!<tag:yaml.org,2002:map> &d {type: http, url: \(subscriptionURL)}",
    "&d [{type: http, url: \(subscriptionURL)}]",
]
for (index, template) in flowTemplates.enumerated() {
    let document = "defaults: \(template)\nproxy-providers:\n  A: *d\n"
    let logged = ConfigWriteAudit.changes(from: [:], to: ConfigWriteAudit.flattenedScalars(in: document))
    check(!logged.joined().contains("EXAMPLE_AUDIT_MARKER"), "flow anchor/tag 前缀组合 \(index) 不泄露 URL")
    check(logged.contains { $0.hasPrefix("defaults: (absent) → <#") }, "flow 模板 \(index) 保留可比较指纹")
}

let opaqueAlias = """
source: &source EXAMPLE_OPAQUE_CREDENTIAL
label: &label readable
proxy-providers:
  A:
    url: *source
    type: http
mode: *label
"""
let opaqueChanges = ConfigWriteAudit.changes(from: [:], to: ConfigWriteAudit.flattenedScalars(in: opaqueAlias))
check(!opaqueChanges.joined().contains("EXAMPLE_OPAQUE_CREDENTIAL"), "敏感 url alias 反向保护非 URL 形状源值")
check(opaqueChanges.contains("label: (absent) → &label readable"), "未被凭据引用的普通 anchor 不被整片抹光")
let flowAlias = "source: &source EXAMPLE_FLOW_CREDENTIAL\nproxy-providers: {A: {url: *source}}\n"
check(!ConfigWriteAudit.changes(from: [:], to: ConfigWriteAudit.flattenedScalars(in: flowAlias))
    .joined().contains("EXAMPLE_FLOW_CREDENTIAL"), "flow url alias 也反向保护 scalar 源")

let anchoredBlock = """
defaults: &d
  type: http
  url: \(subscriptionURL)
  interval: 3600
proxy-providers:
  A:
    <<: *d
mode: rule
"""
let anchoredFields = ConfigWriteAudit.flattenedScalars(in: anchoredBlock)
checkEq(anchoredFields["defaults.interval"], "3600", "只有 anchor 的块头仍建立正确父路径")
let anchoredDrift = ConfigWriteAudit.drift(before: anchoredBlock,
    profile: anchoredBlock.replacingOccurrences(of: "interval: 3600", with: "interval: 7200"))
check(anchoredDrift.contains("defaults.interval: 3600 → 7200"), "模板中普通间隔漂移保留明文定位")
let rotatedTemplate = scalarTemplate.replacingOccurrences(of: "EXAMPLE_AUDIT_MARKER", with: "EXAMPLE_ROTATED_MARKER")
let templateDrift = ConfigWriteAudit.drift(before: scalarTemplate, profile: rotatedTemplate)
check(templateDrift.contains { $0.hasPrefix("source: <#") && $0.contains(" → <#") }, "alias 源凭据轮换仍留下指纹对漂移")
check(!templateDrift.joined().contains("EXAMPLE_"), "轮换前后凭据均不泄露")
checkEq(ConfigWriteAudit.drift(before: scalarTemplate, profile: scalarTemplate), [], "未变 alias 文档不产生漂移")
checkEq(ConfigWriteAudit.render("&source \"\(subscriptionURL)\"", forKey: "source"),
        ConfigWriteAudit.render(subscriptionURL, forKey: "proxy-providers.A.url"), "引号和 anchor 装饰不改变凭据指纹")
checkEq(ConfigWriteAudit.render("&d {interval: 3600, lazy: true}", forKey: "defaults"),
        "&d {interval: 3600, lazy: true}", "无凭据 flow 模板仍可读")
check(ConfigWriteAudit.render("&d {\"password\" : EXAMPLE_PASSWORD}", forKey: "defaults").hasPrefix("<#"),
      "非 URL 凭据字段允许引号和冒号前空格")

let removedAlias = ConfigWriteAudit.changes(
    from: ConfigWriteAudit.flattenedScalars(in: opaqueAlias),
    to: ["source": "EXAMPLE_REPLACEMENT_CREDENTIAL"])
check(!removedAlias.joined().contains("EXAMPLE_"), "删除引用并替换源值时，两版源值都脱敏")
let selectiveFlow = """
source: &source EXAMPLE_SELECTIVE_CREDENTIAL
seconds: &seconds 3600
proxy-providers: {A: {url: *source, interval: *seconds}}
"""
let selectiveChanges = ConfigWriteAudit.changes(from: [:], to: ConfigWriteAudit.flattenedScalars(in: selectiveFlow))
check(!selectiveChanges.joined().contains("EXAMPLE_SELECTIVE_CREDENTIAL"), "flow 凭据 alias 源脱敏")
check(selectiveChanges.contains("seconds: (absent) → &seconds 3600"), "flow 中非凭据 alias 不被传播污染")
let quotedAlias = "label: &label readable\nproxy-providers: {A: {url: '*label'}}\n"
check(ConfigWriteAudit.changes(from: [:], to: ConfigWriteAudit.flattenedScalars(in: quotedAlias))
    .contains("label: (absent) → &label readable"), "被引号包住的 alias 只是字面量，不污染无关 anchor")
let quotedBlockAlias = "label: &label readable\nproxy-providers:\n  A:\n    url: '*label'\n"
check(ConfigWriteAudit.changes(from: [:], to: ConfigWriteAudit.flattenedScalars(in: quotedBlockAlias))
    .contains("label: (absent) → &label readable"), "block 字段带引号 alias 也不污染普通源值")
let flowQuotedDescription = "&d {description: 'url: example', interval: 3600}"
checkEq(ConfigWriteAudit.render(flowQuotedDescription, forKey: "defaults"), flowQuotedDescription,
        "说明文本中的 url: 不是凭据字段")
for field in ["url", "path", "password", "uuid", "auth-key", "secret", "authentication", "private-key", "token"] {
    check(ConfigWriteAudit.render("&d {'\(field)' : EXAMPLE_FIELD_CREDENTIAL}", forKey: "defaults").hasPrefix("<#"),
          "flow 凭据字段 \(field) 统一脱敏")
}
let multiFlow = """
defaults: &d {
  type: http,
  url: \(subscriptionURL),
  interval: 3600
}
proxy-providers:
  A: *d
"""
check(!ConfigWriteAudit.changes(from: [:], to: ConfigWriteAudit.flattenedScalars(in: multiFlow))
    .joined().contains("EXAMPLE_AUDIT_MARKER"), "多行 flow 模板凭据不泄露")
let blockScalarAlias = """
source: &source >-
  https://example.com/sub?token=EXAMPLE_BLOCK_MARKER
proxy-providers:
  A:
    url: *source
"""
check(!ConfigWriteAudit.changes(from: [:], to: ConfigWriteAudit.flattenedScalars(in: blockScalarAlias))
    .joined().contains("EXAMPLE_BLOCK_MARKER"), "块标量订阅源不被伪装成顶层键泄露")
let nextLineAlias = """
source: &source
  https://example.com/sub?token=EXAMPLE_NEXT_LINE_MARKER
proxy-providers:
  A:
    url: *source
"""
check(!ConfigWriteAudit.changes(from: [:], to: ConfigWriteAudit.flattenedScalars(in: nextLineAlias))
    .joined().contains("EXAMPLE_NEXT_LINE_MARKER"), "下一行的 anchor scalar 内容不被拆成脏键")

print("── 多行值不能破坏「一行一记录」 ──")
let multiline = ConfigWriteAudit.changes(from: [:], to: ["payload": "line1\nline2"])
checkEq(multiline.count, 1, "含换行的值仍只产出 1 条记录")
check(!multiline[0].contains("\n"), "记录内不含裸换行（可用 grep 逐行检索）")

print("── 超长值截断（避免单条记录吞掉整个日志） ──")
let long = String(repeating: "x", count: 500)
let truncated = ConfigWriteAudit.changes(from: [:], to: ["big": long])
check(truncated[0].contains("…"), "超长值被截断并标记省略号")
check(truncated[0].count < 200, "记录长度受控（实得 \(truncated[0].count) 字符）")

print("── 事故复盘：真实 8 处差异能被正确复现 ──")
// 用本次排查中实测到的 profile 与运行 config.yaml 的顶层键，验证审计能报出全部差异
let profileKeys: [String: String] = [
    "external-controller": "127.0.0.1:9090",
    "find-process-mode": "strict",
    "geo-auto-update": "true",
    "geodata-loader": "memconservative",
    "geodata-mode": "true",
    "log-level": "warning",
    "secret": "synthetic-secret-not-a-real-key-01",
    "unified-delay": "true",
]
let runningKeys: [String: String] = [
    "external-controller": "'127.0.0.1:9090'",  // 相同值，但 profile 带引号
    "find-process-mode": "always",
    "geo-auto-update": "false",
    "geodata-loader": "standard",
    "geodata-mode": "false",
    "log-level": "error",
    "secret": "1234qwer",
    "unified-delay": "false",
]
let replay = ConfigWriteAudit.changes(from: profileKeys, to: runningKeys)
checkEq(replay.count, 7, "复现出 7 处差异（6 处明文漂移 + secret 轮换留痕；external-controller 同值不产出）")
check(!replay.contains { $0.hasPrefix("external-controller") }, "未变的 external-controller 不产出")
check(replay.contains("find-process-mode: strict → always"), "find-process-mode 漂移被捕获")
check(replay.contains("unified-delay: true → false"), "unified-delay 漂移被捕获")
check(replay.contains("geodata-loader: memconservative → standard"), "geodata-loader 漂移被捕获")
check(replay.contains("log-level: warning → error"), "log-level 漂移被捕获")
check(replay.contains { $0.hasPrefix("secret: <#") }, "secret 轮换以指纹对留痕（CFG-16）")
check(!replay.contains { $0.contains("synthetic-secret-not-a-real-key-01") || $0.contains("1234qwer") },
      "secret 明文不进日志")

print("── 路径与上限 ──")
check(ConfigWriteAudit.auditPath().hasSuffix("/Library/Logs/ClashHalo/config-writes.log"),
      "审计日志路径固定为 ~/Library/Logs/ClashHalo/config-writes.log")
check(ConfigWriteAudit.maxBytes == 4 * 1024 * 1024, "轮转上限 4 MB")

print("")
if failed == 0 {
    print("configwriteaudit-tests   PASS     \(total) 断言")
} else {
    print("configwriteaudit-tests   FAIL     \(failed)/\(total) 断言失败")
    exit(1)
}
