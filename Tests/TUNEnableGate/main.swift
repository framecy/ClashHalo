// 「重复开启 TUN」闸门的纯逻辑回归。
//
// 2026-11-27 现场：09:06:03 TUN 开启成功，09:06:24（+21s）一条 NWPathMonitor
// 路径变化事件在 10s settle 窗之外又整条重建了隧道（丢弃全部在途连接）。闸门的
// 作用是：隧道已按目标态工作、且刚通过真实公网验收时，不再重建。
//
// 钉住的关键边界（写错任何一条都是「让 TUN 起不来」或「让风暴继续」）：
// ① 关闭请求永不拦；② tunOn=false 永不拦（内核重启/自愈正是要重建）；
// ③ 没有验收时间戳不拦；④ 窗口外的请求不拦；⑤ 窗口<=0 视为关闸。
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

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
let window: TimeInterval = 60

print("── 1. 真正的重复开启必须被拦下 ──")
do {
    check(TUNEnableGate.shouldSkipDuplicateEnable(
        want: true, tunOn: true, acceptedAt: at(0), now: at(21), window: window),
          "开启后 21s 的路径变化事件 → 拦（现场复现的那一拍）")
    check(TUNEnableGate.shouldSkipDuplicateEnable(
        want: true, tunOn: true, acceptedAt: at(0), now: at(0), window: window),
          "同一刻重复请求 → 拦")
    check(TUNEnableGate.shouldSkipDuplicateEnable(
        want: true, tunOn: true, acceptedAt: at(0), now: at(59.9), window: window),
          "窗口边缘 59.9s → 拦")
}

print("── 2. 窗口之外放行 ──")
do {
    check(!TUNEnableGate.shouldSkipDuplicateEnable(
        want: true, tunOn: true, acceptedAt: at(0), now: at(60), window: window),
          "整 60s → 放行（窗口是半开区间）")
    check(!TUNEnableGate.shouldSkipDuplicateEnable(
        want: true, tunOn: true, acceptedAt: at(0), now: at(600), window: window),
          "10 分钟后 → 放行")
}

print("── 3. 关闭请求永不拦 ──")
do {
    check(!TUNEnableGate.shouldSkipDuplicateEnable(
        want: false, tunOn: true, acceptedAt: at(0), now: at(1), window: window),
          "想关就让它关，哪怕刚验收过")
}

print("── 4. tunOn 为假时永不拦（内核重启 / 自愈 / 关后再开） ──")
do {
    check(!TUNEnableGate.shouldSkipDuplicateEnable(
        want: true, tunOn: false, acceptedAt: at(0), now: at(1), window: window),
          "重启内核后立刻恢复 TUN → 放行")
}

print("── 5. 没有验收时间戳就不拦（状态未被证明） ──")
do {
    check(!TUNEnableGate.shouldSkipDuplicateEnable(
        want: true, tunOn: true, acceptedAt: nil, now: at(1), window: window),
          "从未验收 → 放行")
}

print("── 6. 窗口配置异常按老行为跑 ──")
do {
    check(!TUNEnableGate.shouldSkipDuplicateEnable(
        want: true, tunOn: true, acceptedAt: at(0), now: at(1), window: 0),
          "窗口 0 → 不拦")
    check(!TUNEnableGate.shouldSkipDuplicateEnable(
        want: true, tunOn: true, acceptedAt: at(0), now: at(1), window: -5),
          "窗口负数 → 不拦")
}

print("── 7. 闸门日志口径 ──")
do {
    checkEq(TUNEnableGate.skipNote(acceptedAt: at(0), now: at(21)), "距上次验收通过 21s",
            "21s 向下取整")
    checkEq(TUNEnableGate.skipNote(acceptedAt: at(0), now: at(0.9)), "距上次验收通过 0s",
            "不足 1s 不四舍五入")
}

print("")
if failed == 0 {
    print("PASS  \(total) checks")
    exit(0)
} else {
    print("FAIL  \(failed)/\(total) checks")
    exit(1)
}
