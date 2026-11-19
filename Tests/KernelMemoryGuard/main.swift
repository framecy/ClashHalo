// Tests/KernelMemoryGuard — 直接编译生产源码 Sources/Model/KernelMemoryGuard.swift。
//
// 钉住 2026-09-28 的六天长待机事故：内核 RSS 426 MB（健康空载实测 145 MB），
// /connections 返回 1412 条连接，其中 1039 条 TCP 年龄 >12h、合计只走过 1.2 MB
// 流量，897 条属于同一个 Electron 进程；旧看门狗读的是 mihomo 的连接内存记账
// （两小时采样里冻结在 363,905,024 而 ps 实测 148 MB），阈值 512MB 从未触发，
// 且触发后只清 DNS/fake-ip 缓存，对那 1039 条尸体零作用。
//
// 验证两半：该回收时必须回收（事故回放），不该回收时一条都不许动
// （心跳型空闲长连、慢心跳推送、arm 后新建、grace 窗口内、未 arm 的 3h 静默、UDP）。
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ✓ \(msg)") }
    else { print("  ✗ \(msg)"); failures += 1 }
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func ago(_ s: TimeInterval) -> Date { t0.addingTimeInterval(-s) }
let h: TimeInterval = 3600

// ── 事故回放：尸体连接在唤醒后必须全部判死 ──
// 快照节奏 2s；尸体自 firstSeen 起字节恒为 0，跨越一次休眠后被 arm。
print("== 事故回放：1039 条静默 TCP 唤醒后判死 ==")
var w = StaleConnectionWatch()
for i in 0..<1039 {
    w.observe(id: "corpse\(i)", bytes: 1200, tcp: true, now: ago(20 * h))
    // 之后 20 小时字节不再变化
    w.observe(id: "corpse\(i)", bytes: 1200, tcp: true, now: ago(19.9 * h))
}
// 未 arm 且静默不足 12h 时不动手（此处静默 20h，走 ungated 轨道）
check(w.candidates(now: t0).count == 1039, "未 arm 时 12h 绝对静默轨道仍判死 \(w.candidates(now: t0).count) 条")

print("== 事故回放：arm 之后静默满 2 小时即判死 ==")
var w2 = StaleConnectionWatch()
for i in 0..<10 {
    w2.observe(id: "c\(i)", bytes: 900, tcp: true, now: ago(3 * h))
    w2.observe(id: "c\(i)", bytes: 900, tcp: true, now: ago(2.5 * h))   // 最后一次动
}
w2.arm(now: ago(40 * 60))                       // 40 分钟前唤醒
check(w2.candidates(now: t0).count == 10, "arm 后静默 2.5h 的 10 条全部判死")

// ── 负样本 1：活的空闲长连——心跳跨越 arm 一直持续到现在 ──
// SSH/IM/HTTP2 的真实形态：arm 前静默很久，唤醒后自己的 keepalive 让它活下来。
print("== 负样本：arm 后仍有心跳的空闲长连不得被关 ==")
var w3 = StaleConnectionWatch()
w3.observe(id: "ssh", bytes: 4_000, tcp: true, now: ago(6 * h))
w3.arm(now: ago(2 * h))
// 唤醒后每 5 分钟一次 keepalive，一直持续到 t0 前 5 分钟
for k in 1...23 {
    w3.observe(id: "ssh", bytes: Int64(4_000 + k * 64), tcp: true,
               now: ago(2 * h).addingTimeInterval(TimeInterval(k * 5 * 60)))
}
check(w3.candidates(now: t0).isEmpty, "5 分钟心跳的 SSH 在 arm 轨道下存活")

// ── 负样本 1b：慢心跳的推送连接（29 分钟间隔，IMAP IDLE / APNs 量级） ──
var w3b = StaleConnectionWatch()
w3b.observe(id: "push", bytes: 900, tcp: true, now: ago(6 * h))
w3b.arm(now: ago(3 * h))
var pushBytes: Int64 = 900
var at = ago(3 * h)
while at < t0 {
    pushBytes += 26
    w3b.observe(id: "push", bytes: pushBytes, tcp: true, now: at)
    at = at.addingTimeInterval(29 * 60)
}
check(w3b.candidates(now: t0).isEmpty, "29 分钟心跳的推送连接存活（armedSilent=2h）")

// ── 负样本 2：arm 之后新建的连接不受 arm 轨道影响 ──
print("== 负样本：arm 之后新建的连接不得被 arm 轨道判死 ==")
var w4 = StaleConnectionWatch()
w4.arm(now: ago(3 * h))
w4.observe(id: "newborn", bytes: 10, tcp: true, now: ago(2 * h))   // 唤醒后才出现
w4.observe(id: "newborn", bytes: 10, tcp: true, now: ago(1.5 * h))
check(w4.candidates(now: t0).isEmpty, "arm 后新建、静默 1.5h 的连接存活")

// ── 负样本 3：grace 窗口内不动手，给 App 自己的重连留时间 ──
print("== 负样本：arm 后 1 分钟（grace 未满）不得判死 ==")
var w5 = StaleConnectionWatch()
w5.observe(id: "mid", bytes: 700, tcp: true, now: ago(5 * h))
w5.observe(id: "mid", bytes: 700, tcp: true, now: ago(3 * h))   // 静默 3h > armedSilent
w5.arm(now: ago(60))            // 刚唤醒 1 分钟，armedGrace(5m) 未满
check(w5.candidates(now: t0).isEmpty, "grace 未满时即使静默 3 小时也不动手")
check(!w5.candidates(now: ago(-20 * 60)).isEmpty, "grace 满后同一条即被判死")

// ── 负样本 4：未 arm 时，只有 12 小时绝对静默才动手 ──
print("== 负样本：未 arm 时静默 3 小时必须存活 ==")
var w6 = StaleConnectionWatch()
w6.observe(id: "quiet3", bytes: 300, tcp: true, now: ago(15 * h))
w6.observe(id: "quiet3", bytes: 410, tcp: true, now: ago(3 * h))    // 3 小时前还在动
check(w6.candidates(now: t0).isEmpty, "静默 3h < alwaysSilent(12h) 且未 arm → 存活")

// 同一连接再次出现在快照里，但字节没变 —— 静默时钟不得前移，
// 否则 2s 节奏的快照会让尸体永远数不到 12 小时。
w6.observe(id: "quiet20", bytes: 1_200, tcp: true, now: ago(15 * h))
w6.observe(id: "quiet20", bytes: 1_200, tcp: true, now: ago(3 * h))
check(w6.candidates(now: t0) == ["quiet20"], "字节未变的再次观测不前移静默时钟")

// ── 负样本 5：UDP 永不回收（内核自己会老化关联） ──
print("== 负样本：UDP 静默 30 天也不得判死 ==")
var w7 = StaleConnectionWatch()
w7.observe(id: "udp", bytes: 1_400, tcp: false, now: ago(720 * h))
w7.observe(id: "udp", bytes: 1_400, tcp: false, now: ago(719 * h))
w7.arm(now: ago(600 * h))
check(w7.candidates(now: t0).isEmpty, "UDP 排除在回收之外")

// ── 休眠期间不产生任何观测：墙钟一次跳变数天，必须照样判死 ──
// 计时器在合盖期间不触发，`observe` 的两次调用之间可以隔着三天。判据是
// Date() 之差而非观测次数，所以这段空档必须计入静默——按拍次计数会漏掉
// 整个事故形态（这正是本次事故的现场）。
print("== 休眠墙钟跳变：三天空档必须计入静默 ==")
let day: TimeInterval = 86400
var w11 = StaleConnectionWatch()
w11.observe(id: "sleeper", bytes: 5_000, tcp: true, now: ago(3 * day))    // 合盖前最后一次快照
w11.observe(id: "revived", bytes: 1, tcp: true, now: ago(3 * day))
w11.arm(now: ago(2 * h))                                                  // 三天后唤醒
w11.observe(id: "revived", bytes: 900_000, tcp: true, now: ago(30 * 60))  // 唤醒后仍在传
let jumped = w11.candidates(now: t0)
check(jumped == ["sleeper"], "跨三天空档的静默连接被判死，唤醒后还在动的存活：\(jumped)")

// ── 表内消失即遗忘 ──
print("== reap(excluding:) 只留活着的 ==")
var w8 = StaleConnectionWatch()
w8.observe(id: "a", bytes: 1, tcp: true, now: ago(20 * h))
w8.observe(id: "b", bytes: 1, tcp: true, now: ago(20 * h))
w8.reap(excluding: ["a"])
check(w8.trackedCount == 1 && w8.candidates(now: t0) == ["a"], "消失的连接不再被追踪与提名")

// ── 排序：最久静默优先，保证有界批次切到的是最坏的 ──
print("== 候选按静默时长降序 ==")
var w9 = StaleConnectionWatch()
w9.observe(id: "older", bytes: 5, tcp: true, now: ago(30 * h))
w9.observe(id: "newer", bytes: 5, tcp: true, now: ago(14 * h))
let ordered = w9.candidates(now: t0)
check(ordered == ["older", "newer"], "排序 \(ordered)")

// ── forget：在途批次不得被重复提名 ──
var w10 = StaleConnectionWatch()
w10.observe(id: "x", bytes: 5, tcp: true, now: ago(30 * h))
w10.forget(["x"])
check(w10.candidates(now: t0).isEmpty, "forget 后不再提名")

// ── 看门狗：分级、限频、徒劳退避、再武装 ──
print("== KernelMemoryGuardPolicy 分级 ==")
let p = KernelMemoryGuardPolicy()
var st = KernelMemoryGuardPolicy.State()
let mb: UInt64 = 1_000_000

// 地板回归：TUN 开启的全新内核实测 316~330MB 且平稳。阈值若定在地板之下，
// 每次开机都会空转三轮然后暂停，反而在早期累积阶段最不可用——这正是
// 320MB 那版踩的坑（它标定用的是 9-16 那次 TUN 关闭状态的 145MB）。
for floor in [316, 330] {
    var sf = KernelMemoryGuardPolicy.State()
    check(p.decide(rss: UInt64(floor) * mb, now: t0, state: &sf).action == .skip,
          "实测地板 \(floor)MB 不得触发（TUN 开启态）")
}
check(p.decide(rss: 145 * mb, now: t0, state: &st).action == .skip, "TUN 关闭地板 145MB → skip")
check(p.decide(rss: 426 * mb, now: t0.addingTimeInterval(600), state: &st).action == .reap,
      "六天事故水位 426MB → 只回收连接")
check(p.decide(rss: 426 * mb, now: t0.addingTimeInterval(660), state: &st).action == .skip,
      "间隔未满 300s → skip（限频）")
var st2 = KernelMemoryGuardPolicy.State()
check(p.decide(rss: 500 * mb, now: t0, state: &st2).action == .reapAndFlush,
      "≥flushLimit \(p.flushLimit / mb)MB → 回收 + 清缓存")
var st2b = KernelMemoryGuardPolicy.State()
check(p.decide(rss: 465 * mb, now: t0, state: &st2b).action == .reap,
      "实测峰值 465MB 落在回收档而非清缓存档")

print("== 徒劳退避：三次无效即暂停，靠增长再武装 ==")
// 全程取 350MB：在 reapLimit(320) 与 flushLimit(448) 之间，动作恒为 .reap。
var st3 = KernelMemoryGuardPolicy.State()
// 动作 1
var d = p.decide(rss: 400 * mb, now: t0, state: &st3)
check(d.action == .reap && d.transition == .engaged, "首次动作 engaged")
// RSS 没动 → 每次动作记一次无效
d = p.decide(rss: 400 * mb, now: t0.addingTimeInterval(600), state: &st3)
check(d.action == .reap, "第 2 次仍动作")
d = p.decide(rss: 400 * mb, now: t0.addingTimeInterval(1200), state: &st3)
check(d.action == .reap, "第 3 次仍动作")
d = p.decide(rss: 400 * mb, now: t0.addingTimeInterval(1800), state: &st3)
check(d.action == .skip && d.transition == .suspended(afterActions: 3),
      "连续 3 次无效 → 暂停且只说一次")
d = p.decide(rss: 400 * mb, now: t0.addingTimeInterval(2400), state: &st3)
check(d.action == .skip && d.transition == .none, "暂停期间不再重复刷日志")
d = p.decide(rss: 470 * mb, now: t0.addingTimeInterval(3000), state: &st3)
check(d.action == .reap && d.transition == .reArmed, "增长超过 reArmGrowth → 再武装")

print("== 一次有效下降必须重置无效计数 ==")
// 若无重置：t+1800 就该暂停（426 未降 + 400 未降 + 400 未降）。
var st4 = KernelMemoryGuardPolicy.State()
_ = p.decide(rss: 426 * mb, now: t0, state: &st4)                                  // 动作 1
_ = p.decide(rss: 426 * mb, now: t0.addingTimeInterval(600), state: &st4)          // 未降 → 1
let eff = p.decide(rss: 400 * mb, now: t0.addingTimeInterval(1200), state: &st4)   // 降 26MB → 有效
check(eff.action == .reap && eff.transition == .engaged, "有效下降后重新 engaged")
let still = p.decide(rss: 400 * mb, now: t0.addingTimeInterval(1800), state: &st4)
check(still.action == .reap, "有效下降使暂停推迟一轮")
let susp = p.decide(rss: 400 * mb, now: t0.addingTimeInterval(2400), state: &st4)
check(susp.action == .reap, "第 2 次无效仍继续处置")
let third = p.decide(rss: 400 * mb, now: t0.addingTimeInterval(3000), state: &st4)
check(third.action == .skip && third.transition == .suspended(afterActions: 3),
      "连续 3 次无效才暂停")

print("== 回落到 reapLimit 之下不再动作 ==")
var st5 = KernelMemoryGuardPolicy.State()
_ = p.decide(rss: 400 * mb, now: t0, state: &st5)
let back = p.decide(rss: 150 * mb, now: t0.addingTimeInterval(600), state: &st5)
check(back.action == .skip && !st5.isSuspended && st5.ineffectiveStreak == 0,
      "健康区间内 skip 且状态复位")

if failures == 0 { print("\nKernelMemoryGuard: 全部通过") }
else { print("\nKernelMemoryGuard: \(failures) 项失败"); exit(1) }
