import Foundation

// MARK: - 纯逻辑半边（可测）

/// 按键隔离的滑动窗口节流判定：任意长度小于 `window` 的时间区间内，同一 key
/// 最多放行 `limit` 次。时间由调用方传入（生产传
/// `Date().timeIntervalSinceReferenceDate`，回归套件传合成时钟），本类型不持
/// 时钟、无隔离域、无 IO。
///
/// 为什么是滑动窗口而不是固定窗口：固定窗口在边界两侧各发满额，中间一秒
/// 实际能打到 2×limit——那正是订阅服务商侧 429 的尖峰形态。滑动窗口保证
/// 任意时刻往前看 1 秒都不超发。
struct ProviderRateWindow {
    let limit: Int
    let window: TimeInterval
    private var stamps: [String: [TimeInterval]] = [:]

    init(limit: Int, window: TimeInterval) {
        precondition(limit > 0 && window > 0)
        self.limit = limit
        self.window = window
    }

    /// 尝试在 `now` 放行一次 `key`。放行即记录时间戳；拒绝不改状态。
    mutating func admit(_ key: String, at now: TimeInterval) -> Bool {
        prune(key, now: now)
        var list = stamps[key] ?? []
        guard list.count < limit else { return false }
        list.append(now)
        stamps[key] = list
        return true
    }

    /// `key` 已满时下一次可放行还要等多久；未满返回 0。等待者醒来后必须
    /// 重新走 `admit`——这个值只是唤醒提示，不是保留名额。
    mutating func waitSeconds(_ key: String, at now: TimeInterval) -> TimeInterval {
        prune(key, now: now)
        guard let list = stamps[key], list.count >= limit else { return 0 }
        return max(0, list[0] + window - now)
    }

    /// 窗口语义为半开区间：时间戳年龄 `>= window` 即过期清除。
    private mutating func prune(_ key: String, now: TimeInterval) {
        guard var list = stamps[key] else { return }
        let cutoff = now - window
        guard list.contains(where: { $0 <= cutoff }) else { return }
        list.removeAll { $0 <= cutoff }
        if list.isEmpty { stamps.removeValue(forKey: key) } else { stamps[key] = list }
    }
}

// MARK: - 策略（键的口径）

/// 节流策略常量与键推导。独立成非隔离 enum：纯函数 + 常量，测试与生产
/// 共用同一份口径。
enum ProviderThrottlePolicy {
    /// 每秒对同一订阅服务商 API 的请求上限。产品需求：Provider 的 API KEY
    /// 每秒请求 ≤ 9 次（机场面板按 key 限频，超发直接 429）。
    static let maxPerSecond = 9

    /// 订阅 URL → 节流键（scheme 归一后的 host:port，小写）。
    ///
    /// 键取 host 而不是完整 URL：同一 API key 常以不同查询参数出现在多条订阅
    /// URL 里（flag=clash / flag=singbox…），按完整 URL 分桶会放过「同 key 多
    /// URL」叠加超频；按 host 分桶只会更严不会更松。https 默认 443 / http
    /// 默认 80 不进键，避免「带不带默认端口」拆成两个桶。
    ///
    /// 已知边界：跨 host 共享同一 key（CDN 多子域）无法从 URL 侧识别，各子域
    /// 各得一桶；非 http(s) 或解析不了的地址统一落到 "other" 单桶，共享最保守
    /// 的预算。
    static func throttleKey(forURL raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return "other" }
        if let port = url.port,
           !(scheme == "https" && port == 443) && !(scheme == "http" && port == 80) {
            return "\(host):\(port)"
        }
        return host
    }
}

// MARK: - 生产闸门

/// 订阅服务商（机场）API 的每秒请求闸门：同一 host 任意 1 秒窗口内最多放行
/// `ProviderThrottlePolicy.maxPerSecond`（9）次请求。
///
/// 两个挂载点，缺一不可：
/// 1. **App 自己的直连下载**：`ConfigStore` 的订阅 URL 漏斗（`download` /
///    `importRemoteDraft` / `updateRemote` 共用 `fetchSubscriptionData`）
/// 2. **触发内核去拉订阅**：`refreshProviderNodes` 的 http 分支在
///    `PUT /providers/proxies/:name` 之前过闸——这个 PUT 会让 mihomo 携带
///    订阅 URL（内含 API key）重新下载
///
/// 不在管辖内：内核按 `interval` 的自动更新（分钟级，不构成秒级突发）与
/// 健康检查 / 延迟测试（打 gstatic，经节点出网，不用订阅 key）。file 型
/// provider 的内核刷新只重读本地文件，无网络请求，同样不需要过闸。
///
/// 所有调用方都在 MainActor（ConfigStore / AppModel 都是 @MainActor），闸门
/// 的窗口状态由 MainActor 串行化保护；等待期间仅挂起任务、不占线程。
@MainActor
final class ProviderRequestGate {
    static let shared = ProviderRequestGate()

    private var rate = ProviderRateWindow(limit: ProviderThrottlePolicy.maxPerSecond, window: 1.0)
    private init() {}

    /// 挂起直到 `key` 获得一个名额（最多约 1 秒）。
    ///
    /// 等待用的是不可取消的定时器：外层任务被取消时不得绕过闸门（那正是
    /// 超频的来源），也不得改用 `Task.sleep` 忙等——已取消任务里的
    /// `Task.sleep` 会立刻抛出，循环会退化为热自旋。
    func awaitTurn(key: String) async {
        while true {
            let now = Date().timeIntervalSinceReferenceDate
            if rate.admit(key, at: now) { return }
            let wait = rate.waitSeconds(key, at: now)
            await Self.hardSleep(max(wait, 0.01))
        }
    }

    /// 不可取消的短暂等待。continuation 在全局队列上恢复，MainActor 调用方
    /// 在 await 边界自动跳回主线程，不阻塞 UI。
    private static func hardSleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { cont.resume() }
        }
    }
}
