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
                // Check reachability before showing generic error
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
            let overrides: [String: Any] = [
                "tun": [
                    "enable": want,
                    "stack": (configs["tun"] as? [String:Any])?["stack"] ?? "gvisor",
                    "auto-route": true,
                    "auto-detect-interface": true
                ]
            ]

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
