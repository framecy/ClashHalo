// Tailscale 子网路由修复的判定回归。
// 2026-11-27 现场：对端 A 广播 10.20.0.0/24、对端 B 广播 192.168.30.0/24，本机
// `--accept-routes` 为 false，对端路由从未进入路由表，流量走物理网卡。
// 本套件钉住两件事：① 「问不到」不能被当成「关着」，否则按钮会引导用户去开
// 一个可能已经开着的开关；② 已开启但仍缺路由时只能等重连，不能再点一次。
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

func data(_ s: String) -> Data { Data(s.utf8) }

print("── 1. `tailscale debug prefs` 的 RouteAll 解析 ──")
do {
    // 真实输出形态（1.104.7）：一个扁平 JSON 对象，RouteAll 是布尔。
    let on = data(#"{"RouteAll": true, "ExitNodeID": "", "WantRunning": true}"#)
    let off = data(#"{"RouteAll": false}"#)
    checkEq(TailscaleSubnetRouting.acceptsRoutes(inPrefsJSON: on), true, "RouteAll=true → true")
    checkEq(TailscaleSubnetRouting.acceptsRoutes(inPrefsJSON: off), false, "RouteAll=false → false")

    // 「问不到」必须与 false 分开：缺字段、类型不对、非 JSON 都是 nil。
    checkEq(TailscaleSubnetRouting.acceptsRoutes(inPrefsJSON: data(#"{"ExitNodeID": ""}"#)),
            nil, "字段缺失 → nil（不是 false）")
    checkEq(TailscaleSubnetRouting.acceptsRoutes(inPrefsJSON: data(#"{"RouteAll": "false"}"#)),
            nil, "RouteAll 非布尔 → nil")
    checkEq(TailscaleSubnetRouting.acceptsRoutes(inPrefsJSON: data("not json at all")),
            nil, "非 JSON → nil")
    checkEq(TailscaleSubnetRouting.acceptsRoutes(inPrefsJSON: data("")),
            nil, "空输出 → nil")
    checkEq(TailscaleSubnetRouting.acceptsRoutes(inPrefsJSON: data("[]")),
            nil, "顶层数组而非对象 → nil")
}

print("── 2. 动作分派 ──")
do {
    checkEq(TailscaleSubnetRouting.action(acceptsRoutes: false, gaps: 2), .acceptRoutes,
            "未接受 + 2 个缺口 → 可一键修复")
    checkEq(TailscaleSubnetRouting.action(acceptsRoutes: false, gaps: 1), .acceptRoutes,
            "未接受 + 1 个缺口 → 可一键修复")
    checkEq(TailscaleSubnetRouting.action(acceptsRoutes: true, gaps: 2), .waitForRebroadcast,
            "已接受但仍有缺口 → 只能等重连")
    checkEq(TailscaleSubnetRouting.action(acceptsRoutes: nil, gaps: 2), .unavailable,
            "问不到 prefs → 不提供修复")
}

print("── 3. 没有缺口时不提供任何动作 ──")
do {
    // gaps == 0 优先于 prefs 取值：面板上没有要修的东西，按钮不得出现。
    checkEq(TailscaleSubnetRouting.action(acceptsRoutes: false, gaps: 0), .unavailable,
            "无缺口 + 未接受 → unavailable")
    checkEq(TailscaleSubnetRouting.action(acceptsRoutes: true, gaps: 0), .unavailable,
            "无缺口 + 已接受 → unavailable")
    checkEq(TailscaleSubnetRouting.action(acceptsRoutes: nil, gaps: 0), .unavailable,
            "无缺口 + 问不到 → unavailable")
}

print("")
if failed == 0 {
    print("PASS  \(total) checks")
    exit(0)
} else {
    print("FAIL  \(failed)/\(total) checks")
    exit(1)
}
