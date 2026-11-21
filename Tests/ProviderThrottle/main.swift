import Foundation

// Provider API 每秒节流闸的回归套件。
//
// 钉住三件事：
// 1. 滑动窗口语义：任意小于 1 秒的区间内同一 key 至多放行 9 次——固定窗口
//    在边界两侧各发满额的尖峰形态不允许出现
// 2. 键口径：同 host 不同 URL 参数必须共享同一把闸（同一 API key 常以
//    flag=clash / flag=singbox 等参数出现在多条订阅 URL 里）
// 3. 端到端冒烟：10 连发真实等待 ≥0.9s（下界断言，慢机器只会更久，
//    不会假红；只有「不等待」这种回归才会红）
@MainActor
func runTests() async {
    var passed = 0, failed = 0
    func expect(_ condition: Bool, _ label: String) {
        if condition { passed += 1; print("✓ \(label)") }
        else { failed += 1; print("✗ \(label)") }
    }

    // ── 1. 滑动窗口纯逻辑 ───────────────────────────────────────────
    var window = ProviderRateWindow(limit: 9, window: 1.0)

    var admitted = 0
    for _ in 0..<9 { if window.admit("k", at: 0.5) { admitted += 1 } }
    expect(admitted == 9, "同 key 前 9 次全部放行")
    expect(!window.admit("k", at: 0.5), "第 10 次必须拒绝（同刻突发）")
    expect(!window.admit("k", at: 1.499), "窗口内任意时刻第 10 次仍拒绝（t=1.499）")
    expect(window.admit("k", at: 1.5), "最早条目滑出窗口后放行（t=1.5，年龄恰为 1.0）")

    window = ProviderRateWindow(limit: 9, window: 1.0)
    expect(window.waitSeconds("fresh", at: 0) == 0, "未满时 waitSeconds 为 0")

    // 交错形态：4 条在 0.0~0.3、5 条在 0.9 —— 9 条之后 0.95 必须仍被拒，
    // 因为窗口 [0.0, 0.95) 内已有 9 条。
    window = ProviderRateWindow(limit: 9, window: 1.0)
    for i in 0..<4 { _ = window.admit("k", at: Double(i) * 0.1) }
    for i in 0..<5 { _ = window.admit("k", at: 0.9) }
    expect(!window.admit("k", at: 0.95), "交错突发：0~0.9 的 9 条在 0.95 仍占满窗口")
    expect(window.waitSeconds("k", at: 0.95) > 0.04 && window.waitSeconds("k", at: 0.95) < 0.06,
           "等待时长指向最早条目滑出时刻（≈0.05s）")

    // 密集扫描：每 0.037s 申请一次（与窗口不可通约，避免混叠），断言任意
    // 连续 10 次放行的首尾间隔 ≥ 窗口（即任何 <1s 区间内 ≤9 次）。
    window = ProviderRateWindow(limit: 9, window: 1.0)
    var times: [Double] = []
    var t = 0.0
    while t < 3.0 {
        if window.admit("k", at: t) { times.append(t) }
        t += 0.037
    }
    var minSpan = Double.greatestFiniteMagnitude
    if times.count >= 10 {
        for i in 0...(times.count - 10) {
            minSpan = min(minSpan, times[i + 9] - times[i])
        }
    }
    expect(minSpan >= 0.999, "任意连续 10 次放行首尾间隔 ≥ 1s（实测最小 \(minSpan)s）")

    // 键隔离
    window = ProviderRateWindow(limit: 9, window: 1.0)
    for _ in 0..<9 { _ = window.admit("a", at: 0) }
    expect(window.admit("b", at: 0), "不同 key 互不影响")

    // ── 2. 键口径 ──────────────────────────────────────────────────
    typealias P = ProviderThrottlePolicy
    expect(P.maxPerSecond == 9, "上限常量为 9 次/秒")
    expect(P.throttleKey(forURL: "https://api.example.com/link?user=12345") == "api.example.com",
           "标准订阅 URL 取 host")
    expect(P.throttleKey(forURL: "HTTPS://API.Example.COM/link") == "api.example.com",
           "host 与 scheme 大小写归一")
    expect(P.throttleKey(forURL: "https://example.com:443/x") == "example.com",
           "https 默认端口 443 不拆桶")
    expect(P.throttleKey(forURL: "http://example.com:80/x") == "example.com",
           "http 默认端口 80 不拆桶")
    expect(P.throttleKey(forURL: "https://example.com:8443/x") == "example.com:8443",
           "非默认端口保留在键里")
    expect(P.throttleKey(forURL: "https://example.com/a?flag=clash")
        == P.throttleKey(forURL: "https://example.com/b?flag=singbox"),
           "同 host 不同路径/参数共享同一把闸（同 key 多 URL 不得叠加超发）")
    expect(P.throttleKey(forURL: "https://a.example.com/x")
        != P.throttleKey(forURL: "https://b.example.com/x"),
           "不同 host 各自独立")
    expect(P.throttleKey(forURL: "ftp://files.example.net/pub") == "other",
           "非 http(s) 协议落到 other 桶")
    expect(P.throttleKey(forURL: "  https://example.com/x  ") == "example.com",
           "首尾空白被裁剪")
    expect(P.throttleKey(forURL: "") == "other" && P.throttleKey(forURL: "not a url") == "other",
           "空串/非法 URL 落到 other 桶")

    // ── 3. 端到端冒烟（真实时钟）────────────────────────────────────
    let started = Date()
    for _ in 0..<10 {
        await ProviderRequestGate.shared.awaitTurn(key: "smoke.test.host")
    }
    let elapsed = Date().timeIntervalSince(started)
    expect(elapsed >= 0.9, "同 key 10 连发被压到 ≥0.9s（实测 \(String(format: "%.2f", elapsed))s）")

    print("ProviderThrottle: \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
Task { @MainActor in await runTests() }
dispatchMain()
