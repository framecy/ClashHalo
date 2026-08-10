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
    }

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
        syncTailscaleToEngine()
    }

    /// The single point where the Keychain secret and live peer IPs are merged
    /// into the plan. Nothing else may read or copy the auth key.
    private func syncTailscaleToEngine() {
        guard tsEnabled else { engine.tailscaleSettings = nil; return }
        var s = tsSettings
        s.authKey = KeychainHelper.read(key: kTailscaleAuthKey) ?? ""
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
        syncTailscaleToEngine()
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
        if !force, Date().timeIntervalSince(tsDevicesFetchedAt) < 30, !tsDevices.isEmpty {
            return
        }
        guard !tsDevicesLoading else { return }
        tsDevicesLoading = true
        tsDevicesError = nil
        let token = tailscaleAPIToken
        Task {
            // Decode and suffix-infer from the same raw body so we do not pay
            // for a second round-trip just to read the FQDN field.
            let result = await Self.fetchDevicesWithSuffix(token: token)
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

    /// One request, two products: the device list and an optional MagicDNS
    /// suffix inferred from FQDNs in the same payload.
    private static func fetchDevicesWithSuffix(token: String)
    async -> Result<([TailscaleDevice], String?), TailscaleAPI.Error> {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.noToken) }
        // fields=all is required for advertisedRoutes / enabledRoutes.
        guard let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=all") else {
            return .failure(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        req.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await tsAPISession.data(for: req)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                return .failure(.http(h.statusCode))
            }
            let devices = try TailscaleAPI.decodeDevices(data)
            let suffix = TailscaleAPI.inferMagicDNSSuffix(fromFQDNs: TailscaleAPI.fqdns(from: data))
            return .success((devices, suffix))
        } catch let e as TailscaleAPI.Error {
            return .failure(e)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

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
                self.tsState = self.tsEnabled ? .idle : .disabled
                return
            }
            self.tsState = on ? .idle : .disabled
            if on {
                self.refreshTailscaleEnvironmentWarnings()
                self.refreshTailscaleDevices()
                self.showToast(self.hasTailscaleAuthKey
                               ? "内置 Tailnet 已启用"
                               : "内置 Tailnet 已启用，请完成浏览器登录", kind: .ok)
            } else {
                self.stopTailscaleLoginWatch()
                self.tsWarnings = []
                self.tsDevices = []
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
        if let normalized = TailscaleOverlay.normalizeControlURL(tsSettings.controlURL) {
            tsSettings.controlURL = normalized
        } else {
            showToast("控制服务器地址无效：需要 http(s):// 开头的完整 URL", kind: .error)
            return
        }
        guard tsEnabled else { saveTailscalePrefs(); return }
        withEngineBusy("更新内置 Tailnet") { [weak self] in
            guard let self else { return }
            self.saveTailscalePrefs()
            if await self.reloadWithTailscaleOverlay() {
                self.refreshTailscaleEnvironmentWarnings()
                self.showToast("内置 Tailnet 配置已更新", kind: .ok)
            }
        }
    }

    /// Push the current on-disk config back through `setConfig`, which re-applies
    /// every runtime override — including the tailnet overlay — and reloads.
    ///
    /// Feeding the file back to itself looks odd but is the honest path: the
    /// overrides are idempotent by construction, and this keeps exactly one
    /// place that knows how a config reaches the kernel.
    private func reloadWithTailscaleOverlay() async -> Bool {
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
        return true
    }

    // MARK: - Environment conflicts

    /// The one conflict that makes the feature silently useless: a system
    /// Tailscale client already owns 100.64/10 on this machine.
    ///
    /// We do not fight it. The coexistence layer will keep excluding the CGNAT
    /// range from the proxy TUN — which is correct for the system client and
    /// fatal for us — so the honest move is to say so and let the user choose,
    /// rather than quietly winning or quietly losing.
    func refreshTailscaleEnvironmentWarnings() {
        guard tsEnabled else { tsWarnings = []; return }
        var warnings = engine.tailscaleWarnings
        if NetScanner.interfaces().contains(where: { $0.kind == .tailscale }) {
            warnings.append("检测到系统 Tailscale 客户端正在运行。100.64/10 会被让给它，"
                            + "内置节点收不到流量——请退出系统客户端后再使用内置节点")
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
        tsWarnings = warnings
    }

    /// Merge API-advertised subnet routes into `extraCIDRs` (user still has to
    /// hit 应用配置). Returns how many *new* CIDRs were added.
    @discardableResult
    func importAdvertisedSubnetRoutes() -> Int {
        let suggested = TailscaleAPI.suggestedSubnetRoutes(from: tsDevices)
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

    /// Whether the live device list implies peer /32 rules the kernel does not
    /// yet have. Soft signal only — never auto-reloads.
    var tsPeerRulesStale: Bool {
        guard tsEnabled, tsAutoPeerRules, !tsDevices.isEmpty else { return false }
        let live = Set(TailscaleOverlay.normalizePeerIPs(
            tsDevices.filter(\.online).flatMap(\.ips)
        ))
        let planned = Set(engine.tailscaleSettings?.peerIPs ?? [])
        return live != planned
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
        stopTailscaleLoginWatch()
        tsState = .starting
        tsLoginDeadline = Date().addingTimeInterval(60)

        let node = tsSettings.nodeName
        tsLoginWatch = api.stream("/logs?level=info", type: LogTick.self) { [weak self] tick in
            let payload = tick.payload
            Task { @MainActor in
                guard let self, self.tsLoginWatch != nil else { return }
                if let url = TailscaleLog.loginURL(in: payload, nodeName: node) {
                    self.tsState = .needsLogin(url: url)
                    self.stopTailscaleLoginWatch()
                    NSWorkspace.shared.open(URL(string: url) ?? URL(fileURLWithPath: "/"))
                    self.showToast("已打开 Tailscale 登录页面", kind: .info)
                    self.logKernel("内置 Tailnet：登录地址 \(url)")
                } else if let warn = TailscaleLog.exitNodeFailure(in: payload, nodeName: node) {
                    self.logKernel("内置 Tailnet：\(warn)")
                }
            }
        }

        // Kick tsnet awake. The delay test dials through the node, which is the
        // only thing that runs `ensureStarted`. It is expected to fail (there is
        // no exit node yet) — the failure is not the point, the dial is.
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.api.testDelay(name: node)
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            await MainActor.run {
                guard case .starting = self.tsState else { return }
                self.stopTailscaleLoginWatch()
                self.tsState = .failed(reason: "未在 60 秒内收到登录地址")
                self.showToast("未收到登录地址：请确认日志级别不低于 info", kind: .warn)
            }
        }
    }

    func stopTailscaleLoginWatch() {
        tsLoginWatch?.cancel()
        tsLoginWatch = nil
        tsLoginDeadline = nil
    }

    /// Wake the node without the login flow — used by the UI's "测试连通" action
    /// and after a config reload, so the first real connection does not pay the
    /// whole control-plane round trip.
    func kickTailscale() {
        guard tsEnabled else { return }
        let node = tsSettings.nodeName
        Task { [weak self] in
            guard let self else { return }
            let delay = try? await self.api.testDelay(name: node)
            await MainActor.run {
                if let d = delay, d > 0 {
                    self.tsState = .running
                    self.showToast("Tailnet 出口可达（\(d) ms）", kind: .ok)
                } else {
                    // Without an exit node there is no Internet egress through
                    // this policy, so a failed URL test is the *expected*
                    // result for a peer-to-peer tailnet — not a fault.
                    self.showToast(self.tsSettings.exitNode.isEmpty
                                   ? "已唤醒 Tailnet 会话（未配置出口节点，URL 测试不适用）"
                                   : "Tailnet 出口不可达，请检查出口节点与授权", kind: .info)
                }
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
        let path = engine.tailscaleStateDirPath
        guard FileManager.default.fileExists(atPath: path) else {
            if !silent { showToast("没有需要清除的登录状态", kind: .info) }
            return
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            if !silent {
                showToast("已清除本机 Tailnet 身份，下次启用会重新登录", kind: .ok)
            }
            logKernel("内置 Tailnet：已删除 \(path)")
        } catch {
            // The kernel runs as root when the Helper is installed, so the state
            // directory is root-owned — the same single-identity rule that keeps
            // cache.db consistent. A user-mode delete cannot touch it.
            logKernel("内置 Tailnet：清除身份失败（\(path)）：\(error.localizedDescription)")
            if !silent {
                showToast("清除失败（目录属主为 root）：\(error.localizedDescription)", kind: .error)
            }
        }
    }
}
