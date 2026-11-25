import Foundation
import AppKit

// Built-in tailnet node — lifecycle and orchestration.
//
// The protocol work lives in the kernel (mihomo `type: tailscale`, tsnet in
// userspace). Everything here is orchestration: persisting intent, rendering
// the overlay through `EngineControl`, driving the interactive login, and
// telling the user the truths the kernel keeps to itself.
//
// Pure decisions belong in `TailscaleNode.swift`, which is compiled into the
// regression suite. Keep this file to I/O and state.

extension AppModel {

    // MARK: - Persistence

    private enum TSKey {
        static let enabled = "tailscale.enabled"
        static let nodeName = "tailscale.nodeName"
        static let hostname = "tailscale.hostname"
        static let controlURL = "tailscale.controlURL"
        static let exitNode = "tailscale.exitNode"
        static let acceptRoutes = "tailscale.acceptRoutes"
        static let udp = "tailscale.udp"
        static let autoRules = "tailscale.autoRules"
        static let magicDNS = "tailscale.magicDNSSuffix"
        static let includeCGNAT = "tailscale.includeCGNATRule"
        static let extraCIDRs = "tailscale.extraCIDRs"
        static let exitNodeAllowLAN = "tailscale.exitNodeAllowLANAccess"
        static let autoPeerRules = "tailscale.autoPeerRules"
        static let ephemeral = "tailscale.ephemeral"
        static let dialerProxy = "tailscale.dialerProxy"
        static let preferIPv6 = "tailscale.preferIPv6"
        /// Fingerprint of the credentials the *current* on-disk tsnet identity
        /// was registered with. Never the key itself — see `TailscaleIdentity`.
        static let identityFingerprint = "tailscale.identityFingerprint"
        /// TS-4：上次**成功应用**时的 peerIPs 快照（规范化后）。tsPeerRulesStale
        /// 与它比较，而不是与 engine plan 同拍比较（后者恒等，指示死掉）。
        static let appliedPeerIPs = "tailscale.appliedPeerIPs"
    }

    /// F13：浏览器登录等待上限。一次性授权码在服务端也会过期，本地把 watch
    /// （连同抬高的内核日志级别）无限挂下去没有意义；超时回落 .failed。
    private static let tsNeedsLoginCapSeconds: TimeInterval = 600

    /// When on, online device IPs from the API panel are merged into
    /// `tsSettings.peerIPs` before each overlay render. Off keeps the rule
    /// table stable for users who only want the CGNAT aggregate + hand CIDRs.
    /// Stored in UserDefaults (not `@AppStorage`) because this file is an
    /// extension — stored properties are illegal here.
    var tsAutoPeerRules: Bool {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: TSKey.autoPeerRules) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: TSKey.autoPeerRules) }
    }

    /// Restore intent at launch. Deliberately does *not* infer anything from
    /// config.yaml: a `type: tailscale` block left behind by a hand-edited
    /// profile is not a request to join a tailnet (same rule as the gateway
    /// switch — see AppModel+Config).
    func loadTailscalePrefs() {
        let d = UserDefaults.standard
        var s = TailscaleSettings()
        if let v = d.string(forKey: TSKey.nodeName), !v.isEmpty { s.nodeName = v }
        if let v = d.string(forKey: TSKey.hostname), !v.isEmpty { s.hostname = v }
        s.controlURL = d.string(forKey: TSKey.controlURL) ?? ""
        s.exitNode = d.string(forKey: TSKey.exitNode) ?? ""
        s.acceptRoutes = d.object(forKey: TSKey.acceptRoutes) as? Bool ?? true
        s.udp = d.object(forKey: TSKey.udp) as? Bool ?? true
        s.autoRules = d.object(forKey: TSKey.autoRules) as? Bool ?? true
        s.magicDNSSuffix = d.string(forKey: TSKey.magicDNS) ?? ""
        s.includeCGNATRule = d.object(forKey: TSKey.includeCGNAT) as? Bool ?? true
        s.exitNodeAllowLANAccess = d.object(forKey: TSKey.exitNodeAllowLAN) as? Bool ?? true
        s.ephemeral = d.object(forKey: TSKey.ephemeral) as? Bool ?? false
        s.dialerProxy = d.string(forKey: TSKey.dialerProxy) ?? ""
        s.preferIPv6 = d.object(forKey: TSKey.preferIPv6) as? Bool ?? false
        if let arr = d.array(forKey: TSKey.extraCIDRs) as? [String] {
            s.extraCIDRs = TailscaleOverlay.normalizeCIDRs(arr)
        }
        // peerIPs are derived from the live device list, not persisted — a
        // stale /32 for a machine that left the tailnet is worse than none.
        tsSettings = s
        tsEnabled = d.bool(forKey: TSKey.enabled)
        tsState = tsEnabled ? .idle : .disabled
        // Hand the engine the resolved plan so the very next `setConfig` —
        // including one triggered by a subscription update we did not initiate —
        // carries the node.
        syncTailscaleToEngine()

        // Check at launch whether the auth key has changed since the last run
        // (e.g. recovered from the Keychain mirror after a reinstall, or the
        // user swapped keys externally). If so, retire the old tsnet identity
        // directory so tsnet does not silently ignore the new key.
        if tsEnabled {
            retireTailscaleIdentityIfCredentialsChanged()
        }
    }

    func saveTailscalePrefs() {
        let d = UserDefaults.standard
        d.set(tsEnabled, forKey: TSKey.enabled)
        d.set(tsSettings.nodeName, forKey: TSKey.nodeName)
        d.set(tsSettings.hostname, forKey: TSKey.hostname)
        d.set(tsSettings.controlURL, forKey: TSKey.controlURL)
        d.set(tsSettings.exitNode, forKey: TSKey.exitNode)
        d.set(tsSettings.acceptRoutes, forKey: TSKey.acceptRoutes)
        d.set(tsSettings.udp, forKey: TSKey.udp)
        d.set(tsSettings.autoRules, forKey: TSKey.autoRules)
        d.set(tsSettings.magicDNSSuffix, forKey: TSKey.magicDNS)
        d.set(tsSettings.includeCGNATRule, forKey: TSKey.includeCGNAT)
        d.set(tsSettings.exitNodeAllowLANAccess, forKey: TSKey.exitNodeAllowLAN)
        d.set(tsSettings.extraCIDRs, forKey: TSKey.extraCIDRs)
        d.set(tsSettings.ephemeral, forKey: TSKey.ephemeral)
        d.set(tsSettings.dialerProxy, forKey: TSKey.dialerProxy)
        d.set(tsSettings.preferIPv6, forKey: TSKey.preferIPv6)
        syncTailscaleToEngine()
    }

    /// The single point where the Keychain secret and live peer IPs are merged
    /// into the plan. Nothing else may read or copy the auth key.
    private func syncTailscaleToEngine() {
        guard tsEnabled else { engine.tailscaleSettings = nil; return }
        var s = tsSettings
        s.authKey = KeychainHelper.read(key: kTailscaleAuthKey) ?? ""
        // TS-1 渲染兜底：extraCIDRs 无论来自哪条路径（API 导入 / 手工添加 /
        // 旧版本持久化数据），会劫持本机的前缀一律不进 engine plan。入口
        // （importAdvertisedSubnetRoutes / applyTailscaleSettings）负责带原因
        // 的 warnings；这里静默防御，保证 autoRules 渲染到的永远是干净输入。
        let localSubnets = PeerRouteGuard.localAttachedSubnets()
        s.extraCIDRs = s.extraCIDRs.filter {
            tsSubnetRejection($0, localSubnets: localSubnets) == nil
        }
        if tsAutoPeerRules {
            // Online peers only — offline /32s would black-hole until the next
            // refresh, which is worse than falling through to the CGNAT rule.
            s.peerIPs = tsDevices.filter(\.online).flatMap(\.ips)
        } else {
            s.peerIPs = []
        }
        engine.tailscaleSettings = s
    }

    // MARK: - Credentials

    var tailscaleAuthKey: String { KeychainHelper.read(key: kTailscaleAuthKey) ?? "" }
    var hasTailscaleAuthKey: Bool { !tailscaleAuthKey.isEmpty }

    func setTailscaleAuthKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.delete(key: kTailscaleAuthKey)
        } else {
            KeychainHelper.save(key: kTailscaleAuthKey, value: trimmed)
        }
        // A new key means a (possibly) different node or tailnet, but tsnet
        // *ignores* the key whenever the state directory already holds an
        // identity. Retire the old state now so the key actually gets used;
        // otherwise the user pastes a perfectly valid key and nothing happens.
        retireTailscaleIdentityIfCredentialsChanged()
        syncTailscaleToEngine()
    }

    // MARK: - Identity lifecycle

    /// Fingerprint of the credentials the on-disk identity was created with.
    private var tsStoredIdentityFingerprint: String {
        get { UserDefaults.standard.string(forKey: TSKey.identityFingerprint) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: TSKey.identityFingerprint) }
    }

    private var tsCurrentIdentityFingerprint: String {
        TailscaleIdentity.fingerprint(authKey: tailscaleAuthKey,
                                      controlURL: tsSettings.controlURL)
    }

    /// Retire the tsnet state directory when the credentials that produced it
    /// have changed. No-op on first use and when nothing changed. Decision
    /// logic lives in `TailscaleIdentity.retirementDecision` (pure, tested);
    /// this is just the Keychain/UserDefaults/filesystem side effects.
    @discardableResult
    func retireTailscaleIdentityIfCredentialsChanged() -> Bool {
        let decision = TailscaleIdentity.retirementDecision(
            hasAuthKey: hasTailscaleAuthKey,
            current: tsCurrentIdentityFingerprint,
            stored: tsStoredIdentityFingerprint)
        if let newStored = decision.newStored {
            tsStoredIdentityFingerprint = newStored
        }
        guard decision.retire else { return false }
        let retired = retireTailscaleStateDir()
        if retired {
            logKernel("内置 Tailnet：凭证已变更，已退休旧身份目录（新 key 才能生效）")
        }
        return retired
    }

    /// Move the tsnet state directory aside so the next start registers fresh.
    ///
    /// Deleting outright usually fails: the kernel runs as root (single-identity
    /// rule), so `tailscale/` and its contents are root-owned and a user-mode
    /// `removeItem` cannot unlink files *inside* it. Renaming works anyway —
    /// POSIX only requires write+execute on the **parent** directory, which is
    /// the user-owned Application Support folder. That is the whole trick that
    /// makes 「清除身份」 work without adding a privileged XPC call.
    @discardableResult
    func retireTailscaleStateDir() -> Bool {
        let fm = FileManager.default
        let path = engine.tailscaleStateDirPath
        guard fm.fileExists(atPath: path) else { return false }
        // Best case: we own it (kernel never ran as root) — just delete.
        if (try? fm.removeItem(atPath: path)) != nil {
            logKernel("内置 Tailnet：已删除身份目录 \(path)")
            pruneRetiredTailscaleIdentities()
            return true
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = "\(path).retired-\(stamp)"
        do {
            try fm.moveItem(atPath: path, toPath: aside)
            logKernel("内置 Tailnet：身份目录归 root，已改名让位 → \(aside)")
            pruneRetiredTailscaleIdentities()
            return true
        } catch {
            logKernel("内置 Tailnet：无法退休身份目录（\(path)）：\(error.localizedDescription)")
            return false
        }
    }

    /// F14：`.retired-<stamp>` 目录只保留最近 1 份，其余尽力清理。
    /// root 属主的 retired 目录在用户态删不掉（与改名让位同一个原因：
    /// 删除需要目录**内部**的写权限），失败就跳过、不阻塞主流程——
    /// 下一次退休还会再试。只匹配 `tailscale.retired-` 精确前缀，不碰别的。
    private func pruneRetiredTailscaleIdentities() {
        let fm = FileManager.default
        let path = engine.tailscaleStateDirPath
        let parent = (path as NSString).deletingLastPathComponent
        let prefix = (path as NSString).lastPathComponent + ".retired-"
        guard let entries = try? fm.contentsOfDirectory(atPath: parent) else { return }
        let retired = entries.filter { $0.hasPrefix(prefix) }
        guard retired.count > 1 else { return }
        // 按时间戳降序；非数字后缀视为最旧。最新一份（刚改名让位的）保留。
        let sorted = retired.sorted {
            (Int($0.dropFirst(prefix.count)) ?? -1) > (Int($1.dropFirst(prefix.count)) ?? -1)
        }
        for name in sorted.dropFirst() {
            let full = (parent as NSString).appendingPathComponent(name)
            if (try? fm.removeItem(atPath: full)) != nil {
                logKernel("内置 Tailnet：已清理过期退休身份目录 \(name)")
            }
        }
    }

    /// Control-plane API token used only for the device panel. Distinct from
    /// the auth key: one joins the tailnet as a node, the other reads the
    /// admin API. Never written into config.yaml.
    var tailscaleAPIToken: String { KeychainHelper.read(key: kTailscaleAPIToken) ?? "" }
    var hasTailscaleAPIToken: Bool { !tailscaleAPIToken.isEmpty }

    func setTailscaleAPIToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.delete(key: kTailscaleAPIToken)
        } else {
            KeychainHelper.save(key: kTailscaleAPIToken, value: trimmed)
        }
        // Token change invalidates the cached list so the next open refetches.
        tsDevices = []
        tsDevicesError = nil
        tsDevicesFetchedAt = .distantPast
    }

    /// Direct-egress session for the Tailscale API. Same rationale as
    /// `KernelManager`: with system proxy ON, a default session would dial
    /// `api.tailscale.com` through our own mixed-port and hang.
    private static let tsAPISession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.connectionProxyDictionary = [:]
        config.httpAdditionalHeaders = [
            "User-Agent": "ClashHalo",
            "Accept": "application/json"
        ]
        return URLSession(configuration: config)
    }()

    /// Pull the device list. Cheap enough to call on page open; rate-limited
    /// to once per 30 s unless `force` is set.
    func refreshTailscaleDevices(force: Bool = false) {
        guard hasTailscaleAPIToken else {
            tsDevices = []
            tsDevicesError = nil
            return
        }
        // F17：空列表也吃限频。旧条件 `!tsDevices.isEmpty` 让「tailnet 里就是
        // 没有别的设备」的账号每次开页都打一次真实 API。首次拉取不受影响
        // （tsDevicesFetchedAt 初值 .distantPast）；失败不更新 fetchedAt，
        // 错误重试节奏维持原样。
        if !force, Date().timeIntervalSince(tsDevicesFetchedAt) < 30 {
            return
        }
        guard !tsDevicesLoading else { return }
        tsDevicesLoading = true
        tsDevicesError = nil
        let token = tailscaleAPIToken
        Task {
            // Decode and suffix-infer from the same raw body so we do not pay
            // for a second round-trip just to read the FQDN field.
            let result = await TailscaleAPI.fetchDevicesWithSuffix(token: token, session: Self.tsAPISession)
            await MainActor.run {
                self.tsDevicesLoading = false
                switch result {
                case .success(let (devices, suffix)):
                    // Equality short-circuit: the panel is a published array
                    // and re-assigning an identical list still wakes observers.
                    if devices != self.tsDevices { self.tsDevices = devices }
                    self.tsDevicesError = nil
                    self.tsDevicesFetchedAt = Date()
                    // Peer IPs feed the overlay; keep the engine plan current
                    // so the next 应用配置 / setConfig picks them up without a
                    // second round-trip through saveTailscalePrefs.
                    self.syncTailscaleToEngine()
                    self.refreshTailscaleLocalAddress()
                    // Prefer a discovered MagicDNS suffix over the generic
                    // `ts.net` when one shows up in a device's FQDN. Do not
                    // auto-apply: that would rewrite rules without the user
                    // hitting 应用配置. Surface it as a suggestion only.
                    if self.tsSettings.magicDNSSuffix.isEmpty, let suffix {
                        let note = "设备列表显示 MagicDNS 后缀 .\(suffix)，可填入上方以收窄规则"
                        if !self.tsWarnings.contains(note) {
                            self.tsWarnings.append(note)
                        }
                    }
                case .failure(let err):
                    self.tsDevicesError = TailscaleAPI.describe(err)
                    // On auth failure clear the stale list so the UI does not
                    // keep showing devices the token can no longer see.
                    if case .http(let code) = err, code == 401 || code == 403 {
                        self.tsDevices = []
                    }
                }
            }
        }
    }

    /// 设备列表 + MagicDNS 后缀推断收敛在 `TailscaleAPI.fetchDevicesWithSuffix`
    /// （与 fetchDevices 共用同一份 URL/Bearer/超时拼装与翻页循环）；此处不再
    /// 保留复制体。

    /// Pick an exit node from the device panel. Empty string clears it.
    /// Does not auto-apply — the user still has to hit 应用配置, same as every
    /// other field on this page. That keeps a mis-tap from reloading the kernel.
    func selectTailscaleExitNode(_ device: TailscaleDevice?) {
        if let device {
            // Prefer a stable IPv4 address; hostname is accepted by mihomo too
            // but an IP survives DNS hiccups during the apply window.
            tsSettings.exitNode = device.ips.first ?? device.hostname
        } else {
            tsSettings.exitNode = ""
        }
    }

    // MARK: - Capability probe

    /// One `mihomo -t` against a throwaway home directory. Cheap enough to run
    /// when the page opens, and the only trustworthy answer: the outbound sits
    /// behind build tags, so a new-enough version number proves nothing.
    func probeTailscaleSupport() {
        guard tsSupported == nil else { return }
        Task {
            let ok = await engine.supportsTailscale()
            tsSupported = ok
            if !ok {
                tsWarnings = ["当前内核不含 Tailscale 出站（需 mihomo v1.19.25+ 且带 with_gvisor 构建），"
                              + "请到「网络 → 内核」升级内核"]
            }
        }
    }

    // MARK: - Enable / apply

    // MARK: - TS-MUX 互斥（内置 Tailnet vs 系统 Tailscale 客户端）

    /// TS-MUX：系统 Tailscale 的「存在」分两级。真正会伤到内置节点的是
    /// **正在运行**的系统客户端——它占住 100.64/10 的 utun，共存层才会为它
    /// 把 100.64/10 排除出 TUN、ts.net 挡出 fake-ip，而内置节点恰靠这两段
    /// 流量进 TUN，同开双输。只装了 CLI/App 却没有那张接口时，内置节点照常
    /// 可用；旧实现「装了就算」还把 tsEnabled=false 写进 UserDefaults，入口
    /// 闸又拦着重开，homebrew 只装 CLI 的用户被永久关掉且没有 UI Undo 路径。
    private enum SystemTailscalePresence {
        case none
        case installedOnly
        case running
    }

    private func systemTailscalePresence() -> SystemTailscalePresence {
        let fm = FileManager.default
        let installPaths = [
            "/Applications/Tailscale.app",
            NSHomeDirectory() + "/Applications/Tailscale.app",
            "/usr/local/bin/tailscale",      // 官方 App 创建的 CLI 链接
            "/opt/homebrew/bin/tailscale"     // homebrew 独立安装（可无 GUI 跑 tailscaled）
        ]
        let installed = installPaths.contains(where: { fm.fileExists(atPath: $0) })
        // TS-MUX：running = tailnet utun 在位**且**本机确有 Tailscale 安装。
        // `.tailscale` 的判据只是 RFC 6598 CGNAT 网段（100.64/10），Cloudflare
        // WARP、自建 WireGuard mesh 同样使用该段——只看网段会把它们误判成
        // 「系统客户端运行中」，回退闸随即持久化 tsEnabled=false 并拦住重开，
        // 把共存层的低后果流量判据升级成写盘的用户状态变更。叠加 isUp 与
        // 安装检查后，唯一已知假阳是「WARP/自建 mesh + 装了 Tailscale CLI
        // 同时在线」——极小众，且此时内置节点确实也进不了 100.64/10，回退
        // 未必是错，接受并记录。
        let tailnetIfaceUp = NetScanner.interfaces().contains(where: {
            $0.kind == .tailscale && $0.isUp
        })
        if tailnetIfaceUp, installed { return .running }
        return installed ? .installedOnly : .none
    }

    /// 运行时钩子（handleNetworkChange）用：系统客户端是否**正在运行**。
    /// 枚举保持 private，这里只暴露布尔语义，避免 presence 三态泄漏成公共 API。
    func systemTailscaleClientRunning() -> Bool {
        systemTailscalePresence() == .running
    }

    /// TS-MUX：互斥二选一的自动回退——检测到系统客户端**正在运行**时关掉
    /// 内置 Tailnet、从运行配置撤除 overlay，并提示用户二选一。返回是否回退。
    ///
    /// 只装了 CLI/App 不算：没有 tailnet utun 就没有 100.64/10 的流量冲突，
    /// 内置节点可以照常用；把它一并关掉且不给 UI Undo，是审查指出的过度反应。
    ///
    /// 撤 overlay 不能省：残留的 `ts://Tailnet` DNS 策略与规则会把 ts.net
    /// 劫持进一个不会再被拨号的节点，正好废掉刚装好的系统客户端——旧实现
    /// 只挂警告不动手（"Reported, never auto-corrected"），而共存层同时为
    /// 保护客户端把 100.64/10 排除出 TUN、ts.net 挡出 fake-ip，内置节点恰恰
    /// 又靠这两段流量进 TUN，同开必然双输。这是 v1.5.3 三 BUG 之二的根因。
    @discardableResult
    func fallbackTailnetForSystemClient() async -> Bool {
        guard tsEnabled, systemTailscalePresence() == .running else { return false }
        logKernel("内置 Tailnet：检测到系统 Tailscale 客户端正在运行，自动停用内置节点（两者互斥）")
        tsEnabled = false
        saveTailscalePrefs()          // engine.tailscaleSettings → nil，后续写盘不再注入
        stopTailscaleLoginWatch()
        tsState = .disabled
        tsWarnings = []
        tsDevices = []
        tsLocalIPs = []
        tsLocalDNSName = ""
        // 状态回退是同步的，所以 overlay 撤除必须确定性完成：withEngineBusy
        // 是 fire-and-forget，busy 时会直接丢掉 body，而 refreshConfigs 只读
        // 不写，运行内核会长期残留 ts://Tailnet 与 100.64 规则。awaitEngineIdle
        // 有界等待后真正 await body，失败时留日志、不留假状态。
        let removed = await awaitEngineIdle("停用内置 Tailnet（回撤 overlay）") {
            await self.reloadWithTailscaleOverlay()   // 从运行内核剥掉节点/围栏/规则
        }
        if removed == true {
            showToast("系统 Tailscale 客户端正在运行，已停用内置 Tailnet（二者互斥）", kind: .warn)
        } else {
            // TS-MUX-R：撤除未确认（nil = 等待内核空闲超时；false = body 跑了
            // 但重载失败）。此刻 tsEnabled=false 已持久化，而运行内核可能仍残留
            // `ts://Tailnet` DNS 策略与 100.64 规则——残留会把 ts.net 劫持进一个
            // 不会再拨号的节点，正好废掉刚启动的系统客户端（本函数头注释批判的
            // "Reported, never auto-corrected" 同型缺陷，不能只留一条日志就发
            // 「已停用」的成功 toast）。如实相告 + 有界重试兜底。
            let reason = removed == nil ? "等待内核空闲超时" : "撤除重载失败"
            logKernel("内置 Tailnet：\(reason)，overlay 仍在运行配置中，已调度 30s×3 自动重试剥除")
            // 文案保持一行可完整显示（toast 通道 lineLimit(1)），细节看日志与告警卡。
            showToast("内置 Tailnet 已停用，撤除未确认（\(reason)），将自动重试", kind: .warn)
            scheduleTailnetOverlayRemovalRetry(remaining: 3)
        }
        return true
    }

    /// TS-MUX-R：overlay 撤除失败后的有界自动重试（30s 间隔，至多 `remaining` 次）。
    ///
    /// 单链保证：调用方 `fallbackTailnetForSystemClient` 的入口 guard 要求
    /// tsEnabled=true，回退后立刻置 false，因此同一条重试链不会叠加；重试期间
    /// 用户重新打开内置节点（setTailscaleEnabled）则直接退出——那时的正确动作
    /// 是注入 overlay，不是剥除。任务被取消/入睡时安静放弃，残留等下一次
    /// fallback 或配置写入剥掉（任何 setConfig 都会按 nil settings 重写剥离）。
    private func scheduleTailnetOverlayRemovalRetry(remaining: Int) {
        guard remaining > 0 else {
            logKernel("内置 Tailnet：overlay 剥除重试已用尽，残留待下次配置写入或重启后清理")
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, !self.sleeping, self.tsEnabled == false else { return }
            let removed = await self.awaitEngineIdle("内置 Tailnet 撤除重试") {
                await self.reloadWithTailscaleOverlay()
            }
            if removed == true {
                self.logKernel("内置 Tailnet：残留 overlay 已在重试中剥除")
            } else {
                self.logKernel("内置 Tailnet：撤除重试第 \(4 - remaining) 次未确认，剩余 \(remaining - 1) 次")
                self.scheduleTailnetOverlayRemovalRetry(remaining: remaining - 1)
            }
        }
    }

    /// Turn the built-in node on or off, and push the result into the kernel.
    ///
    /// Adding a proxy requires a full config reload — `PATCH /configs` cannot
    /// do it — so this is a heavyweight, user-initiated operation and goes
    /// through `withEngineBusy` like every other one.
    func setTailscaleEnabled(_ on: Bool) {
        guard on != tsEnabled else { return }
        if on, tsSupported == false {
            showToast("当前内核不支持 Tailscale 出站，请先升级内核", kind: .error)
            return
        }
        // TS-MUX：互斥入口闸——只在系统客户端**正在运行**时拒绝开启；只装了
        // CLI/App 不拦，用户仍可手动开内置节点（回退路径见 fallback…）。
        if on, systemTailscalePresence() == .running {
            showToast("系统 Tailscale 客户端正在运行，请关闭后使用内置 Tailnet", kind: .error)
            return
        }
        withEngineBusy(on ? "启用内置 Tailnet" : "关闭内置 Tailnet") { [weak self] in
            guard let self else { return }
            self.tsEnabled = on
            self.saveTailscalePrefs()
            let ok = await self.reloadWithTailscaleOverlay()
            if !ok {
                // Do not leave the switch claiming a state the kernel refused,
                // and do not leave the node in a file the kernel never accepted
                // — rewrite the config to match the state we just rolled back to.
                self.tsEnabled = !on
                self.saveTailscalePrefs()
                self.engine.applyTailscaleOverlay()
                // TS-6：reloadWithTailscaleOverlay 已把失败原因置入 .failed
                // （重载失败 / overlay 注入失败）。回滚开关意图，但保留失败态，
                // 让 UI 的失败卡片与 warningCard 把原因说出来。
                if !self.tsState.isTerminalFailure {
                    self.tsState = self.tsEnabled ? .idle : .disabled
                }
                return
            }
            self.tsState = on ? .idle : .disabled
            if on {
                self.refreshTailscaleEnvironmentWarnings()
                self.refreshTailscaleDevices()
                self.showToast(self.hasTailscaleAuthKey
                               ? "内置 Tailnet 已启用，正在注册节点…"
                               : "内置 Tailnet 已启用，请完成浏览器登录", kind: .ok)
                // Without this the node is only *written* to config — tsnet is
                // lazy, so nothing would ever contact the control plane and an
                // entirely valid auth key would look broken.
                self.warmUpTailscale()
            } else {
                self.stopTailscaleLoginWatch()
                self.tsWarnings = []
                self.tsDevices = []
                self.tsLocalIPs = []
                self.tsLocalDNSName = ""
                self.showToast("内置 Tailnet 已关闭", kind: .ok)
            }
        }
    }

    /// Re-render the overlay after a settings change (hostname, exit node, …).
    ///
    /// Name repair happens here rather than per keystroke: a name is only
    /// invalid as a whole, and fixing it while the user is still typing makes
    /// ordinary names impossible to enter.
    func applyTailscaleSettings() {
        tsSettings.nodeName = TailscaleName.sanitize(tsSettings.nodeName)
        tsSettings.hostname = TailscaleName.sanitizeHostname(tsSettings.hostname)
        tsSettings.extraCIDRs = TailscaleOverlay.normalizeCIDRs(tsSettings.extraCIDRs)
        // TS-1：手工 CIDR 与通告导入走同一道安全闸门——链路专用前缀、本机
        // 直连网段、fake-ip 段、默认路由一律不进 extraCIDRs（否则 IP-CIDR
        // 规则插在表头，本机 LAN 流量全进 tailnet 黑洞）。被拒条目带原因
        // 进 warnings；注意 reload / 环境巡检会整份重建 tsWarnings，所以
        // noteRejectedSubnets 必须放在它们**之后**调用。
        let localSubnets = PeerRouteGuard.localAttachedSubnets()
        let rejectedCIDRs = tsSettings.extraCIDRs.compactMap { cidr -> String? in
            guard let reason = tsSubnetRejection(cidr, localSubnets: localSubnets) else { return nil }
            return "\(cidr)（\(reason)）"
        }
        if !rejectedCIDRs.isEmpty {
            tsSettings.extraCIDRs.removeAll {
                tsSubnetRejection($0, localSubnets: localSubnets) != nil
            }
        }
        if let normalized = TailscaleOverlay.normalizeControlURL(tsSettings.controlURL) {
            tsSettings.controlURL = normalized
        } else {
            showToast("控制服务器地址无效：需要 http(s):// 开头的完整 URL", kind: .error)
            return
        }
        // TS-5：controlURL 是身份指纹的一部分——官方 ↔ Headscale 切换就是
        // 另一个身份，即使 key 文本没变。与换 key 同待遇：退休旧 state 目录，
        // 否则 tsnet 沿用旧身份、静默忽略新控制面。判定表在 TailscaleIdentity
        // （无 auth-key 的浏览器登录路径不退休，维持既有契约）。
        retireTailscaleIdentityIfCredentialsChanged()
        guard tsEnabled else {
            saveTailscalePrefs()
            noteRejectedSubnets(rejectedCIDRs)
            return
        }
        withEngineBusy("更新内置 Tailnet") { [weak self] in
            guard let self else { return }
            self.saveTailscalePrefs()
            let ok = await self.reloadWithTailscaleOverlay()
            if ok {
                self.refreshTailscaleEnvironmentWarnings()
            }
            // 放在 reload / 环境巡检之后，warnings 才不会被整份重建冲掉。
            self.noteRejectedSubnets(rejectedCIDRs)
            if ok {
                self.showToast("内置 Tailnet 配置已更新", kind: .ok)
                // A reload builds a brand-new `tsnet.Server`, which is lazy
                // again — wake it so the new settings actually take effect.
                self.warmUpTailscale()
            }
        }
    }

    /// Push the current on-disk config back through `setConfig`, which re-applies
    /// every runtime override — including the tailnet overlay — and reloads.
    ///
    /// Feeding the file back to itself looks odd but is the honest path: the
    /// overrides are idempotent by construction, and this keeps exactly one
    /// place that knows how a config reaches the kernel.
    func reloadWithTailscaleOverlay() async -> Bool {
        // setConfig 现在会按运行态保留 TUN（见其内部 persistTunState 调用），
        // 这里补上与配置切换路径同款的兜底：reload 万一仍把 TUN 拆掉（内核
        // normalize/拒绝文件值），从运行态重新拉起，而不是等 30 s 巡检去报
        // 「接口丢失」再走自动关→自动开的闪烁循环。
        let wasTunOn = tunOn
        guard let text = try? String(contentsOfFile: engine.configFilePath, encoding: .utf8) else {
            showToast("读取配置失败", kind: .error)
            return false
        }
        let r = await engine.setConfig(text)
        tsWarnings = engine.tailscaleWarnings
        if engine.tailscaleDNSSkipped && tsEnabled {
            tsWarnings.append("配置中没有启用的 dns 段落，未写入 MagicDNS 解析策略；"
                              + "*.ts.net 名字可能解析不到（IP 直连不受影响）")
        }
        for w in tsWarnings { logKernel("内置 Tailnet：\(w)") }
        guard r.ok else {
            showToast("配置重载失败：\(r.error ?? "未知错误")", kind: .error)
            tsState = .failed(reason: r.error ?? "配置重载失败")
            return false
        }
        // TS-6 / 契约 C6：reload 成功 ≠ 节点注入成功。setConfig 里 overlay
        // 注入失败只记 warning、不打断 reload——旧实现据此报「已启用」，
        // 开关亮着但内核根本没有节点。读 C6 字段如实判失败；具体原因已在
        // 上面拷进 tsWarnings（warningCard 展示）。
        if tsEnabled && !engine.lastOverlayInjectionOK {
            showToast("Tailnet 节点注入失败，配置未生效（原因见「需要注意」）", kind: .error)
            tsState = .failed(reason: "Tailnet 节点注入失败")
            return false
        }
        // TS-4：只有真正应用成功才记录 peerIPs 快照——tsPeerRulesStale 的
        // 比较基线。注入失败时内核没有节点，不能算「已应用」。
        tsAppliedPeerIPs = TailscaleOverlay.normalizePeerIPs(
            engine.tailscaleSettings?.peerIPs ?? [])
        // 同配置切换路径的兜底顺序：reload 后先刷新运行态，再在 TUN 意外掉线
        // 时走完整 enable 流程拉回（root 切换 + PATCH + 接口 pin）。
        await refreshConfigs()
        if wasTunOn && !tunOn {
            await reapplyTUN(wasOn: true)
        }
        return true
    }

    // MARK: - Environment conflicts

    /// The one conflict that makes the feature silently useless: a system
    /// Tailscale client already owns 100.64/10 on this machine.
    ///
    /// TS-MUX：这里不再只是挂一条警告——旧实现 "Reported, never
    /// auto-corrected"（共存层为保护系统客户端排除 100.64/10、内置节点恰靠
    /// 这段流量进 TUN，同开双输）正是 v1.5.3 Tailnet 完全不可用的根因。
    /// 现在检测到系统客户端在运行即自动回退并提示二选一；只装了 CLI/App 则
    /// 明确告知「内置节点仍可用」，不再悄悄把用户开关关掉。
    func refreshTailscaleEnvironmentWarnings() {
        guard tsEnabled else { tsWarnings = []; return }
        let presence = systemTailscalePresence()
        if presence == .running {
            Task { await fallbackTailnetForSystemClient() }
            return
        }
        var warnings = engine.tailscaleWarnings
        if presence == .installedOnly {
            // 不回退：没有 tailnet utun 就没有 100.64/10 的流量冲突。给出
            // 说明型提示（追加而非整份替换，其余告警照常保留），让用户知道
            // 两个客户端并存时谁会主动让路。
            warnings.append("检测到本机安装了 Tailscale 客户端/CLI，但未在运行；"
                            + "内置节点可正常使用。启动系统客户端后会自动停用内置节点（二者互斥）")
        }
        if !tsSettings.exitNode.isEmpty && !tsSettings.exitNode.hasPrefix("auto:") {
            warnings.append("已指定出口节点：内核在选中失败时只记警告、不报错，"
                            + "请在日志中确认没有 set exit node failed")
        }
        // Gateway mode sends LAN clients through this node. Without an exit
        // node they can only reach tailnet destinations; with one, LAN access
        // back into the house needs exit-node-allow-lan-access (default on).
        if gatewayModeOn {
            if tsSettings.exitNode.isEmpty {
                warnings.append("网关模式已开启：局域网客户端只能访问 tailnet 内目标；"
                                + "要让它们经 tailnet 出公网，请配置出口节点")
            } else if !tsSettings.exitNodeAllowLANAccess {
                warnings.append("网关模式 + 出口节点：建议开启「出口节点允许访问局域网」，"
                                + "否则 LAN 客户端出网后可能回不了内网")
            }
        }
        if !tunOn {
            warnings.append("未开启 TUN：裸 TCP（如 ssh 100.x）不会进入分流，"
                            + "只有走代理端口的流量能命中 tailnet 规则")
        }
        // The tsnet library embedded in mihomo reports its Tailscale client
        // version to the control plane. If the version is older than what the
        // console expects, the console shows "version too low" and refuses
        // certain operations (e.g. editing the node IP). This is a kernel-level
        // limitation — ClashHalo cannot fix it, only surface it.
        warnings.append("内置节点使用 mihomo 内嵌的 tsnet 库，Tailscale 控制面可能提示"
                        + "「版本过低」并拒绝编辑 IP。请使用 hostname + MagicDNS 名称访问本节点，"
                        + "或升级到更新的 mihomo 内核版本")

        tsWarnings = warnings
    }

    /// Merge API-advertised subnet routes into `extraCIDRs` (user still has to
    /// hit 应用配置). Returns how many *new* CIDRs were added.
    @discardableResult
    func importAdvertisedSubnetRoutes() -> Int {
        // TS-1：subnet router 通告与本机同段 LAN 时，导入 = 把本机 LAN 劫进
        // tailnet 黑洞。候选在 API 侧就过闸门（谓词注入，保持 TailscaleAPI
        // 纯逻辑可独立编译）；被拒条目带原因进 warnings。
        let localSubnets = PeerRouteGuard.localAttachedSubnets()
        let gate: (String) -> Bool = {
            self.tsSubnetRejection($0, localSubnets: localSubnets) != nil
        }
        let suggested = TailscaleAPI.suggestedSubnetRoutes(from: tsDevices, isForbidden: gate)
        let rejected = TailscaleAPI.suggestedSubnetRoutes(from: tsDevices)
            .compactMap { cidr -> String? in
                guard let reason = self.tsSubnetRejection(cidr, localSubnets: localSubnets)
                else { return nil }
                return "\(cidr)（\(reason)）"
            }
        noteRejectedSubnets(rejected)
        guard !suggested.isEmpty else { return 0 }
        var existing = Set(tsSettings.extraCIDRs)
        var added = 0
        for cidr in suggested where existing.insert(cidr).inserted {
            tsSettings.extraCIDRs.append(cidr)
            added += 1
        }
        if added > 0 {
            // Persist the list so a quit before 应用配置 does not lose the import,
            // but do not reload the kernel — that is still the user's call.
            saveTailscalePrefs()
            showToast("已加入 \(added) 条通告子网，点「应用配置」后生效", kind: .ok)
        } else {
            showToast("没有新的通告子网可导入", kind: .info)
        }
        return added
    }

    /// TS-1 安全闸门：返回拒绝原因，nil = 放行。判据复用 GUI/Helper 共用的
    /// `PeerRouteGuard.isForbidden`（链路专用前缀 + 本机直连网段），另拒
    /// fake-ip 段（198.18.0.0/15 与 v6 默认段 fdfe:dcba:9876::/64，口径同
    /// DirectExclusionPlanner.hardRejection）与默认路由。
    /// localSubnets 用现有快照来源 `PeerRouteGuard.localAttachedSubnets()`
    /// （getifaddrs 直读，与 Coexistence 同源）。
    /// internal：TailscalePage 预览计数与导入入口同口径过闸（fix-ui 消费）。
    func tsSubnetRejection(_ cidr: String, localSubnets: [String]) -> String? {
        if cidr == "0.0.0.0/0" || cidr == "::/0" {
            return "默认路由，请用出口节点"
        }
        if RouteTable.overlaps(cidr, "198.18.0.0/15")
            || RouteTable.overlaps(cidr, "fdfe:dcba:9876::/64") {
            return "与 fake-ip 段重叠"
        }
        if PeerRouteGuard.isForbidden(cidr, localSubnets: localSubnets) {
            return "链路专用前缀或本机直连网段"
        }
        return nil
    }

    /// TS-1：被拒子网进 warnings（UI warningCard 已有展示位）+ toast + 日志。
    /// 调用时机：必须在 reload / refreshTailscaleEnvironmentWarnings 之后——
    /// 两者都会整份重建 tsWarnings，先 append 会被冲掉。
    private func noteRejectedSubnets(_ rejected: [String]) {
        guard !rejected.isEmpty else { return }
        let w = "已忽略不安全子网：" + rejected.joined(separator: "、")
        if !tsWarnings.contains(w) { tsWarnings.append(w) }
        logKernel("内置 Tailnet：\(w)")
        showToast("已忽略 \(rejected.count) 条不安全子网，详见「需要注意」", kind: .warn)
    }

    /// TS-4：上次成功应用时的 peerIPs 快照。存 UserDefaults 而非存储属性——
    /// 本文件是 extension（与 tsAutoPeerRules 同一理由）。
    private var tsAppliedPeerIPs: [String] {
        get { UserDefaults.standard.array(forKey: TSKey.appliedPeerIPs) as? [String] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: TSKey.appliedPeerIPs) }
    }

    /// Whether the live device list implies peer /32 rules the kernel does not
    /// yet have. Soft signal only — never auto-reloads.
    var tsPeerRulesStale: Bool {
        guard tsEnabled, tsAutoPeerRules, !tsDevices.isEmpty else { return false }
        let live = Set(TailscaleOverlay.normalizePeerIPs(
            tsDevices.filter(\.online).flatMap(\.ips)
        ))
        // TS-4：与「上次成功应用」的快照比。旧实现与 engine plan 比，而
        // syncTailscaleToEngine 在设备刷新的同一拍就更新 plan——planned 恒等
        // 于 live，「设备已变化」提示永不出现（死指示）。
        let applied = Set(tsAppliedPeerIPs)
        return live != applied
    }

    // MARK: - Interactive login

    /// Start the browser sign-in flow.
    ///
    /// Two kernel facts shape this:
    ///   * tsnet starts lazily (`ensureStarted` is a `sync.Once` driven by the
    ///     first dial), so a node nobody routed to never contacts the control
    ///     plane and never prints a login URL. We have to dial it ourselves.
    ///   * the URL arrives on tsnet's `UserLogf`, which mihomo maps to an
    ///     *info*-level log line prefixed `[Tailscale](<node>)`. So we watch the
    ///     log stream, filtered by our own node name.
    func startTailscaleLogin() {
        guard tsEnabled else {
            showToast("请先启用内置 Tailnet", kind: .warn); return
        }
        guard !hasTailscaleAuthKey else {
            showToast("已配置 auth-key，无需浏览器登录（两种方式互斥）", kind: .warn); return
        }
        beginTailscaleSession(openBrowserOnLogin: true, timeout: 60)
    }

    /// Bring the session up after enabling / re-applying.
    ///
    /// **This is what makes an auth key work at all.** tsnet is lazy —
    /// `ensureStarted` is a `sync.Once` driven by the first dial — so injecting
    /// a node with a valid `auth-key` and stopping there registers nothing:
    /// the control plane is never contacted and the node never appears in the
    /// tailnet. Something has to dial it, and nothing in the normal flow does
    /// until the user happens to send matching traffic.
    func warmUpTailscale() {
        guard tsEnabled else { return }
        beginTailscaleSession(openBrowserOnLogin: false, timeout: 45)
    }

    /// One watcher for both flows: dial the node to force `ensureStarted`, then
    /// translate tsnet's info-level log lines into a session state.
    ///
    /// Every branch here corresponds to a real upstream log statement (see
    /// `TailscaleLog`); none of it is inferred from timing.
    private func beginTailscaleSession(openBrowserOnLogin: Bool, timeout: TimeInterval) {
        stopTailscaleLoginWatch()
        tsState = .starting
        let deadline = Date().addingTimeInterval(timeout)
        tsLoginDeadline = deadline

        // tsnet's own session lines (`UserLogf`) arrive on the kernel's
        // *info* level. A user who has turned logging down to error/silent —
        // a completely reasonable thing to do — silently deafens this whole
        // watch: nothing is ever emitted for `/logs?level=info` to receive,
        // so no branch below ever fires and "浏览器登录" never opens a
        // browser. Raise it for the life of this watch; restored in
        // `stopTailscaleLoginWatch()`.
        raiseKernelLogLevelForSession()

        let node = tsSettings.nodeName
        let hadAuthKey = hasTailscaleAuthKey
        let handle = api.stream("/logs?level=info", type: LogTick.self) { [weak self] tick in
            let payload = tick.payload
            Task { @MainActor in
                guard let self, self.tsLoginDeadline == deadline else { return }

                // 1. The silent killer: a valid key that tsnet refuses to use
                //    because the state directory already holds an identity.
                if TailscaleLog.authKeyIgnored(in: payload, nodeName: node) {
                    self.stopTailscaleLoginWatch()
                    self.tsState = .needsIdentityReset(
                        reason: "本机已有旧身份，tsnet 忽略了 auth-key")
                    self.logKernel("内置 Tailnet：\(payload)")
                    self.showToast("auth-key 未生效：本机存有旧身份，请点「清除身份并重试」",
                                   kind: .error)
                    return
                }

                // 2. Authentication finished — `printAuthURLLoop` only exits
                //    once the backend leaves NeedsLogin.
                if let state = TailscaleLog.authLoopState(in: payload, nodeName: node) {
                    self.stopTailscaleLoginWatch()
                    self.tsState = .running
                    self.logKernel("内置 Tailnet：会话已授权（state=\(state)）")
                    self.showToast("Tailnet 会话已建立", kind: .ok)
                    self.refreshTailscaleDevices(force: true)
                    self.refreshTailscaleLocalAddress()
                    return
                }

                // 3. Needs interactive login. With an auth key configured this
                //    means the key was rejected/exhausted — say so plainly
                //    instead of silently opening a browser.
                if let url = TailscaleLog.loginURL(in: payload, nodeName: node) {
                    // Deliberately do NOT stop the watch here. The login page
                    // is completed asynchronously in the user's browser, and
                    // its own completion (`AuthLoop: state is …; done`) lands
                    // on this same channel seconds to minutes later — stopping
                    // now would show the URL once and then never notice a
                    // successful sign-in. The timeout task below already
                    // no-ops once state has left `.starting`, so this watch
                    // simply keeps running (and the log level stays raised)
                    // until authLoopState fires or the user starts a fresh
                    // session (which cancels this one first).
                    self.tsState = .needsLogin(url: url)
                    // F12：URL 里的一次性授权码不入日志，只留域名。
                    // 完整 URL 仍经 tsState 交给 UI / 浏览器（那是它的用途）。
                    self.logKernel("内置 Tailnet：需要浏览器登录，登录页主机 "
                                   + "\(URL(string: url)?.host ?? "未知")（授权码不记录）")
                    // F13：needsLogin 不能无限等——旧实现里 watch 与抬高的
                    // 内核日志级别会一直挂着。10 分钟上限，超时回落 .failed。
                    // 会话身份用 tsLoginDeadline 判定：新会话 / 授权完成都会
                    // 让它失效，本任务自动 no-op。
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds:
                            UInt64(Self.tsNeedsLoginCapSeconds * 1_000_000_000))
                        await MainActor.run {
                            guard let self, self.tsLoginDeadline == deadline else { return }
                            guard case .needsLogin = self.tsState else { return }
                            self.stopTailscaleLoginWatch()
                            self.tsState = .failed(reason: "浏览器登录超时（10 分钟）")
                            self.showToast("浏览器登录超时，请重新点「浏览器登录」", kind: .warn)
                        }
                    }
                    if openBrowserOnLogin {
                        NSWorkspace.shared.open(URL(string: url) ?? URL(fileURLWithPath: "/"))
                        self.showToast("已打开 Tailscale 登录页面", kind: .info)
                    } else if hadAuthKey {
                        self.showToast("auth-key 被控制面拒绝（可能已过期/用尽），需浏览器登录",
                                       kind: .warn)
                    } else {
                        self.showToast("需要浏览器登录，点「浏览器登录」继续", kind: .warn)
                    }
                    return
                }

                if let warn = TailscaleLog.exitNodeFailure(in: payload, nodeName: node) {
                    self.logKernel("内置 Tailnet：\(warn)")
                }
            }
        }
        tsLoginWatch = handle

        // The dial is the whole point — it is the only thing that runs
        // `ensureStarted`. Failure is expected and irrelevant here; we only
        // need tsnet awake.
        // TS-3：peer-only（无 exit-node）不打公网 URL 测速——那次 dial 注定
        // 失败还平白触碰公网。改经 MagicDNS 解析唤醒（nameserver-policy 把
        // `+.<suffix>` 指向 `ts://<node>`），dial 同样触发 `ensureStarted`。
        // 门控复用 TailscaleLatency.usesPublicURLTest，与 refreshProxies 侧
        // 的哨兵分类同一判据。
        Task { [weak self] in
            guard let self else { return }
            if TailscaleLatency.usesPublicURLTest(nodeType: "tailscale",
                                                  exitNode: self.tsSettings.exitNode) {
                _ = try? await self.api.testDelay(name: node)
            } else {
                await self.wakeTailscaleViaMagicDNS()
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            await MainActor.run {
                // A newer session superseded this one — leave its state alone.
                guard self.tsLoginDeadline == deadline else { return }
                guard case .starting = self.tsState else { return }
                self.stopTailscaleLoginWatch()
                // Timing out is not proof of failure: the node may already have
                // been authorized in an earlier run, in which case tsnet prints
                // nothing at all. Fall back to idle rather than crying wolf.
                self.tsState = .idle
                self.logKernel("内置 Tailnet：\(Int(timeout)) 秒内未收到会话日志"
                               + "（本节点可能已在更早的运行中授权过，tsnet 这次不再打印任何东西）")
                self.refreshTailscaleLocalAddress()
            }
        }
    }

    func stopTailscaleLoginWatch() {
        tsLoginWatch?.cancel()
        tsLoginWatch = nil
        tsLoginDeadline = nil
        restoreKernelLogLevelIfRaised()
    }

    /// Ensure the kernel is loud enough to actually emit tsnet's info-level
    /// session lines, without touching the user's persisted preference.
    ///
    /// `PATCH /configs` applies `log-level` to the *running* kernel only —
    /// confirmed empirically (config.yaml keeps the old value after the
    /// patch) — so this is a cheap in-memory bump, not a reload, and never
    /// marks the config file dirty.
    private func raiseKernelLogLevelForSession() {
        guard tsLogLevelToRestore == nil else { return }  // already raised
        let quiet: Set<String> = ["silent", "error", "warning"]
        // Read from disk, not the live `configs` dict: `configs` can still be
        // showing a level *we* raised in a previous, not-yet-restored watch,
        // which would make this look loud enough when the user's real
        // preference is not. The runtime patch never touches config.yaml, so
        // the file is always the true preference.
        let current = (engine.readConfigFile()?["log-level"] as? String)
            ?? (configs["log-level"] as? String) ?? "warning"
        guard quiet.contains(current) else { return }
        tsLogLevelToRestore = current
        Task { [weak self] in
            try? await self?.api.patchConfig(["log-level": "info"])
        }
    }

    private func restoreKernelLogLevelIfRaised() {
        guard let level = tsLogLevelToRestore else { return }
        tsLogLevelToRestore = nil
        Task { [weak self] in
            try? await self?.api.patchConfig(["log-level": level])
        }
    }

    /// Wake the node without the login flow — used by the UI's "测试连通" action
    /// and after a config reload, so the first real connection does not pay the
    /// whole control-plane round trip.
    func kickTailscale() {
        guard tsEnabled else { return }
        let node = tsSettings.nodeName
        Task { [weak self] in
            guard let self else { return }
            // TS-3：peer-only 不参与公网 URL 测速（与 refreshProxies 的哨兵
            // 门控同一判据）。没有出口节点就没有公网出口，URL 测试失败是
            // 预期结果而非故障——只唤醒会话，不打公网。
            if !TailscaleLatency.usesPublicURLTest(nodeType: "tailscale",
                                                   exitNode: self.tsSettings.exitNode) {
                await self.wakeTailscaleViaMagicDNS()
                await MainActor.run {
                    self.showToast("已唤醒 Tailnet 会话（未配置出口节点，URL 测试不适用）",
                                   kind: .info)
                    self.refreshTailscaleLocalAddress()
                }
                return
            }
            let delay = try? await self.api.testDelay(name: node)
            await MainActor.run {
                if let d = delay, d > 0 {
                    self.tsState = .running
                    self.showToast("Tailnet 出口可达（\(d) ms）", kind: .ok)
                } else {
                    self.showToast("Tailnet 出口不可达，请检查出口节点与授权", kind: .info)
                }
                self.refreshTailscaleLocalAddress()
            }
        }
    }

    /// TS-3：peer-only 节点不触碰公网的唤醒 dial。overlay 已把 `+.<suffix>`
    /// 指向 `ts://<node>`（nameserver-policy），这次解析经 tailnet 解析器
    /// 发出，dial 本身触发 tsnet 的 `ensureStarted`——唤醒效果与 testDelay
    /// 等价，但目标始终在 tailnet 内。
    /// 尽力而为：配置没有可用 dns 段（tailscaleDNSSkipped）时 policy 未注入，
    /// 唤醒可能不生效，只能等第一条真实 tailnet 流量；日志里说明白。
    private func wakeTailscaleViaMagicDNS() async {
        let host = TailscaleName.sanitizeHostname(tsSettings.hostname)
        let suffix = tsSettings.magicDNSSuffix.trimmingCharacters(
            in: CharacterSet(charactersIn: ". "))
        let fqdn = "\(host).\(suffix.isEmpty ? "ts.net" : suffix)"
        if engine.tailscaleDNSSkipped {
            logKernel("内置 Tailnet：配置无可用 dns 段，MagicDNS 唤醒尽力而为"
                      + "（peer-only 节点不做公网 URL 测试）")
        }
        _ = try? await api.dnsQuery(name: fqdn, type: "A")
    }

    /// Clear the stale identity and immediately retry — the one-button cure for
    /// `.needsIdentityReset`.
    func resetTailscaleIdentityAndRetry() {
        guard tsEnabled else { return }
        guard retireTailscaleStateDir() else {
            showToast("无法清除身份目录，请查看日志", kind: .error)
            return
        }
        // The identity now matches the current credentials.
        tsStoredIdentityFingerprint = tsCurrentIdentityFingerprint
        withEngineBusy("重建内置 Tailnet 身份") { [weak self] in
            guard let self else { return }
            // tsnet reads its state directory once at `Start`, so the running
            // kernel still holds the retired identity in memory — a config
            // reload is what forces a fresh `tsnet.Server`.
            if await self.reloadWithTailscaleOverlay() {
                self.showToast("已清除旧身份，正在重新注册…", kind: .info)
                self.warmUpTailscale()
            }
        }
    }

    // MARK: - Local tailnet address

    /// Resolve this machine's own tailnet address.
    ///
    /// mihomo exposes no tsnet status over REST and tsnet's info-level logs
    /// never print the address, so there are exactly two indirect sources:
    ///
    ///   1. **Control-plane API** (needs the optional token) — our own node is
    ///      just another device in the list; match it by hostname.
    ///   2. **MagicDNS through our own node** — ask the kernel to resolve
    ///      `<hostname>.<suffix>`; the overlay already points that suffix at
    ///      `ts://<node>`, so the answer comes from the tailnet resolver.
    ///      Token-free, but needs a known MagicDNS suffix.
    func refreshTailscaleLocalAddress() {
        guard tsEnabled else {
            tsLocalIPs = []; tsLocalDNSName = ""; return
        }
        let host = TailscaleName.sanitizeHostname(tsSettings.hostname)

        // Source 1 — authoritative when a token is configured.
        if let mine = tsDevices.first(where: {
            $0.hostname.caseInsensitiveCompare(host) == .orderedSame
                || $0.hostname.lowercased().hasPrefix(host.lowercased() + ".")
        }) {
            if tsLocalIPs != mine.ips { tsLocalIPs = mine.ips }
            if tsLocalDNSName != mine.hostname { tsLocalDNSName = mine.hostname }
            return
        }

        // Source 2 — token-free fallback.
        let suffix = tsSettings.magicDNSSuffix.trimmingCharacters(
            in: CharacterSet(charactersIn: ". "))
        guard !suffix.isEmpty else { return }
        let fqdn = "\(host).\(suffix)"
        Task { [weak self] in
            guard let self else { return }
            guard let raw = try? await self.api.dnsQuery(name: fqdn, type: "A") else { return }
            let answers = (raw["Answer"] as? [[String: Any]]) ?? []
            let ips = answers.compactMap { $0["data"] as? String }
                .filter { TailscaleOverlay.isIPv4($0) }
            guard !ips.isEmpty else { return }
            await MainActor.run {
                if self.tsLocalIPs != ips { self.tsLocalIPs = ips }
                if self.tsLocalDNSName != fqdn { self.tsLocalDNSName = fqdn }
            }
        }
    }

    // MARK: - Reset

    /// Forget the tsnet identity. The next start registers a *new* node, so the
    /// old one lingers in the tailnet admin console until removed there.
    /// Forget the tsnet identity on disk.
    ///
    /// - Parameter silent: when true (wipe-all path), skip toasts — the caller
    ///   already narrates the broader operation. Failures still go to the log.
    func resetTailscaleIdentity(silent: Bool = false) {
        guard FileManager.default.fileExists(atPath: engine.tailscaleStateDirPath) else {
            if !silent { showToast("没有需要清除的登录状态", kind: .info) }
            return
        }
        // `retireTailscaleStateDir` falls back to a rename when the directory is
        // root-owned, which it always is once the Helper is installed — a plain
        // delete fails there and used to leave the user with no way out.
        if retireTailscaleStateDir() {
            tsStoredIdentityFingerprint = tsCurrentIdentityFingerprint
            if !silent {
                showToast("已清除本机 Tailnet 身份，下次启用会重新注册", kind: .ok)
            }
        } else if !silent {
            showToast("清除失败，请查看日志", kind: .error)
        }
    }
}
