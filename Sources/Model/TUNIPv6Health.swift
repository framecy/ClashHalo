import Foundation

/// TUN IPv6 接管闸门（纯逻辑：无 UI、无进程管理、无 MainActor，直接被
/// `Tests/TUNIPv6Health` 编译）。
///
/// 2026-08-29 mini-pro 事件：物理 IPv6 断供（RA 停发、en0 全局地址全部
/// deprecated、无经物理口的 v6 默认路由），但 TUN 的 v6 auto-route 仍把
/// 公网 v6 吸进隧道；微信用自带 HTTPDNS 拿到腾讯真实 v6 → 规则判 DIRECT →
/// mihomo 从物理口拨 v6 → `no route to host`，三小时 1400 次失败，表现为
/// 「发送图片失败、时间过长」。TUN 是否接管 v6 是随内核版本/环境漂移的
/// 隐式行为（同一台机器换内核后行为可能翻转），必须由应用显式拥有。
///
/// 语义：**未证实健康即按断供处理**（保守缺省）。断供时
/// `tunPatchBody` 在 `route-exclude-address` 追加 `2000::/3`，让 v6 失败
/// 发生在内核层、应用毫秒级回退 IPv4；恢复健康后移除排除项，v6 分流
/// 交还规则表。
enum TUNIPv6Health {

    /// 断供期追加到 `tun.route-exclude-address` 的整段排除项：
    /// 覆盖全部全球单播 IPv6（含 240e/2408/2409 等运营商段），
    /// 不含 ULA（fd00::/8，Tailscale ULA 另有专条）、链路本地与多播。
    static let ipv6GlobalUnicastExclude = "2000::/3"

    struct Snapshot: Equatable {
        /// 经物理口（非 utun/lo0）的 IPv6 默认路由存在
        var hasV6DefaultRouteOnPhysical: Bool
        /// 该口存在未 deprecated 的 2000::/3 全球单播地址
        var hasFreshGlobalV6Address: Bool
        /// 主动探测：对公共 v6 DNS 的 UDP 可达性。nil = 探测本身不可用
        /// （如 socket 创建失败），此时降级为只信被动判定。
        var probeReachable: Bool?
    }

    /// 被动 + 主动判定。缺一即视为断供。
    static func isHealthy(_ s: Snapshot) -> Bool {
        guard s.hasV6DefaultRouteOnPhysical, s.hasFreshGlobalV6Address else { return false }
        return s.probeReachable != false
    }

    /// 滞回状态机：初始化为「死」（保守缺省，避免启动早期未证实窗口把 v6
    /// 吸进 TUN）。**首次**完整通过（被动+主动）即复活——保守缺省针对的是
    /// 「未证实」状态，而一次健康观测就是证实；此后的死亡需连续
    /// `deadStreakToKill` 次不健康、复活需连续 `aliveStreakToRevive` 次健康。
    struct Gate: Equatable {
        let aliveStreakToRevive: Int
        let deadStreakToKill: Int

        private(set) var dead: Bool = true
        private(set) var everAlive: Bool = false
        private(set) var aliveStreak: Int = 0
        private(set) var deadStreak: Int = 0

        init(aliveStreakToRevive: Int = 2, deadStreakToKill: Int = 3) {
            self.aliveStreakToRevive = aliveStreakToRevive
            self.deadStreakToKill = deadStreakToKill
        }

        enum Transition: Equatable {
            case none
            case wentAlive
            case wentDead
        }

        @discardableResult
        mutating func observe(healthy: Bool) -> Transition {
            if healthy {
                deadStreak = 0
                aliveStreak += 1
                guard dead else { return .none }
                let enough = !everAlive || aliveStreak >= aliveStreakToRevive
                guard enough else { return .none }
                everAlive = true
                dead = false
                return .wentAlive
            } else {
                aliveStreak = 0
                deadStreak += 1
                guard !dead, deadStreak >= deadStreakToKill else { return .none }
                dead = true
                return .wentDead
            }
        }
    }
}
