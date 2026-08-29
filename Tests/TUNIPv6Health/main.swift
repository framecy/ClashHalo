// TUN IPv6 接管闸门回归：钉住 2026-08-29 的语义。
//
// 保守缺省（未证实健康即按断供处理）+ 滞回（复活/判死阈值不对称）。
// 对应 mini-pro 事件：物理 v6 断供 + TUN v6 auto-route + 微信自带
// HTTPDNS → 3h 1400 次 `no route to host`。
import Foundation

var failed = 0
var total = 0
func check(_ cond: Bool, _ name: String) {
    total += 1
    print(cond ? "  ✓ \(name)" : "  ✗ FAIL: \(name)")
    if !cond { failed += 1 }
}

// ── isHealthy 判定矩阵 ──
check(!TUNIPv6Health.isHealthy(.init(hasV6DefaultRouteOnPhysical: false,
                                     hasFreshGlobalV6Address: false,
                                     probeReachable: nil)),
      "无路由无地址 → 断供")
check(!TUNIPv6Health.isHealthy(.init(hasV6DefaultRouteOnPhysical: true,
                                     hasFreshGlobalV6Address: false,
                                     probeReachable: nil)),
      "有路由无地址 → 断供（deprecated 残留地址不算）")
check(!TUNIPv6Health.isHealthy(.init(hasV6DefaultRouteOnPhysical: false,
                                     hasFreshGlobalV6Address: true,
                                     probeReachable: true)),
      "有地址无路由 → 断供")
check(!TUNIPv6Health.isHealthy(.init(hasV6DefaultRouteOnPhysical: true,
                                     hasFreshGlobalV6Address: true,
                                     probeReachable: false)),
      "被动全过但主动探测不可达 → 断供")
check(TUNIPv6Health.isHealthy(.init(hasV6DefaultRouteOnPhysical: true,
                                    hasFreshGlobalV6Address: true,
                                    probeReachable: true)),
      "三路全过 → 健康")
check(TUNIPv6Health.isHealthy(.init(hasV6DefaultRouteOnPhysical: true,
                                    hasFreshGlobalV6Address: true,
                                    probeReachable: nil)),
      "探测不可用（nil）降级为只信被动判定 → 健康")

// ── Gate 滞回状态机 ──
// 保守缺省：初始即 dead（启动早期未证实窗口不把 v6 吸进 TUN）
var g = TUNIPv6Health.Gate()
check(g.dead, "初始为 dead（保守缺省）")

// 首次健康观测即复活：一次完整的被动+主动通过足以推翻保守缺省
check(g.observe(healthy: true) == .wentAlive, "首次健康 → wentAlive")
check(!g.dead, "复活后不再 dead")

// 活期：单次失败不判死（半抖动吸收）
check(g.observe(healthy: false) == .none, "活期 1 次失败 → none")
check(g.observe(healthy: true) == .none, "恢复健康 → none")

// 判死需连续 deadStreakToKill 次
g = TUNIPv6Health.Gate()
g.observe(healthy: true)   // alive
check(g.observe(healthy: false) == .none, "断供第 1 次 → none")
check(g.observe(healthy: false) == .none, "断供第 2 次 → none")
check(g.observe(healthy: false) == .wentDead, "断供第 3 次 → wentDead")
check(g.dead, "判死后 dead = true")

// 死→活需要连续 aliveStreakToRevive 次
check(g.observe(healthy: true) == .none, "死期 1 次健康 → none")
check(g.observe(healthy: true) == .wentAlive, "死期第 2 次健康 → wentAlive")

// 抖动序列：活期一次失败后跟健康，计数不累积判死
g = TUNIPv6Health.Gate()
g.observe(healthy: true)
g.observe(healthy: false)
g.observe(healthy: true)
check(g.observe(healthy: false) == .none, "抖动后 1 次失败 → none（streak 已被健康清零）")
check(!g.dead, "抖动序列不误判死")

// 排除项常量：必须覆盖全部全球单播 v6，且不吞 ULA
check(TUNIPv6Health.ipv6GlobalUnicastExclude == "2000::/3", "排除项为 2000::/3")

print("\n\(total - failed)/\(total) 通过")
exit(failed == 0 ? 0 : 1)
