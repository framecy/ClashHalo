import Foundation

/// 「重复开启 TUN」的闸门判定：纯逻辑、无 MainActor、无进程管理。
///
/// ### 为什么需要它
/// TUN 一建立，`configd` 会重挂 utun 并装载路由，`NWPathMonitor` 随之打出一串
/// 路径变化事件。每条事件都答「重建隧道」的话，整条隧道会被反复拆建，每拆一次
/// 丢掉全部在途连接——这是代码注释里已经记载过的事故形态。原来的唯一防线是一个
/// 时间窗（settle window），而窗口的长度永远只能逼近风暴的尾巴：2026-11-27 实测
/// 09:06:03 开启成功，09:06:24（+21s）仍有一次完整重建，10s 窗没拦住。
///
/// 窗口之外还需要一条**不看时间、看状态**的判据：隧道已经按目标态工作、并且刚刚
/// 通过过真实公网验收时，再来一次「开启」没有任何正确性收益，只有断流成本。
///
/// ### 边界（必须保持不变）
/// - `want == false` 永远不拦：关闭是用户的显式意图，也是自愈的收尾动作。
/// - `tunOn == false` 永远不拦：内核重启 / 自愈 / 用户关闭后再开，此刻开关已落，
///   真需要重建的正是这些路径；拦了它们等于让 TUN 永远起不来。
/// - 没有验收时间戳（`nil`）不拦：从未通过验收就代表状态未被证明，应当放行。
/// - 窗口小于等于 0 视为关闭闸门（配置错误时选择「按老行为跑」而不是全拦）。
enum TUNEnableGate {

    /// 是否应当忽略这次「开启」请求。
    ///
    /// - Parameters:
    ///   - want: 本次请求的方向（true = 开启）。
    ///   - tunOn: 当前已推导出的真实状态（enable + root + 接口存在）。
    ///   - acceptedAt: 最近一次通过真实公网验收的时刻，nil 表示从未验证过。
    ///   - now: 判定时刻，注入以便测试固定时间。
    ///   - window: 抑制窗，来自 `AppModel.kTunRebuildSuppressionWindow`。
    static func shouldSkipDuplicateEnable(
        want: Bool,
        tunOn: Bool,
        acceptedAt: Date?,
        now: Date,
        window: TimeInterval
    ) -> Bool {
        guard want, tunOn, window > 0, let acceptedAt else { return false }
        return now.timeIntervalSince(acceptedAt) < window
    }

    /// 闸门日志用的人话后缀：`距上次验收通过 12s`。纯格式化，便于测试钉住口径。
    static func skipNote(acceptedAt: Date, now: Date) -> String {
        let elapsed = Int(now.timeIntervalSince(acceptedAt).rounded(.down))
        return "距上次验收通过 \(elapsed)s"
    }
}
