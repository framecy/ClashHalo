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
            var (ok, err) = await engine.setConfig(content)
            // `setConfig` applies the YAML by hot-reloading a running kernel, so
            // it necessarily fails when there is no kernel — the normal state
            // right after 清空全部, and after any manual stop. The file it just
            // wrote is still the one we want, so start the kernel on it instead
            // of reporting a config error and rolling back a perfectly good
            // profile.
            if !ok && !reachable {
                logKernel("内核未运行，改为以新配置启动内核…")
                engine.isRoot = await XPCManager.shared.verifyConnectivity()
                await engine.ensureRunningAsync(preferRoot: engine.isRoot)
                ok = await waitForKernelReady(maxAttempts: 10)
                err = ok ? nil : "内核启动失败"
                if ok { await reconnect() }
            }
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
            let excludeRoutes = Coexistence.excludeRouteMap(await Coexistence.detect())
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
        // Seed the persistent step banner with the operation label; flow bodies
        // refine it via `.info` toasts (see showToast). Setting isBusy=false in
        // the defer auto-clears busyStep (EngineControl.isBusy didSet).
        engine.busyStep = label
        Task {
            defer { engine.isBusy = false }
            await body()
        }
        return true
    }

    /// Delete every profile and leave the machine in a clean, inert state.
    ///
    /// Order is the whole point. Deleting the files first would strand the
    /// machine: the system proxy would keep pointing at a dead mixed-port and
    /// TUN would keep owning the default route for a kernel that no longer has
    /// a config — both are full-network outages that the user cannot undo from
    /// an app whose config is gone. So every piece of running state comes down
    /// first, while `config.yaml` still exists for the teardown paths that edit
    /// it (`forceTUNDisabled`), and only then does storage get wiped.
    ///
    /// `stopEngine()` already cascades the rest — Gateway mode, tunnel DNS
    /// restore, system proxy, Helper-injected static routes, residual utun — so
    /// this adds only what is specific to a wipe: an orderly TUN teardown that
    /// withdraws the coexistence exclusions before the kernel goes away, and
    /// dropping the provenance/fingerprint records that describe a config which
    /// will not exist a moment later.
    func deleteAllProfiles() {
        guard !store.profiles.isEmpty else { return }
        _ = withEngineBusy("正在清空全部配置…") {
            if self.tunOn {
                self.showToast("正在关闭 TUN…")
                await self.applyTUNState(false, allowRestartFallback: false)
            }
            await self.stopEngine()

            let failed = self.store.removeAll()
            self.pendingApplyID = nil
            // The exclusions we injected are gone with the config that held
            // them; a record claiming otherwise would make the next TUN session
            // withdraw entries it never wrote.
            Coexistence.commitProvenance(field: "route-exclude-address", injected: [])
            self.lastCoexistenceFingerprint = ""

            self.logKernel("已清空全部配置文件，系统代理与 TUN 已关闭，内核已停止")
            if failed.isEmpty {
                self.showToast("已清空全部配置。导入新配置后需重新开启系统代理 / TUN", kind: .ok)
            } else {
                // Root-owned leftovers from a root kernel session. Harmless —
                // the next kernel overwrites them — but say so rather than
                // report a clean wipe that wasn't.
                let list = failed.joined(separator: "、")
                self.logKernel("以下缓存归 root 所有，用户态无法删除，已保留：\(list)")
                self.showToast("配置已清空；缓存 \(list) 需管理员权限，已保留", kind: .warn)
            }
        }
    }

    func toggleSystemProxy() {
        // With no profile there is no config.yaml to start a kernel from, so the
        // enable path would fork mihomo, time out, and blame the timeout. Say
        // the real reason instead.
        guard systemProxyOn || !store.profiles.isEmpty else {
            showToast("请先导入配置后再开启系统代理", kind: .warn); return
        }
        let on = !systemProxyOn
        let port = proxyPort
        // Hold isBusy for the full path (start kernel + set proxy) so TUN /
        // engine / rule reload cannot interleave mid-flight.
        withEngineBusy(on ? "正在开启系统代理…" : "正在关闭系统代理…") {
            if on && !self.reachable {
                self.showToast("正在启动核心以开启系统代理…")
                // Start as root when the helper is available so the kernel keeps a
                // single identity (see the ownership note in AppModel.start), but
                // never restart an already-running user-mode kernel just to gain
                // root: the system proxy only needs a listening mixed-port, and
                // that upgrade-restart is what made this toggle feel dead (v1.1.4).
                self.engine.isRoot = await XPCManager.shared.verifyConnectivity()
                await self.engine.ensureRunningAsync(preferRoot: self.engine.isRoot,
                                                     allowRootUpgradeRestart: false)
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
                } else {
                    // Nothing routes through the kernel any more — release the
                    // connections still pinned to it so traffic re-dials direct.
                    await self.dropAllConnectionsWhenIdle()
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

    /// Drop every connection the kernel still holds once no forwarding face is
    /// active. Turning TUN / the system proxy off only changes where *new*
    /// traffic goes: sockets already established through mihomo stay alive and
    /// keep carrying data through a kernel that is no longer supposed to be in
    /// the path, so long-lived connections (streams, websockets, downloads)
    /// silently keep using the old route after the user flipped everything off.
    /// Closing them forces an immediate re-dial, which now goes direct.
    ///
    /// Deliberately gated on Gateway being off too: Gateway exists to serve LAN
    /// clients through this kernel, so tearing their connections down while it
    /// is on would be sabotage rather than cleanup.
    func dropAllConnectionsWhenIdle() async {
        guard reachable, !tunOn, !systemProxyOn, !gatewayModeOn else { return }
        do {
            try await api.closeAllConnections()
            logKernel("TUN 与系统代理均已关闭，已断开全部既有连接以恢复直连")
        } catch {
            logKernel("断开既有连接失败：\(error.localizedDescription)")
        }
    }

    func toggleTUN() {
        // Same reason as `toggleSystemProxy`: enabling TUN without a config
        // would restart a kernel that has nothing to load, and the failure would
        // surface as a privilege/route conflict it is not.
        guard tunOn || !store.profiles.isEmpty else {
            showToast("请先导入配置后再开启 TUN", kind: .warn); return
        }
        let want = !tunOn
        withEngineBusy(want ? "正在开启 TUN 模式…" : "正在关闭 TUN 模式…") {
            await self.applyTUNState(want)
        }
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

    // MARK: - TUN coexistence with other tunnels

    /// A complete `tun` PATCH body carrying `enable` and the shape fields.
    ///
    /// `PATCH /configs` **replaces** each nested object rather than deep-merging
    /// it: sending `tun: {route-exclude-address: [...]}` alone comes back with
    /// `enable: false` and an empty `device`, i.e. it silently tears TUN down.
    /// Every tun PATCH must therefore restate the full runtime shape.
    func tunPatchBody(enable: Bool, extra: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "enable": enable,
            "stack": (configs["tun"] as? [String: Any])?["stack"] ?? "gvisor",
            "auto-route": true,
            "auto-detect-interface": true
        ]
        // Ask for our own name rather than accepting the next free index. Only on
        // enable — a disable PATCH has no device to name.
        if enable, let dev = pinnedTunDevice { body["device"] = dev }
        for (k, v) in extra { body[k] = v }
        return body
    }

    /// The utun name to request, or nil once this kernel has proven it will not
    /// honour one.
    ///
    /// The pin is what makes our interface identifiable (198.18 is shared with
    /// other proxy apps) and stable across reboots. It is also the one thing here
    /// a kernel could reject, and a rejected pin means no TUN at all — so
    /// `applyTUNState` watches for that, sets this flag, and never asks again on
    /// this machine. Worst case is therefore the old kernel-assigned behaviour,
    /// not a broken tunnel.
    var pinnedTunDevice: String? {
        UserDefaults.standard.bool(forKey: Self.kTunPinUnsupportedKey) ? nil : kPinnedTunDevice
    }

    static let kTunPinUnsupportedKey = "tun.device.pinUnsupported"

    /// Record that the kernel would not take the pinned name, and stop asking.
    func disableTunDevicePin() {
        UserDefaults.standard.set(true, forKey: Self.kTunPinUnsupportedKey)
        NetScanner.pinnedDeviceActive = false
        engine.setTunDevice(nil)
    }

    /// Fold the route half of a coexistence plan into a pending tun PATCH body.
    ///
    /// Route exclusion only. The DNS half (`fake-ip-filter` / `nameserver-policy`)
    /// is deliberately *not* handled here: mihomo accepts a runtime DNS PATCH with
    /// 204 and then ignores it entirely — verified against a live kernel — and
    /// `GET /configs` returns an empty `dns` object, so there is no safe basis for
    /// a merge either. DNS coexistence has to go through config.yaml + reload,
    /// which is a heavier and more disruptive operation than this path should
    /// ever trigger implicitly. See `coexistenceDNSAdvice`.
    ///
    /// Provenance is *not* recorded here — the caller records it only after the
    /// kernel has accepted the change, so a dropped PATCH cannot leave us
    /// believing we applied something we did not.
    func coexistenceRouteBody(_ plan: CoexistencePlan) -> [String]? {
        guard !plan.routeExcludes.isEmpty else { return nil }
        let existing = (configs["tun"] as? [String: Any])?["route-exclude-address"] as? [String] ?? []
        return Coexistence.mergePreservingUserEntries(
            field: "route-exclude-address",
            desired: plan.routeExcludes,
            in: existing
        )
    }

    /// Re-apply route coexistence when the set of peer tunnels changes *while TUN
    /// is already up* — a VPN connecting after TUN, a new subnet route being
    /// accepted, or a peer disconnecting. Injection used to happen only at the
    /// moment TUN was enabled, so any of those left the exclusions stale until
    /// the user toggled TUN by hand.
    ///
    /// Gated on the plan fingerprint: mihomo ACKs a PATCH before deciding whether
    /// it can apply it, so pushing an unchanged plan on every poll risks a real
    /// change being lost in the churn.
    func reconcileCoexistenceIfChanged() async {
        guard tunOn, reachable, !engine.isBusy, !sleeping else { return }
        guard Date() >= tunStateSettleUntil else { return }
        let plan = Coexistence.plan(await Coexistence.detect())
        let fp = Coexistence.fingerprint(plan)
        guard fp != lastCoexistenceFingerprint else { return }
        guard let excludes = coexistenceRouteBody(plan) else { return }

        logKernel("TUN 共存：检测到网络拓扑变化，正在同步排除规则…")
        let ok = await engine.patchConfig([
            "tun": tunPatchBody(enable: true, extra: ["route-exclude-address": excludes])
        ])
        // Only now is the change real. Recording provenance/fingerprint on a
        // failed PATCH would both skip the retry and mis-attribute the entries
        // as ours on the next withdrawal pass.
        guard ok else {
            logKernel("TUN 共存：同步失败，保留原有排除规则")
            return
        }
        Coexistence.commitProvenance(field: "route-exclude-address", injected: plan.routeExcludes)
        lastCoexistenceFingerprint = fp
    }

    /// Peer subnets the tailnet advertises that the local route table does not
    /// carry. Read-only diagnostic; see `Coexistence.tailscaleSubnetGaps`.
    func peerSubnetGaps() async -> [Coexistence.PeerSubnetGap] {
        await Coexistence.tailscaleSubnetGaps(interfaces: NetScanner.interfaces(),
                                              routes: NetScanner.allRoutes())
    }

    /// Resolver pins (`<address>#<utunN>`) in config.yaml that no longer name the
    /// interface their peer is actually on. Read-only — see
    /// `repairDNSInterfaceBindings` for the fix.
    func dnsInterfaceDrift() async -> [Coexistence.ResolverDrift] {
        let desired = Coexistence.resolverInterfaces(Coexistence.plan(await Coexistence.detect()))
        guard !desired.isEmpty else { return [] }
        return Coexistence.resolverDrift(configured: engine.dnsResolverBindings(), desired: desired)
    }

    /// Repoint drifted resolver pins at the right interfaces, then reload.
    ///
    /// User-triggered only. This is the channel the automatic path deliberately
    /// refuses to take (see `coexistenceRouteBody`): it rewrites the user's file
    /// and a reload restarts DNS, dropping in-flight connections. Backed up and
    /// validated first, rolled back on any failure — a bad edit here costs name
    /// resolution outright.
    @discardableResult
    func repairDNSInterfaceBindings() async -> Bool {
        let drift = await dnsInterfaceDrift()
        guard !drift.isEmpty else {
            showToast("DNS 出口绑定无需修复", kind: .ok)
            return true
        }
        let path = engine.configFilePath
        let backup = try? String(contentsOfFile: path, encoding: .utf8)
        let map = Dictionary(uniqueKeysWithValues: drift.map { ($0.resolver, $0.to) })
        let n = engine.rebindDNSResolvers(map)
        guard n > 0 else { return false }
        engine.setTunEnabled(tunOn)      // a reload re-reads the file; keep TUN as-is
        if tunOn { engine.setTunDevice(pinnedTunDevice) }

        func rollback(_ reason: String) {
            if let b = backup { try? b.write(toFile: path, atomically: true, encoding: .utf8) }
            showToast("DNS 出口修复失败，已回滚：\(reason)", kind: .error)
        }
        if let err = await engine.validateConfig() {
            rollback(err)
            return false
        }
        do {
            try await api.reloadConfig(path: path)
        } catch {
            rollback(error.localizedDescription)
            return false
        }
        await refreshConfigs()
        noteConfigContentChanged()
        for d in drift { logKernel("DNS 出口绑定修复：\(d.resolver)#\(d.from) → #\(d.to)") }
        showToast("已修复 \(n) 处 DNS 出口绑定", kind: .ok)
        return true
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
    ///
    /// - Parameter allowRestartFallback: when the PATCH path fails to produce a
    ///   utun, retry once via the persist-flag + restart path (see the failure
    ///   branch). Recursive retries pass false so a genuinely broken TUN cannot
    ///   loop restarts.
    func applyTUNState(_ want: Bool, allowRestartFallback: Bool = true) async {
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

        var tunOverrideMap = tunPatchBody(enable: want)

        // Carve out routing room for every other tunnel on the machine before TUN
        // takes over. (The DNS half cannot ride along here — mihomo ignores a
        // runtime DNS PATCH; see `coexistenceRouteBody`.)
        var pendingRouteProvenance: [String]?
        if want {
            let plan = Coexistence.plan(await Coexistence.detect())
            if let excludes = coexistenceRouteBody(plan) {
                tunOverrideMap["route-exclude-address"] = excludes
                pendingRouteProvenance = plan.routeExcludes
                logKernel("TUN 共存：排除 \(plan.routeExcludes.count) 个网段（\(plan.peerSummary)）")
            }
            // Reported, not applied — mihomo ignores a runtime DNS PATCH, and the
            // only working channel (rewrite config.yaml + reload) is too
            // destructive to run behind the user's back. See `dnsAdvice`.
            for line in plan.dnsAdvice {
                logKernel("TUN 共存（需手动配置）：\(line)")
            }
            lastCoexistenceFingerprint = Coexistence.fingerprint(plan)
        } else {
            // Strip what we injected so a peer's prefixes do not outlive the TUN
            // session that needed them. Withdrawal must remove the entries, not
            // merely forget them — forgetting promotes them to user-owned and
            // they would then survive forever.
            let existing = (configs["tun"] as? [String: Any])?["route-exclude-address"] as? [String] ?? []
            let kept = Coexistence.withdraw(field: "route-exclude-address", from: existing)
            if kept.count != existing.count { tunOverrideMap["route-exclude-address"] = kept }
            pendingRouteProvenance = []
            lastCoexistenceFingerprint = ""
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
            // Bring TUN up as part of the kernel's own initialization rather than
            // PATCHing it in afterwards. mihomo answers `PATCH /configs` with 200
            // before it decides whether it can apply the change, and an update
            // that lands while a freshly started kernel is still settling (proxy
            // providers fetching) is dropped silently: `tun.enable` stays false,
            // no utun is ever created, and the user sees "第一次点击失败、第二次
            // 才成功" (the second PATCH hits a settled kernel). Persisting the
            // flag before the restart removes the race entirely.
            // `forceTUNDisabled()` at the next launch keeps a stale `true` from
            // auto-enabling TUN without privileges.
            engine.setTunEnabled(true)
            // This start reads the file, not the PATCH — the name has to be there
            // too or the restart path lands on a kernel-assigned utun.
            engine.setTunDevice(pinnedTunDevice)
            let tRestart = Date()
            await engine.restart()
            logKernel("TUN 阶段：root 重启完成 +\(String(format: "%.2f", Date().timeIntervalSince(tRestart)))s")
            // restart = stop + start; a cold root spawn must parse the profile and
            // load geodata before the controller answers. `maxAttempts` is now
            // honoured literally (it used to be silently capped at 8 ≈ 3.2 s, too
            // short for a real profile) — 18 attempts ≈ 13 s of headroom.
            let tReady = Date()
            guard await waitForKernelReady(maxAttempts: 18) else {
                logKernel("TUN 阶段：内核就绪等待超时 +\(String(format: "%.2f", Date().timeIntervalSince(tReady)))s")
                showToast("Root 内核启动超时，TUN 未启用", kind: .error)
                return
            }
            logKernel("TUN 阶段：内核就绪 +\(String(format: "%.2f", Date().timeIntervalSince(tReady)))s")
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

        let tPatch = Date()
        var ok = await engine.patchConfig(overrides)
        logKernel("TUN 阶段：PATCH(enable=\(want)) \(ok ? "接受" : "拒绝") +\(String(format: "%.2f", Date().timeIntervalSince(tPatch)))s")
        // HTTP 200 is not proof of application (see the note on the pre-restart
        // setTunEnabled): read the value back and re-PATCH while it disagrees.
        if ok {
            ok = await confirmTunFlagApplied(want: want, overrides: overrides)
        }
        if ok {
            // The kernel took the payload — only now may we claim the coexistence
            // entries as ours. Recording earlier would mis-attribute them on the
            // next withdrawal pass if the PATCH had been dropped.
            if let injected = pendingRouteProvenance {
                Coexistence.commitProvenance(field: "route-exclude-address", injected: injected)
            }
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
                // This wait can legitimately run for ~10 s on a cold root kernel,
                // so give the busy banner an accurate step instead of leaving it
                // on the previous one.
                showToast("正在等待 TUN 虚拟网卡就绪…")
                let tIface = Date()
                let up = await waitForTUNInterface()
                let elapsed = String(format: "%.2f", Date().timeIntervalSince(tIface))
                if up {
                    logKernel("TUN 阶段：utun 就绪 +\(elapsed)s")
                } else {
                    logKernel("TUN 阶段：等待 utun 超时 +\(elapsed)s，仍按实际状态核对…")
                }
            }
            // Decisive re-checks must never read a cached negative: the interface
            // lookup caches `nil` like any other result, so a reconcile inside the
            // TTL would re-read the very `nil` the wait above just stored and
            // reach the same verdict — the retry was a guaranteed no-op, and a
            // TUN that came up slightly late still surfaced as "开启失败".
            if want { NetScanner.invalidateTunCache() }
            await refreshConfigs()
            if want && !tunOn {
                // Two more spaced reconciles in case route/flags lag past the wait.
                for delay in [400_000_000, 1_200_000_000] as [UInt64] {
                    try? await Task.sleep(nanoseconds: delay)
                    NetScanner.invalidateTunCache()
                    await refreshConfigs()
                    if tunOn { break }
                }
            }
            if want && !tunOn, pinnedTunDevice != nil {
                // Requesting a specific utun name is the one demand this flow makes
                // that a kernel could refuse or ignore outright, and either way the
                // result looks identical to "no TUN": with the pin active,
                // `mihomoTunInterface` only accepts our name, so a tunnel brought up
                // under a kernel-assigned one reads as absent.
                //
                // Give the name up and retry once — the pin is an improvement, never
                // a requirement. This also swallows an unrelated transient failure
                // into a permanent fallback, which is the deliberate trade: the cost
                // is losing the pin's benefits on this machine, i.e. exactly the
                // behaviour every earlier build had.
                logKernel("TUN 未出现在固定设备名 \(kPinnedTunDevice) 上，放弃固定名后重试…")
                disableTunDevicePin()
                await applyTUNState(want, allowRestartFallback: allowRestartFallback)
                return
            }
            if want && !tunOn {
                // The kernel returned 200 and even read `enable: true` back, yet no
                // utun exists. That is the documented silent-drop above: mihomo ACKs
                // `PATCH /configs` before deciding whether it can apply the change,
                // so a PATCH landing on a still-settling kernel updates the reported
                // value while the TUN subsystem never starts. The pre-restart persist
                // is the known-reliable answer, but it only runs on the
                // `!runningAsRoot` branch — an already-root kernel that happens to
                // have restarted moments ago (health check, profile switch, crash
                // respawn) takes the plain PATCH path and loses the same race. That
                // is the "第一次点击失败、第二次才成功" the comment predicts.
                //
                // Rather than surface a failure the user fixes by clicking again,
                // run that reliable path once: persist the flag and restart so TUN
                // comes up during kernel init, then re-derive from reality.
                if allowRestartFallback {
                    logKernel("TUN 首次 PATCH 未生成 utun，回退到持久化+重启路径重试…")
                    showToast("正在重启核心以启用 TUN…")
                    engine.setTunEnabled(true)
                    engine.setTunDevice(pinnedTunDevice)
                    await engine.restart()
                    if await waitForKernelReady(maxAttempts: 18) {
                        await reconnect()
                        if !engine.runningAsRoot { await engine.syncRunningAsRootIfNeeded() }
                        _ = await waitForTUNInterface()
                        NetScanner.invalidateTunCache()
                        await refreshConfigs()
                    } else {
                        logKernel("TUN 回退重试：内核就绪等待超时")
                    }
                    if !tunOn {
                        // Still no utun after a clean init — genuinely cannot start
                        // (no privilege, or another VPN owns the routes). Tear the
                        // kernel back down so it cannot keep TUN half-up, and undo
                        // the persist above so the next plain start does not retry
                        // TUN outside this flow.
                        await applyTUNState(false, allowRestartFallback: false)
                        engine.setTunEnabled(false)
                        showToast("TUN 开启失败：可能无管理员权限或路由被其他 VPN 占用冲突", kind: .error)
                        logKernel("TUN 开启失败（含重启重试）：runningAsRoot=\(engine.runningAsRoot) reachable=\(reachable) hasIface=\(await NetScanner.mihomoTunInterface(maxAge: 0) != nil)")
                    }
                    return
                }
                // Roll the *running* kernel back too, not just the file: without
                // this the kernel keeps TUN enabled while the file and the switch
                // both say off, so traffic still goes through a tunnel the UI
                // claims is disabled and no reconcile path ever closes the gap
                // (refreshConfigs derives tunOn from `enable && root && iface`,
                // which stays false precisely because the iface is missing).
                // Full block, not just `enable`: PATCH replaces nested objects.
                _ = await engine.patchConfig(["tun": tunPatchBody(enable: false)])
                // The pre-restart persist above wrote `tun.enable: true`; undo it
                // so a later plain start cannot bring TUN up outside this flow.
                engine.setTunEnabled(false)
                showToast("TUN 开启失败：可能无管理员权限或路由被其他 VPN 占用冲突", kind: .error)
                logKernel("TUN 开启失败：runningAsRoot=\(engine.runningAsRoot) reachable=\(reachable) hasIface=\(await NetScanner.mihomoTunInterface(maxAge: 0) != nil)")
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
                if !want {
                    // Kernel stays warm, but nothing should be flowing through it
                    // any more — release connections still pinned to the tunnel.
                    await dropAllConnectionsWhenIdle()
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

    /// Verify the kernel really adopted `tun.enable == want`, re-PATCHing while
    /// it has not. Returns true once the kernel agrees (or false after the
    /// budget is spent).
    ///
    /// Why this exists: `PATCH /configs` returns 200 as soon as the request is
    /// parsed — *before* mihomo decides whether it can apply it. A tun update
    /// delivered to a kernel that is still initializing (proxy providers being
    /// fetched right after a root restart) is accepted and then silently
    /// dropped. The old code trusted the 200, waited in vain for a utun that
    /// would never appear, and reported "TUN 开启失败" while nothing was wrong
    /// with permissions at all.
    private func confirmTunFlagApplied(want: Bool, overrides: [String: Any]) async -> Bool {
        let delays: [UInt64] = [150_000_000, 400_000_000, 800_000_000, 1_500_000_000]
        for (i, delay) in delays.enumerated() {
            if let c = try? await api.fetchConfigs(),
               let tun = c["tun"] as? [String: Any],
               (tun["enable"] as? Bool) == want {
                if i > 0 { logKernel("TUN 阶段：tun.enable 在第 \(i + 1) 次尝试后生效") }
                return true
            }
            logKernel("TUN 阶段：内核未采纳 tun.enable=\(want)（PATCH 返回 200 但被丢弃），重试…")
            try? await Task.sleep(nanoseconds: delay)
            _ = await engine.patchConfig(overrides)
        }
        // Final read-back after the last re-PATCH.
        if let c = try? await api.fetchConfigs(),
           let tun = c["tun"] as? [String: Any],
           (tun["enable"] as? Bool) == want {
            return true
        }
        logKernel("TUN 阶段：内核始终未采纳 tun.enable=\(want)")
        return false
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

        // The control-plane secret and listen address are bound once when the
        // REST server starts. A config reload re-applies proxies/rules/DNS to
        // the already-running process but never touches its listener/auth, so
        // a changed secret here would silently never take effect — the kernel
        // keeps answering to the old one until the process itself restarts.
        if overrides.keys.contains("external-controller") || overrides.keys.contains("secret") {
            await engine.restart(preferRoot: engine.isRoot)
            _ = await waitForKernelReady(maxAttempts: 8)
            await reconnect()
            await refreshConfigs()
            noteConfigContentChanged()
            if reachable {
                showToast("配置已更新", kind: .ok)
            } else {
                showToast("内核重启后未响应，请检查配置", kind: .error)
            }
            return
        }

        do {
            try await api.reloadConfig(path: engine.configFilePath)
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
