import Foundation

// MARK: - AppModel · Config, switches & profiles
// Profile activation, running-config refresh/patch, master switches (system
// proxy / TUN / engine), mode, and the read-only rules view.

extension AppModel {
    /// Switch the active config profile: persist as engine config + hot-apply.
    func activateProfile(_ id: String) {
        guard let content = store.makeActiveContent(id) else { showToast("配置为空"); return }
        let name = store.profiles.first { $0.id == id }?.name ?? ""
        Task {
            // hardenControllerConfig is called inside setConfig, which writes
            // to config.yaml → hardens → reloads — correct ordering.
            let (ok, err) = await engine.setConfig(content)
            showToast(ok ? "已切换配置「\(name)」" : "配置错误：\(err ?? "")，已回滚")
            if ok { await reconnect() }
        }
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
        configs = c
        if let m = c["mode"] as? String { mode = m }
        // B9: a user-mode kernel cannot create the utun device (operation not
        // permitted), so even if the config declares tun.enable=true it is not
        // actually active. Reflect the real state instead of the declared one.
        if let tun = c["tun"] as? [String: Any] {
            tunOn = (tun["enable"] as? Bool) == true && engine.runningAsRoot
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
    }

    // MARK: Master switches

    func toggleSystemProxy() {
        let on = !systemProxyOn
        let port = (configs["mixed-port"] as? Int) ?? (configs["port"] as? Int) ?? 7890
        Task {
            let ok = await engine.setSystemProxy(enabled: on, port: port)
            if ok {
                systemProxyOn = on
                showToast(on ? "系统代理已开启" : "系统代理已关闭")
            } else {
                systemProxyOn = !on // Revert the switch if operation fails
                await api.probe()
                if api.reachable { showToast("系统代理设置失败") }
            }
        }
    }

    func toggleTUN() {
        guard !engine.isBusy else { showToast("内核操作进行中，请稍候…"); return }
        let want = !tunOn
        engine.isBusy = true
        Task {
            defer { engine.isBusy = false }
            await applyTUNState(want)
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
        var overrides: [String: Any] = [
            "tun": [
                "enable": want,
                "stack": (configs["tun"] as? [String:Any])?["stack"] ?? "gvisor",
                "auto-route": true,
                "auto-detect-interface": true
            ]
        ]
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
            } else if engine.helperVersion != EngineControl.kExpectedHelperVersion,
                      engine.helperVersion != "?" {
                // Installed helper is outdated — full upgrade (uninstall → install)
                // so the old process is properly removed before the new one starts.
                showToast("特权服务需要更新，正在自动升级…")
                let ok = await XPCManager.shared.upgradeDaemon()
                guard ok else { showToast("Helper 升级失败，TUN 未启用"); return }
                // Wait for new helper to come up
                for _ in 0..<6 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if await XPCManager.shared.verifyConnectivity() { break }
                }
                engine.refreshHelperVersion()
                // upgradeDaemon goes through XPCManager directly (not
                // installPrivileged), so it doesn't set isRoot. pollStatus would
                // eventually re-sync it, but restart() below runs immediately and
                // reads isRoot to choose root-vs-user launch — without this the
                // 2s pollStatus window (isRoot=false during uninstall) could make
                // it launch user-mode and TUN would fail.
                engine.isRoot = true
            }

            showToast("正在以 Root 权限重启核心…")
            await engine.restart()
            // Poll until the root kernel is up — ensureRunning is fire-and-forget
            // so the 2 s hardcoded sleep was a race: the startMihomo XPC callback
            // (sets runningAsRoot) and mihomo startup both need variable time.
            var rootReady = false
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await api.probe(timeout: 1.0)
                if api.reachable && engine.runningAsRoot { rootReady = true; break }
            }
            guard rootReady else { showToast("Root 内核启动超时，TUN 未启用"); return }
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
                showToast("TUN 开启失败：内核未以管理员权限运行，无法创建 TUN 接口")
            } else {
                showToast(want ? "TUN 模式已开启" : "TUN 模式已关闭")
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
    private func tunnelDNSAddress() -> String {
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
            d.set(original.joined(separator: ","), forKey: Self.kDNSSavedKey)
            d.set(true, forKey: Self.kDNSOverriddenKey)
        }
        await EngineControl.applySystemDNS([gateway])
    }

    /// Restore the system DNS saved before TUN took over (no-op if we never
    /// overrode it). Idempotent — safe to call from every teardown path.
    func restoreTunnelDNS() async {
        let d = UserDefaults.standard
        guard d.bool(forKey: Self.kDNSOverriddenKey) else { return }
        let saved = (d.string(forKey: Self.kDNSSavedKey) ?? "")
            .split(separator: ",").map(String.init)
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

    func toggleEngine() {
        guard !engine.isBusy else { showToast("内核操作进行中，请稍候…"); return }
        let want = !reachable
        engine.isBusy = true
        Task {
            defer { engine.isBusy = false }
            if want {
                logKernel("正在请求启动核心...")
                showToast("正在启动核心...")
                engine.ensureRunning()

                // Wait and verify
                for i in 1...5 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await api.probe(timeout: 0.5)
                    if api.reachable {
                        logKernel("核心启动成功 (尝试 \(i))")
                        await reconnect()
                        return
                    }
                    logKernel("等待核心响应... (\(i)/5)")
                }
                // Not reachable after retries — surface the REAL reason. A bad
                // config makes mihomo exit immediately on start, which looks
                // identical to a timeout; previously this was misreported as
                // "权限不足", sending users to needlessly reinstall the helper.
                if let cfgErr = await engine.validateConfig() {
                    logKernel("配置错误，核心无法启动：\(cfgErr)")
                    showToast("配置错误：\(cfgErr)")
                } else {
                    logKernel("错误：核心未响应（启动超时或权限不足）")
                    showToast("核心启动失败，请检查内核与权限")
                }
            } else {
                logKernel("正在停止核心...")
                await engine.stopKernel()   // proper async stop (SIGTERM → wait → SIGKILL)
                reachable = false
                tunOn = false   // 核心停止 → TUN 必然失效，复位开关避免状态卡 on
                await restoreTunnelDNS()   // kernel gone → tunnel DNS would black-hole resolution
                // Clear system proxy so traffic isn't black-holed to a dead kernel
                if systemProxyOn {
                    let port = (configs["mixed-port"] as? Int) ?? (configs["port"] as? Int) ?? 7890
                    _ = await engine.setSystemProxy(enabled: false, port: port)
                    systemProxyOn = false
                }
                logKernel("核心已停止")
                showToast("核心已停止")
            }
        }
    }

    func setMode(_ m: String) {
        mode = m
        Task { try? await api.patchConfig(["mode": m]); showToast("已切换至\(modeLabel(m))模式") }
    }

    // Rules (read-only view of the kernel's active rule set).
    // mihomo does NOT expose rules in /configs nor accept rule edits via PATCH;
    // rules are read from the dedicated /rules endpoint, editing is via profile YAML.
    func refreshRules() async {
        if let r = try? await api.fetchRules() { rules = r.rules }
    }
}
