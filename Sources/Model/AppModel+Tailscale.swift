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
            return true
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = "\(path).retired-\(stamp)"
        do {
            try fm.moveItem(atPath: path, toPath: aside)
            logKernel("内置 Tailnet：身份目录归 root，已改名让位 → \(aside)")
            return true
        } catch {
            logKernel("内置 Tailnet：无法退休身份目录（\(path)）：\(error.localizedDescription)")
            return false
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
                    self.logKernel("内置 Tailnet：登录地址 \(url)")
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
        // `ensureStarted`. Failure is expected and irrelevant here (a
        // peer-only tailnet has no public egress); we only need tsnet awake.
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.api.testDelay(name: node)
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
                self.refreshTailscaleLocalAddress()
            }
        }
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
