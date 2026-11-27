import Foundation

/// Tailscale 子网路由的**判定**逻辑（纯逻辑，无 UI、无进程管理、无 MainActor）。
///
/// 现场（2026-11-27）：本机 Tailscale 由 Homebrew `tailscaled` 提供，
/// `--accept-routes` 为 false。对端 A 广播的 `10.20.0.0/24`、对端 B 广播的
/// `192.168.30.0/24` 因此从未进入本机路由表，流量按默认路由走物理网卡，
/// 网络拓扑页只能报「对端网段不可达」。
///
/// 修复方向必须是**让 tailscaled 自己安装路由**（`tailscale set --accept-routes`），
/// 不能由本应用 `route add`：这些路由归 tailscaled 所有，代装会与它的路由管理
/// 互相覆盖（`Coexistence.tailscaleSubnetGaps` 的既有设计前提）。
/// 本文件只负责把「prefs 里到底开没开」解析清楚，CLI 调用留在 `Coexistence`。
enum TailscaleSubnetRouting {
    /// UI 该提供哪一种动作。
    enum Action: Equatable {
        /// 未接受子网路由 → 可以一键开启，让 tailscaled 自己下发。
        case acceptRoutes
        /// 已接受但路由仍未下发 → 改设置修不了，只能等重连/重启隧道。
        case waitForRebroadcast
        /// 拿不到 Tailscale 状态（CLI 缺失 / 未运行 / 输出不可解析）→ 不提供修复。
        case unavailable
    }

    /// 从 `tailscale debug prefs` 的 JSON 读 `RouteAll`（即 `--accept-routes`）。
    ///
    /// 返回 nil 表示「问不到」（字段缺失或 JSON 非法），与 false 严格区分：
    /// nil 时不得显示修复按钮——「不知道」不能当作「关着」，否则会引导用户去开
    /// 一个可能已经开着的开关，还会把「CLI 不在」误报成「设置没开」。
    static func acceptsRoutes(inPrefsJSON data: Data) -> Bool? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["RouteAll"] as? Bool
    }

    /// 有缺口时该做什么。`gaps == 0` 时没有要修的东西，直接 unavailable。
    ///
    /// `acceptsRoutes == true` 仍报缺口是真实存在的形态：tailscaled 已接受路由，
    /// 但还没从协调服务器收到更新（离线/重连中），此时改设置毫无作用，
    /// 文案必须把用户引向「重启 Tailscale 或等待重连」，而不是再点一次。
    static func action(acceptsRoutes: Bool?, gaps: Int) -> Action {
        guard gaps > 0 else { return .unavailable }
        guard let acceptsRoutes else { return .unavailable }
        return acceptsRoutes ? .waitForRebroadcast : .acceptRoutes
    }
}
