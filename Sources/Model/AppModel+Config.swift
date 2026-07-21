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
        guard !engine.isBusy else { showToast("内核操作进行中，请稍候…", kind: .warn); return }
        let oldActiveID = store.activeID
        let backupContent = (try? String(contentsOfFile: engine.configFilePath, encoding: .utf8)) ?? ""
        
        guard let content = store.commit(id) else { showToast("配置为空", kind: .error); return }
        let name = store.profiles.first { $0.id == id }?.name ?? ""
        let wasTunOn = tunOn
        // Skip reload if the on-disk content matches the last applied hash.
        // `commit` just rewrote config.yaml with the same content, but the
        // kernel state is unchanged — avoid the hot-reload churn.
        if let last = store.profiles.first(where: { $0.id == id })?.appliedHash,
           last == Sha1.hex(content) {
            store.markApplied(id, hash: last)
            showToast("已切换配置「\(name)」", kind: .ok)
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
                noteConfigContentChanged()
                showToast("已切换配置「\(name)」", kind: .ok)
                await reconnect()
                await reapplyTUN(wasOn: wasTunOn)

                // Port-change cascade: if the new profile uses a different
                // mixed-port and the system proxy is on, re-set it so traffic
                // doesn't leak to the old (now dead) port.
                let newPort = proxyPort
                if systemProxyOn && newPort != oldPort {
                    let ok = await engine.setSystemProxy(enabled: true, port: newPort)
                    if ok { showToast("系统代理已更新至端口 \(newPort)", kind: .ok) }
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
                        showToast("网关配置重载失败", kind: .error)
                    }
                }

                // Refresh proxies after profile switch (event-driven)
                await refreshProxies()
            } else {
                showToast("配置错误：\(err ?? "")，已回滚", kind: .error)
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

    /// Public entry: coalesce concurrent callers onto a single in-flight run.
    /// The TUN bring-up path storm (utun creation + route + DNS change events)
    /// used to stack several parallel runs that raced each other's side effects
    /// (three duplicate static-route cleanups observed in helper logs). A caller
    /// arriving mid-run awaits the in-flight refresh instead of starting another.
    func refreshConfigs() async {
        if let inflight = refreshConfigsTask {
            await inflight.value
            return
        }
        let task = Task { await refreshConfigsBody() }
        refreshConfigsTask = task
        await task.value
        refreshConfigsTask = nil
    }

    private func refreshConfigsBody() async {
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

        if let m = c["mode"] as? String, m != mode { mode = m }
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
            // reachable is required: a stale in-flight /configs response after
            // stopKernel must not re-arm the TUN switch when the core is already
            // dead. runningAsRoot alone is insufficient (it was historically not
            // cleared on stop; even after that fix, residual utun can still exist).
            let shouldBeOn = reachable && configEnabled && engine.runningAsRoot && hasInterface

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
            if reachable && configEnabled && engine.runningAsRoot && !hasInterface && tunOn,
               !engine.isBusy, !tunAutoTeardownInFlight,
               Date() >= tunStateSettleUntil {
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
            if tunOn != shouldBeOn {
                if tunOn && !shouldBeOn && Date() < tunStateSettleUntil {
                    // Bring-up settle window: a transiently-false signal from the
                    // path-update storm must not flip the switch off and run the
                    // OFF cascade (route cleanup + DNS restore). Explicit teardowns
                    // (user toggle, stopEngine, unreachable reconnect) bypass this
                    // by writing tunOn directly / clearing the window first.
                    logKernel("TUN 稳定期内忽略瞬时状态抖动（reachable=\(reachable) enable=\(configEnabled) root=\(engine.runningAsRoot) iface=\(hasInterface)）")
                } else {
                    tunOn = shouldBeOn
                }
            }
        }
        // Gateway is user intent only (persisted via UserDefaults mirror). Never
        // infer it from config.yaml: residual `allow-lan + dns.listen=0.0.0.0:53`
        // left by a previous session / incomplete disable used to flip the switch
        // on at startup, then verifyGatewayConfig re-enforced sysctl IP forwarding
        // and could cascade into a black-hole network. The write path
        // (applyGatewayMode) remains the only place that turns Gateway on.
        if !gatewayModeOn {
            let dnsListen = (c["dns"] as? [String: Any])?["listen"] as? String
            if dnsListen == "0.0.0.0:53" {
                // Soft-clean residual Gateway DNS bind so a cold start with the
                // switch off does not keep hijacking LAN DNS / port 53.
                logKernel("检测到残留网关 DNS 监听（0.0.0.0:53），正在清理…")
                engine.setTopLevelScalars([
                    "dns": [
                        "enable": true,
                        "listen": "127.0.0.1:1053",
                        "enhanced-mode": "fake-ip"
                    ]
                ])
                noteConfigContentChanged()
                // Best-effort live reload; ignore failures (kernel may be down).
                try? await api.reloadConfig(path: engine.configFilePath)
                if var dns = configs["dns"] as? [String: Any] {
                    dns["listen"] = "127.0.0.1:1053"
                    configs["dns"] = dns
                }
                // Residual Gateway signature usually means a previous session left
                // IP forwarding on too — clear it once when we clean the config.
                if engine.isRoot {
                    _ = await engine.setGatewayMode(enabled: false)
                }
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
        // Fresh XPC (not cached helper()) — same silent-drop issue as start/sysproxy.
        if tunOn && !staticRoutesInjected {
            let excludeRoutes = await NetScanner.sdwanExcludeRoutes()
            if !excludeRoutes.isEmpty {
                let ok = await XPCManager.shared.callSetupExcludeRoutes(excludeRoutes)
                logKernel("XPC Helper 注入静态路由: \(ok == true ? "成功" : "失败")")
                if ok == true { staticRoutesInjected = true }
            } else {
                // If there are no routes to exclude, mark it as injected to prevent repeated checks
                staticRoutesInjected = true
            }
        } else if !tunOn && staticRoutesInjected {
            let ok = await XPCManager.shared.callCleanupAllExcludeRoutes()
            logKernel("XPC Helper 清理静态路由: \(ok == true ? "成功" : "失败")")
            if ok == true { staticRoutesInjected = false }
        }
    }

    // MARK: Master switches

    /// Guard + set + defer-reset wrapper for `engine.isBusy`. All long-running
    /// kernel lifecycle operations (TUN/engine/Gateway toggle, restart, kernel
    /// switch) must go through this so the isBusy flag has a single write path.
    /// Returns `false` and shows a toast if the engine is already busy.
    @discardableResult
    func withEngineBusy(_ label: String = "操作", _ body: @escaping () async -> Void) -> Bool {
        guard !engine.isBusy else { showToast("内核操作进行中，请稍候…", kind: .warn); return false }
        engine.isBusy = true
        Task {
            defer { engine.isBusy = false }
            await body()
        }
        return true
    }

    func toggleSystemProxy() {
        let on = !systemProxyOn
        let port = proxyPort
        // Hold isBusy for the full path (start kernel + set proxy) so TUN /
        // engine / rule reload cannot interleave mid-flight.
        withEngineBusy {
            if on && !self.reachable {
                self.showToast("正在启动核心以开启系统代理…")
                // System proxy only needs a listening mixed-port — do NOT force a
                // root upgrade restart (that path was multi-second and raced helper XPC).
                await self.engine.ensureRunningAsync(preferRoot: false)
                guard await self.waitForKernelReady(maxAttempts: 8) else {
                    self.showToast("内核启动超时，无法开启系统代理", kind: .error)
                    return
                }
                // reconnect() re-syncs proxy from SCDynamicStore (still off here).
                await self.reconnect()
            }

            let ok = await self.engine.setSystemProxy(enabled: on, port: port)
            if ok {
                // Prefer SCDynamicStore reality. Store can lag a beat after
                // networksetup — if it still disagrees with the write we just
                // did, trust the write so the switch doesn't stick off while
                // toast says "已开启".
                self.syncSystemProxyState()
                if self.systemProxyOn != on {
                    self.systemProxyOn = on
                }
                self.logKernel(on ? "系统代理已开启 (port \(port))" : "系统代理已关闭")
                if on {
                    self.showToast("系统代理已开启", kind: .ok)
                } else if !self.tunOn && self.reachable {
                    self.showToast("系统代理已关闭（内核仍在运行，可在侧栏停止）", kind: .ok)
                } else {
                    self.showToast("系统代理已关闭", kind: .ok)
                }

                // LAN clients that point HTTP/SOCKS at this Mac need allow-lan.
                // Gateway mode also sets it; system-proxy-only users previously
                // had to flip "允许局域网" by hand or open full Gateway. Runs
                // *after* the proxy is live + toast shown — it needs a config
                // patch + refresh and shouldn't delay the visible toggle result.
                if on {
                    await self.ensureAllowLanForSharing()
                }
            } else {
                self.syncSystemProxyState()
                self.logKernel("系统代理设置失败 (want=\(on), port=\(port))")
                await self.api.probe()
                if self.api.reachable {
                    self.showToast("系统代理设置失败", kind: .error)
                } else {
                    // Kernel is down too — say so instead of failing silently.
                    self.showToast("系统代理设置失败（内核未运行）", kind: .error)
                }
            }
        }
    }

    /// Ensure mihomo accepts LAN inbound connections (HTTP/SOCKS on mixed-port).
    /// Used when system proxy is on so other devices can point gateway/DNS or
    /// explicit proxy at this Mac without enabling full Gateway (IP forward).
    private func ensureAllowLanForSharing() async {
        guard reachable else { return }
        let allow = (configs["allow-lan"] as? Bool) == true
        // bind-address "*" or empty/"0.0.0.0" means all interfaces; some profiles
        // pin 127.0.0.1 which blocks LAN clients even with allow-lan.
        let bind = (configs["bind-address"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "*"
        let bindOK = bind.isEmpty || bind == "*" || bind == "0.0.0.0" || bind == "::"
        if allow && bindOK { return }

        var patch: [String: Any] = [:]
        if !allow { patch["allow-lan"] = true }
        if !bindOK { patch["bind-address"] = "*" }
        guard !patch.isEmpty else { return }

        // Persist so a profile reload / restart keeps LAN share available while
        // system proxy remains the user's chosen mode.
        engine.setTopLevelScalars(patch)
        do {
            try await api.patchConfig(patch)
            await refreshConfigs()
            logKernel("已开启 allow-lan，供局域网设备经 mixed-port 使用代理")
        } catch {
            logKernel("开启 allow-lan 失败：\(error.localizedDescription)")
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
                    self.showToast("TUN 启动失败，无法开启网关中枢", kind: .error)
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
                guard ok else { showToast("授权失败，未开启网关", kind: .error); return }
            }
            // Verify XPC connectivity even when a helper plist already exists;
            // a stale or unloaded LaunchDaemon cannot enable forwarding.
            guard await XPCManager.shared.verifyConnectivity() else {
                showToast("特权服务无法连接，未开启网关", kind: .error)
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
                    showToast("Root 内核启动超时，未开启网关", kind: .error)
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
                    showToast("端口冲突，正在回滚配置…", kind: .warn)
                    try? await api.reloadConfig(path: cfgPath)
                    await refreshConfigs()
                }
                preGatewayAllowLan = nil; preGatewayDNSListen = nil
                showToast("网关配置应用失败，请检查 53 端口是否被占用", kind: .error)
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
                    showToast("TUN 恢复失败，未开启网关中枢", kind: .error)
                    return
                }
            }

            let ok = await engine.setGatewayMode(enabled: true)
            if ok {
                gatewayModeOn = true
                noteConfigContentChanged()
                showToast("网关中枢（旁路由）已成功开启", kind: .ok)
            } else {
                gatewayModeOn = false
                gatewayDevices.removeAll(keepingCapacity: false)
                preGatewayAllowLan = nil; preGatewayDNSListen = nil
                showToast("底层 IP 转发开启失败", kind: .error)
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
                gatewayDevices.removeAll(keepingCapacity: false)
                do {
                    try await api.reloadConfig(path: engine.configFilePath)
                    await refreshConfigs()
                    noteConfigContentChanged()
                    showToast("网关中枢已关闭", kind: .ok)
                } catch {
                    noteConfigContentChanged()
                    showToast("网关中枢已关闭，配置重载失败", kind: .warn)
                }
            } else {
                showToast("网关中枢关闭失败", kind: .error)
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
        // Explicit disable is user/system intent — lift the bring-up settle
        // window so the OFF derivation is never blocked.
        if !want { tunStateSettleUntil = .distantPast }
        if want && !reachable {
            showToast("正在启动核心以启用 TUN…")
            // TUN needs root. Verify helper before forcing isRoot — a stale
            // isRoot=true + fire-and-forget ensureRunning used to no-op when the
            // cached XPC proxy dropped startMihomo, then surface as "权限不足".
            var helperOK = await XPCManager.shared.verifyConnectivity()
            if !helperOK {
                showToast("启用 TUN 需要管理员授权以安装特权服务…")
                let installed = await engine.installPrivileged()
                guard installed else { showToast("授权失败，TUN 未启用", kind: .error); return }
                helperOK = await XPCManager.shared.verifyConnectivity()
                guard helperOK else {
                    showToast("特权服务安装后无法连接，请重启应用或检查 system 日志", kind: .error)
                    engine.isRoot = false
                    return
                }
            }
            engine.isRoot = true
            await engine.ensureRunningAsync()
            guard await waitForKernelReady(maxAttempts: 10) else {
                showToast("内核启动超时，TUN 无法启用", kind: .error)
                return
            }
            // refreshConfigs gates tunOn on `reachable`. Without reconnect here
            // reachable stays false → false "开启失败" even when root+utun are OK.
            await reconnect()
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
                logKernel("TUN 路由排除：自动注入网络拓扑前缀 \(sdwanPrefixes.joined(separator: ", "))")
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

        // TUN requires root. Covers: core already up in user-mode, or the
        // !reachable branch above fell back to user-mode.
        if want && !engine.runningAsRoot {
            if !engine.isRoot {
                showToast("启用 TUN 需要管理员授权以安装特权服务…")
                let ok = await engine.installPrivileged()
                guard ok else { showToast("授权失败，TUN 未启用", kind: .error); return }
                // Verify XPC connectivity after installation to catch launchd bootstrap failures
                let connected = await XPCManager.shared.verifyConnectivity()
                guard connected else {
                    showToast("特权服务安装后无法连接，请重启应用或检查 system 日志", kind: .error)
                    engine.isRoot = false  // Reset to prevent permanent lock
                    return
                }
            } else {
                // Re-verify even when isRoot is true — after auto-stop cascade the
                // flag can lag a dead LaunchDaemon, and restart would then no-op.
                let connected = await XPCManager.shared.verifyConnectivity()
                if !connected {
                    showToast("特权服务无法连接，TUN 未启用", kind: .error)
                    engine.isRoot = false
                    return
                }
                if engine.helperVersion != EngineControl.kExpectedHelperVersion,
                   engine.helperVersion != "?" {
                    // Helper version mismatch detected during TUN toggle.
                    // This should rarely happen since app startup auto-upgrades,
                    // but handle it gracefully just in case.
                    showToast("特权服务需要更新，正在自动升级…")
                    let upgraded = await engine.checkAndUpgradeHelperIfNeeded()
                    guard upgraded else {
                        showToast("Helper 升级失败，TUN 未启用", kind: .error)
                        return
                    }
                }
            }

            showToast("正在以 Root 权限重启核心…")
            await engine.restart()
            // restart = stop + start; cold root spawn often needs a longer window.
            guard await waitForKernelReady(maxAttempts: 12) else {
                showToast("Root 内核启动超时，TUN 未启用", kind: .error)
                return
            }
            await self.reconnect()
            if !engine.runningAsRoot {
                await engine.syncRunningAsRootIfNeeded()
            }
            if !engine.runningAsRoot {
                showToast("Root 内核未就绪，TUN 未启用", kind: .error)
                logKernel("TUN 中止：restart 后 runningAsRoot 仍为 false")
                return
            }
        }

        let ok = await engine.patchConfig(overrides)
        if ok {
            // Arm the settle window immediately — the path-update storm begins
            // the moment the kernel creates the utun, i.e. right at this PATCH.
            if want { tunStateSettleUntil = Date().addingTimeInterval(10) }
            // refreshConfigs sets tunOn from the *actual* kernel state
            // (enable && runningAsRoot && hasInterface, per B9) — do not blindly
            // set tunOn=want. A user-mode kernel accepts the PATCH (HTTP 200) but
            // cannot create the utun device and silently reverts enable to false.
            //
            // Important: PATCH returns before utun is fully up. Refreshing too
            // early yields hasInterface=false → a false "开启失败" toast, then a
            // later poll/refresh looks like a second "success". Wait for the
            // interface (or a short deadline) before the single final toast.
            if want {
                let up = await waitForTUNInterface()
                if !up {
                    logKernel("TUN PATCH 已接受，等待 utun 出现超时，仍按实际状态核对…")
                }
            }
            await refreshConfigs()
            if want && !tunOn {
                // One more delayed reconcile in case route/flags lag past the wait.
                try? await Task.sleep(nanoseconds: 400_000_000)
                await refreshConfigs()
            }
            if want && !tunOn {
                showToast("TUN 开启失败：可能无管理员权限或路由被其他 VPN 占用冲突", kind: .error)
                logKernel("TUN 开启失败：runningAsRoot=\(engine.runningAsRoot) reachable=\(reachable)")
            } else {
                // TUN disable cascades: Gateway mode requires TUN, so if we
                // just turned TUN off, also tear down Gateway (sysctl + UI +
                // restore the allow-lan/dns.listen overrides Gateway applied).
                if !want && gatewayModeOn {
                    _ = await engine.setGatewayMode(enabled: false)
                    gatewayModeOn = false
                    gatewayDevices.removeAll(keepingCapacity: false)
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
                    noteConfigContentChanged()
                }
                // No auto-stopEngine when both proxy faces are off — keep the core
                // warm so re-enabling TUN is a PATCH, not a full root restart.
                if want {
                    showToast("TUN 模式已开启", kind: .ok)
                } else if !systemProxyOn && reachable {
                    showToast("TUN 模式已关闭（内核仍在运行，可在侧栏停止）", kind: .ok)
                } else {
                    showToast("TUN 模式已关闭", kind: .ok)
                }
            }
        } else {
            await api.probe()
            if api.reachable {
                showToast(want ? "TUN 模式开启失败" : "TUN 模式关闭失败", kind: .error)
            } else {
                // Kernel died mid-flight — surface it instead of failing silently.
                showToast(want ? "TUN 开启失败（内核未运行）" : "TUN 已随内核停止关闭", kind: want ? .error : .ok)
            }
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
    ///
    /// Ordering matters: the `overridden` flag is only set AFTER the
    /// networksetup write succeeds. Flag-first used to desync the state machine
    /// when the write failed mid path-storm — overridden=1 with system DNS still
    /// at the original value, so later teardowns "restored" a redirect that
    /// never happened and health checks believed the redirect was live.
    func enableTunnelDNS() async {
        let gateway = tunnelDNSAddress()
        let d = UserDefaults.standard
        let wasOverridden = d.bool(forKey: Self.kDNSOverriddenKey)
        var snapshot: String? = nil
        if !wasOverridden {
            let original = await EngineControl.currentSystemDNS()
            // Use sentinel value "Empty" if system DNS is unconfigured (common on fresh macOS)
            snapshot = original.isEmpty ? "Empty" : original.joined(separator: ",")
        }
        let ok = await EngineControl.applySystemDNS([gateway])
        guard ok else {
            logKernel("TUN DNS 重定向写入失败，保持原状态待下次巡检重试")
            return
        }
        if !wasOverridden, let snapshot {
            d.set(snapshot, forKey: Self.kDNSSavedKey)
            d.set(true, forKey: Self.kDNSOverriddenKey)
        }
    }

    /// Restore the system DNS saved before TUN took over (no-op if we never
    /// overrode it). Idempotent — safe to call from every teardown path.
    /// The flag is only cleared after the restore write succeeds, so a failed
    /// networksetup keeps the state machine armed for the next teardown pass.
    func restoreTunnelDNS() async {
        let d = UserDefaults.standard
        guard d.bool(forKey: Self.kDNSOverriddenKey) else { return }
        let savedString = d.string(forKey: Self.kDNSSavedKey) ?? ""
        // Handle sentinel "Empty" by clearing DNS (networksetup needs "Empty" literal)
        let saved = savedString == "Empty" ? ["Empty"] : savedString.split(separator: ",").map(String.init)
        let ok = await EngineControl.applySystemDNS(saved)
        guard ok else {
            logKernel("TUN DNS 恢复写入失败，保留重定向标记待重试")
            return
        }
        d.set(false, forKey: Self.kDNSOverriddenKey)
        d.removeObject(forKey: Self.kDNSSavedKey)
    }

    /// Deep-merge config overrides into the running config via the engine
    /// (validate + rollback). The primitive behind all settings forms.
    func patch(_ overrides: [String: Any]) async {
        guard reachable else {
            showToast("内核未连接，无法修改配置", kind: .error)
            return
        }

        let ok = await engine.patchConfig(overrides)
        if ok {
            await refreshConfigs()
            showToast("配置已更新", kind: .ok)
        } else {
            // Check if it just died
            await api.probe(timeout: 0.5)
            if api.reachable {
                showToast("内核拒绝了该配置修改", kind: .error)
            } else {
                reachable = false
                showToast("内核已断开，配置写入失败", kind: .error)
            }
        }
    }

    /// Apply load-time-only settings that mihomo ignores on a runtime PATCH
    /// (geodata-*, unified-delay, keep-alive…): write them to config.yaml and
    /// reload. The current runtime TUN state is written back first so the reload
    /// (which re-reads the file) doesn't drop a running root TUN.
    func patchPersistent(_ overrides: [String: Any]) async {
        guard reachable else { showToast("内核未连接，无法修改配置", kind: .error); return }
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
            noteConfigContentChanged()
            showToast("配置已更新", kind: .ok)
        } catch {
            showToast("更新失败：\(error.localizedDescription)", kind: .error)
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
            showToast("配置无效，已回滚：\(err)", kind: .error)
            return false
        }
        do {
            try await api.reloadConfig(path: path)
            await refreshConfigs()
            await refreshProxies()
            noteConfigContentChanged()
            showToast("订阅已保存", kind: .ok)
            return true
        } catch {
            if let b = backup { try? b.write(toFile: path, atomically: true, encoding: .utf8) }
            showToast("保存失败，已回滚：\(error.localizedDescription)", kind: .error)
            return false
        }
    }

    func stopEngine() async {
        logKernel("正在停止核心...")
        // Snapshot residual state before stopKernel clears ownership flags.
        // TUN is runtime-only, but reloads may have written tun.enable=true to
        // disk to preserve a live root TUN — force it back off so the next
        // ensureRunning cannot auto-bring TUN up from a dead session.
        let hadTun = tunOn
        let hadStaticRoutes = staticRoutesInjected
        await engine.stopKernel()
        reachable = false
        tunOn = false
        engine.forceTUNDisabled()
        // 停核心时主动清理 Gateway 系统级 IP 转发（sysctl），防止残留
        if gatewayModeOn {
            _ = await engine.setGatewayMode(enabled: false)
        }
        gatewayModeOn = false
        gatewayDevices.removeAll(keepingCapacity: false)
        await restoreTunnelDNS()
        if systemProxyOn {
            let port = proxyPort
            _ = await engine.setSystemProxy(enabled: false, port: port)
            systemProxyOn = false
        }
        // Clear SD-WAN static routes that were injected while TUN was live.
        // stopKernel does not touch Helper route state; without this, excluded
        // prefixes stay pinned after the core is gone. Fresh XPC only.
        if hadStaticRoutes {
            let ok = await XPCManager.shared.callCleanupAllExcludeRoutes()
            logKernel("XPC Helper 清理静态路由: \(ok == true ? "成功" : "失败")")
            if ok == true || ok == nil {
                // nil = helper unreachable: drop the local flag so we retry inject
                // on next TUN up rather than believing routes still managed.
                staticRoutesInjected = false
            }
        }
        // Physical residual: killall may leave a downed 198.18 utun whose
        // Supplemental DNS resolver still pins the fake-ip gateway. Only act
        // when a downed proxyTun is present (or TUN was on and still visible).
        // Note: do not put `await` on the RHS of `||` — Swift autoclosure there
        // does not support concurrency.
        var residualVisible = NetScanner.hasDownedMihomoTun()
        if !residualVisible && hadTun {
            residualVisible = await NetScanner.mihomoTunInterface() != nil
        }
        if residualVisible {
            logKernel("停核后检测到 TUN 残留，请求特权服务物理清理...")
            let ok = await XPCManager.shared.callCleanupTUNResidual()
            if ok != true {
                logKernel("停核后 TUN 物理清理: 特权服务未完成或不可达")
            }
        }
        logKernel("核心已停止")
        showToast("核心已停止", kind: .ok)
    }

    func toggleEngine() {
        let want = !reachable
        withEngineBusy {
            if want {
                self.logKernel("正在请求启动核心...")
                self.showToast("正在启动核心...")
                await self.engine.ensureRunningAsync()

                // Wait and verify with smart backoff
                if await self.waitForKernelReady(maxAttempts: 6) {
                    self.logKernel("核心启动成功")
                    await self.reconnect()
                    return
                }

                // Not reachable after retries — surface the REAL reason.
                if let cfgErr = await self.engine.validateConfig() {
                    self.logKernel("配置错误，核心无法启动：\(cfgErr)")
                    self.showToast("配置错误：\(cfgErr)", kind: .error)
                } else {
                    self.logKernel("错误：核心未响应（启动超时或权限不足）")
                    self.showToast("核心启动失败，请检查内核与权限", kind: .error)
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
            showToast("已切换至\(modeLabel(m))模式", kind: .ok)
        }
    }

    // Rules (read-only view of the kernel's active rule set).
    // mihomo does NOT expose rules in /configs nor accept rule edits via PATCH;
    // rules are read from the dedicated /rules endpoint, editing is via profile YAML.
    func refreshRules() async {
        if let r = try? await api.fetchRules() { rules = r.rules }
    }
}
