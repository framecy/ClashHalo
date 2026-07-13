import Foundation

// MARK: - AppModel · Config, switches & profiles
// Profile activation, running-config refresh/patch, master switches (system
// proxy / TUN / engine), mode, and the read-only rules view.

extension AppModel {
    /// Gateway mode configuration overrides (allow-lan + DNS listen on 0.0.0.0:53)
    static let gatewayOverrides: [String: Any] = [
        "allow-lan": true,
        "dns": [
            "enable": true,
            "listen": "0.0.0.0:53",
            "enhanced-mode": "fake-ip"
        ]
    ]

    /// Promote an Imported (or re-activate an Applied) profile to the
    /// running kernel: persist → reload → mark applied. Pure side-effects;
    /// the user already consented at the call site (two-stage sheet or
    /// "设为活动" tap). Reload coalesces via `appliedHash`: a re-apply of
    /// unchanged content short-circuits before touching the kernel.
    func selectForApply(_ id: String) {
        guard !engine.isBusy else { showToast("内核操作进行中，请稍候…"); return }
        let oldActiveID = store.activeID
        let backupContent = (try? String(contentsOfFile: engine.configFilePath, encoding: .utf8)) ?? ""
        
        guard let content = store.commit(id) else { showToast("配置为空"); return }
        let name = store.profiles.first { $0.id == id }?.name ?? ""
        let wasTunOn = tunOn
        // Skip reload if the on-disk content matches the last applied hash.
        // `commit` just rewrote config.yaml with the same content, but the
        // kernel state is unchanged — avoid the hot-reload churn.
        if let last = store.profiles.first(where: { $0.id == id })?.appliedHash,
           last == Sha1.hex(content) {
            store.markApplied(id, hash: last)
            showToast("已切换配置「\(name)」")
            return
        }
        let oldPort = proxyPort
        pendingApplyID = id
        engine.isBusy = true
        Task {
            defer { engine.isBusy = false }
            let (ok, err) = await engine.setConfig(content)
            pendingApplyID = nil
            if ok {
                store.markApplied(id, hash: Sha1.hex(content))
                showToast("已切换配置「\(name)」")
                await reconnect()
                await reapplyTUN(wasOn: wasTunOn)

                // Port-change cascade: if the new profile uses a different
                // mixed-port and the system proxy is on, re-set it so traffic
                // doesn't leak to the old (now dead) port.
                let newPort = proxyPort
                if systemProxyOn && newPort != oldPort {
                    let ok = await engine.setSystemProxy(enabled: true, port: newPort)
                    if ok { showToast("系统代理已更新至端口 \(newPort)") }
                }

                // Gateway cascade: the new profile may have overwritten
                // allow-lan / dns.listen. Re-apply the Gateway overrides so
                // the gateway keeps working.
                if gatewayModeOn {
                    engine.setTopLevelScalars(Self.gatewayOverrides)
                    do {
                        try await api.reloadConfig(path: engine.configFilePath)
                        await refreshConfigs()
                    } catch {
                        showToast("网关配置重载失败")
                    }
                }

                // Refresh proxies after profile switch (event-driven)
                await refreshProxies()
            } else {
                showToast("配置错误：\(err ?? "")，已回滚")
                if !oldActiveID.isEmpty {
                    store.activeID = oldActiveID
                    if oldActiveID == id {
                        if !backupContent.isEmpty {
                            try? backupContent.write(toFile: store.path(id), atomically: true, encoding: .utf8)
                            try? backupContent.write(toFile: engine.configFilePath, atomically: true, encoding: .utf8)
                            if let oldHash = store.profiles.first(where: { $0.id == id })?.appliedHash {
                                store.markApplied(id, hash: oldHash)
                            } else {
                                // Fallback: if there was no applied hash, mark applied anyway as it was running
                                store.markApplied(id, hash: Sha1.hex(backupContent))
                            }
                        }
                    } else {
                        if !backupContent.isEmpty {
                            try? backupContent.write(toFile: engine.configFilePath, atomically: true, encoding: .utf8)
                            if let oldHash = store.profiles.first(where: { $0.id == oldActiveID })?.appliedHash {
                                store.markApplied(oldActiveID, hash: oldHash)
                            }
                        }
                    }
                }
                if !backupContent.isEmpty {
                    _ = await engine.setConfig(backupContent)
                }
                store.save()
            }
        }
    }

    /// Legacy single-shot entry point kept for any non-UI callers (notably
    /// `ProfileEditSheet` "保存并应用"). Behaviour is identical to a tap on
    /// the card for an already-Applied profile, and identical to confirming
    /// preview for a Draft. Use `selectForApply` directly from the new two-
    /// stage sheets to preserve the pending/spinner UX.
    func activateProfile(_ id: String) {
        selectForApply(id)
    }

    func refreshConfigs() async {
        guard var c = try? await api.fetchConfigs() else { return }

        // Strictly enforce CDN GEO defaults if missing or empty
        var geo: [String: String] = [:]
        if let rawGeo = c["geox-url"] as? [String: Any] {
            for (k, v) in rawGeo { geo[k] = "\(v)" }
        }

        let defaults = [
            "mmdb": "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/country.mmdb",
            "asn": "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb",
            "geosite": "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat",
            "geoip": "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
        ]
        var changed = false
        for (k, v) in defaults {
            let current = geo[k] ?? ""
            if (current.isEmpty || current.contains("geodata.kelee.one")) && current != v {
                geo[k] = v
                changed = true
            }
        }

        if changed {
            // Background correction: use api directly and silently
            _ = try? await api.patchConfig(["geox-url": geo])
            c["geox-url"] = geo
        }

        // Mihomo API does not return sniffer or dns config, so read them from config.yaml
        if let fileConfig = engine.readConfigFile() {
            if let sniffer = fileConfig["sniffer"] as? [String: Any] {
                c["sniffer"] = sniffer
            }
            if let dns = fileConfig["dns"] as? [String: Any] {
                c["dns"] = dns
            }
        }

        // Deep compare to avoid unnecessary @Published triggers (RSS optimization)
        if !(c as NSDictionary).isEqual(configs) {
            configs = c
        }
        
        if let m = c["mode"] as? String { mode = m }
        // B9: a user-mode kernel cannot create the utun device (operation not
        // permitted), so even if the config declares tun.enable=true it is not
        // actually active. Reflect the real state instead of the declared one.
        // B10: Also verify the mihomo TUN interface actually exists. When other
        // utun interfaces (Tailscale, VPN, etc.) coexist, the kernel may crash or
        // lose its TUN while those survive, leaving stale config state. Check that
        // a utun with the fake-ip range (198.18.x.x) is present before reporting TUN as active.
        if let tun = c["tun"] as? [String: Any] {
            let configEnabled = (tun["enable"] as? Bool) == true
            let hasInterface = await NetScanner.mihomoTunInterface() != nil
            let shouldBeOn = configEnabled && engine.runningAsRoot && hasInterface

            // If config says TUN is on but interface is missing, log and auto-disable.
            // Guarded so it doesn't fire concurrently with a user toggle / restart
            // (engine.isBusy) or duplicate the 30 s verifyTUNConfig probe
            // (tunAutoTeardownInFlight) — both paths target the same teardown.
            // We also hold `engine.isBusy` for the duration (P2 root-cause: the
            // detached teardown previously raced the user's `applyTUNState`). We
            // bypass `withEngineBusy` because it is fire-and-forget — the caller
            // cannot await its body, so the in-flight guard would clear before
            // the teardown finishes. Manual isBusy + defer guarantees the guard
            // clears only after `applyTUNState(false)` truly completes.
            if configEnabled && engine.runningAsRoot && !hasInterface && tunOn,
               !engine.isBusy, !tunAutoTeardownInFlight {
                tunAutoTeardownInFlight = true
                engine.isBusy = true
                logKernel("检测到 TUN 接口丢失（可能与其他 utun 服务冲突），正在自动关闭...")
                Task {
                    defer {
                        self.engine.isBusy = false
                        self.tunAutoTeardownInFlight = false
                    }
                    await self.applyTUNState(false)
                    // Fallback: if a mihomo utun residue (198.18 address, flags
                    // down) still lingers after the logical teardown, ask the
                    // privilege Helper to physically neutralize it (ifconfig
                    // down + delete IP + route flush) so its Supplemental DNS
                    // resolver cannot keep pinning 198.18.0.1. Only fires when a
                    // downed proxyTun actually remains — never on a clean exit,
                    // sparing co-resident VPNs sharing the 198.18.x range.
                    if NetScanner.hasDownedMihomoTun() {
                        self.logKernel("检测到僵尸 TUN 残留，请求特权服务物理清理...")
                        let ok = await XPCManager.shared.callCleanupTUNResidual()
                        if ok != true {
                            self.logKernel("僵尸 TUN 物理清理: 特权服务未完成或不可达")
                        }
                    }
                }
            }
            tunOn = shouldBeOn
        }
        // Gateway state inference (cautious): if UI thinks Gateway is off but
        // config has the signature (allow-lan=true AND dns.listen=0.0.0.0:53),
        // sync UI to true. Never sync false → avoids overwriting user's manual
        // LAN-sharing configs. The write path (applyGatewayMode) remains authoritative.
        if !gatewayModeOn {
            let allowLan = (c["allow-lan"] as? Bool) == true
            let dnsListen = (c["dns"] as? [String: Any])?["listen"] as? String
            if allowLan && dnsListen == "0.0.0.0:53" {
                gatewayModeOn = true
            }
        }
        // Keep system DNS in sync with the real TUN state. This is the single
        // point where tunOn is derived from reality, so it also recovers the
        // correct DNS after an app restart (TUN survived → keep redirect; TUN
        // died → restore). Both calls are idempotent and only act on a transition.
        let dnsRedirected = UserDefaults.standard.bool(forKey: Self.kDNSOverriddenKey)
        if tunOn && !dnsRedirected {
            await enableTunnelDNS()
        } else if !tunOn && dnsRedirected {
            await restoreTunnelDNS()
        }

        // Align static routes for excluded prefixes in sync with the real TUN state.
        if tunOn && !staticRoutesInjected {
            let excludeRoutes = await NetScanner.sdwanExcludeRoutes()
            if !excludeRoutes.isEmpty {
                if let helper = XPCManager.shared.helper() {
                    helper.setupExcludeRoutes(excludeRoutes) { ok in
                        self.logKernel("XPC Helper 注入静态路由: \(ok ? "成功" : "失败")")
                        if ok {
                            Task { @MainActor in
                                self.staticRoutesInjected = true
                            }
                        }
                    }
                }
            } else {
                // If there are no routes to exclude, mark it as injected to prevent repeated checks
                staticRoutesInjected = true
            }
        } else if !tunOn && staticRoutesInjected {
            if let helper = XPCManager.shared.helper() {
                helper.cleanupAllExcludeRoutes { ok in
                    self.logKernel("XPC Helper 清理静态路由: \(ok ? "成功" : "失败")")
                    if ok {
                        Task { @MainActor in
                            self.staticRoutesInjected = false
                        }
                    }
                }
            }
        }
    }

    // MARK: Master switches

    /// Guard + set + defer-reset wrapper for `engine.isBusy`. All long-running
    /// kernel lifecycle operations (TUN/engine/Gateway toggle, restart, kernel
    /// switch) must go through this so the isBusy flag has a single write path.
    /// Returns `false` and shows a toast if the engine is already busy.
    @discardableResult
    func withEngineBusy(_ label: String = "操作", _ body: @escaping () async -> Void) -> Bool {
        guard !engine.isBusy else { showToast("内核操作进行中，请稍候…"); return false }
        engine.isBusy = true
        Task {
            defer { engine.isBusy = false }
            await body()
        }
        return true
    }

    func toggleSystemProxy() {
        guard !engine.isBusy else { showToast("内核操作进行中，请稍候…"); return }
        let on = !systemProxyOn
        let port = proxyPort
        Task {
            if on && !reachable {
                showToast("正在启动核心以开启系统代理…")
                engine.ensureRunning()
                guard await waitForKernelReady(maxAttempts: 8) else {
                    showToast("内核启动超时，无法开启系统代理")
                    return
                }
                await reconnect()
            }

            let ok = await engine.setSystemProxy(enabled: on, port: port)
            if ok {
                systemProxyOn = on
                showToast(on ? "系统代理已开启" : "系统代理已关闭")
                
                // Auto-stop kernel cascade: if both system proxy and TUN are now off, stop the kernel
                if !on && !tunOn && reachable {
                    showToast("已无代理服务运行，正在停止内核…")
                    await stopEngine()
                }
            } else {
                systemProxyOn = !on // Revert the switch if operation fails
                await api.probe()
                if api.reachable { showToast("系统代理设置失败") }
            }
        }
    }

    func toggleTUN() {
        withEngineBusy { await self.applyTUNState(!self.tunOn) }
    }

    func toggleGatewayMode() {
        let want = !gatewayModeOn

        // Active Gateway needs TUN, let's enforce it
        if want && !tunOn {
            showToast("正准备环境：网关中枢需要 TUN 模式…")
            withEngineBusy {
                await self.applyTUNState(true)
                if self.tunOn {
                    await self.applyGatewayMode(true)
                } else {
                    self.showToast("TUN 启动失败，无法开启网关中枢")
                }
            }
            return
        }

        withEngineBusy("系统配置") { await self.applyGatewayMode(want) }
    }

    private func applyGatewayMode(_ want: Bool) async {
        if want {
            // Check helper privileges for sysctl and root-mode mihomo.
            if !engine.isRoot {
                showToast("开启网关中枢需要管理员授权…")
                let ok = await engine.installPrivileged()
                guard ok else { showToast("授权失败，未开启网关"); return }
            }
            // Verify XPC connectivity even when a helper plist already exists;
            // a stale or unloaded LaunchDaemon cannot enable forwarding.
            guard await XPCManager.shared.verifyConnectivity() else {
                showToast("特权服务无法连接，未开启网关")
                engine.isRoot = false
                return
            }
            engine.isRoot = true

            // Gateway traffic must enter a root-owned TUN. If the helper exists
            // but the current kernel is user-mode, restart it through the helper.
            if !engine.runningAsRoot {
                showToast("正在以 Root 权限重启核心…")
                await engine.restart()
                guard await waitForKernelReady(maxAttempts: 8) else {
                    showToast("Root 内核启动超时，未开启网关")
                    return
                }
                await reconnect()
            }

            // Write configs for gateway mode (allow-lan and dns listen).
            let oldTun = tunOn

            // Snapshot current allow-lan / dns.listen values so Gateway
            // disable can restore them later (avoid stale overrides).
            preGatewayAllowLan = (configs["allow-lan"] as? Bool) ?? false
            if let dns = configs["dns"] as? [String: Any] {
                preGatewayDNSListen = dns["listen"] as? String
            }

            // Back up config.yaml before Gateway overwrites so we can
            // roll back if the kernel crashes (e.g. port 53 conflict).
            let cfgPath = engine.configFilePath
            let backup = try? String(contentsOfFile: cfgPath, encoding: .utf8)

            engine.setTopLevelScalars(Self.gatewayOverrides)
            engine.setTunEnabled(oldTun)
            showToast("正在应用网关配置…")
            do {
                try await api.reloadConfig(path: cfgPath)
                await refreshConfigs()
            } catch {
                if let b = backup {
                    try? b.write(toFile: cfgPath, atomically: true, encoding: .utf8)
                    showToast("端口冲突，正在回滚配置…")
                    try? await api.reloadConfig(path: cfgPath)
                    await refreshConfigs()
                }
                preGatewayAllowLan = nil; preGatewayDNSListen = nil
                showToast("网关配置应用失败，请检查 53 端口是否被占用")
                return
            }

            // A force reload can drop runtime TUN if the kernel rejects or
            // normalizes the file value. Reconcile from the live config and
            // re-run the normal TUN enable flow if needed.
            if oldTun && !tunOn {
                await reapplyTUN(wasOn: true)
                guard tunOn else {
                    if let b = backup {
                        try? b.write(toFile: cfgPath, atomically: true, encoding: .utf8)
                        try? await api.reloadConfig(path: cfgPath)
                        await refreshConfigs()
                    }
                    preGatewayAllowLan = nil; preGatewayDNSListen = nil
                    showToast("TUN 恢复失败，未开启网关中枢")
                    return
                }
            }

            let ok = await engine.setGatewayMode(enabled: true)
            if ok {
                gatewayModeOn = true
                showToast("网关中枢（旁路由）已成功开启")
            } else {
                gatewayModeOn = false
                preGatewayAllowLan = nil; preGatewayDNSListen = nil
                showToast("底层 IP 转发开启失败")
            }
        } else {
            // Restore config.yaml overrides that Gateway mode applied.
            let restores: [String: Any] = [
                "allow-lan": preGatewayAllowLan ?? false,
                "dns": [
                    "enable": true,
                    "listen": preGatewayDNSListen ?? "127.0.0.1:1053",
                    "enhanced-mode": "fake-ip"
                ]
            ]
            preGatewayAllowLan = nil; preGatewayDNSListen = nil
            engine.setTopLevelScalars(restores)

            let ok = await engine.setGatewayMode(enabled: false)
            if ok {
                gatewayModeOn = false
                do {
                    try await api.reloadConfig(path: engine.configFilePath)
                    await refreshConfigs()
                    showToast("网关中枢已关闭")
                } catch {
                    showToast("网关中枢已关闭，配置重载失败")
                }
            } else {
                showToast("网关中枢关闭失败")
            }
        }
    }

    /// Re-establish the user's TUN state after a kernel (re)start (restart button /
    /// kernel version switch / reinstall). A restart re-reads config.yaml where
    /// `tun.enable` is always false — TUN is a runtime-only PATCH that never
    /// persists — and may even come up user-mode, so a previously active TUN
    /// silently dies. Callers capture `tunOn` *before* the restart (reconnect
    /// resets it) and pass it here; we re-run the full enable flow (root switch +
    /// PATCH + interface pin) only if TUN was on. No-op otherwise.
    func reapplyTUN(wasOn: Bool) async {
        guard wasOn else { return }
        await applyTUNState(true)
    }

    /// Core TUN enable/disable: root-mode kernel switch (when enabling without an
    /// already-root kernel) + runtime PATCH of `tun.enable`/interface pin, then
    /// reconcile `tunOn` from the kernel's *actual* state. The shared body behind
    /// `toggleTUN` and `reapplyTUN`. Caller owns `engine.isBusy`.
    func applyTUNState(_ want: Bool) async {
        if want && !reachable {
            showToast("正在启动核心以启用 TUN…")
            engine.isRoot = true
            engine.ensureRunning()
            guard await waitForKernelReady(maxAttempts: 8) else {
                showToast("内核启动超时，TUN 无法启用")
                return
            }
        }

        var tunOverrideMap: [String: Any] = [
            "enable": want,
            "stack": (configs["tun"] as? [String:Any])?["stack"] ?? "gvisor",
            "auto-route": true,
            "auto-detect-interface": true
        ]

        // When enabling TUN, detect active SD-WAN interfaces (Tailscale, ZeroTier, etc.)
        // and merge their CIDR prefixes into route-exclude-address so TUN auto-route
        // does not shadow/hijack those routes (e.g. Tailscale 100.64.0.0/10).
        if want {
            let sdwanPrefixes = await NetScanner.sdwanExcludePrefixes()
            if !sdwanPrefixes.isEmpty {
                // Merge with any existing user-defined excludes from config
                let existing = (configs["tun"] as? [String: Any])?["route-exclude-address"] as? [String] ?? []
                let merged = Array(Set(existing + sdwanPrefixes)).sorted()
                tunOverrideMap["route-exclude-address"] = merged
                logKernel("TUN 路由排除：自动注入 SD-WAN 前缀 \(sdwanPrefixes.joined(separator: ", "))")
            }
        }

        var overrides: [String: Any] = ["tun": tunOverrideMap]
        // Pin the outbound interface to the real default-route NIC when enabling
        // TUN. auto-detect-interface alone loses a startup race — auto-route
        // hijacks the default route before the monitor identifies the NIC, so
        // every dial fails "interface not found" until it catches up, black-holing
        // traffic. An explicit interface-name gives egress a concrete NIC at once;
        // the monitor still updates it on later network changes. Clear it on
        // disable so non-TUN egress returns to fully automatic selection.
        if want, let iface = await EngineControl.defaultInterface() {
            overrides["interface-name"] = iface
        } else if !want {
            overrides["interface-name"] = ""
        }

        // TUN requires root.
        if want && !engine.runningAsRoot {
            if !engine.isRoot {
                showToast("启用 TUN 需要管理员授权以安装特权服务…")
                let ok = await engine.installPrivileged()
                guard ok else { showToast("授权失败，TUN 未启用"); return }
                // Verify XPC connectivity after installation to catch launchd bootstrap failures
                let connected = await XPCManager.shared.verifyConnectivity()
                guard connected else {
                    showToast("特权服务安装后无法连接，请重启应用或检查 system 日志")
                    engine.isRoot = false  // Reset to prevent permanent lock
                    return
                }
            } else if engine.helperVersion != EngineControl.kExpectedHelperVersion,
                      engine.helperVersion != "?" {
                // Helper version mismatch detected during TUN toggle.
                // This should rarely happen since app startup auto-upgrades,
                // but handle it gracefully just in case.
                showToast("特权服务需要更新，正在自动升级…")
                let upgraded = await engine.checkAndUpgradeHelperIfNeeded()
                guard upgraded else {
                    showToast("Helper 升级失败，TUN 未启用")
                    return
                }
            }

            showToast("正在以 Root 权限重启核心…")
            await engine.restart()
            // Wait for root kernel with smart backoff
            guard await waitForKernelReady(maxAttempts: 8) else {
                showToast("Root 内核启动超时，TUN 未启用")
                return
            }
            await self.reconnect()
        }

        let ok = await engine.patchConfig(overrides)
        if ok {
            // refreshConfigs sets tunOn from the *actual* kernel state
            // (enable && runningAsRoot, per B9) — do not blindly set tunOn=want.
            // A user-mode kernel accepts the PATCH (HTTP 200) but cannot create
            // the utun device and silently reverts enable to false; reporting
            // success there is the "succeeds but actually fails" bug.
            // refreshConfigs reconciles system DNS with the real TUN state
            // (redirect into tunnel when up, restore when down).
            await refreshConfigs()
            if want && !tunOn {
                showToast("TUN 开启失败：可能无管理员权限或路由被其他 VPN 占用冲突")
            } else {
                // TUN disable cascades: Gateway mode requires TUN, so if we
                // just turned TUN off, also tear down Gateway (sysctl + UI +
                // restore the allow-lan/dns.listen overrides Gateway applied).
                if !want && gatewayModeOn {
                    _ = await engine.setGatewayMode(enabled: false)
                    gatewayModeOn = false
                    // Restore config.yaml overrides so a later config switch /
                    // Gateway re-enable doesn't read stale snapshot values.
                    let restores: [String: Any] = [
                        "allow-lan": preGatewayAllowLan ?? false,
                        "dns": [
                            "enable": true,
                            "listen": preGatewayDNSListen ?? "127.0.0.1:1053",
                            "enhanced-mode": "fake-ip"
                        ]
                    ]
                    preGatewayAllowLan = nil; preGatewayDNSListen = nil
                    engine.setTopLevelScalars(restores)
                }
                showToast(want ? "TUN 模式已开启" : "TUN 模式已关闭")

                // Auto-stop kernel cascade: if both system proxy and TUN are now off, stop the kernel
                if !want && !systemProxyOn && reachable {
                    showToast("已无代理服务运行，正在停止内核…")
                    await stopEngine()
                }
            }
        } else {
            await api.probe()
            if api.reachable { showToast(want ? "TUN 模式开启失败" : "TUN 模式关闭失败") }
        }
    }

    // MARK: TUN DNS redirection
    //
    // With TUN + fake-ip, macOS keeps sending DNS to the LAN gateway (e.g.
    // 10.1.1.1), which the profile's `route-exclude-address` (10.0.0.0/8, …)
    // excludes from the tunnel. So DNS bypasses mihomo entirely: it gets poisoned
    // upstream answers, fake-ip never engages, and mihomo only ever sees real IPs
    // — domain-based policy-group rules can never match and proxied traffic fails.
    // The fix: while TUN is up, point the system DNS at the TUN gateway so queries
    // enter the tunnel and hit mihomo's dns-hijack/fake-ip. Original DNS is saved
    // and restored on disable/stop (and recovered at next launch after a crash).

    static let kDNSOverriddenKey = "tun.dns.overridden"
    static let kDNSSavedKey = "tun.dns.saved"

    /// The TUN gateway to use as the system resolver. Prefers the live config's
    /// `tun.inet4-address` gateway; falls back to mihomo's default fake-ip gateway.
    func tunnelDNSAddress() -> String {
        if let tun = configs["tun"] as? [String: Any],
           let addrs = tun["inet4-address"] as? [String],
           let first = addrs.first {
            let ip = String(first.split(separator: "/").first ?? "")
            if !ip.isEmpty { return ip }
        }
        return "198.18.0.1"
    }

    /// Redirect system DNS into the tunnel (idempotent). Saves the pre-existing
    /// DNS once so a manual user setting is restored later, not clobbered.
    func enableTunnelDNS() async {
        let gateway = tunnelDNSAddress()
        let d = UserDefaults.standard
        if !d.bool(forKey: Self.kDNSOverriddenKey) {
            let original = await EngineControl.currentSystemDNS()
            // Use sentinel value "Empty" if system DNS is unconfigured (common on fresh macOS)
            let snapshot = original.isEmpty ? "Empty" : original.joined(separator: ",")
            d.set(snapshot, forKey: Self.kDNSSavedKey)
            d.set(true, forKey: Self.kDNSOverriddenKey)
        }
        await EngineControl.applySystemDNS([gateway])
    }

    /// Restore the system DNS saved before TUN took over (no-op if we never
    /// overrode it). Idempotent — safe to call from every teardown path.
    func restoreTunnelDNS() async {
        let d = UserDefaults.standard
        guard d.bool(forKey: Self.kDNSOverriddenKey) else { return }
        let savedString = d.string(forKey: Self.kDNSSavedKey) ?? ""
        // Handle sentinel "Empty" by clearing DNS (networksetup needs "Empty" literal)
        let saved = savedString == "Empty" ? ["Empty"] : savedString.split(separator: ",").map(String.init)
        await EngineControl.applySystemDNS(saved)
        d.set(false, forKey: Self.kDNSOverriddenKey)
        d.removeObject(forKey: Self.kDNSSavedKey)
    }

    /// Deep-merge config overrides into the running config via the engine
    /// (validate + rollback). The primitive behind all settings forms.
    func patch(_ overrides: [String: Any]) async {
        guard reachable else {
            showToast("内核未连接，无法修改配置")
            return
        }

        let ok = await engine.patchConfig(overrides)
        if ok {
            await refreshConfigs()
            showToast("配置已更新")
        } else {
            // Check if it just died
            await api.probe(timeout: 0.5)
            if api.reachable {
                showToast("内核拒绝了该配置修改")
            } else {
                reachable = false
                showToast("内核已断开，配置写入失败")
            }
        }
    }

    /// Apply load-time-only settings that mihomo ignores on a runtime PATCH
    /// (geodata-*, unified-delay, keep-alive…): write them to config.yaml and
    /// reload. The current runtime TUN state is written back first so the reload
    /// (which re-reads the file) doesn't drop a running root TUN.
    func patchPersistent(_ overrides: [String: Any]) async {
        guard reachable else { showToast("内核未连接，无法修改配置"); return }
        engine.setTopLevelScalars(overrides)
        engine.setTunEnabled(tunOn)
        do {
            try await api.reloadConfig(path: engine.configFilePath)
            
            if overrides.keys.contains("external-controller") || overrides.keys.contains("secret") {
                // Wait briefly for the kernel to bind the new port before probing
                try? await Task.sleep(nanoseconds: 500_000_000)
                await reconnect()
            }
            
            await refreshConfigs()
            showToast("配置已更新")
        } catch {
            showToast("更新失败：\(error.localizedDescription)")
        }
    }

    /// Safely persist the proxy-providers list to config.yaml + reference them in
    /// the primary group, then reload. Backs up first and validates with
    /// `mihomo -t`; on any error the original config is restored (never corrupts a
    /// working subscription). Returns true on success.
    @discardableResult
    func saveProxyProviders(_ providers: [(name: String, url: String)]) async -> Bool {
        let path = engine.configFilePath
        let backup = try? String(contentsOfFile: path, encoding: .utf8)
        engine.writeProxyProviders(providers)
        engine.setTunEnabled(tunOn)   // preserve running TUN across reload
        if let err = await engine.validateConfig() {
            if let b = backup { try? b.write(toFile: path, atomically: true, encoding: .utf8) }
            showToast("配置无效，已回滚：\(err)")
            return false
        }
        do {
            try await api.reloadConfig(path: path)
            await refreshConfigs()
            await refreshProxies()
            showToast("订阅已保存")
            return true
        } catch {
            if let b = backup { try? b.write(toFile: path, atomically: true, encoding: .utf8) }
            showToast("保存失败，已回滚：\(error.localizedDescription)")
            return false
        }
    }

    func stopEngine() async {
        logKernel("正在停止核心...")
        await engine.stopKernel()
        reachable = false
        tunOn = false
        // 停核心时主动清理 Gateway 系统级 IP 转发（sysctl），防止残留
        if gatewayModeOn {
            _ = await engine.setGatewayMode(enabled: false)
        }
        gatewayModeOn = false
        await restoreTunnelDNS()
        if systemProxyOn {
            let port = proxyPort
            _ = await engine.setSystemProxy(enabled: false, port: port)
            systemProxyOn = false
        }
        logKernel("核心已停止")
        showToast("核心已停止")
    }

    func toggleEngine() {
        let want = !reachable
        withEngineBusy {
            if want {
                self.logKernel("正在请求启动核心...")
                self.showToast("正在启动核心...")
                self.engine.ensureRunning()

                // Wait and verify with smart backoff
                if await self.waitForKernelReady(maxAttempts: 6) {
                    self.logKernel("核心启动成功")
                    await self.reconnect()
                    return
                }

                // Not reachable after retries — surface the REAL reason.
                if let cfgErr = await self.engine.validateConfig() {
                    self.logKernel("配置错误，核心无法启动：\(cfgErr)")
                    self.showToast("配置错误：\(cfgErr)")
                } else {
                    self.logKernel("错误：核心未响应（启动超时或权限不足）")
                    self.showToast("核心启动失败，请检查内核与权限")
                }
            } else {
                await self.stopEngine()
            }
        }
    }

    func setMode(_ m: String) {
        mode = m
        Task {
            try? await api.patchConfig(["mode": m])
            // Mode switch (global/direct) changes the routing logic; close existing
            // connections so traffic re-dials through the new path immediately.
            if closeOnSwitch {
                try? await api.closeAllConnections()
            }
            // Refresh proxies after mode change (event-driven instead of polling)
            await refreshProxies()
            showToast("已切换至\(modeLabel(m))模式")
        }
    }

    // Rules (read-only view of the kernel's active rule set).
    // mihomo does NOT expose rules in /configs nor accept rule edits via PATCH;
    // rules are read from the dedicated /rules endpoint, editing is via profile YAML.
    func refreshRules() async {
        if let r = try? await api.fetchRules() { rules = r.rules }
    }
}
