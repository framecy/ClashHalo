import Foundation

// Test harness over the real shipping source
// (Sources/Model/AppMemoryGuard.swift), compiled in, not re-implemented.
// Re-implementing the rule in the test is how a test passes while the product
// is broken — which is precisely what happened twice here:
//
//   * before v1.1.16 the guard's threshold sat *above* the footprint it was
//     meant to catch, so it never ran once;
//   * v1.1.16 fixed the threshold but compared it against phys_footprint while
//     calibrating from RSS figures, so on a real machine (309–317MB idle
//     footprint vs a 250MB soft limit) it ran every 15s for 2 hours straight —
//     463 actions, 463 log lines, and the number never moved.
//
// The second failure is why this file drives the full give-up/re-arm cycle and
// not just single decisions.
//
// **Expectations are derived from the policy's own constants, never hardcoded.**
// The thresholds are tuning knobs that get retuned as field data arrives; a test
// that pins them to literals fails on every retune while proving nothing about
// behaviour. What must hold across any tuning is the *shape*: tiering order,
// rate limiting, and — the point of this change — that a guard which achieves
// nothing stops trying. Literals appear only where the number is itself the
// historical evidence (the 350MB field plateau).

var failures = 0, checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  ✗ FAIL: \(what)") } else { print("  ✓ \(what)") }
}
func section(_ s: String) { print("\n── \(s) ──") }

let MB: UInt64 = 1_000_000
let policy = AppMemoryGuardPolicy()
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Footprints derived from the live policy, so retuning cannot invalidate them.
let healthy = policy.softLimit / 2
let justOverSoft = policy.softLimit + 1
let justUnderHard = policy.hardLimit
let overHard = policy.hardLimit + 1

/// One-shot decision against a fresh state, rate limiter disarmed.
func decide(_ footprint: UInt64,
            visible: Bool = true,
            now: Date = t0) -> AppMemoryGuardPolicy.Action {
    var s = AppMemoryGuardPolicy.State()
    return policy.decide(rss: footprint, uiVisible: visible, now: now, state: &s).action
}

/// Drive `rounds` evaluations at a fixed footprint, one policy interval apart,
/// returning how many actually acted plus the final state.
func drive(footprint: UInt64,
           rounds: Int,
           visible: Bool = true) -> (actions: Int, state: AppMemoryGuardPolicy.State,
                                     suspendedAfter: Int?) {
    var s = AppMemoryGuardPolicy.State()
    var now = t0
    var acted = 0
    var suspendedAfter: Int? = nil
    for _ in 0..<rounds {
        let d = policy.decide(rss: footprint, uiVisible: visible, now: now, state: &s)
        if d.action != .skip { acted += 1 }
        if case let .suspended(n) = d.transition { suspendedAfter = n }
        now = now.addingTimeInterval(policy.interval)
    }
    return (acted, s, suspendedAfter)
}

// MARK: - The regression this whole change exists for

section("350MB 必须触发 —— v1.1.16 之前的实际故障点")

// 350MB 是现场报告的实际占用平台期，是历史证据本身，故保留字面量。
expect(decide(350 * MB) != .skip,
       "350MB 且窗口可见时会动作（旧的 400MB 阈值在此处完全不触发）")
expect(policy.softLimit < 350 * MB,
       "软阈值必须低于实测占用平台期 350MB，否则等于没有守卫")

// MARK: - Tiering

section("分档（阈值取自 policy，随调参自动跟随）")

expect(decide(healthy) == .skip,
       "健康占用（\(healthy / MB)MB）不动作")
expect(decide(policy.softLimit) == .skip,
       "等于软阈值（\(policy.softLimit / MB)MB）不动作（阈值是严格大于）")
expect(decide(justOverSoft) == .soft(keepRows: policy.softKeepRows),
       "刚过软阈值走软档，保留 \(policy.softKeepRows) 行")
expect(decide(justUnderHard) == .soft(keepRows: policy.softKeepRows),
       "等于硬阈值仍是软档（硬档同样严格大于）")
expect(decide(overHard) == .hard(includingBookkeeping: false),
       "超硬阈值（\(policy.hardLimit / MB)MB）且窗口可见 → 硬档，但保留 diff 记账")

section("UI 不可见时不需要温柔")

expect(decide(justOverSoft, visible: false) == .hard(includingBookkeeping: true),
       "窗口不可见时即使只过软阈值也整体释放，并连 diff 记账一起丢")
expect(decide(overHard, visible: false) == .hard(includingBookkeeping: true),
       "窗口不可见 + 超硬阈值同样连记账一起丢")
expect(decide(healthy, visible: false) == .skip,
       "窗口不可见但占用健康时仍然什么都不做")
expect(decide(overHard * 2, visible: true) == .hard(includingBookkeeping: false),
       "窗口可见时无论多高都不丢 diff 记账（否则速率会空一拍）")

// MARK: - Rate limiting

section("限频")

func decideAfter(_ gap: TimeInterval, footprint: UInt64 = 0) -> AppMemoryGuardPolicy.Action {
    var s = AppMemoryGuardPolicy.State()
    s.lastRun = t0.addingTimeInterval(-gap)
    let f = footprint == 0 ? overHard : footprint
    return policy.decide(rss: f, uiVisible: true, now: t0, state: &s).action
}

expect(decideAfter(policy.interval * 0.05) == .skip,
       "远小于限频间隔：跳过")
expect(decideAfter(policy.interval - 0.1) == .skip,
       "差 0.1s 到限频间隔：跳过")
expect(decideAfter(policy.interval) != .skip,
       "恰好到限频间隔（\(policy.interval)s）：放行")
expect(decide(overHard) != .skip, "从未动作过（distantPast）：放行")
expect(decideAfter(policy.interval * 0.2, footprint: overHard * 3) == .skip,
       "硬档同样受限频约束，不能每 tick 清一次")

// MARK: - 徒劳退避：本次修复的核心

section("徒劳退避 —— 清理无效时必须停手")

// 复刻实测形态：占用稳定不动，每次清理后纹丝不动。
// 修复前这里会无限触发；修复后必须在 ineffectiveLimit 次后停手。
let stuck = justOverSoft
let r = drive(footprint: stuck, rounds: 40)

expect(r.actions <= policy.ineffectiveLimit + 1,
       "占用不下降时 40 次评估里最多动作 \(policy.ineffectiveLimit + 1) 次（实际 \(r.actions) 次）")
expect(r.suspendedAfter != nil, "会明确进入 suspended 状态并给出一次可诊断的转换")
expect(r.state.isSuspended, "停手后状态标记为已暂停")
expect(r.actions < 40, "远离修复前「每个间隔清一次、永不停止」的形态")

section("真实负载回放 —— 用实测 RSS 序列钉住「不该介入时绝不介入」")

// 这一组来自 2 小时 589 个真实样本（monitor_4h/logs/metrics.csv）的回放结论。
// 数据不内联全序列（那会把测试变成数据文件），而是内联其决定性特征：
// 序列在 115.4–145.8MB 之间，中位数 145.2MB，后 90 分钟稳定在平台期。
// 回放结果：新策略动作 0 次；旧版 build 82 在同一时段打了 463 行。
//
// 这条测试的意义不在于"守卫不工作"，而在于**守卫在正常负载下必须完全沉默**——
// 这正是 v1.1.16 违反的性质，也是 463 次空转的直接来源。
let fieldRSSFloor: UInt64 = 115 * MB      // 实测最小值 115.4MB
let fieldRSSPlateau: UInt64 = 146 * MB    // 实测平台期上沿 145.8MB

var sField = AppMemoryGuardPolicy.State()
var nowField = t0
var fieldActions = 0
// 模拟真实形态：先低位爬升，再长期停在平台期
for i in 0..<589 {
    let rss = i < 60 ? fieldRSSFloor : fieldRSSPlateau
    let d = policy.decide(rss: rss, uiVisible: true, now: nowField, state: &sField)
    if d.action != .skip { fieldActions += 1 }
    nowField = nowField.addingTimeInterval(10)   // 采样周期 10s
}
expect(fieldActions == 0,
       "实测负载（\(fieldRSSFloor / MB)–\(fieldRSSPlateau / MB)MB，589 样本）下守卫必须 0 次介入（实际 \(fieldActions) 次）")
expect(!sField.isSuspended, "正常负载下不该进入暂停——因为压根不该动作过")

// 反事实：若有人把度量改回 phys_footprint，同一策略也不能退化成无限空转。
// 这是第二道独立防线：即使口径再次弄错，徒劳退避仍然兜底。
var sCounter = AppMemoryGuardPolicy.State()
var nowCounter = t0
var counterActions = 0
let observedFootprint: UInt64 = 316 * MB   // 同期 phys_footprint 实测值
for _ in 0..<589 {
    let d = policy.decide(rss: observedFootprint, uiVisible: true, now: nowCounter, state: &sCounter)
    if d.action != .skip { counterActions += 1 }
    nowCounter = nowCounter.addingTimeInterval(10)
}
expect(counterActions <= policy.ineffectiveLimit + 1,
       "即使误用 phys_footprint(\(observedFootprint / MB)MB)，589 次评估也最多动作 " +
       "\(policy.ineffectiveLimit + 1) 次（实际 \(counterActions) 次）—— 退避是独立于口径的第二道防线")
expect(sCounter.isSuspended, "误用口径时会停手，而不是像 v1.1.16 那样打 463 行日志")

section("暂停后只有真实增长才重新武装")

var s2 = AppMemoryGuardPolicy.State()
var now2 = t0
for _ in 0..<(policy.ineffectiveLimit + 5) {
    _ = policy.decide(rss: stuck, uiVisible: true, now: now2, state: &s2)
    now2 = now2.addingTimeInterval(policy.interval)
}
expect(s2.isSuspended, "先进入暂停")

// 小于 reArmGrowth 的抖动不得重新武装（否则等于没暂停）
now2 = now2.addingTimeInterval(policy.interval)
let jitter = policy.decide(rss: stuck + policy.reArmGrowth / 2,
                           uiVisible: true, now: now2, state: &s2)
expect(jitter.action == .skip,
       "暂停后 +\(policy.reArmGrowth / 2 / MB)MB 抖动（小于重新武装阈值）不复位")
expect(s2.isSuspended, "抖动后仍保持暂停")

// 超过 reArmGrowth 的真实增长必须重新武装——否则真泄漏会被退避掩盖
now2 = now2.addingTimeInterval(policy.interval)
let grown = policy.decide(rss: stuck + policy.reArmGrowth + MB,
                          uiVisible: true, now: now2, state: &s2)
expect(grown.action != .skip,
       "增长超过 \(policy.reArmGrowth / MB)MB 后重新武装并动作")
expect(grown.transition == .reArmed, "重新武装给出可诊断的转换")
expect(!s2.isSuspended, "重新武装后不再是暂停态")

section("清理有效时不得误判为徒劳")

// 每次清理都真实降低占用 → streak 必须归零，守卫应持续工作。
var s3 = AppMemoryGuardPolicy.State()
var now3 = t0
var falling = overHard * 2
let drop = policy.effectiveDrop * 3
var effectiveActions = 0
let rounds3 = 5
for _ in 0..<rounds3 {
    let d = policy.decide(rss: falling, uiVisible: true, now: now3, state: &s3)
    if d.action != .skip {
        effectiveActions += 1
        falling -= drop          // 清理确实起作用
    }
    now3 = now3.addingTimeInterval(policy.interval)
}
expect(effectiveActions == rounds3,
       "清理有效时 \(rounds3) 次评估全部动作，不会被误判停手")
expect(!s3.isSuspended, "清理有效时不进入暂停")

section("占用回落到健康区间后重置")

var s4 = AppMemoryGuardPolicy.State()
var now4 = t0
for _ in 0..<(policy.ineffectiveLimit + 5) {
    _ = policy.decide(rss: stuck, uiVisible: true, now: now4, state: &s4)
    now4 = now4.addingTimeInterval(policy.interval)
}
expect(s4.isSuspended, "先进入暂停")

now4 = now4.addingTimeInterval(policy.interval)
let recovered = policy.decide(rss: healthy, uiVisible: true, now: now4, state: &s4)
expect(recovered.action == .skip, "健康占用不动作")
expect(!s4.isSuspended, "回落到软阈值以下后清除暂停状态")
expect(recovered.transition == .recovered, "回落给出 recovered 转换")
expect(s4.ineffectiveStreak == 0, "回落后无效计数归零")

// MARK: - 边界与健壮性（本轮隐性问题排查补充）

section("读取失败必须安全降级")

// residentMemoryBytes() 在 task_info 失败时返回 0。0 必须被当成健康，
// 绝不能因为读不到内存就把用户正在看的连接表清空。
expect(decide(0) == .skip, "RSS 读取失败返回 0 时不动作（不得误清缓存）")

var s0 = AppMemoryGuardPolicy.State()
var now0 = t0
// 先让守卫进入暂停，再模拟读取失败，确认不会误判为「回落恢复」而乱打日志
for _ in 0..<(policy.ineffectiveLimit + 5) {
    _ = policy.decide(rss: justOverSoft, uiVisible: true, now: now0, state: &s0)
    now0 = now0.addingTimeInterval(policy.interval)
}
expect(s0.isSuspended, "先进入暂停")
now0 = now0.addingTimeInterval(policy.interval)
let failedRead = policy.decide(rss: 0, uiVisible: true, now: now0, state: &s0)
expect(failedRead.action == .skip, "暂停期间读取失败仍不动作")

section("算术不得溢出")

// suspendedAt + reArmGrowth 与 rss + effectiveDrop 若写成裸加法，
// 病态大值会回绕：前者静默永远重新武装，后者把无效判成有效。
// 这两处已改写为在差值上比较，这里用 UInt64.max 钉住。
var sMax = AppMemoryGuardPolicy.State()
let huge = UInt64.max
let dMax = policy.decide(rss: huge, uiVisible: true, now: t0, state: &sMax)
expect(dMax.action == .hard(includingBookkeeping: false),
       "UInt64.max 不崩溃，且按硬档处理")

// 驱动完整循环，确认在极端值下也能正常进入暂停而不是回绕成永久空转
var nowMax = t0.addingTimeInterval(policy.interval)
var maxActions = 0
for _ in 0..<20 {
    let d = policy.decide(rss: huge, uiVisible: true, now: nowMax, state: &sMax)
    if d.action != .skip { maxActions += 1 }
    nowMax = nowMax.addingTimeInterval(policy.interval)
}
expect(maxActions <= policy.ineffectiveLimit,
       "极端值下同样会停手（实际再动作 \(maxActions) 次），不会因回绕永久空转")
expect(sMax.isSuspended, "极端值下最终进入暂停")

section("系统回收导致的下降不得被误判为「清理有效」而无限续命")

// 真实风险：macOS 内存压力会自行压缩/回收页面，RSS 可能在守卫没做任何有效工作时
// 也自然下降。若每次都恰好下降超过 effectiveDrop，streak 会被反复清零 → 又变成
// 无限空转。这不是逻辑 bug（下降本身就是「有效」的定义），但必须确认：一旦下降
// 停止，守卫仍会在 ineffectiveLimit 次内停手，而不是被之前的清零永久续命。
var sOsc = AppMemoryGuardPolicy.State()
var nowOsc = t0
var oscRSS = policy.hardLimit + 100 * MB
// 前 3 轮：每轮真实下降（模拟系统回收）
for _ in 0..<3 {
    _ = policy.decide(rss: oscRSS, uiVisible: true, now: nowOsc, state: &sOsc)
    oscRSS -= policy.effectiveDrop * 2
    nowOsc = nowOsc.addingTimeInterval(policy.interval)
}
expect(!sOsc.isSuspended, "持续下降期间不暂停（下降就是有效，符合设计）")
// 之后停止下降 → 必须在 ineffectiveLimit 次内停手
var oscActions = 0
for _ in 0..<20 {
    let d = policy.decide(rss: oscRSS, uiVisible: true, now: nowOsc, state: &sOsc)
    if d.action != .skip { oscActions += 1 }
    nowOsc = nowOsc.addingTimeInterval(policy.interval)
}
expect(sOsc.isSuspended, "下降停止后仍会进入暂停，不被之前的「有效」永久续命")
expect(oscActions <= policy.ineffectiveLimit + 1,
       "下降停止后最多再动作 \(policy.ineffectiveLimit + 1) 次（实际 \(oscActions) 次）")

section("阈值必须与 RSS 口径相称（钉住实测分布，不是拍脑袋）")

// 本次事故的核心防线：阈值是拿来和 RSS 比的，不是和 phys_footprint 比的。
// 下列数字来自 2 小时 589 样本的真实采集（monitor_4h/logs/metrics.csv）：
//   启动 123MB → 爬升至平台期 145.1–145.8MB → 后 90 分钟持平（p50 145.2 / p99 145.8 / max 145.8）
//   冷启动约 90MB；同期 phys_footprint 报 316–384MB。
// 关键认知：~146MB 是**稳态**而非峰值，阈值必须显著高于它，否则常态即触发。
let measuredFreshLaunchRSS: UInt64 = 90 * MB
let measuredPlateauRSS: UInt64 = 146 * MB
let measuredFootprint: UInt64 = 316 * MB
/// 稳态之上至少要留这么多余量，否则一次连接激增就把守卫打成常态空转。
let requiredHeadroom: UInt64 = 50 * MB

expect(policy.softLimit > measuredFreshLaunchRSS,
       "软阈值（\(policy.softLimit / MB)MB）高于冷启动 RSS（\(measuredFreshLaunchRSS / MB)MB）")
expect(policy.softLimit > measuredPlateauRSS + requiredHeadroom,
       "软阈值（\(policy.softLimit / MB)MB）必须高于实测稳态平台（\(measuredPlateauRSS / MB)MB）+ " +
       "\(requiredHeadroom / MB)MB 余量 —— 只高出几 MB 等于把空转以更小幅度重演一遍")
expect(policy.hardLimit > measuredPlateauRSS * 2,
       "硬阈值（\(policy.hardLimit / MB)MB）高于稳态平台的两倍（\(measuredPlateauRSS * 2 / MB)MB），" +
       "只有真正失控才整体释放")
expect(policy.softLimit < measuredFootprint,
       "软阈值仍低于同期 phys_footprint（\(measuredFootprint / MB)MB）—— 若有人把度量改回 footprint，" +
       "守卫会立刻恒真，这条与上面几条一起把口径错配暴露出来")

// MARK: - Invariants

section("不变量")

expect(policy.softLimit < policy.hardLimit, "软阈值严格小于硬阈值")
expect(policy.interval > 0, "限频间隔为正")
expect(policy.softKeepRows > 0, "软档保留行数为正")
expect(policy.interval >= 1.5,
       "限频间隔（\(policy.interval)s）不小于最快轮询周期 1.5s，否则限频名存实亡")
expect(policy.softKeepRows < 2000,
       "软档保留行数（\(policy.softKeepRows)）小于 cachedConns 上限 2000")
expect(policy.ineffectiveLimit > 0, "徒劳上限为正，否则守卫一次都不会动作")
expect(policy.ineffectiveLimit <= 5,
       "徒劳上限（\(policy.ineffectiveLimit)）足够小，不会让无效清理持续太久")
expect(policy.effectiveDrop > 0, "有效降幅阈值为正，否则任何抖动都算「有效」")
expect(policy.reArmGrowth > policy.effectiveDrop,
       "重新武装所需增长（\(policy.reArmGrowth / MB)MB）必须大于有效降幅（\(policy.effectiveDrop / MB)MB），否则会在暂停边缘反复抖动")

print("")
print("当前调参：soft=\(policy.softLimit / MB)MB hard=\(policy.hardLimit / MB)MB " +
      "interval=\(policy.interval)s keepRows=\(policy.softKeepRows) " +
      "ineffLimit=\(policy.ineffectiveLimit) effDrop=\(policy.effectiveDrop / MB)MB " +
      "reArm=\(policy.reArmGrowth / MB)MB")
print("")
if failures == 0 {
    print("全部通过：\(checks)/\(checks)")
} else {
    print("失败 \(failures)/\(checks)")
    exit(1)
}
