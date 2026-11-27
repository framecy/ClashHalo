// 内核布尔缺省表 + 「写了就用写的」判定的纯逻辑回归。
//
// 2026-11-27 现场：config.yaml 里只写了
// `sniffer: { enable: true, parse-pure-ip: true, override-destination: true }`
// （没有 force-dns-mapping），界面却把四项里的三项显示成「关」，而内核缺省是开。
// 用户点一次开关写入 true，行为没有任何变化，看起来像开关失灵。
//
// 同一天把口径推广到全部界面布尔开关：mihomo 的缺省值来自 `DefaultRawConfig()`
// 预置结构体 + YAML 逐键覆盖，所以「没写」不等于 false——`ipv6` 缺省真、`tun.auto-route`
// 缺省真、`dns.ipv6` 缺省假（这一条推翻了「dns 缺省为开」的猜测，必须钉住，否则
// 下一个人会照着错的口径去「修」）。
//
// 2026-11-27 第二轮（`tun.stack`）：枚举型键有同一个坑，而且后果更重。内核
// `DefaultRawConfig()` 写的是 `Stack: C.TunMips`（config.go:550，String() == "Mips"，
// `StackTypeMapping` 认 gvisor/system/mixed/mips），界面 `NPicker` 却在缺键时回落
// **第一个选项** gVisor：用户以为在跑 gVisor，实际是 Mips；他为了「确认一下」选一次
// 其他值，就等于在一次无关操作里换掉了数据面。
//
// 钉住的边界：
// ① 16 条布尔缺省值逐条核对（写反就是反向说谎），枚举缺省值单独一段；
// ② `isKnown` 只认已登记的完整路径——顶层 `auto-route` 不是 `tun.auto-route`；
// ③ 未登记的键回落 false（显示成「关」而不是「开」，且预检会挡住漏登记）；
// ④ 显式 false 不得被缺省值盖掉（用户真的关掉过）；
// ⑤ 块整个不存在、键缺失、值类型不是 Bool 时都退回缺省——这是「看不懂就用内核语义」，
//    不能因为解析失败把开关翻到反方向。
import Foundation

var total = 0
var failed = 0

func check(_ cond: Bool, _ name: String) {
    total += 1
    if cond {
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(name)")
    }
}

func checkEq<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    total += 1
    if got == want {
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(name) — got \(got), want \(want)")
    }
}

func def(_ parent: String, _ key: String) -> Bool {
    KernelDefaults.bool(parent: parent, key: key)
}

print("── 1. 登记表本身 ──")
checkEq(KernelDefaults.bools.count, 16, "16 条缺省值，一条不多一条不少")

print("── 2. 顶层缺省（RawConfig）──")
check(def("", "ipv6"), "ipv6 缺省 true（这条最容易写反）")
check(!def("", "allow-lan"), "allow-lan 缺省 false")
check(!def("", "geodata-mode"), "geodata-mode 缺省 false（geodata.GeodataMode() 的 geoMode 零值）")
check(!def("", "geo-auto-update"), "geo-auto-update 缺省 false")
check(!def("", "tcp-concurrent"), "tcp-concurrent 缺省 false")
check(!def("", "unified-delay"), "unified-delay 缺省 false")
check(!def("", "disable-keep-alive"), "disable-keep-alive 缺省 false")
check(!def("", "inbound-mptcp"), "inbound-mptcp 缺省 false")

print("── 3. tun / dns 缺省 ──")
check(def("tun", "auto-route"), "tun.auto-route 缺省 true（与 tunPatchBody 的 ?? true 一致）")
check(def("tun", "auto-detect-interface"), "tun.auto-detect-interface 缺省 true")
check(!def("dns", "enable"), "dns.enable 缺省 false")
check(!def("dns", "ipv6"), "dns.ipv6 缺省 false（不是「dns 缺省为开」）")

print("── 4. sniffer 缺省：只有 enable 是关 ──")
check(!def("sniffer", "enable"), "sniffer.enable 缺省 false")
check(def("sniffer", "override-destination"), "sniffer.override-destination 缺省 true")
check(def("sniffer", "force-dns-mapping"), "sniffer.force-dns-mapping 缺省 true")
check(def("sniffer", "parse-pure-ip"), "sniffer.parse-pure-ip 缺省 true")

print("── 5. 路径拼接与登记查询 ──")
checkEq(KernelDefaults.path("", "ipv6"), "ipv6", "顶层路径不带点")
checkEq(KernelDefaults.path("tun", "auto-route"), "tun.auto-route", "嵌套路径用点")
check(KernelDefaults.isKnownBool(parent: "", key: "ipv6"), "已登记：顶层 ipv6")
check(KernelDefaults.isKnownBool(parent: "tun", key: "auto-route"), "已登记：tun.auto-route")
check(KernelDefaults.isKnownBool(parent: "dns", key: "ipv6"), "已登记：dns.ipv6")
check(!KernelDefaults.isKnownBool(parent: "", key: "auto-route"), "顶层 auto-route 不算登记过")
check(!KernelDefaults.isKnownBool(parent: "tun", key: "auto-routes"), "近似拼写不算登记过")
check(!KernelDefaults.isKnownBool(parent: "", key: "nope"), "没登记的键查不到")

print("── 5b. 枚举型缺省（tun.stack）──")
checkEq(KernelDefaults.string(parent: "tun", key: "stack"), "Mips",
        "tun.stack 缺省 Mips（不是第一个选项 gVisor）")
check(KernelDefaults.isKnownString(parent: "tun", key: "stack"), "已登记：tun.stack")
check(!KernelDefaults.isKnownString(parent: "tun", key: "auto-route"),
      "布尔键不算枚举键登记过（两本表互不冒充）")
check(KernelDefaults.string(parent: "tun", key: "auto-route") == nil,
      "问枚举缺省拿到 nil，而不是一个看起来合法的空串")
check(KernelDefaults.string(parent: "", key: "stack") == nil, "顶层 stack 不冒充 tun.stack")
checkEq(KernelDefaults.string(parent: "dns", key: "enhanced-mode"), "redir-host",
        "dns.enhanced-mode 缺省 redir-host（不是选项里的第一个 fake-ip）")
checkEq(KernelDefaults.string(parent: "", key: "find-process-mode"), "strict",
        "find-process-mode 缺省 strict（不是选项里的第一个 always）")
checkEq(KernelDefaults.string(parent: "", key: "geodata-loader"), "memconservative",
        "geodata-loader 缺省 memconservative")
checkEq(KernelDefaults.string(parent: "", key: "log-level"), "info", "log-level 缺省 info")
checkEq(KernelDefaults.strings.count, 5, "枚举表 5 条（tun.stack + dns.enhanced-mode + 三个 PickerRow）")

print("── 6. 显式值优先 ──")
let needOn: [String: Any] = ["enable": true]
check(NestedBoolSetting.effectiveValue(in: needOn, key: "enable", defaultValue: def("sniffer", "enable")),
      "显式 true 原样返回")
let forceOff: [String: Any] = ["force-dns-mapping": false]
check(!NestedBoolSetting.effectiveValue(in: forceOff, key: "force-dns-mapping",
                                       defaultValue: def("sniffer", "force-dns-mapping")),
      "显式 false 不被缺省 true 盖掉")
let empty: [String: Any] = [:]
check(NestedBoolSetting.effectiveValue(in: empty, key: "parse-pure-ip",
                                      defaultValue: def("sniffer", "parse-pure-ip")),
      "键缺失时走缺省（parse-pure-ip 缺省开）")
check(NestedBoolSetting.effectiveValue(in: nil, key: "parse-pure-ip",
                                       defaultValue: def("sniffer", "parse-pure-ip")),
      "整个块不存在时走缺省")
check(NestedBoolSetting.effectiveValue(in: nil, key: "ipv6", defaultValue: def("", "ipv6")),
      "块不存在 + 顶层缺省 true 仍显示开")

print("── 7. 值类型不对时退回缺省 ──")
let stringy: [String: Any] = ["parse-pure-ip": "true", "override-destination": 1]
check(NestedBoolSetting.effectiveValue(in: stringy, key: "parse-pure-ip",
                                       defaultValue: def("sniffer", "parse-pure-ip")),
      "字符串 \"true\" 不被当成 true，退回缺省（此处缺省也是 true）")
check(NestedBoolSetting.effectiveValue(in: stringy, key: "override-destination",
                                       defaultValue: def("sniffer", "override-destination")),
      "数字 1 不被当成 true，退回缺省")

print("── 8. 最小配置的快照（真实订阅形态）──")
let minimalSniffer: [String: Any] = ["enable": true]
check(NestedBoolSetting.effectiveValue(in: minimalSniffer, key: "enable",
                                       defaultValue: def("sniffer", "enable")),
      "最小配置：enable 显示开")
check(NestedBoolSetting.effectiveValue(in: minimalSniffer, key: "override-destination",
                                       defaultValue: def("sniffer", "override-destination")),
      "最小配置：override-destination 显示开（不再是假象的「关」）")
check(NestedBoolSetting.effectiveValue(in: minimalSniffer, key: "force-dns-mapping",
                                       defaultValue: def("sniffer", "force-dns-mapping")),
      "最小配置：force-dns-mapping 显示开")
check(NestedBoolSetting.effectiveValue(in: minimalSniffer, key: "parse-pure-ip",
                                       defaultValue: def("sniffer", "parse-pure-ip")),
      "最小配置：parse-pure-ip 显示开")

print("")
if failed == 0 {
    print("通过：\(total) 项")
    exit(0)
} else {
    print("失败：\(failed)/\(total) 项")
    exit(1)
}
