// 重新激活 profile 的短路判定回归。
//
// 事故（2026-10-09 实测）：selectForApply 原用 `appliedHash == sha1(profile 内容)`
// 决定是否跳过重载。但 appliedHash 哈希的是 **profile 自身**，而设置页的
// persistent 键（geodata-mode / unified-delay / find-process-mode / log-level …）
// 是就地写进 **config.yaml** 的。于是 profile 没变、config.yaml 却漂移了，
// 短路判定仍然成立 —— 用户点「激活」看到绿色「已切换配置」，7 个键一个都没恢复。
//
// 这套钉住：漂移检测必须看得见这些差异，同时不能把 App 刻意的加固键算成漂移
// （否则每次点击都报漂移，反而失去区分能力）。
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

let profile = """
mode: rule
log-level: warning
find-process-mode: strict
unified-delay: true
geodata-mode: true
geodata-loader: memconservative
geo-auto-update: true
geodata-loader: memconservative
external-controller: '127.0.0.1:9090'
secret: EXAMPLE_SECRET_A
dns:
  enable: true
"""

print("── 无漂移：内容一致 → 应为空（短路成立，可以跳过重载） ──")
checkEq(ConfigWriteAudit.drift(before: profile, profile: profile), [],
        "完全相同 → 无漂移")

print("── 引号差异不算漂移 ──")
let requoted = profile.replacingOccurrences(of: "external-controller: '127.0.0.1:9090'",
                                            with: "external-controller: 127.0.0.1:9090")
checkEq(ConfigWriteAudit.drift(before: requoted, profile: profile), [],
        "profile 加引号、运行配置不加 → 不算漂移")

print("── 刻意加固键不计入漂移 ──")
let hardened = """
mode: rule
log-level: warning
find-process-mode: strict
unified-delay: true
geodata-mode: true
geodata-loader: memconservative
geo-auto-update: true
external-controller: 127.0.0.1:9090
secret: EXAMPLE_SECRET_B
dns:
  enable: true
"""
checkEq(ConfigWriteAudit.drift(before: hardened, profile: profile), [],
        "secret 被加固替换、external-controller 去引号 → 均不计漂移（否则每次点击都误报）")

print("── 真实漂移：设置页改过的键必须被识别 ──")
let drifted = """
mode: rule
log-level: error
find-process-mode: always
unified-delay: false
geodata-mode: false
geodata-loader: standard
geo-auto-update: false
external-controller: 127.0.0.1:9090
secret: EXAMPLE_SECRET_B
dns:
  enable: true
"""
let d = ConfigWriteAudit.drift(before: drifted, profile: profile)
checkEq(d.count, 6, "识别出 6 处真实漂移（顶层标量）（实得 \(d.count)：\(d)）")
check(d.contains("find-process-mode: always → strict"), "find-process-mode 漂移被识别")
check(d.contains("unified-delay: false → true"), "unified-delay 漂移被识别")
check(d.contains("geodata-mode: false → true"), "geodata-mode 漂移被识别")
check(d.contains("geodata-loader: standard → memconservative"), "geodata-loader 漂移被识别")
check(d.contains("log-level: error → warning"), "log-level 漂移被识别")
check(d.contains("geo-auto-update: false → true"), "geo-auto-update 漂移被识别")
check(!d.contains { $0.hasPrefix("secret") }, "secret 不计入漂移（加固是刻意的）")
check(!d.contains { $0.hasPrefix("external-controller") }, "external-controller 不计入漂移")

print("── 只有加固键不同 → 无漂移（短路仍应成立） ──")
let onlyHardened = hardened
checkEq(ConfigWriteAudit.drift(before: onlyHardened, profile: profile), [],
        "唯一差异是加固键 → 无漂移，允许短路")

print("── 单个键漂移也足以阻断短路 ──")
let oneKey = profile.replacingOccurrences(of: "log-level: warning", with: "log-level: error")
checkEq(ConfigWriteAudit.drift(before: oneKey, profile: profile).count, 1,
        "只改 log-level 一个键 → 也报 1 处漂移（短路必须被阻断）")

// 这一段是本次事故的**核心盲区**：初版 drift 只看顶层标量，嵌套块被渲染成不透明的
// "(block)"，于是 dns.enable: true → false 报 0 处漂移 —— 而这正是用户机器上真实
// 发生的差异。测试当初还因此越界崩溃（nd[0] on empty）。现在必须精确到点号键。
print("── 嵌套块内的差异必须可见（初版盲区） ──")
let nestedChanged = profile.replacingOccurrences(of: "  enable: true", with: "  enable: false")
let nd = ConfigWriteAudit.drift(before: nestedChanged, profile: profile)
checkEq(nd, ["dns.enable: false → true"], "dns.enable 变化 → 精确报到 dns.enable 键")

// 用户 profile 与运行配置的差异就是这一类：sniffer.enable 与 override-destination。
let nestedReal = """
mode: rule
log-level: warning
find-process-mode: strict
unified-delay: true
geodata-mode: true
geodata-loader: memconservative
geo-auto-update: true
external-controller: '127.0.0.1:9090'
secret: EXAMPLE_SECRET_A
dns:
  enable: true
sniffer:
  enable: false
  override-destination: false
"""
// 注意：不能把 sniffer 追加在 dns 块之后 —— 那会嵌进 dns 里（初版测试正是这样写错，
// 解析器报出 dns.override-destination 才是对的）。这里显式构造两个并列块。
let nestedProfile = """
mode: rule
log-level: warning
find-process-mode: strict
unified-delay: true
geodata-mode: true
geodata-loader: memconservative
geo-auto-update: true
external-controller: '127.0.0.1:9090'
secret: EXAMPLE_SECRET_A
dns:
  enable: true
sniffer:
  enable: true
  override-destination: true
"""
let nr = ConfigWriteAudit.drift(before: nestedReal, profile: nestedProfile)
check(nr.contains("sniffer.enable: false → true"), "sniffer.enable 漂移可见（实得 \(nr)）")
check(nr.contains("sniffer.override-destination: false → true"), "sniffer.override-destination 漂移可见")

print("── 列表变化以计数呈现，不逐项输出 ──")
let seqA = "rules:\n  - DOMAIN,a.example,DIRECT\n"
let seqB = "rules:\n  - DOMAIN,a.example,DIRECT\n  - DOMAIN,b.example,DIRECT\n"
checkEq(ConfigWriteAudit.drift(before: seqA, profile: seqB),
        ["rules: (seq: 1) → (seq: 2)"], "rules 增一项 → 报计数变化")

print("── 订阅 URL/凭据不得明文进日志 ──")
let urlA = "proxy-providers:\n  \"P\":\n    url: https://example.invalid/sub/SECRET-TOKEN\n"
let urlB = "proxy-providers:\n  \"P\":\n    url: https://example.invalid/sub/SECRET-TOKEN\n    path: ./providers/P.yaml\n"
let urlDrift = ConfigWriteAudit.drift(before: urlA, profile: urlB)
check(!urlDrift.contains { $0.contains("SECRET-TOKEN") },
      "订阅令牌不出现于漂移记录（实得 \(urlDrift)）")
check(urlDrift.contains { $0.contains("path:") && $0.contains("<#") },
      "path 以指纹呈现（实得 \(urlDrift)）")
// 同一 URL 必须指纹相同，否则「URL 没变」会被误读成「URL 换了」。
// 键已归一为裸形（proxy-providers.P.url），带引号的键不再单独成键。
let sameUrl = ConfigWriteAudit.drift(
    before: "proxy-providers:\n  \"P\":\n    url: https://example.invalid/sub/SECRET-TOKEN\n    interval: 60\n",
    profile: "proxy-providers:\n  \"P\":\n    url: https://example.invalid/sub/SECRET-TOKEN\n    interval: 120\n")
check(!sameUrl.contains { $0.hasPrefix("proxy-providers.P.url") },
      "URL 未变 → 不产生记录（同一值指纹相同，实得 \(sameUrl)）")

print("── 带引号的 provider 键与裸键归一 ──")
let requotedProvider = "proxy-providers:\n  \"P\":\n    url: https://example.invalid/sub/SECRET-TOKEN\n    interval: 60\n"
let bareProvider = "proxy-providers:\n  P:\n    url: https://example.invalid/sub/SECRET-TOKEN\n    interval: 60\n"
checkEq(ConfigWriteAudit.drift(before: bareProvider, profile: requotedProvider), [],
        "provider 键带引号与不带引号 → 同一键、同值指纹 → 无漂移")
let urlChanged = "proxy-providers:\n  P:\n    url: https://example.invalid/sub/OTHER-TOKEN\n    interval: 60\n"
let urlDriftLine = ConfigWriteAudit.drift(before: requotedProvider, profile: urlChanged)
check(urlDriftLine.contains { $0.hasPrefix("proxy-providers.P.url") && $0.contains("<#") },
      "URL 变化归一记在 proxy-providers.P.url 下，值以指纹呈现（实得 \(urlDriftLine)）")
check(!urlDriftLine.contains { $0.contains("SECRET-TOKEN") || $0.contains("OTHER-TOKEN") },
      "URL 明文不进漂移记录")

print("── 空输入不崩 ──")
checkEq(ConfigWriteAudit.drift(before: "", profile: ""), [], "两侧都空 → 无漂移")
checkEq(ConfigWriteAudit.drift(before: "", profile: profile).isEmpty, false,
        "运行配置为空（首次安装）→ 视为有漂移，不会误短路")

print("")
if failed == 0 {
    print("applydrift-tests   PASS     \(total) 断言")
} else {
    print("applydrift-tests   FAIL     \(failed)/\(total) 断言失败")
    exit(1)
}
