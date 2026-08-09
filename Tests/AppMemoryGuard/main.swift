import Foundation

// Test harness over the real shipping source
// (Sources/Model/AppMemoryGuard.swift), compiled in, not re-implemented.
// Re-implementing the rule in the test is how a test passes while the product
// is broken — which is precisely what happened here before v1.1.16: the guard
// existed, looked correct in review, and never ran once in the field because
// its threshold sat above the footprint it was meant to catch.

var failures = 0, checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  ✗ FAIL: \(what)") } else { print("  ✓ \(what)") }
}
func section(_ s: String) { print("\n── \(s) ──") }

let MB: UInt64 = 1_000_000
let policy = AppMemoryGuardPolicy()
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
/// Far enough back that the rate limiter never interferes.
let longAgo = t0.addingTimeInterval(-3600)

func decide(_ rss: UInt64,
            visible: Bool = true,
            now: Date = t0,
            last: Date = longAgo) -> AppMemoryGuardPolicy.Action {
    policy.decide(rss: rss, uiVisible: visible, now: now, lastRun: last)
}

// MARK: - The regression this whole change exists for

section("350MB 必须触发 —— v1.1.16 之前的实际故障点")

// The field reports were "经常 350MB+". The old guard was a bare
// `rss > 400MB`, so this exact input did nothing at all.
expect(decide(350 * MB) != .skip,
       "350MB 且窗口可见时会动作（旧的 400MB 阈值在此处完全不触发）")
expect(decide(350 * MB) == .soft(keepRows: 300),
       "350MB 走软档，保留 300 行而不是清空")
expect(policy.softLimit < 350 * MB,
       "软阈值必须低于实测占用平台期 350MB，否则等于没有守卫")
expect(policy.softLimit > 150 * MB,
       "软阈值必须高于健康空闲态（80–150MB），否则常态误触发")

// MARK: - Tiering

section("分档")

expect(decide(100 * MB) == .skip, "100MB 空闲态不动作")
expect(decide(249 * MB) == .skip, "刚好低于软阈值不动作")
expect(decide(250 * MB) == .skip, "等于软阈值不动作（阈值是严格大于）")
expect(decide(251 * MB) == .soft(keepRows: 300), "刚过软阈值走软档")
expect(decide(399 * MB) == .soft(keepRows: 300), "刚好低于硬阈值仍是软档")
expect(decide(401 * MB) == .hard(includingBookkeeping: false),
       "超硬阈值且窗口可见 → 硬档，但保留 diff 记账")

section("UI 不可见时不需要温柔")

expect(decide(251 * MB, visible: false) == .hard(includingBookkeeping: true),
       "窗口不可见时即使只过软阈值也整体释放，并连 diff 记账一起丢")
expect(decide(401 * MB, visible: false) == .hard(includingBookkeeping: true),
       "窗口不可见 + 超硬阈值同样连记账一起丢")
expect(decide(100 * MB, visible: false) == .skip,
       "窗口不可见但占用健康时仍然什么都不做")

// 可见性是唯一决定「是否丢弃 diff 记账」的因素：记账被清掉会让下一拍的
// 速率全部归零，界面上就是一整拍的 0 B/s，所以只在没人看的时候才允许。
expect(decide(500 * MB, visible: true) == .hard(includingBookkeeping: false),
       "窗口可见时无论多高都不丢 diff 记账（否则速率会空一拍）")

// MARK: - Rate limiting

section("限频")

expect(decide(500 * MB, now: t0, last: t0.addingTimeInterval(-1)) == .skip,
       "距上次动作 1s：跳过")
expect(decide(500 * MB, now: t0, last: t0.addingTimeInterval(-14.9)) == .skip,
       "距上次动作 14.9s：跳过")
expect(decide(500 * MB, now: t0, last: t0.addingTimeInterval(-15)) != .skip,
       "距上次动作 15s：放行")
expect(decide(500 * MB, now: t0, last: .distantPast) != .skip,
       "从未动作过（distantPast）：放行")

// 限频必须先于阈值判断，且对所有档位一视同仁——否则一个稳定停在硬阈值
// 上方的占用会在每个 tick（连接页 1.5s）都清一次缓存，那本身就是故障。
expect(decide(1000 * MB, now: t0, last: t0.addingTimeInterval(-2)) == .skip,
       "硬档同样受限频约束，不能每 tick 清一次")

// MARK: - Invariants

section("不变量")

expect(policy.softLimit < policy.hardLimit, "软阈值严格小于硬阈值")
expect(policy.interval > 0, "限频间隔为正")
expect(policy.softKeepRows > 0, "软档保留行数为正")

// 连接页 1.5s 一拍，网关 3s 一拍：限频必须显著大于最快的轮询周期，
// 否则「限频」名存实亡。
expect(policy.interval >= 10,
       "限频间隔（\(Int(policy.interval))s）显著大于最快轮询周期 1.5s")

// 软档保留行数必须远小于 maxCachedConns(2000)，否则软档形同虚设。
expect(policy.softKeepRows < 2000,
       "软档保留行数（\(policy.softKeepRows)）小于 cachedConns 上限 2000")

print("")
if failures == 0 {
    print("全部通过：\(checks)/\(checks)")
} else {
    print("失败 \(failures)/\(checks)")
    exit(1)
}
