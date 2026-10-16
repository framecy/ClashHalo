import Foundation

// MARK: - 系统 DNS 重定向的记账层（解耦核心）
//
// 2026-10-14 代码审查的结构性修复。修复前，「系统 DNS 被我们改过」这件事的
// 记账散落在四个文件里的裸 UserDefaults 读写：
//
//   写者：`enableTunnelDNS`（TUN fake-ip 网关）、`ensureProxyDNS`（代理模式 127.0.0.1）
//         —— 两者**共用同一套 key**，原注释自己写着
//            "whichever set it last is responsible for restoring"
//   读者：`restoreTunnelDNS`、`sweepOrphanedTunnelDNS`、`ClashHaloApp.performCleanup`
//         —— 各自解释同一套 key
//
// 共用账本 + 多处独立解释，直接产出了审查里的两条高危：
//
//   高-1：退出清理用 2s 限时「尽力」恢复 DNS，**超时/失败也照清三个 key**。
//         账本一失忆，`restoreTunnelDNS()` 首行 guard 直接 return、reconcile
//         两个分支同时失明，系统 DNS 却仍钉在 198.18.x —— 只剩自带盲区的
//         sweep 兜底，于是「一开 TUN 就断网 / 退出后断网」。
//   高-2：代理模式写 127.0.0.1 时**不 pin 服务、不重新快照**，却和 TUN 共用
//         flag。默认服务在两次写入之间漂移（Wi-Fi ↔ 以太网）时，127.0.0.1 落到
//         pin 之外的服务上无人回收；内核一停，那个服务的解析全黑洞。
//
// 本文件把「谁改了系统 DNS、改的是哪个服务、原值是什么、写成功了没有」收敛成
// 唯一属主，其余文件只调 API、不再直接碰 key。
//
// ## 本层保证的不变量
//
// 1. **属主隔离**：`.tun` 与 `.proxy` 各持独立的 service pin + 快照，互不覆盖。
//    同一服务上发生接管时，新属主**继承**原属主的快照（这样最终还原到的是
//    「任何重定向之前」的真值，而不是中间态），并留下交接日志。
// 2. **快照只在读取成功时落盘**：`currentSystemDNS` 是三态（nil = 读取失败），
//    nil 绝不写成 "Empty"（中-3）。读取失败即放弃本轮重定向 —— 快照缺失意味着
//    将来无法还原，而重定向本身下一拍巡检还能重试，先写后失忆才是断网来源。
// 3. **pending → committed 两段式**：写系统 DNS **之前**先落 pending 记录，写成功
//    才转正，写失败立即回滚删除。既堵住「写完还没记账就崩溃」的窗口（旧实现
//    的真实盲区，sweep 的文档注释里记载过 2026-10-09 的现场），又保住「没有
//    写入就不留记录」的老不变量（:2887 记载的 flag-first desync 教训）。
// 4. **恢复失败保留账本**：`restore` 只在写成功后清 key；失败保留状态交下一拍
//    重试。这是 `restoreTunnelDNS` 原有语义，本层把它推广到**退出路径**（高-1）。
// 5. **服务漂移可自愈**：pin 的服务 ≠ 当前默认服务时，先把旧服务按快照还原，
//    再对新服务重新快照 + 重定向（中-4）。
//
// ## 排查入口
//
// 所有日志带 `[DNSLedger]` 前缀。生产调用方把 `log:` 传成 `logKernel`（落
// `~/Library/Logs/ClashHalo/app.log`），于是：
//
//     grep '\[DNSLedger\]' ~/Library/Logs/ClashHalo/app.log
//
// 即可看到完整记账链：谁接管了谁、pin 在哪个服务、快照是什么、写入成没成功、
// 恢复有没有被保留重试。
//
// ## 可测性
//
// 本文件不引用 `AppModel`/`EngineControl`、不带 `@MainActor`、无 UI：状态与决策
// 走注入的 `DNSLedgerStore`，系统 DNS 读写走注入的 `SystemDNSDriving`，日志走
// 注入的闭包。生产适配器 `EngineControlDNSDriver` 在 EngineControl.swift 末尾，
// 本文件保持零 impure 依赖（回归套件 Tests/DNSLedger 可单独编译真实源码）。

/// 系统 DNS 重定向的属主。
///
/// 两类属主对应两个真实写点，语义完全不同，必须分开记账：
/// - `.tun`：TUN 开启时把系统 DNS 指向 fake-ip 网关（198.18.x）。该地址**只在
///   隧道活着时**可达，隧道一死即全网解析黑洞 —— 所以它的账本绝不能丢。
/// - `.proxy`：系统代理 + `enhanced-mode: redir-host` 时把系统 DNS 指向
///   127.0.0.1:53（走 mihomo 的 DoH 上游防污染）。fake-ip 模式下该写点自行跳过
///   （见 `ensureProxyDNS`），因为 fake-ip 应答会让不走代理的应用连到不可路由
///   的假地址。
enum DNSRedirectOwner: String, CaseIterable {
    case tun
    case proxy

    /// 日志里的人话名字。
    var label: String {
        switch self {
        case .tun: return "TUN fake-ip 网关"
        case .proxy: return "系统代理 127.0.0.1"
        }
    }

    // MARK: key 命名空间
    //
    // `.tun` **沿用历史 key 名**：旧版本写下的记录（以及旧版本 Helper 死亡清理
    // 所依赖的现场）必须仍可读可清，升级不能把在账的重定向变成无主残留。
    // `.proxy` 使用独立命名空间 —— 这正是高-2 的结构性修复：两个写者不再共用
    // 一份快照/一个 flag。

    /// 「重定向已写入成功」标志。
    var overriddenKey: String {
        self == .tun ? "tun.dns.overridden" : "proxy.dns.overridden"
    }
    /// 重定向之前的原 DNS 快照（`"Empty"` 哨兵或逗号分隔列表）。
    var savedKey: String {
        self == .tun ? "tun.dns.saved" : "proxy.dns.saved"
    }
    /// 重定向写入的目标网络服务名（N9：默认服务会在 enable/restore 之间漂移）。
    var serviceKey: String {
        self == .tun ? "tun.dns.service" : "proxy.dns.service"
    }
    /// 「写入已发起但尚未确认」的 pending 标记（堵崩溃窗口）。
    var pendingKey: String {
        self == .tun ? "tun.dns.pending" : "proxy.dns.pending"
    }
}

/// 一条在账的重定向记录。
struct DNSLedgerRecord: Equatable {
    var owner: DNSRedirectOwner
    /// pin 住的网络服务名；`""` = 未 pin（旧版本代理写点的历史形态）。
    var service: String
    /// 原 DNS 快照；`""` = 快照缺失（同样是旧版本遗留形态）。
    var snapshot: String
    /// `false` = pending：写入已发起但未确认成功。
    var committed: Bool

    /// 日志用的一行摘要。
    var summary: String {
        "\(owner.label)｜服务 \(service.isEmpty ? "未 pin" : service)"
            + "｜快照 \(snapshot.isEmpty ? "缺失" : snapshot)"
            + "｜\(committed ? "已确认" : "pending")"
    }
}

/// 快照编解码（纯逻辑，无 I/O）。
enum DNSLedgerCodec {
    /// 「该服务本来没有配 DNS」的哨兵值。`networksetup -setdnsservers` 需要
    /// 字面量 `Empty` 才能清空，所以哨兵直接沿用这个字面量。
    static let emptySentinel = "Empty"

    /// DNS 列表 → 快照字符串。空列表编码成哨兵，不编码成 `""`
    /// （`""` 专表「快照缺失」，二者语义不同：前者是「确认过没有 DNS」）。
    static func encode(_ servers: [String]) -> String {
        let cleaned = servers.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? emptySentinel : cleaned.joined(separator: ",")
    }

    /// 快照字符串 → 要写回系统的 DNS 列表。
    ///
    /// `""`（快照缺失）与 `"Empty"` 都还原成 `["Empty"]`：清掉我们写的解析器、
    /// 让服务回到 DHCP 下发的 DNS。这与修复前 `restoreTunnelDNS` 的行为一致 ——
    /// 缺快照时宁可回到 DHCP，也不能把空列表写成一个语法错误的调用。
    static func decode(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != emptySentinel else { return [emptySentinel] }
        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let cleaned = parts.filter { !$0.isEmpty }
        return cleaned.isEmpty ? [emptySentinel] : cleaned
    }

    /// sweep 专用：从快照里剔除 fake-ip 地址后再决定写什么。
    ///
    /// 快照本身可能被污染（旧版本把 198.18.x 当「用户原值」存过），直接回写等于
    /// 把黑洞重新钉回去。剔完为空则回到 `["Empty"]`（DHCP）。
    static func sanitizedRestoreTarget(fromSnapshot raw: String) -> [String] {
        let kept = decode(raw).filter { $0 != emptySentinel && !TUNDNSAddress.isFakeIPResolver($0) }
        return kept.isEmpty ? [emptySentinel] : kept
    }
}

/// 记账存储抽象。生产用 UserDefaults，测试可注入内存实现。
protocol DNSLedgerStore: AnyObject {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    /// `nil` = 删除该键。
    func setString(_ value: String?, forKey key: String)
    func setBool(_ value: Bool, forKey key: String)
}

extension UserDefaults: DNSLedgerStore {
    func setString(_ value: String?, forKey key: String) {
        if let value { set(value, forKey: key) } else { removeObject(forKey: key) }
    }
    func setBool(_ value: Bool, forKey key: String) {
        set(value, forKey: key)
    }
}

/// 系统 DNS 的读写抽象。把「记账决策」与「真的去 fork networksetup」分开，
/// 前者才可测、可推理。
protocol SystemDNSDriving {
    /// 三态：nil = 读取失败（超时/无默认服务），`[]` = 确认没有配 DNS。
    func currentDNS(service: String?) async -> [String]?
    @discardableResult
    func applyDNS(_ servers: [String], service: String?) async -> Bool
    func defaultService() async -> String?
}

// 生产适配器 `EngineControlDNSDriver` 已移至 `Sources/XPC/EngineControl.swift`
// 末尾：Ledger 因此保持零 impure 依赖，回归套件 Tests/DNSLedger 可单独编译本
// 文件（套件提供同名 stub 满足 `TunnelDNSLedger.driver` 默认值的解析）。stub
// 边界钉在 `SystemDNSDriving` 协议上——协议一变套件即编译失败，不会静默漂移。

/// 系统 DNS 重定向记账的唯一属主。
///
/// 调用方（`enableTunnelDNS` / `ensureProxyDNS` / `restoreTunnelDNS` /
/// `sweepOrphanedTunnelDNS` / `performCleanup`）一律走这里的 API，
/// **不要再直接读写 `kDNS*Key`** —— 共用账本正是高-1/高-2 的成因。
enum TunnelDNSLedger {

    /// 可注入的存储（测试用内存实现替换）。
    static var store: DNSLedgerStore = UserDefaults.standard
    /// 可注入的系统 DNS 驱动（测试用假实现替换）。
    static var driver: SystemDNSDriving = EngineControlDNSDriver()
    /// 兜底日志汇。生产调用方通过 `log:` 参数传入 `logKernel`，让记账链落进
    /// app.log；未传时走 NSLog，保证任何路径都不会静默。
    static var logSink: (String) -> Void = { NSLog("[ClashHalo DNSLedger] %@", $0) }

    private static func emit(_ msg: String, _ log: ((String) -> Void)?) {
        let line = msg.hasPrefix("[DNSLedger]") ? msg : "[DNSLedger] " + msg
        (log ?? logSink)(line)
    }

    // MARK: 读

    /// 某属主当前在账的记录（含 pending）。nil = 该属主没有写过重定向。
    static func record(for owner: DNSRedirectOwner) -> DNSLedgerRecord? {
        let committed = store.bool(forKey: owner.overriddenKey)
        let pending = store.bool(forKey: owner.pendingKey)
        guard committed || pending else { return nil }
        return DNSLedgerRecord(owner: owner,
                               service: store.string(forKey: owner.serviceKey) ?? "",
                               snapshot: store.string(forKey: owner.savedKey) ?? "",
                               committed: committed)
    }

    /// 该属主是否持有已确认的重定向。等价于历史上直接读 `kDNSOverriddenKey`。
    static func isActive(_ owner: DNSRedirectOwner) -> Bool {
        store.bool(forKey: owner.overriddenKey)
    }

    /// 任一属主是否有在账记录（含 pending）。
    ///
    /// reconcile 用它替代裸读 `kDNSOverriddenKey`：只看 TUN 的 flag 会漏掉代理
    /// 属主的记录，而系统 DNS 是**一份全局状态**，两个属主任何一个在账都意味着
    /// 「当前系统 DNS 不是用户自己的」。
    static func isAnyActive() -> Bool {
        DNSRedirectOwner.allCases.contains { record(for: $0) != nil }
    }

    /// 当前在账的属主列表（诊断/日志用）。
    static func activeOwners() -> [DNSRedirectOwner] {
        DNSRedirectOwner.allCases.filter { record(for: $0) != nil }
    }

    /// 某属主 pin 的服务名（`""` = 未 pin）。sweep 用它决定扫哪些服务。
    static func pinnedService(for owner: DNSRedirectOwner) -> String {
        store.string(forKey: owner.serviceKey) ?? ""
    }

    // MARK: 写

    /// 把系统 DNS 重定向到 `servers`，并记账。幂等。
    ///
    /// 顺序（不变量 2/3/5）：
    /// 1. 解析目标服务（调用方未指定则取当前默认服务）；
    /// 2. **服务漂移**：本属主已 pin 的服务 ≠ 目标服务 → 先按快照还原旧服务，
    ///    再作废旧账（下面会对新服务重新快照）；
    /// 3. **属主接管**：另一属主在同一服务上在账 → 继承其快照、清其账；
    /// 4. 取快照：本属主已有同服务快照则沿用（保住最初真值），否则读系统 DNS，
    ///    **读取失败即放弃本轮、不写系统 DNS**；
    /// 5. 落 pending → 写系统 DNS → 成功转正 / 失败回滚删账。
    ///
    /// - Returns: 系统 DNS 是否确实被写成 `servers`。false 时账本已回滚，
    ///   调用方可以下一拍重试，不会留下「有账无写」或「有写无账」。
    @discardableResult
    static func redirect(owner: DNSRedirectOwner,
                         servers: [String],
                         service: String? = nil,
                         log: ((String) -> Void)? = nil) async -> Bool {
        // `??` 右侧不能直接 await（autoclosure 不支持并发），显式分支。
        let target: String?
        if let service, !service.isEmpty {
            target = service
        } else {
            target = await driver.defaultService()
        }
        let targetName = target ?? "默认"

        // 步骤 2：服务漂移（中-4）。旧 pin 服务上的重定向如果不先还原，就会变成
        // 无主残留 —— 用户把默认服务切回去的那一刻即解析黑洞。
        if let existing = record(for: owner),
           !existing.service.isEmpty,
           let target,
           existing.service != target {
            emit("\(owner.label)：默认服务已从 \(existing.service) 漂移到 \(target)，先还原旧服务再重定向新服务", log)
            let restoredOld = await driver.applyDNS(DNSLedgerCodec.decode(existing.snapshot),
                                                    service: existing.service)
            if restoredOld {
                emit("\(owner.label)：旧服务 \(existing.service) 已按快照还原", log)
            } else {
                // 旧服务还原失败不阻断新服务接管：新服务不接管就是当下的黑洞，
                // 旧服务的残留由 sweepOrphanedTunnelDNS 兜底（它按观测状态清理，
                // 不依赖账本）。
                emit("\(owner.label)：旧服务 \(existing.service) 还原失败，仍接管新服务（旧服务残留交 sweep 兜底）", log)
            }
            clear(owner: owner)
        }

        // 步骤 3：属主接管（高-2）。系统 DNS 是一份全局状态，两个属主同时在账
        // 只会让「还原到哪一份快照」变成猜谜。接管时继承原快照，保证最终能还原
        // 到「任何重定向之前」的真值。
        var inherited: String? = nil
        for other in DNSRedirectOwner.allCases where other != owner {
            guard let rec = record(for: other) else { continue }
            // 只在「同一处系统状态」上才算接管：服务相同，或对方未 pin
            // （旧版本代理写点的历史形态，它写的就是当时的默认服务）。
            guard rec.service.isEmpty || rec.service == (target ?? "") else { continue }
            inherited = rec.snapshot
            emit("\(owner.label) 接管 \(other.label) 的重定向（\(rec.summary)），继承其快照以保证可还原到任何重定向之前", log)
            clear(owner: other)
        }

        // 步骤 4：快照。已有同服务快照则沿用 —— 重新快照会把我们自己写进去的
        // 解析器当成「用户原值」存下来，那正是恢复后仍黑洞的成因。
        let snapshot: String
        if let existing = record(for: owner), existing.service == (target ?? "") {
            snapshot = existing.snapshot
            emit("\(owner.label)：沿用既有快照（\(snapshot)），不重复快照", log)
        } else if let inherited {
            snapshot = inherited
        } else {
            guard let original = await driver.currentDNS(service: target) else {
                // 不变量 2：读取失败 ≠ 没有 DNS。把 nil 当 [] 存成 "Empty"，
                // 恢复时就会把用户真实配置（可能是公司内网 DNS）洗成 DHCP。
                emit("\(owner.label)：读取服务 \(targetName) 的原 DNS 失败，放弃本轮重定向（快照缺失则将来无法还原，宁可不写）", log)
                return false
            }
            // 快照净化：剔除 fake-ip 段（198.18/198.19）的地址再存。
            //
            // 两种真实场景会让「当前系统 DNS」里已经带着 fake-ip 地址：
            //   · 我们自己上一次的重定向没记上账（崩溃/被杀/旧版本），此刻账本
            //     是空的，于是走到这个分支重新快照；
            //   · 别的内核留下的残留。
            // 直接把它当「用户原值」存下来，恢复时就会把黑洞地址重新钉回系统 ——
            // 判据与 sweep 用的是同一条（`TUNDNSAddress.isFakeIPResolver`）：
            // 没有用户会手填 198.18.x.x 当解析器。剔完为空即 "Empty"（回到 DHCP），
            // 那是快照不可知时唯一安全的答案。
            let cleaned = original.filter { !TUNDNSAddress.isFakeIPResolver($0) }
            if cleaned.count != original.count {
                let dropped = original.filter { TUNDNSAddress.isFakeIPResolver($0) }
                emit("\(owner.label)：快照剔除了 fake-ip 地址 \(dropped.joined(separator: ","))（那是重定向/残留，不是用户原值）", log)
            }
            snapshot = DNSLedgerCodec.encode(cleaned)
        }

        // 步骤 5：pending 先落盘，再写系统 DNS。
        writePending(DNSLedgerRecord(owner: owner,
                                     service: target ?? "",
                                     snapshot: snapshot,
                                     committed: false))
        let ok = await driver.applyDNS(servers, service: target)
        guard ok else {
            // 回滚：没有写入就不留记录。留着会让后续 restore「还原」一次从未
            // 发生过的重定向，健康巡检也会误判重定向仍在生效。
            clear(owner: owner)
            emit("\(owner.label)：写入 \(servers.joined(separator: ",")) 到服务 \(targetName) 失败，已回滚账本（系统 DNS 未变，待下拍重试）", log)
            return false
        }
        commit(owner: owner)
        emit("\(owner.label)：系统 DNS 已重定向到 \(servers.joined(separator: ","))（\(record(for: owner)?.summary ?? "记账缺失")）", log)
        return true
    }

    /// 还原某属主的系统 DNS 并清账。幂等：无账即视为成功。
    ///
    /// 不变量 4：**只在写成功后清 key**。写失败保留账本，让 reconcile /
    /// 下次启动 / sweep 继续重试 —— 这是高-1 的正解：退出路径过去无论成败都清账，
    /// 一次 2s 超时就永久失忆。
    ///
    /// - Returns: 是否已无需再还原（true = 本来就无账，或还原写成功）。
    @discardableResult
    static func restore(owner: DNSRedirectOwner,
                        log: ((String) -> Void)? = nil) async -> Bool {
        guard let rec = record(for: owner) else { return true }
        let servers = DNSLedgerCodec.decode(rec.snapshot)
        var ok = await driver.applyDNS(servers, service: rec.service.isEmpty ? nil : rec.service)
        if !ok, !rec.service.isEmpty {
            emit("\(owner.label)：原服务 \(rec.service) 不可用，回退当前默认服务", log)
            ok = await driver.applyDNS(servers, service: nil)
        }
        guard ok else {
            emit("\(owner.label)：恢复写入失败，**保留账本待重试**（\(rec.summary)）", log)
            return false
        }
        clear(owner: owner)
        emit("\(owner.label)：系统 DNS 已还原为 \(servers.joined(separator: ","))，账本已清", log)
        return true
    }

    /// 还原所有在账属主（退出清理、TUN+代理同时关闭时用）。
    ///
    /// 不短路：一个属主还原失败不影响另一个继续尝试。返回值是「是否全部无需
    /// 再还原」，调用方据此决定是否还需要下一拍重试。
    @discardableResult
    static func restoreAll(log: ((String) -> Void)? = nil) async -> Bool {
        var allOK = true
        for owner in DNSRedirectOwner.allCases {
            guard record(for: owner) != nil else { continue }
            let ok = await restore(owner: owner, log: log)
            allOK = allOK && ok
        }
        return allOK
    }

    /// 只清账本、不动系统 DNS。
    ///
    /// 供 sweep 使用：它按**观测到的系统状态**清理残留，清完某服务后账本已经
    /// 不再描述现实，此时应当清账（但只在整轮 sweep 没有残留/没有写失败时）。
    static func clear(owner: DNSRedirectOwner) {
        store.setBool(false, forKey: owner.overriddenKey)
        store.setBool(false, forKey: owner.pendingKey)
        store.setString(nil, forKey: owner.savedKey)
        store.setString(nil, forKey: owner.serviceKey)
    }

    /// 清空所有属主账本（仅诊断/测试用；生产路径请走 `restore`）。
    static func clearAll() {
        DNSRedirectOwner.allCases.forEach { clear(owner: $0) }
    }

    // MARK: 内部

    private static func writePending(_ rec: DNSLedgerRecord) {
        store.setString(rec.snapshot, forKey: rec.owner.savedKey)
        store.setString(rec.service, forKey: rec.owner.serviceKey)
        store.setBool(true, forKey: rec.owner.pendingKey)
        store.setBool(false, forKey: rec.owner.overriddenKey)
    }

    private static func commit(owner: DNSRedirectOwner) {
        store.setBool(true, forKey: owner.overriddenKey)
        store.setBool(false, forKey: owner.pendingKey)
    }
}
