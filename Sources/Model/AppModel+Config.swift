import Foundation

// MARK: - AppModel · Config, switches & profiles
// Profile activation, running-config refresh/patch, master switches (system
// proxy / TUN / engine), mode, and the read-only rules view.

extension AppModel {
    /// Gateway mode configuration overrides (allow-lan + a LAN-wide bind +
    /// DNS listen on 0.0.0.0:53).
    ///
    /// `bind-address` belongs here for the same reason `allow-lan` does: a
    /// profile that pins it to `127.0.0.1` keeps every inbound on loopback, so
    /// gateway clients reach the box and get nothing. `allow-lan: true` alone
    /// does not override it.
    static let gatewayOverrides: [String: Any] = [
        "allow-lan": true,
        "bind-address": "*",
        "dns": [
            "enable": true,
            "listen": "0.0.0.0:53",
            "enhanced-mode": "fake-ip"
        ]
    ]

    /// 内核 DNS 监听地址的唯一来源（P3-3）。
    ///
    /// 系统代理的防污染重定向要求 mihomo 监听在 `127.0.0.1:53`（系统解析器只会
    /// 问 127.0.0.1 的 53 端口）；`1053` 是 mihomo 默认值，也是“该重定向不成立时”
    /// 应当写回的形态。两者此前以字面量散落 6 处，改端口时很容易只改一半。
    static let systemProxyDNSListen = "127.0.0.1:53"
    static let defaultDNSListen = "127.0.0.1:1053"

    /// 内核 `log-level` 的唯一选项真相源（P1-8）。
    ///
    /// 设置页与日志页此前各写一份：设置页有 `silent`、日志页没有，于是用户在设置页
    /// 选“静默”后日志页一个段都不选中 —— 界面看起来“坏了”。两边都从这里取，
    /// 且标签统一成与每行日志前缀同形的短大写（`Log.level.uppercased()`），
    /// 免得“选的是 warning、行首印的是 WARN”再制造一次对不上号。
    ///
    /// `silent` 必须保留：它是 mihomo 唯一能彻底停掉日志推送的值，用户抱怨日志
    /// 刷屏时这就是正解；日志页把它显示成一段，而不是藏起来。
    static let logLevelOptions: [(value: String, label: String)] = [
        ("silent", "SILENT"),
        ("error", "ERROR"),
        ("warning", "WARN"),
        ("info", "INFO"),
        ("debug", "DEBUG")
    ]

    // MARK: - 访问控制 × 局域网网关
    //
    // These two cards write the same mihomo fields with opposite intent, and
    // neither knew the other existed. Gateway is not a config flag — it is
    // `allow-lan` + a DNS listener on `0.0.0.0:53` + IP forwarding — and mihomo
    // enforces every 访问控制 key on exactly the inbounds gateway clients arrive
    // on. So each of these silently half-breaks an active Gateway:
    //
    //   * `allow-lan: false` / a non-wildcard `bind-address` unbind the DNS and
    //     mixed-port listeners from the LAN. Forwarded clients lose name
    //     resolution while the Gateway switch still reads "开启".
    //   * `lan-allowed-ips` / `lan-disallowed-ips` filter those same inbounds, so
    //     an allow-list that omits the local subnet excludes every client.
    //   * `authentication` demands proxy credentials that transparently
    //     forwarded traffic can never supply — the only remedy mihomo offers is
    //     listing the client prefixes in `skip-auth-prefixes`.
    //
    // None of these settings is wrong on its own; they were wrong *silently*.
    // The two structural ones (allow-lan / bind-address) are Gateway's to own
    // while it runs and are refused with a reason; `authentication` is repaired
    // by widening `skip-auth-prefixes` (additive, never removes a user entry);
    // the IP filters are the user's call and only earn a warning.

    /// Private ranges a gateway client can plausibly come from. Gateway forwards
    /// LAN traffic, and the LAN is RFC1918 — matching on those rather than
    /// guessing a prefix length off the interface address keeps this correct on
    /// /16 and /22 home networks alike.
    static let lanAuthPrefixes = ["127.0.0.1/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]

    /// Reconcile an access-control write against a running Gateway.
    ///
    /// Returns the patch to actually apply (possibly narrowed or widened) plus
    /// the messages to surface. A no-op when Gateway is off — access control is
    /// then free to do whatever the user asked.
    func reconcileAccessControlWithGateway(
        _ overrides: [String: Any]
    ) -> (patch: [String: Any], blocked: [String], warnings: [String]) {
        guard gatewayModeOn || gatewayApplyInFlight else { return (overrides, [], []) }
        var patch = overrides
        var blocked: [String] = []
        var warnings: [String] = []

        if let allow = patch["allow-lan"] as? Bool, !allow {
            patch.removeValue(forKey: "allow-lan")
            blocked.append("「允许局域网连接」")
        }
        if let bind = patch["bind-address"] as? String, !Self.isWildcardBindAddress(bind) {
            patch.removeValue(forKey: "bind-address")
            blocked.append("「绑定地址 \(bind)」")
        }

        // Auth would lock out every forwarded client; widen the skip list to the
        // private ranges they arrive from instead of letting Gateway go dark.
        let auth = (patch["authentication"] as? [Any]) ?? (configs["authentication"] as? [Any]) ?? []
        // `gatewayApplyInFlight` covers the reverse order: auth configured first,
        // Gateway switched on afterwards.
        let touchesAuth = patch["authentication"] != nil
            || patch["skip-auth-prefixes"] != nil
            || gatewayApplyInFlight
        if !auth.isEmpty, touchesAuth {
            let existing = (patch["skip-auth-prefixes"] as? [Any])
                ?? (configs["skip-auth-prefixes"] as? [Any]) ?? []
            var skip = existing.map { "\($0)" }
            let missing = Self.lanAuthPrefixes.filter { p in
                !skip.contains { NetScanner.cidrsOverlap($0, p) }
            }
            if !missing.isEmpty {
                skip.append(contentsOf: missing)
                patch["skip-auth-prefixes"] = skip
                warnings.append("已为网关客户端补充免认证网段 \(missing.joined(separator: "、"))")
            }
        }

        // IP filters stay the user's decision — the whole point of the card — so
        // say what it costs rather than overriding it.
        if let allowed = patch["lan-allowed-ips"] as? [Any], !allowed.isEmpty {
            let list = allowed.map { "\($0)" }
            let localIPs = NetScanner.interfaces()
                .filter { $0.kind == .physical && $0.isUp }
                .flatMap { $0.ipv4 }
            let covered = localIPs.contains { ip in list.contains { NetScanner.cidrsOverlap($0, ip + "/32") } }
            if !localIPs.isEmpty && !covered {
                warnings.append("「允许的 IP」未包含本机所在网段，网关客户端将被拒绝")
            }
        }
        if let denied = patch["lan-disallowed-ips"] as? [Any], !denied.isEmpty {
            let list = denied.map { "\($0)" }
            if list.contains(where: { NetScanner.parseCIDR($0).map { $0.1 <= 16 } ?? false }) {
                warnings.append("「拒绝的 IP」覆盖了整段私有网络，网关客户端可能被拒绝")
            }
        }

        return (patch, blocked, warnings)
    }

    /// Whether a `bind-address` leaves inbounds reachable from the LAN.
    static func isWildcardBindAddress(_ raw: String) -> Bool {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty || v == "*" || v == "0.0.0.0" || v == "::" || v == "[::]"
    }

    /// Top-level keys where the on-disk config disagrees with `profile`.
    ///
    /// Thin wrapper over `ConfigWriteAudit.drift`, which holds the logic so it can
    /// be compiled and tested standalone (this file needs SwiftUI, so no test
    /// harness can link it). See that function for which keys are exempt.
    static func configDrift(before: String, profile: String) -> [String] {
        ConfigWriteAudit.drift(before: before, profile: profile)
    }

    /// Promote an Imported (or re-activate an Applied) profile to the
    /// running kernel: persist → reload → mark applied. Pure side-effects;
    /// the user already consented at the call site (two-stage sheet or
    /// "设为活动" tap). Reload coalesces via `appliedHash`: a re-apply of
    /// unchanged content short-circuits before touching the kernel — unless
    /// the running config drifted since (see the guard below).
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
        //
        // …but NOT when the running config has since drifted from the profile.
        // `commit` above has already overwritten config.yaml with the profile
        // text, so this guard must compare against the *pre-commit* snapshot to
        // see the drift at all. Measured on a real machine: the settings page
        // persists `geodata-mode` / `unified-delay` / `find-process-mode` /
        // `log-level` … straight into config.yaml, where they outrank the
        // profile; because `appliedHash` still hashes the untouched *profile*,
        // re-activating the profile reported success and changed nothing. Seven
        // keys stayed drifted through any number of "已切换配置". A guard whose
        // whole purpose is to skip a redundant write must not also skip the
        // repair the user is asking for by clicking the row.
        let drifted = Self.configDrift(before: backupContent, profile: content)
        if let last = store.profiles.first(where: { $0.id == id })?.appliedHash,
           last == Sha1.hex(content), drifted.isEmpty {
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
                //
                // 走与设置页同一条事务（备份→写盘→mihomo -t 校验→重载→失败回滚），
                // 不再手写第二份 setTopLevelScalars + reload。那份重复实现既不校验
                // 也不回滚，失败时只有一句裸 toast，文件却已经改过 —— 与设置页
                // 那条“有保护”的路是同一个功能的两套实现。
                if gatewayModeOn {
                    let gatewayOK = await patchPersistentTransactional(Self.gatewayOverrides)
                    if !gatewayOK {
                        // 事务内部已经弹出具体失败原因并回滚了文件，这里只补一条
                        // 日志说明后果，不再叠加 toast 盖掉那条更有信息量的提示。
                        logKernel("网关级联：网关配置未能重新应用（已按事务回滚），请检查「网络」页网关状态")
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
        // P0-3：这里**不能**静默 return。TUN 对账、静态路由注入、按属主的 DNS
        // 对账全都挂在“这个函数跑到尾”上；静默失败会让所有自愈停摆，而界面只
        // 表现为「怎么切配置都不再注入绕行路由」，日志里一个字都没有。
        let fetched: [String: Any]?
        let fetchError: Error?
        do {
            fetched = try await api.fetchConfigs()
            fetchError = nil
        } catch {
            fetched = nil
            fetchError = error
        }
        guard let fetched else {
            await noteConfigFetchFailure(fetchError)
            return
        }
        var c = fetched

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
        var diskEnhancedMode = "fake-ip"
        if let fileConfig = engine.readConfigFile() {
            if let sniffer = fileConfig["sniffer"] as? [String: Any] {
                c["sniffer"] = sniffer
            }
            if let dns = fileConfig["dns"] as? [String: Any] {
                c["dns"] = dns
                if let mode = dns["enhanced-mode"] as? String, !mode.isEmpty { diskEnhancedMode = mode }
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
                noteTunInterfaceTeardown()
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
                    let wasOn = tunOn
                    tunOn = shouldBeOn
                    // TUN just went from on→off: restore system DNS immediately.
                    // Without this, the system keeps pointing at 198.18.0.0
                    // (the TUN fake-ip gateway) which only answers while the
                    // tunnel is up — a downed utun black-holes all DNS,
                    // breaking every app including the proxy itself.
                    // This is the single source of truth for tunOn derivation,
                    // so every path (user toggle, auto-teardown, config drift)
                    // is covered in one place.
                    if wasOn && !shouldBeOn {
                        // 按属主判断，不再裸读共享 flag：TUN 关闭要收的是 `.tun`
                        // 属主的重定向。pending 记录（写入已发起未确认）同样算在账，
                        // 所以用 record(for:) 而不是 isActive()。
                        if TunnelDNSLedger.record(for: .tun) != nil {
                            await restoreTunnelDNS()
                        }
                    }
                }
            }
        }
        // Gateway is user intent only (persisted via UserDefaults mirror). Never
        // infer it from config.yaml: residual `allow-lan + dns.listen=0.0.0.0:53`
        // left by a previous session / incomplete disable used to flip the switch
        // on at startup, then verifyGatewayConfig re-enforced sysctl IP forwarding
        // and could cascade into a black-hole network. The write path
        // (applyGatewayMode) remains the only place that turns Gateway on.
        // `gatewayApplyInFlight` is the difference between residue and an enable
        // that has not finished committing. Without it this branch fires from
        // the `refreshConfigs()` call inside `applyGatewayMode` itself — the
        // overrides are on disk, `gatewayModeOn` is not yet true, so the enable
        // reverts its own work. Every Gateway enable then produced the same
        // cascade: clean → "配置丢失" → two repair reloads → give up, nine full
        // kernel reloads inside ten minutes, each one dropping every live
        // connection. Deterministic, not a race.
        if !gatewayModeOn && !gatewayApplyInFlight {
            let dnsListen = (c["dns"] as? [String: Any])?["listen"] as? String
            if dnsListen == "0.0.0.0:53" {
                // Soft-clean residual Gateway DNS bind so a cold start with the
                // switch off does not keep hijacking LAN DNS / port 53.
                logKernel("检测到残留网关 DNS 监听（0.0.0.0:53），正在清理…")
                engine.setTopLevelScalars([
                    "dns": [
                        "enable": true,
                        "listen": Self.defaultDNSListen,
                        "enhanced-mode": "fake-ip"
                    ]
                ])
                noteConfigContentChanged()
                // Best-effort live reload; ignore failures (kernel may be down).
                try? await api.reloadConfig(path: engine.configFilePath)
                if var dns = configs["dns"] as? [String: Any] {
                    dns["listen"] = Self.defaultDNSListen
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
        // died → restore). Both calls are idempotent and only act on a
        // transition.
        //
        // 属主分离后必须**按属主**对账，不能再共用一个 flag：
        // - `tunOn` 为真 → `.tun` 属主必须在账，缺了就补写；
        // - `tunOn` 为假 → `.tun` 属主必须清账，还在就还原（pending 记录同样
        //   算在账 —— 那正是「写入已发起、进程被杀」的崩溃窗口，需要还原）。
        //
        // `.proxy` 属主**不在这里对账**：它由系统代理开关路径（`ensureProxyDNS`
        // / `restoreProxyDNS`）与 fake-ip 自愈分支管理。旧实现两个属主共用
        // `kDNSOverriddenKey`，于是 redir-host 模式下代理写下的 127.0.0.1 会在
        // 下一拍 refresh 被这个分支当成「TUN 残留」还原掉（:883 注释记载的
        // "reverted within ~12 s"）—— 两个写者互相拆台，谁的状态都保不住。
        //
        // 顺带修正上面那段过时注释的说法：TUN 并非系统 DNS 重定向的**唯一**写者，
        // 代理模式在 `enhanced-mode: redir-host` 下确实会写 127.0.0.1（fake-ip
        // 下自行跳过）。真正的不变量是「**每个写者各有独立账本**」。
        //
        // P0-5：但“不在这里对账”过头了 —— `.tun` 属主每拍都会对账，`.proxy` 属主
        // 却只在 `ensureProxyDNS` 的 fake-ip 分支里被顺手 `restoreAll`，于是
        // redir-host + 系统代理写下的 127.0.0.1 **没有常规回收路径**：关掉系统代理，
        // `scutil --dns` 里那行 127.0.0.1 会一直留着，内核一停就是解析黑洞。
        // 这一拍按属主对账，判据只有两条：这笔账还在，且它成立的前提已经不在
        // （系统代理关了，或增强模式已不是 redir-host）。
        //
        // 顺序很关键：必须排在下面 `.tun` 分支**之前**。TUN 关闭的那一拍，
        // `.tun` 分支会在 restore 之后调 `ensureProxyDNS()` 重建代理的重定向，先清
        // 后建才对；反过来会把刚建好的账目又拆掉。
        if TunnelDNSLedger.record(for: .proxy) != nil,
           !systemProxyOn || diskEnhancedMode != "redir-host" {
            let why = !systemProxyOn ? "系统代理已关闭" : "增强模式为 \(diskEnhancedMode)"
            logKernel("[DNSLedger] .proxy 属主失去成立前提（\(why)），还原系统 DNS…")
            let restored = await TunnelDNSLedger.restore(owner: .proxy, log: { self.logKernel($0) })
            if !restored, throttleAllows("proxyDNS.restore", interval: 120) {
                showToast("系统 DNS 未能还原（127.0.0.1 可能残留），请检查网络设置", kind: .warn)
            }
        }
        let tunRedirect = TunnelDNSLedger.record(for: .tun)
        if tunOn && tunRedirect == nil {
            await enableTunnelDNS()
        } else if !tunOn && tunRedirect != nil {
            await restoreTunnelDNS()
            // 属主接管的收尾：TUN 开启时会**继承并清除** `.proxy` 属主的账
            // （系统 DNS 只有一份全局状态，留两条账就等于让退出清理把
            // 127.0.0.1 写回一个已经停掉的内核 —— 那正是要修的黑洞形态）。
            // 代价是 TUN 关闭后，代理模式原有的 DNS 重定向意图也一并没了。
            // 所以这里补一次重建：仅在系统代理确实还开着时，且本分支是
            // transition-gated（restore 成功后账本即清，不会每拍重入）。
            // `ensureProxyDNS` 自带全部前提守卫（!tunOn / redir-host /
            // 监听 53 / 探测应答），fake-ip 模式下它只会自愈残留、不会写入。
            if systemProxyOn {
                await ensureProxyDNS()
            }
        }
        // …but never trust that bit alone. A redirect written before its flag was
        // set (crash / kill / teardown racing the write) leaves the fake-ip
        // address on a service with `overridden = 0`, and then BOTH branches
        // above are dead forever. Sweep on observed system state instead.
        await sweepOrphanedTunnelDNS()

        // Align static routes for excluded prefixes in sync with the real TUN state.
        // Fresh XPC (not cached helper()) — same silent-drop issue as start/sysproxy.
        //
        // P0-3 两处修正：
        //  · 「这一拍没有路由要注入」≠「已经注入过了」。旧代码把空路由图直接置
        //    `staticRoutesInjected = true`，于是之后即使检测出真实对端网段，
        //    `tunOn && !staticRoutesInjected` 永远为假 —— 绕行路由一辈子不再注入。
        //    改为到期复查（30s），既不每拍 fork 探测，也不会永久锁死。
        //  · 注入/清理失败不再只写一行日志：限流 toast 让用户知道绕行没做成，同时
        //    `staticRoutesInjected` 保持假值让下一轮继续重试（重试语义本来就是对的，
        //    这里只补可观测性，**不**改成放弃）。
        if tunOn && !staticRoutesInjected {
            if Date() >= staticRoutesCheckedUntil {
                staticRoutesCheckedUntil = Date().addingTimeInterval(Self.kStaticRoutesRecheck)
                let excludeRoutes = Coexistence.excludeRouteMap(await Coexistence.detect()) { cidr, kept, droppedPeer, droppedIface in
                    self.logKernel("TUN 共存：网段 \(cidr) 被多条隧道同时声明——保留 \(kept)，忽略 \(droppedPeer)→\(droppedIface)（首赢取自检测顺序而非仲裁；若该网段黑洞请查此条）")
                }
                if !excludeRoutes.isEmpty {
                    let ok = await XPCManager.shared.callSetupExcludeRoutes(excludeRoutes)
                    logKernel("XPC Helper 注入静态路由: \(ok == true ? "成功" : (ok == nil ? "失败（特权服务不可达）" : "失败（被拒绝）"))")
                    if ok == true { staticRoutesInjected = true } else { noteRouteXPCFailure("注入", ok: ok) }
                } else if throttleAllows("routes.empty", interval: 300) {
                    // 空图只做诊断记录（5 分钟一次），绝不能当成“已注入”。
                    logKernel("TUN 共存：本次检测无对端网段需要注入静态绕行路由（\(Int(Self.kStaticRoutesRecheck))s 后复查）")
                }
            }
        } else if !tunOn && staticRoutesInjected {
            let ok = await XPCManager.shared.callCleanupAllExcludeRoutes()
            logKernel("XPC Helper 清理静态路由: \(ok == true ? "成功" : (ok == nil ? "失败（特权服务不可达）" : "失败（被拒绝）"))")
            if ok == true { staticRoutesInjected = false } else { noteRouteXPCFailure("清理", ok: ok) }
        }
    }

    /// 静态路由注入/清理的到期复查间隔（P0-3）。`Coexistence.detect()` 会 fork
    /// `ipconfig`/`netstat`，3 s 一拍太贵；30 s 足够跟上“用户刚打开 Tailscale”
    /// 这种分钟级变化。
    static let kStaticRoutesRecheck: TimeInterval = 30

    /// `/configs` 取失败时的统一处置（P0-3）。
    ///
    /// 单次失败不等于内核已死（6 s 超时可能正撞上内核重载），所以这里**不自己**
    /// 写 `reachable` —— 那会绕过 `reconnect()` 里“内核刚死”的 DNS / 系统代理
    /// 回退（`wasReachable` 被提前置假，那段回退就永远不进）。交给单一属主
    /// `reconnect()` 判断并处置；本函数只负责限频记录原因。
    private func noteConfigFetchFailure(_ error: Error?) async {
        let reason = error?.localizedDescription ?? "未知原因"
        if throttleAllows("refreshConfigs.fetch", interval: 30) {
            logKernel("配置刷新失败：无法获取 /configs（\(reason)），本轮跳过 TUN/路由/DNS 对账")
        }
        guard reachable else { return }   // 已断线：重连链路在跑，别重复触发
        await reconnect()
    }

    /// 路由 XPC 失败的限流可观测性（P0-3）：一个永远失败的注入会每轮重试，
    /// 不能每轮弹一次 toast，但也不能只在日志里留一行。
    private func noteRouteXPCFailure(_ action: String, ok: Bool?) {
        guard throttleAllows("routes.xpc", interval: 60) else { return }
        let why = ok == nil ? "特权服务不可达" : "特权服务拒绝执行"
        showToast("静态路由\(action)失败（\(why)），将自动重试", kind: .warn)
    }

    /// 同一类事件在窗口内只放行一次（日志/toast 限频）。窗口状态在
    /// `AppModel.throttleStamps`，按 key 隔离，互不影响。
    private func throttleAllows(_ key: String, interval: TimeInterval) -> Bool {
        let now = Date()
        if let last = throttleStamps[key], now.timeIntervalSince(last) < interval { return false }
        throttleStamps[key] = now
        return true
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

    /// Run a kernel restart (or any window where the mixed-port stops
    /// listening) with the system proxy suspended, restoring it only once the
    /// kernel answers again.
    ///
    /// The system proxy points every app on the Mac at `127.0.0.1:mixed-port`.
    /// macOS does not fall back to direct when that port stops answering — it
    /// fails the connection — so any restart taken while the proxy is on is a
    /// hard blackout for its full duration, and a restart that never completes
    /// is a permanent one. The kernel-switch path has bracketed its restart this
    /// way since v1.0.18; the TUN root-switch restarts for exactly the same
    /// reason (user-mode kernel → root kernel) and never did, which is why
    /// enabling TUN while the proxy was on read as "开 TUN 把网断了".
    ///
    /// Restoring is deliberately gated on `reachable`: putting the proxy back in
    /// front of a port nothing is listening on would re-create the very blackout
    /// the suspend avoided, and leaving it off is both visible and recoverable.
    func withSystemProxySuspended<T>(_ reason: String, _ body: () async -> T) async -> T {
        guard systemProxyOn else { return await body() }
        let port = proxyPort
        logKernel("\(reason)：临时关闭系统代理以防断网")
        _ = await engine.setSystemProxy(enabled: false, port: port)
        systemProxyOn = false

        let result = await body()

        guard reachable else {
            logKernel("\(reason)：内核未就绪，系统代理保持关闭")
            showToast("内核未就绪，系统代理未恢复（避免断网）", kind: .warn)
            return result
        }
        // Re-read: a restart can land on a profile with a different mixed-port.
        let restorePort = proxyPort
        if await restoreSystemProxy(reason: reason, port: restorePort) {
            return result
        }
        showToast("系统代理恢复失败，请重新开启", kind: .error)
        return result
    }

    /// Single restore entry point for lifecycle interruptions (wake, network
    /// recovery, kernel restart / version switch). Every caller used to run
    /// `setSystemProxy(true)` and then optimistically flip `systemProxyOn`;
    /// they converge here so the acceptance contract is written once:
    ///
    ///   1. the mixed-port must actually be listening — macOS has no
    ///      direct-connect fallback for a configured proxy, so restoring in
    ///      front of a dead port recreates the blackout the suspend bracket
    ///      exists to prevent;
    ///   2. the write must land (Helper or fallback, full-success only — a
    ///      partial service set is reported, not swallowed);
    ///   3. reality is re-read from SCDynamicStore before the toggle may
    ///      show on.
    ///
    /// Returns true only when the system proxy is verified on afterwards.
    @discardableResult
    func restoreSystemProxy(reason: String, port overridePort: Int? = nil) async -> Bool {
        let port = overridePort ?? proxyPort
        guard await EngineControl.isLocalPortListening(port) else {
            logKernel("\(reason)：mixed-port \(port) 未监听，系统代理保持关闭（避免断网）")
            syncSystemProxyState()
            return false
        }
        let ok = await engine.setSystemProxy(enabled: true, port: port)
        // Verify the actual system state instead of trusting the Bool — partial
        // service coverage must not leave the toggle optimistic.
        syncSystemProxyState()
        if systemProxyOn {
            logKernel("\(reason)：已恢复系统代理 (port \(port))\(ok ? "" : "，部分服务未确认写入")")
            if !ok {
                systemProxyStatus.mode = .partial
                showToast("系统代理恢复不完整，请重新开启", kind: .warn)
            }
            return true
        }
        logKernel("\(reason)：系统代理恢复失败 (write=\(ok))")
        return false
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

            // Built-in tailnet identity is not part of any profile — wipe it
            // with the rest so a "清空全部" really leaves the machine inert.
            // State dir may be root-owned under the single-identity rule; the
            // reset helper already surfaces that without failing the wipe.
            if self.tsEnabled {
                self.tsEnabled = false
                self.saveTailscalePrefs()
                self.tsState = .disabled
                self.tsDevices = []
                self.tsWarnings = []
                self.stopTailscaleLoginWatch()
            }
            self.resetTailscaleIdentity(silent: true)

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
        var port = proxyPort
        // Hold isBusy for the full path (start kernel + set proxy) so TUN /
        // engine / rule reload cannot interleave mid-flight.
        withEngineBusy(on ? "正在开启系统代理…" : "正在关闭系统代理…") {
            // One TCP probe serves both the stale-`reachable` check here and
            // the acceptance gate below. A stale `reachable` (kernel died
            // after the last successful probe) must not skip the start block
            // — observed live: the boot kernel fell to a helper quit/relaunch
            // race and seven consecutive toggles dead-ended at the port gate
            // without ever attempting a kernel restart. Port dead → re-probe
            // the controller and let a failed probe clear `reachable`.
            var portProbe: Bool? = nil
            if on && self.reachable {
                portProbe = await EngineControl.isLocalPortListening(port)
                if portProbe == false {
                    await self.api.probe(timeout: 2.0)
                    self.reachable = self.api.reachable
                    if !self.reachable {
                        self.logKernel("系统代理开启：内核实际未运行（状态过期），正在重新启动…")
                    }
                }
            }
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
                // The port above was read with `configs` still empty (the core
                // was down), i.e. from config.yaml. Now that a kernel is
                // answering, take the port it actually bound — a profile switch
                // or a kernel-side normalization can make the two differ, and
                // pointing macOS at the wrong one is a silent blackout.
                await self.refreshConfigs()
                port = self.proxyPort
                // A fresh kernel may bind a different mixed-port — the earlier
                // probe result no longer applies.
                portProbe = nil
            }

            // Acceptance gate: macOS has no direct-connect fallback for a
            // configured proxy — pointing the system at a mixed-port nothing
            // is listening on is a full blackout, so verify the listener
            // before writing anything. Reuses the probe from the stale-check
            // when the kernel did not restart in between.
            if on {
                let listening: Bool
                if let probed = portProbe {
                    listening = probed
                } else {
                    listening = await EngineControl.isLocalPortListening(port)
                }
                guard listening else {
                    self.logKernel("系统代理开启中止：mixed-port \(port) 未监听")
                    self.showToast("混合端口 \(port) 未监听，已取消开启系统代理（避免断网）", kind: .error)
                    return
                }
            }

            let ok = await self.engine.setSystemProxy(enabled: on, port: port)
            if ok {
                // Verify against SCDynamicStore — the Bool from engine covers
                // the write path, not "HTTP+HTTPS+SOCKS all landed".
                self.syncSystemProxyState()
                if on {
                    if self.systemProxyOn {
                        // Fast path — two independent confirmations: the helper
                        // reported a full write (partial maps to false) and the
                        // merged SCDynamicStore triple check agrees. The
                        // per-service readback (a second enumeration + 3 forks
                        // per service, ~0.5–1 s) is a *diagnostic* that names
                        // stragglers, not the gate — it only runs below, when
                        // these two checks disagree or the write was not full.
                        self.systemProxyStatus = SystemProxyStatus(mode: .active)
                        self.showToast("系统代理已开启", kind: .ok)
                    } else {
                        // Full write but the merged view disagrees — diagnose
                        // per service and name whichever uplinks stayed direct.
                        let coverage = await EngineControl.verifySystemProxyCoverage(port: port)
                        self.systemProxyStatus = SystemProxyStatus(
                            mode: .partial,
                            targetServices: coverage.targets,
                            failedServices: coverage.missing)
                        let detail = coverage.missing.isEmpty
                            ? "" : "（未配置：\(coverage.missing.joined(separator: "、"))）"
                        self.logKernel("系统代理开启但状态复核不完整，部分服务可能未配置成功\(detail)")
                        self.showToast("系统代理开启不完整，建议重新开启", kind: .warn)
                    }
                } else {
                    // Turning off: SCDynamicStore may lag a beat; the user
                    // asked to stop, so accept the write.
                    self.systemProxyOn = false
                    self.systemProxyStatus = SystemProxyStatus()
                    if !self.tunOn && self.reachable {
                        self.showToast("系统代理已关闭（内核仍在运行，可在侧栏停止）", kind: .ok)
                    } else {
                        self.showToast("系统代理已关闭", kind: .ok)
                    }
                }
                self.logKernel(on ? "系统代理已开启 (port \(port))" : "系统代理已关闭")

                // LAN clients that point HTTP/SOCKS at this Mac need allow-lan.
                // Gateway mode also sets it; system-proxy-only users previously
                // had to flip "允许局域网" by hand or open full Gateway. Runs
                // *after* the proxy is live + toast shown — it needs a config
                // patch + refresh and shouldn't delay the visible toggle result.
                //
                // DNS: Without TUN's dns-hijack, the system resolves domains
                // via its own DNS (usually the router, which is GFW-polluted).
                // Google/youtube/Github domains resolve to wrong IPs and the
                // proxy connects to a dead endpoint — "开启了系统代理后无法访问
                // Google". Route DNS through mihomo (listening on 127.0.0.1:53)
                // so DoH nameservers resolve correctly and rules match by host.
                if on {
                    await self.ensureProxyDNS()
                    await self.ensureAllowLanForSharing()
                } else {
                    // Restore system DNS to what it was before proxy mode took
                    // over (DHCP / user config). Without this the system keeps
                    // pointing at 127.0.0.1:53 which is only alive while mihomo
                    // runs — a later kernel stop would black-hole all DNS.
                    await self.restoreProxyDNS()
                    // Nothing routes through the kernel any more — release the
                    // connections still pinned to it so traffic re-dials direct.
                    await self.dropAllConnectionsWhenIdle()
                }
            } else {
                self.syncSystemProxyState()
                if on && self.systemProxyOn {
                    // Partial coverage: the primary service landed (effective
                    // on) while other target services failed — the case the
                    // legacy anyOK contract collapsed into plain success and
                    // the full-only contract would collapse into plain
                    // failure. Name the stragglers instead.
                    let coverage = await EngineControl.verifySystemProxyCoverage(port: port)
                    self.systemProxyStatus = SystemProxyStatus(
                        mode: .partial,
                        targetServices: coverage.targets,
                        failedServices: coverage.missing)
                    let list = coverage.missing.isEmpty ? "未知服务" : coverage.missing.joined(separator: "、")
                    self.logKernel("系统代理部分服务配置失败：\(list) (port=\(port))")
                    self.showToast("系统代理开启不完整：\(list)", kind: .warn)
                    // The primary service is live — it carries proxied traffic,
                    // so the DNS redirect / allow-lan follow-ups matter exactly
                    // as they do for a full landing.
                    await self.ensureProxyDNS()
                    await self.ensureAllowLanForSharing()
                } else {
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

    /// Set system DNS to 127.0.0.1 so domain resolution goes through mihomo's
    /// DNS listener (127.0.0.1:53) instead of the router / ISP DNS. Without TUN's
    /// dns-hijack, the system resolves domains via its own DNS server, which is
    /// typically GFW-polluted (e.g. www.google.com → 157.240.7.20). This makes
    /// proxy-routed domains like Google/GitHub unreachable even though the proxy
    /// itself works fine for direct domains (Baidu).
    ///
    /// Idempotent: saves the pre-existing DNS once (shared with TUN DNS restore)
    /// so a manual user setting is restored later. Only runs when TUN is OFF —
    /// TUN mode already hijacks DNS via dns-hijack and setting 127.0.0.1 here
    /// would conflict with the TUN fake-ip gateway redirect.
    func ensureProxyDNS() async {
        let tunOnBefore = tunOn
        logKernel("ensureProxyDNS: tunOn=\(tunOnBefore) reachable=\(reachable)")
        guard !tunOnBefore else { return }

        // The system-DNS redirect is only safe when the 127.0.0.1 resolver
        // answers with REAL IPs. In fake-ip mode (the default) every answer is
        // an unroutable 198.18.x.x address: apps that honor the system proxy
        // still work (mihomo reverse-maps fake IPs on inbound), but apps that
        // DON'T honor it resolve to a fake IP and connect directly — with no
        // TUN there is no route for 198.18.0.0/15 and those apps black-hole
        // completely (verified live: direct connect to a fake IP times out,
        // same host via proxy returns 200). This redirect used to be reverted
        // within ~12 s by the DNS-ownership bug, which masked the breakage;
        // once the redirect persisted it surfaced. Domain-based unpolluted
        // routing for proxied apps is already covered by mihomo's sniffer
        // (parse-pure-ip). TUN remains the one legitimate owner of a system
        // DNS redirect — with the tunnel up, 198.18.0.0/15 is routed and
        // fake-ip is by design.
        let mode = (engine.readConfigFile()?["dns"] as? [String: Any])?["enhanced-mode"] as? String
            ?? "fake-ip"
        if mode != "redir-host" {
            logKernel("ensureProxyDNS: enhanced-mode=\(mode)，跳过系统 DNS 重定向（fake-ip 应答会让不走代理的应用断网；域名防污染由 sniffer 承担）")
            // Self-heal: a redirect left by an older build (or a TUN session
            // whose teardown raced) must not survive in proxy-only mode —
            // with the tunnel gone, fake-ip answers black-hole direct apps.
            //
            // 走 restoreAll：fake-ip + 代理模式下**任何属主**的重定向都不该站着
            // —— `.proxy` 属主本来就不该在 fake-ip 下写入（旧版本共用 key 时写过），
            // `.tun` 属主则是 TUN 关闭后未回收的残留（含 pending：写入已发起但
            // 进程被杀的崩溃窗口）。Ledger 按属主逐条还原并只在写成功后清账。
            if TunnelDNSLedger.isAnyActive() {
                let owners = TunnelDNSLedger.activeOwners().map(\.label).joined(separator: "、")
                logKernel("ensureProxyDNS: 检测到残留的 DNS 重定向（在账属主：\(owners)），正在回退…")
                await TunnelDNSLedger.restoreAll(log: { self.logKernel($0) })
            }
            return
        }

        // Ensure mihomo DNS listens on port 53 so the system resolver
        // (set to 127.0.0.1 below) can reach it. The default config uses
        // 127.0.0.1:1053 which is unreachable from port 53. Without this,
        // setting system DNS to 127.0.0.1 would black-hole all DNS queries.
        //
        // P2 transaction: the system DNS override below is only committed
        // once the listener is (1) configured on 127.0.0.1:53, (2) verified
        // to actually answer a query. Writing 127.0.0.1 into the system
        // resolvers in front of a listener that failed to reload or bind
        // black-holes every lookup on the Mac — strictly worse than the GFW
        // pollution this redirect exists to fix. On any failure the original
        // DNS stays untouched (the snapshot is only taken after the checks
        // pass), which is the rollback.
        guard await ensureMihomoDNSPort53() else {
            logKernel("ensureProxyDNS: mihomo DNS 监听 127.0.0.1:53 未确认（重载失败或缺 dns.listen），跳过系统 DNS 重定向，保持原 DNS")
            return
        }

        // reload inside ensureMihomoDNSPort53 may have changed tunOn (the
        // kernel re-reads config.tun.enable). Re-check and skip DNS redirect
        // if TUN came back up — TUN's dns-hijack already handles DNS.
        if tunOn {
            logKernel("ensureProxyDNS: TUN 在 reload 后变为开启，跳过系统 DNS 设置")
            return
        }

        guard await probeLocalDNS53() else {
            logKernel("ensureProxyDNS: 127.0.0.1:53 探测无应答，保持系统 DNS 不变（避免解析黑洞）")
            showToast("DNS 经内核转发未验证，系统 DNS 保持不变", kind: .warn)
            return
        }

        logKernel("ensureProxyDNS: 正在设置系统 DNS 为 127.0.0.1")
        // 走 Ledger 的 `.proxy` 属主（审查高-2 修复）。
        //
        // 修复前这里与 `enableTunnelDNS` **共用同一套 key**（原注释："whichever
        // set it last is responsible for restoring"），而且既不 pin 服务、也不在
        // flag 已置时重新快照。两个后果都是实打实的断网：
        //   · 127.0.0.1 可能写到与 TUN pin 不同的服务上 —— TUN 的恢复只管自己
        //     pin 的服务，那个服务上的 127.0.0.1 就没人回收，内核一停即黑洞；
        //   · flag 已被 TUN 置位时这里跳过快照，于是它写下的 127.0.0.1 从来没有
        //     对应的原值记录，恢复时写回的是 TUN 之前的快照，代理这次的写入成了
        //     无主状态。
        // 现在两类属主各持独立 pin + 快照；同一服务上发生接管时由 Ledger 继承原
        // 快照，保证最终能还原到「任何重定向之前」的真值。
        //
        // 快照同样遵守三态语义：读取失败（nil）时 Ledger 直接放弃本轮重定向，
        // 不会把空列表当 "Empty" 存下来。
        let ok = await TunnelDNSLedger.redirect(owner: .proxy,
                                                servers: ["127.0.0.1"],
                                                log: { self.logKernel($0) })
        if ok {
            logKernel("系统代理 DNS 已设为 127.0.0.1（经 mihomo DoH 解析，防 GFW 污染）")
        } else {
            // 同类失败两种反馈（P0-5）：探测失败会弹 toast，写入失败却只有一行日志。
            // 用户看到的是“代理开着但域名照样被污染”，界面什么都不说。
            logKernel("系统代理 DNS 重定向未完成（读取原 DNS 失败或写入失败），域名可能被 GFW 污染")
            if throttleAllows("proxyDNS.redirect", interval: 120) {
                showToast("系统 DNS 重定向未完成，域名可能被污染", kind: .warn)
            }
        }
    }

    /// Ensure mihomo's DNS listener is on 127.0.0.1:53 so system DNS
    /// (set to 127.0.0.1 by ensureProxyDNS) can reach it. Reads config.yaml,
    /// patches dns.listen if needed, and triggers a kernel reload.
    /// Idempotent — no-op if already on :53. Returns false when the listener
    /// cannot be confirmed on 53 (no dns.listen in config, or reload failed),
    /// which callers must treat as "do not touch system DNS".
    @discardableResult
    private func ensureMihomoDNSPort53() async -> Bool {
        guard let disk = engine.readConfigFile(),
              let dns = disk["dns"] as? [String: Any],
              let listen = dns["listen"] as? String else { return false }
        if listen == Self.systemProxyDNSListen { return true }

        logKernel("系统代理需要 DNS 监听 53 端口，当前为 \(listen)，正在修改并重载内核…")
        // Patch config.yaml: change dns.listen to 127.0.0.1:53.
        // Also force tun.enable=false so the reload does NOT re-create the
        // TUN interface — the user explicitly turned TUN off, and a reload
        // that reads tun.enable=true from the file would bring it back up,
        // which then makes the !tunOn guard in ensureProxyDNS skip the DNS
        // redirect (leaving the system on the polluted router DNS).
        engine.setTopLevelScalars([
            "dns": ["listen": Self.systemProxyDNSListen],
            "tun": ["enable": false]
        ])
        noteConfigContentChanged()
        // Reload so mihomo re-reads the file and binds 53
        let cfgPath = engine.configFilePath
        do {
            try await api.reloadConfig(path: cfgPath)
            logKernel("内核配置已重载（DNS 监听端口切换）")
        } catch {
            logKernel("内核重载失败：\(error.localizedDescription)")
            return false
        }
        // Re-sync after reload
        await refreshConfigs()
        logKernel("mihomo DNS 已切换到 \(Self.systemProxyDNSListen)")
        return true
    }

    /// One-shot UDP DNS round-trip to 127.0.0.1:53 — the live-listener half of
    /// the P2 proxy-DNS transaction. Reuses the TUN data-plane probe's wire
    /// format: any format-valid reply (NXDOMAIN/SERVFAIL included) proves a
    /// listener is answering; silence means the reload never bound the port
    /// and the system DNS must not be redirected.
    ///
    /// Retried rather than lengthened: mihomo rebinds the DNS listener
    /// asynchronously after the reload reply, and a UDP datagram sent before
    /// the bind is simply dropped — a single longer wait cannot recover a
    /// packet that was already lost (observed live: reload ok in ~0.5 s,
    /// one-shot probe fired ~1.5 s later got silence, listener answered
    /// queries moments after). Three short rounds bound the total (~6 s worst)
    /// while the healthy path still returns instantly.
    private func probeLocalDNS53() async -> Bool {
        for attempt in 1...3 {
            if await probeLocalDNS53Once() {
                if attempt > 1 {
                    logKernel("ensureProxyDNS: 127.0.0.1:53 第 \(attempt) 次探测才应答（重载后监听重建较慢）")
                }
                return true
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return false
    }

    private func probeLocalDNS53Once() async -> Bool {
        await Task.detached(priority: .utility) { () -> Bool in
            let probe = DNSProbe(txID: UInt16.random(in: 0x0101...0xfffe))
            let query = probe.query(host: "probe.proxy.local")
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(53).bigEndian
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var tv = timeval(tv_sec: 1, tv_usec: 500_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let sent = query.withUnsafeBytes { raw -> Int in
                withUnsafePointer(to: &addr) { aptr -> Int in
                    aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, raw.baseAddress, query.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == query.count else { return false }
            var buf = [UInt8](repeating: 0, count: 512)
            let n = withUnsafeMutablePointer(to: &addr) { aptr -> Int in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                    return recvfrom(fd, &buf, buf.count, 0, sa, &len)
                }
            }
            guard n >= 12 else { return false }
            return probe.validate(response: Data(buf[0..<n])) == .valid
        }.value
    }

    /// Restore system DNS saved before proxy mode took over. Idempotent — safe
    /// to call from every teardown path. Only restores if TUN is OFF (TUN's
    /// redirect is handled separately; don't touch it while tunnel is up).
    ///
    /// 实现走 `.proxy` 属主：TUN off 时才执行，TUN on 时不做（TUN 的恢复由
    /// `restoreTunnelDNS()` 接管）。Ledger 保证只有 proxy 属主的 snapshot 被还原，
    /// tun 属主不动（避免共用同一份快照带来的混乱）。
    func restoreProxyDNS() async {
        guard !tunOn else { return }
        await TunnelDNSLedger.restore(owner: .proxy, log: { self.logKernel($0) })
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
    /// 返回是否真的断开了。P1-5：旧实现返回 `Void`，失败只有一行日志 —— 用户关掉
    /// TUN 与系统代理后，长连接（流媒体、WebSocket、下载）仍从旧路径走，界面却已
    /// 显示“全部关闭”。失败必须能被看见，但三处调用点都会调用它，所以提示在这里
    /// 统一做且限流，避免同一件事弹三次。
    @discardableResult
    func dropAllConnectionsWhenIdle() async -> Bool {
        guard reachable, !tunOn, !systemProxyOn, !gatewayModeOn else { return true }
        do {
            try await api.closeAllConnections()
            logKernel("TUN 与系统代理均已关闭，已断开全部既有连接以恢复直连")
            return true
        } catch {
            logKernel("断开既有连接失败：\(error.localizedDescription)")
            if throttleAllows("dropAll.fail", interval: 120) {
                showToast("未能断开既有连接，部分长连接可能仍在走内核", kind: .warn)
            }
            return false
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
        // An explicit toggle is a fresh decision, not a retry: clear the flap
        // breaker so the user's request is honoured and, if it flaps again, gets
        // its own full window before the app gives up a second time.
        resetTunFlapBreaker()
        withEngineBusy(want ? "正在开启 TUN 模式…" : "正在关闭 TUN 模式…") {
            await self.applyTUNState(want)
        }
    }

    /// Re-apply Gateway after a TUN teardown took it down with the tunnel.
    ///
    /// Only runs when TUN is genuinely up — Gateway without a tunnel is the
    /// black-hole state `applyGatewayMode` guards against. The pending flag is
    /// consumed either way: a restore that fails surfaces its own error, and
    /// retrying it on every enable would just replay the failure.
    func restoreGatewayAfterTUNIfPending() async {
        guard gatewayPendingTunRestore else { return }
        gatewayPendingTunRestore = false
        guard tunOn, reachable else { return }
        logKernel("TUN 已恢复，正在同步恢复网关中枢…")
        showToast("正在恢复网关中枢…")
        await applyGatewayMode(true)
        if !gatewayModeOn {
            logKernel("网关中枢自动恢复失败，请在「网络」页手动重新开启")
        }
    }

    func toggleGatewayMode() {
        let want = !gatewayModeOn
        // An explicit switch-off is the user's decision and must stick: drop any
        // pending "restore Gateway with TUN" intent so a later TUN enable doesn't
        // turn it back on behind their back.
        if !want { gatewayPendingTunRestore = false }
        // A hand-thrown switch is also the one signal that re-arms a repair that
        // gave up — cascaded changes to `gatewayModeOn` deliberately do not.
        resetGatewayRepairBreakers()

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
            // Held for the whole enable, including every early `return` below —
            // an abandoned transaction must leave the residue detector armed
            // again, or a half-applied Gateway would never be cleaned up.
            gatewayApplyInFlight = true
            defer { gatewayApplyInFlight = false }
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
                // Same mixed-port blackout as the TUN root switch — see
                // `withSystemProxySuspended`.
                let restarted = await withSystemProxySuspended("网关 Root 切换") { () -> Bool in
                    await engine.restart()
                    guard await waitForKernelReady(maxAttempts: 8) else { return false }
                    await reconnect()
                    return true
                }
                guard restarted else {
                    showToast("Root 内核启动超时，未开启网关", kind: .error)
                    return
                }
            }

            // Write configs for gateway mode (allow-lan and dns listen).
            let oldTun = tunOn

            // Snapshot current allow-lan / bind-address / dns.listen values so
            // Gateway disable can restore them later (avoid stale overrides).
            preGatewayAllowLan = (configs["allow-lan"] as? Bool) ?? false
            preGatewayBindAddress = configs["bind-address"] as? String
            if let dns = configs["dns"] as? [String: Any] {
                preGatewayDNSListen = dns["listen"] as? String
            }

            // Back up config.yaml before Gateway overwrites so we can
            // roll back if the kernel crashes (e.g. port 53 conflict).
            let cfgPath = engine.configFilePath
            let backup = try? String(contentsOfFile: cfgPath, encoding: .utf8)

            var overrides = Self.gatewayOverrides
            // An access-control `authentication` list that predates this enable
            // would reject every forwarded client, and the user has no way to
            // hand credentials to transparently routed traffic. Widen
            // `skip-auth-prefixes` the same way an edit made *during* Gateway
            // would be widened, so the order the two cards are used in stops
            // mattering.
            let (reconciled, _, notes) = reconcileAccessControlWithGateway(overrides)
            overrides = reconciled
            for n in notes { logKernel("网关中枢：\(n)") }

            engine.setTopLevelScalars(overrides)
            // Writing only `tun.enable` here would drop the pinned device name,
            // and the reload below re-reads the file — see `persistTunState`.
            engine.persistTunState(enabled: oldTun, device: pinnedTunDevice)
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
                preGatewayAllowLan = nil; preGatewayBindAddress = nil; preGatewayDNSListen = nil
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
                    preGatewayAllowLan = nil; preGatewayBindAddress = nil; preGatewayDNSListen = nil
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
                preGatewayAllowLan = nil; preGatewayBindAddress = nil; preGatewayDNSListen = nil
                showToast("底层 IP 转发开启失败", kind: .error)
            }
        } else {
            // Restore config.yaml overrides that Gateway mode applied. The
            // snapshot is still authoritative because `allow-lan` /
            // `bind-address` are refused to the 访问控制 card for as long as
            // Gateway runs, so nothing can have moved underneath it.
            var restores: [String: Any] = [
                "allow-lan": preGatewayAllowLan ?? false,
                "dns": [
                    "enable": true,
                    "listen": preGatewayDNSListen ?? Self.defaultDNSListen,
                    "enhanced-mode": "fake-ip"
                ]
            ]
            // Only restore a bind-address the profile actually carried: writing
            // `*` back for a config that never had the key would hand the user a
            // setting Gateway invented.
            if let bind = preGatewayBindAddress { restores["bind-address"] = bind }
            preGatewayAllowLan = nil; preGatewayBindAddress = nil; preGatewayDNSListen = nil
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

    /// The `tun` block as the running kernel sees it, merged over the one
    /// persisted in config.yaml.
    ///
    /// `configs` is only populated by `refreshConfigs`, which needs a reachable
    /// kernel — so on a cold start, or in the window right after a restart, it is
    /// empty and every read off it silently yields a hardcoded default instead of
    /// the user's actual setting. The disk block is the fallback for exactly
    /// those windows.
    ///
    /// Read as a whole block rather than per key: config.yaml is ~32 KB and
    /// `readConfigFile` line-scans all of it, so a per-field accessor would have
    /// re-parsed the file once for every field of every PATCH body.
    func liveTunBlock() -> [String: Any] {
        let live = (configs["tun"] as? [String: Any]) ?? [:]
        guard live.isEmpty else { return live }
        return (engine.readConfigFile()?["tun"] as? [String: Any]) ?? [:]
    }

    /// A complete `tun` PATCH body: `enable` plus every field of the running
    /// shape that the user owns.
    ///
    /// `PATCH /configs` **replaces** each nested object rather than deep-merging
    /// it: sending `tun: {route-exclude-address: [...]}` alone comes back with
    /// `enable: false` and an empty `device`, i.e. it silently tears TUN down.
    /// Every tun PATCH must therefore restate the full runtime shape — and for a
    /// long time this function did not, which made "replaces, not merges" a
    /// standing hazard rather than a handled one:
    ///
    ///   * `dns-hijack` was never restated, so every PATCH-path TUN toggle (the
    ///     normal case once the kernel is already root) silently dropped
    ///     `any:53` hijacking from the running kernel. The file still declared
    ///     it, `/configs` no longer reported it, and DNS quietly stopped being
    ///     captured until something reloaded the file.
    ///   * `route-exclude-address` was only attached when a *peer tunnel* was
    ///     detected, so with no peer up the user's own exclusions — private
    ///     ranges, multicast, link-local, ping targets — were wiped the same way.
    ///   * `stack` fell back to the literal `"gvisor"` whenever `configs` was
    ///     empty, so a cold-start TUN enable could silently switch a `mixed`
    ///     config onto a different stack.
    ///
    /// Fields are therefore sourced from the kernel first and config.yaml second
    /// (`liveTunBlock`), with literals only as last-resort defaults for keys
    /// neither source carries; only truly kernel-derived values
    /// (`file-descriptor`, `inet4-address`) are left out — echoing those
    /// back is not ours to do.
    ///
    /// One field deserves special handling: mihomo marshals `recvmsgx` with
    /// `omitempty` on a plain bool, so `/configs` hides it when disabled and
    /// a reported `true` may be the v1.19.30 default rather than user intent.
    /// The disk value therefore wins when present — an explicit `false` must
    /// survive every PATCH (replace semantics would otherwise resurrect the
    /// default), exactly like the incident-driven watchdog assumes when it
    /// rebuilds devices through `tunPatchBody`.
    func tunPatchBody(enable: Bool, extra: [String: Any] = [:]) -> [String: Any] {
        let live = liveTunBlock()
        let disk = (engine.readConfigFile()?["tun"] as? [String: Any]) ?? [:]
        var body: [String: Any] = [
            "enable": enable,
            "stack": live["stack"] ?? disk["stack"] ?? "system",
            "auto-route": live["auto-route"] ?? disk["auto-route"] ?? true,
            "auto-detect-interface": live["auto-detect-interface"] ?? disk["auto-detect-interface"] ?? true
        ]
        // Restate the user-owned fields that would otherwise be dropped by the
        // replace semantics. Only when actually present — inventing a key the
        // config never had would be its own kind of surprise.
        for key in ["dns-hijack", "route-exclude-address", "mtu", "strict-route",
                    "endpoint-independent-nat", "include-package", "exclude-package",
                    "gso-max-size", "rx-queue-size", "tx-queue-size"] {
            if let v = live[key] ?? disk[key] { body[key] = v }
        }
        if let v = disk["recvmsgx"] ?? live["recvmsgx"] { body["recvmsgx"] = v }

        // `inet4-address` is deliberately NOT written here, and this is a measured
        // finding rather than an omission.
        //
        // The obvious fix for the tunnel claiming the all-zero host address —
        //
        //     $ ifconfig utun100
        //     inet 198.18.0.0 --> 198.18.0.0 netmask 0xfffffffc
        //
        // — is to own the key and send `198.18.0.1/30`. That was implemented and
        // then disproved live on mihomo v1.19.29 (darwin arm64, with_gvisor):
        // **this build ignores `tun.inet4-address` entirely.** The key is accepted
        // and silently dropped; the kernel kept reporting its built-in
        // `["198.18.0.0/30"]` through all four routes tried:
        //
        //   1. PATCH /configs {"tun":{"enable":true,"inet4-address":["198.18.0.1/30"]}}
        //      → HTTP 204, value unchanged.
        //   2. disable → enable (fresh bring-up) carrying the key → unchanged.
        //   3. `inet4-address: [198.18.0.1/30]` written into config.yaml and
        //      reloaded via `PUT /configs?force=true` → unchanged.
        //   4. Decisive: a *malformed* value (`NOT-AN-IP`) reloaded with HTTP 204
        //      and no validation error, and a different *valid* value
        //      (`198.19.0.1/30`) was ignored too. The key is never parsed.
        //
        // Sending it anyway would be worse than useless: it makes the App's
        // intent look satisfied while the kernel does the opposite, and it hides
        // the real remedy (a privileged `ifconfig utun100 inet 198.18.0.1 ...`
        // after bring-up, the same mechanism `ProxyManager.cleanupTUNResidual`
        // already uses for `inet <addr> delete`).
        //
        // TUN v6 显式接管（TUNIPv6Health）：物理 v6 断供（RA 停发/路由缺失/
        // 探测不可达）时，把全球单播 v6 整段排除出 auto-route——v6 失败发生在
        // 内核层、应用毫秒级回退 IPv4，而不是进隧道后被 DIRECT 拨号放大成
        // 应用层长超时（2026-08-29 mini-pro 事件：微信发图 3h 1400 次失败）。
        // 仅 enable 时需要；disable 的 PATCH 没有路由可排除。TUN 是否接管 v6
        // 是随内核版本/环境漂移的隐式行为，必须由应用显式拥有。
        if enable, tunIPv6Gate.dead {
            var excludes = (body["route-exclude-address"] as? [Any]) ?? []
            if !excludes.contains(where: { "\($0)" == TUNIPv6Health.ipv6GlobalUnicastExclude }) {
                excludes.append(TUNIPv6Health.ipv6GlobalUnicastExclude)
            }
            body["route-exclude-address"] = excludes
        }
        // Ask for our own name rather than accepting the next free index. Only on
        // enable — a disable PATCH has no device to name.
        if enable, let dev = pinnedTunDevice { body["device"] = dev }
        for (k, v) in extra { body[k] = v }
        return body
    }

    // MARK: - TUN IPv6 接管闸门（采样与推进）

    /// 采样并推进 IPv6 健康闸门；状态翻转且 TUN 在开时重新下发 tun PATCH，
    /// 让 `tunPatchBody` 按当前 dead 标志增删 `2000::/3` 排除项。
    /// 调用点：`applyTUNState`（构造 PATCH 前，`applyPatch: false`）、30s
    /// 巡检 healthDue、唤醒恢复。路径风暴期间不做（有 fork 开销）。
    func refreshTUNIPv6Gate(applyPatch: Bool = true) async {
        let snapshot = await Self.collectIPv6HealthSnapshot()
        var gate = tunIPv6Gate
        let transition = gate.observe(healthy: TUNIPv6Health.isHealthy(snapshot))
        tunIPv6Gate = gate
        switch transition {
        case .none:
            return
        case .wentAlive:
            logKernel("IPv6 上行恢复（物理路由 + 全球地址 + 主动探测均健康），解除 2000::/3 排除，v6 分流交还规则表")
        case .wentDead:
            logKernel("IPv6 上行断供（RA 停发/路由缺失/探测不可达），v6 排除出 TUN auto-route：v6 失败发生在内核层，应用毫秒级回退 IPv4")
        }
        guard applyPatch, tunOn, reachable, !engine.isBusy else { return }
        engine.isBusy = true
        defer { engine.isBusy = false }
        let ok = await engine.patchConfig(["tun": tunPatchBody(enable: true)])
        if ok { logKernel("TUN 路由表已按 IPv6 健康状态重新下发") }
    }

    /// 三路采样：物理口 v6 默认路由、未过期全球地址、公共 v6 DNS 的 UDP 可达性。
    static func collectIPv6HealthSnapshot() async -> TUNIPv6Health.Snapshot {
        async let probe = probeIPv6UDP()
        let (hasRoute, iface) = await physicalV6DefaultRoute()
        var hasAddr = false
        if let iface {
            hasAddr = await ifaceHasFreshGlobalV6(iface)
        }
        return TUNIPv6Health.Snapshot(
            hasV6DefaultRouteOnPhysical: hasRoute,
            hasFreshGlobalV6Address: hasAddr,
            probeReachable: await probe
        )
    }

    /// 经物理口（非 utun/lo0）的 IPv6 默认路由。返回 (存在, 接口名)。
    private static func physicalV6DefaultRoute() async -> (Bool, String?) {
        await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
            p.arguments = ["-rn", "-f", "inet6"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            do { try p.run() } catch { return (false, nil) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let out = String(data: data, encoding: .utf8) else { return (false, nil) }
            for line in out.split(separator: "\n") {
                let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard cols.count >= 4, cols[0] == "default" else { continue }
                let iface = String(cols[cols.count - 1])
                if !iface.hasPrefix("utun") && iface != "lo0" {
                    return (true, iface)
                }
            }
            return (false, nil)
        }.value
    }

    /// 接口上是否存在未 deprecated 的 2000::/3 全球单播地址。
    private static func ifaceHasFreshGlobalV6(_ iface: String) async -> Bool {
        await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
            p.arguments = [iface]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            do { try p.run() } catch { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let out = String(data: data, encoding: .utf8) else { return false }
            for line in out.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("inet6 ") else { continue }
                let addr = t.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                guard let first = addr.first else { continue }
                // 2000::/3：首 nibble 为 2 或 3 的全球单播
                guard first == "2" || first == "3" else { continue }
                if !t.contains("deprecated") && !t.contains("tentative") { return true }
            }
            return false
        }.value
    }

    /// 主动探测：对公共 v6 DNS 的 UDP connect——UDP connect 只校验路由可用性，
    /// 不发包、不阻塞；两上游串联（阿里 → Cloudflare），全不可达才算死。
    /// nil = 探测本身不可用（socket 失败等），降级为只信被动判定。
    private static func probeIPv6UDP() async -> Bool? {
        await Task.detached(priority: .utility) {
            for host in ["2400:3200::1", "2606:4700:4700::1111"] {
                var addr = sockaddr_in6()
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_port = UInt16(53).bigEndian
                guard inet_pton(AF_INET6, host, &addr.sin6_addr) == 1 else { continue }
                let fd = socket(AF_INET6, SOCK_DGRAM, 0)
                guard fd >= 0 else { return nil }
                let r = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
                close(fd)
                if r == 0 { return true }
                switch errno {
                case ENETUNREACH, EHOSTUNREACH, EADDRNOTAVAIL, ENETDOWN:
                    continue   // 该上游不可达，试下一个
                default:
                    return nil
                }
            }
            return false
        }.value
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

    /// Persist the *current* runtime TUN state (enable + pinned device) so a
    /// config reload or kernel restart that re-reads `config.yaml` brings back
    /// the same tunnel, on the same interface name.
    ///
    /// Call this before every `reloadConfig` / `restart`. See
    /// `EngineControl.persistTunState` for why writing only `tun.enable` is a
    /// network-outage bug rather than a partial fix.
    /// 写回运行中的 TUN 状态 + pin 住的设备名（reload/restart 会重读文件）。
    ///
    /// P1-6：写失败必须被看见。设备名没写进文件时，内核重启后会自己挑一个 utun
    /// 名，而巡检按 pin 的旧名字判“接口丢失”，接着把整条隧道拆掉 —— 一次静默的
    /// 写失败会变成一次断网，所以这里既返回 Bool 也弹提示。
    @discardableResult
    func persistTunStateForReload() -> Bool {
        let ok = engine.persistTunStateReporting(tunOn, device: pinnedTunDevice)
        if !ok, throttleAllows("tunDevice.persist", interval: 120) {
            logKernel("TUN 设备名写入 config.yaml 失败：重载后内核可能换用别的 utun 名")
            showToast("TUN 设备名未能写入配置，重载后隧道名可能变化", kind: .warn)
        }
        return ok
    }

    // MARK: TUN flap circuit breaker

    /// Record one interface-missing auto-teardown and decide whether the loop has
    /// become the problem. Called by both teardown sites (`refreshConfigs` B10 and
    /// `verifyTUNConfig`) *before* they tear TUN down — the teardown itself is
    /// always correct; what must stop is the automatic re-enable that follows it.
    ///
    /// Returns true the moment the breaker latches, so the caller can say so once
    /// rather than on every subsequent cycle.
    @discardableResult
    func noteTunInterfaceTeardown() -> Bool {
        let now = Date()
        if now.timeIntervalSince(tunFlapWindowStart) > Self.kTunFlapWindow {
            tunFlapWindowStart = now
            tunFlapTeardownCount = 0
        }
        tunFlapTeardownCount += 1
        tunFlapLastTeardown = now
        guard !tunFlapAbandoned, tunFlapTeardownCount >= Self.kTunFlapMaxTeardowns else {
            return false
        }
        tunFlapAbandoned = true
        logKernel("TUN 在 \(Int(Self.kTunFlapWindow / 60)) 分钟内第 \(tunFlapTeardownCount) 次因接口丢失被自动关闭，"
                + "已停止自动重开 —— 继续反复开关会持续中断全部连接。"
                + "通常是另一个 utun 服务（Shadowrocket / Tailscale / 公司 VPN）正在占用路由，"
                + "请退出冲突的客户端后手动重新开启 TUN。")
        showToast("TUN 反复掉线，已停止自动重试。请关闭其他 VPN / 代理客户端后手动重开。",
                  kind: .error, duration: 10)
        return true
    }

    /// Clear the breaker. Called on an explicit user toggle (a fresh decision, not
    /// a retry) and whenever TUN has been demonstrably healthy long enough that
    /// the previous run is no longer evidence of anything.
    func resetTunFlapBreaker() {
        tunFlapTeardownCount = 0
        tunFlapWindowStart = .distantPast
        tunFlapLastTeardown = .distantPast
        tunFlapAbandoned = false
    }

    /// Record that the kernel would not take the pinned name, and stop asking.
    func disableTunDevicePin() {
        // 2026-10-14（审查低级项）：此前放弃 pin 完全静默——事后排查
        // 「cleanupTUNResidual 的 UP 形态判定、僵尸巡检 upDetachedMihomoTun
        // 为何全部失效」毫无线索（它们都以 pinnedDeviceActive 为前提）。
        // 该标志原本无任何重置点：一次瞬态失败即永久放弃。现在
        // AppModel.start() 每次启动都会重置它（每次启动重试一次 pin）；
        // 会话内语义不变——写下这行后本次会话不再尝试 pin。
        logKernel("放弃 TUN 固定设备名 \(kPinnedTunDevice)：内核不接受 pin，改用动态 utun 名（已持久化 tun.device.pinUnsupported=true，本次会话内不再重试，下次启动将重置并重试；身份化清理与僵尸巡检判据随之降级）")
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
    /// The merged `route-exclude-address` list to send, plus the entries this
    /// injection is actually responsible for.
    ///
    /// The two differ whenever the plan agrees with something the user already
    /// wrote, and conflating them is what let a teardown delete the user's own
    /// entries — see `Coexistence.newlyInjected`. Callers must commit
    /// provenance with `.injected`, never with the whole plan.
    func coexistenceRouteBody(_ plan: CoexistencePlan) -> (merged: [String], injected: [String])? {
        guard !plan.routeExcludes.isEmpty else { return nil }
        let existing = liveTunBlock()["route-exclude-address"] as? [String] ?? []
        let merged = Coexistence.mergePreservingUserEntries(
            field: "route-exclude-address",
            desired: plan.routeExcludes,
            in: existing
        )
        return (merged, Coexistence.newlyInjected(desired: plan.routeExcludes,
                                                  existingBefore: existing))
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
    ///
    /// Re-entrancy is guarded separately from the fingerprint. The fingerprint is
    /// written only after the PATCH *and* the static-route push have returned, so
    /// it cannot dedupe callers that arrive inside that window — and the network
    /// path monitor does deliver them in bursts (two callbacks 85 ms apart on a
    /// peer tunnel moving interface). A caller arriving mid-run returns instead of
    /// pushing a second whole-block `tun` PATCH for the same topology; whatever it
    /// would have seen is re-detected by the 2-minute `verifyTUNConfig` sweep.
    func reconcileCoexistenceIfChanged() async {
        guard tunOn, reachable, !engine.isBusy, !sleeping else { return }
        guard Date() >= tunStateSettleUntil else { return }
        guard !coexistenceReconcileInFlight else { return }
        coexistenceReconcileInFlight = true
        defer { coexistenceReconcileInFlight = false }
        let peers = await Coexistence.detect()
        let plan = Coexistence.plan(peers)
        let fp = Coexistence.fingerprint(plan)
        guard fp != lastCoexistenceFingerprint else { return }
        guard let ex = coexistenceRouteBody(plan) else { return }

        logKernel("TUN 共存：检测到网络拓扑变化，正在同步排除规则…")
        let ok = await engine.patchConfig([
            "tun": tunPatchBody(enable: true, extra: ["route-exclude-address": ex.merged])
        ])
        // Only now is the change real. Recording provenance/fingerprint on a
        // failed PATCH would both skip the retry and mis-attribute the entries
        // as ours on the next withdrawal pass.
        guard ok else {
            logKernel("TUN 共存：同步失败，保留原有排除规则")
            return
        }
        Coexistence.commitProvenance(field: "route-exclude-address", injected: ex.injected)

        // The system route table is the other half of the same plan. Leaving it
        // to `staticRoutesInjected` — a latch set once when TUN came up — meant
        // the kernel's exclusions and the real routes drifted apart for as long
        // as TUN stayed on, and a stale route pointing into a peer tunnel is the
        // half that actually breaks traffic. Re-push both together.
        let excludeRoutes = Coexistence.excludeRouteMap(peers) { cidr, kept, droppedPeer, droppedIface in
            self.logKernel("TUN 共存：网段 \(cidr) 被多条隧道同时声明——保留 \(kept)，忽略 \(droppedPeer)→\(droppedIface)（首赢取自检测顺序而非仲裁；若该网段黑洞请查此条）")
        }
        var routesHardFailed = false
        if !excludeRoutes.isEmpty {
            let routesOK = await XPCManager.shared.callSetupExcludeRoutes(excludeRoutes)
            logKernel("TUN 共存：静态路由同步 \(routesOK == true ? "成功" : "失败")（\(excludeRoutes.count) 条）")
            staticRoutesInjected = routesOK == true
            // 中-7（2026-10-14）：`false` = Helper 应答了但推送失败。旧实现此时
            // 照样提交指纹，reconcile 从此认定「已对齐」永不重试，对端网段黑洞
            // 只能等 auditAndRepairPeerRoutes 的 600s 慢心跳。现在明确失败就不
            // 提交指纹，下一拍 reconcile（事件驱动/60s 慢兜底）整块重推。
            // `nil`（Helper 缺失/过旧/XPC 超时）不同：重试也不会成功，照旧提交
            // ——否则无 Helper 的机器每拍都白做一次整块 PATCH。
            routesHardFailed = routesOK == false
        } else {
            _ = await XPCManager.shared.callCleanupAllExcludeRoutes()
            staticRoutesInjected = false
        }
        if routesHardFailed {
            logKernel("TUN 共存：指纹未提交（静态路由推送被 Helper 明确拒绝），下一拍 reconcile 将重试")
        } else {
            lastCoexistenceFingerprint = fp
        }
    }

    /// Periodic route-table audit, and a surgical repair when it finds drift.
    ///
    /// Separate from `reconcileCoexistenceIfChanged` on purpose. That one asks
    /// "have the peers changed?" and pushes a `tun` PATCH when they have; this
    /// one asks "does the route table still match what we already agreed?" and
    /// touches nothing but the routes. They catch different faults and the
    /// cheap one must not be gated on the expensive one's trigger.
    ///
    /// Nothing here reloads or PATCHes the kernel. The repair is `route delete`
    /// + `route add` on individual prefixes, which does not disturb the tunnel
    /// or drop a single connection — the whole reason to fix this at the route
    /// layer instead of by re-applying config.
    func auditAndRepairPeerRoutes() async {
        guard tunOn, reachable, !engine.isBusy, !sleeping else { return }
        guard Date() >= tunStateSettleUntil else { return }

        let peers = await Coexistence.detect()
        let expected = Coexistence.excludeRouteMap(peers)
        guard !expected.isEmpty else { return }

        let drift = Coexistence.auditRoutes(expected: expected)
        guard !drift.isEmpty else {
            // A silent pass and a pass that never ran look identical, which makes
            // the whole self-heal unverifiable — the mistake the Gateway loop
            // made in the other direction by logging success unconditionally.
            // Heartbeat on a slow cadence: enough to prove liveness in a support
            // log, too rare to bury the lines that matter.
            if Date() >= routeAuditHeartbeatDue {
                routeAuditHeartbeatDue = Date().addingTimeInterval(600)
                logKernel("路由巡检：\(expected.count) 个对端网段归属正常，无需修复")
            }
            return
        }

        logKernel("路由巡检：发现 \(drift.count) 条对端网段异常，正在修复…")
        for d in drift { logKernel("　· \(d.describe)") }

        let replied = await XPCManager.shared.callSetupExcludeRoutes(expected)

        // Verify against the table, not against the reply. A repair that
        // reports success and changes nothing is the failure mode that let the
        // Gateway self-heal claim "已自动恢复" 113 times in a row.
        let after = Coexistence.auditRoutes(expected: expected)
        let stillBroken = Set(after.map(\.cidr))
        let fixed = drift.filter { !stillBroken.contains($0.cidr) }

        for d in fixed {
            logKernel("　✓ \(d.cidr) 已改回 \(d.expected)")
        }
        for d in after {
            logKernel("　✗ \(d.describe) —— 修复未生效")
        }
        if fixed.isEmpty && replied != true {
            logKernel("路由巡检：特权服务未响应，本轮未做任何改动")
        }
        logKernel("路由巡检：修复 \(fixed.count) 条，仍异常 \(after.count) 条")

        lastRouteRepair = RouteRepairReport(
            at: Date(),
            fixed: fixed.map { "\($0.cidr) → \($0.expected)" },
            remaining: after.map(\.describe)
        )
        // 低-a 语义注记（2026-10-14）：`staticRoutesInjected` 的含义是「排除路由
        // 当前归我们所有、已在系统路由表上」，不是「本轮全新注入成功」。修复
        // 路径刷新它是正当的：上面的整表重推就是注入本身，留 false 只会让
        // refreshConfigs 的 `tunOn && !staticRoutesInjected` 门在下一拍把同一批
        // 路由再注一遍。全新注入失败仍在其原位可见（reconcile 打「同步失败」
        // 且不提交指纹，见中-7）——两个通道各自记账，不靠这一个布尔区分。
        staticRoutesInjected = true
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
        persistTunStateForReload()       // a reload re-reads the file; keep TUN as-is

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
        // window so the OFF derivation is never blocked. Also cancel any pending
        // data-plane probe / recovery so a late result cannot re-open TUN.
        if !want {
            tunStateSettleUntil = .distantPast
            cancelTUNDataPlaneProbe(resetHealth: true)
        }
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

        // 构造 PATCH 前采样 IPv6 健康闸门（不在此处重下发 PATCH——本函数
        // 随后必然 PATCH tun；仅推进状态，tunPatchBody 按最新标志增删排除项）。
        if want {
            await refreshTUNIPv6Gate(applyPatch: false)
        }

        var tunOverrideMap = tunPatchBody(enable: want)

        // Carve out routing room for every other tunnel on the machine before TUN
        // takes over. (The DNS half cannot ride along here — mihomo ignores a
        // runtime DNS PATCH; see `coexistenceRouteBody`.)
        var pendingRouteProvenance: [String]?
        // Fingerprint is staged here and written only after the kernel has
        // actually accepted the change (same gate as provenance). Writing it
        // up-front made a dropped PATCH look like a successful push:
        // `reconcileCoexistenceIfChanged` then saw `fp == last…` and skipped
        // forever, leaving peer prefixes inside auto-route until the topology
        // itself moved. `nil` = leave the latch alone (failure path).
        var pendingCoexistenceFingerprint: String? = nil
        if want {
            let plan = Coexistence.plan(await Coexistence.detect())
            if let ex = coexistenceRouteBody(plan) {
                tunOverrideMap["route-exclude-address"] = ex.merged
                // Only what we added — claiming the user's pre-existing entries
                // is what made the next teardown delete them.
                pendingRouteProvenance = ex.injected
                logKernel("TUN 共存：排除 \(plan.routeExcludes.count) 个网段"
                          + "（其中本次新增 \(ex.injected.count) 条 · \(plan.peerSummary)）")
            }
            // No `else` needed: with no peer tunnel to carve room for,
            // `tunPatchBody` has already restated the exclusions the config
            // carries, so the replace semantics cannot empty them.
            // Reported, not applied — mihomo ignores a runtime DNS PATCH, and the
            // only working channel (rewrite config.yaml + reload) is too
            // destructive to run behind the user's back. See `dnsAdvice`.
            for line in plan.dnsAdvice {
                logKernel("TUN 共存（需手动配置）：\(line)")
            }
            pendingCoexistenceFingerprint = Coexistence.fingerprint(plan)
        } else {
            // Strip what we injected so a peer's prefixes do not outlive the TUN
            // session that needed them. Withdrawal must remove the entries, not
            // merely forget them — forgetting promotes them to user-owned and
            // they would then survive forever.
            // `liveTunBlock` (kernel → config.yaml), not the in-memory `configs`
            // snapshot: an empty/stale snapshot made withdraw a no-op and left
            // injected exclusions in the running kernel across a TUN-off.
            let existing = liveTunBlock()["route-exclude-address"] as? [String] ?? []
            let kept = Coexistence.withdraw(field: "route-exclude-address", from: existing)
            if kept.count != existing.count { tunOverrideMap["route-exclude-address"] = kept }
            pendingRouteProvenance = []
            pendingCoexistenceFingerprint = ""
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
            // This start reads the file, not the PATCH — the name has to be there
            // too or the restart path lands on a kernel-assigned utun.
            engine.persistTunState(enabled: true, device: pinnedTunDevice)
            let tRestart = Date()
            // The user→root swap takes the mixed-port away for seconds. With the
            // system proxy on that is a blackout, so suspend it across the whole
            // window — restart, readiness wait and reconnect — and let the helper
            // put it back only once a kernel is answering again.
            let restarted = await withSystemProxySuspended("TUN 切换") { () -> Bool in
                await engine.restart()
                logKernel("TUN 阶段：root 重启完成 +\(String(format: "%.2f", Date().timeIntervalSince(tRestart)))s")
                // restart = stop + start; a cold root spawn must parse the profile and
                // load geodata before the controller answers. `maxAttempts` is now
                // honoured literally (it used to be silently capped at 8 ≈ 3.2 s, too
                // short for a real profile) — 18 attempts ≈ 13 s of headroom.
                let tReady = Date()
                guard await waitForKernelReady(maxAttempts: 18) else {
                    logKernel("TUN 阶段：内核就绪等待超时 +\(String(format: "%.2f", Date().timeIntervalSince(tReady)))s")
                    return false
                }
                logKernel("TUN 阶段：内核就绪 +\(String(format: "%.2f", Date().timeIntervalSince(tReady)))s")
                await self.reconnect()
                return true
            }
            guard restarted else {
                showToast("Root 内核启动超时，TUN 未启用", kind: .error)
                return
            }
            if !engine.runningAsRoot {
                await engine.syncRunningAsRootIfNeeded()
            }
            if !engine.runningAsRoot {
                showToast("Root 内核未就绪，TUN 未启用", kind: .error)
                logKernel("TUN 中止：restart 后 runningAsRoot 仍为 false")
                return
            }
        }

        // Turning TUN *off* with no kernel to PATCH is not a failure — there is
        // no tunnel left to disable. The old code sent the PATCH anyway, watched
        // it fail against a dead controller, and fell through to a toast; `tunOn`
        // was never cleared and none of the disable cascade ran, so the switch
        // stayed stuck on with no way to move it while the core was stopped.
        // Do the local half of the teardown and treat it as done.
        if !want && !reachable {
            engine.forceTUNDisabled()
            tunOn = false
            Coexistence.commitProvenance(field: "route-exclude-address", injected: [])
            lastCoexistenceFingerprint = ""
            if gatewayModeOn {
                _ = await engine.setGatewayMode(enabled: false)
                gatewayModeOn = false
                gatewayDevices.removeAll(keepingCapacity: false)
            }
            // 2026-10-14（审查中-11 修复）：先清路由、后恢复 DNS——顺序即
            // 断流窗口。旧顺序先 restoreTunnelDNS：解析器立刻切回真实
            // DNS、应用拿到真 IP 发起连接，而静态路由/残留 utun 还指着死
            // 隧道 → 秒级「解析成功但连不通」的回流丢包（应用还可能缓存
            // 失败结果）。先停流量层（清静态路由 + 物理清残留），再恢复
            // 解析层：DNS 恢复的一刻路由已经直连，新连接一次成功。对齐
            // performCleanup「先断流量层、再恢复解析层」的既有分层。
            // The kernel that owned these is gone, so nothing else will ever
            // withdraw them — same reasoning as the `stopEngine` teardown.
            if staticRoutesInjected {
                let ok = await XPCManager.shared.callCleanupAllExcludeRoutes()
                logKernel("XPC Helper 清理静态路由: \(ok == true ? "成功" : "失败")")
                if ok == true || ok == nil { staticRoutesInjected = false }
            }
            if NetScanner.hasDownedMihomoTun() {
                logKernel("关闭 TUN 时检测到残留 utun，请求特权服务物理清理…")
                _ = await XPCManager.shared.callCleanupTUNResidual()
            }
            await restoreTunnelDNS()
            logKernel("内核未运行，TUN 已就地关闭（配置落盘 tun.enable=false）")
            showToast("TUN 模式已关闭", kind: .ok)
            return
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
                    engine.persistTunState(enabled: true, device: pinnedTunDevice)
                    // Same blackout window as the root switch above.
                    await withSystemProxySuspended("TUN 重启重试") {
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
                    }
                    if tunOn {
                        // The restart brought a utun up, which moves the default
                        // interface — arm the settle window exactly like the
                        // PATCH success path does, or the imminent NWPathMonitor
                        // storm would hit an expired window and rebuild the
                        // tunnel a second time, dropping every live connection.
                        tunStateSettleUntil = Date().addingTimeInterval(10)
                        // Restart path brought the tunnel up outside the PATCH
                        // success latch below — commit the staged fingerprint now
                        // so reconcile does not re-push the same plan, and so a
                        // *failed* first PATCH that later recovered via restart
                        // is not stuck with a blank latch forever.
                        if let fp = pendingCoexistenceFingerprint {
                            lastCoexistenceFingerprint = fp
                        }
                    } else {
                        // Still no utun after a clean init — genuinely cannot start
                        // (no privilege, or another VPN owns the routes). Tear the
                        // kernel back down so it cannot keep TUN half-up, and undo
                        // the persist above so the next plain start does not retry
                        // TUN outside this flow.
                        // Leave `lastCoexistenceFingerprint` untouched: the staged
                        // value was never committed, so reconcile can still retry
                        // after a later successful enable.
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
                // Kernel state now matches intent (tunOn == want after refresh).
                // Only here is the coexistence latch safe to advance — mirrors
                // `reconcileCoexistenceIfChanged`, which writes the fingerprint
                // after a confirmed PATCH, never before.
                if let fp = pendingCoexistenceFingerprint {
                    lastCoexistenceFingerprint = fp
                }
                // TUN disable cascades: Gateway mode requires TUN, so if we
                // just turned TUN off, also tear down Gateway (sysctl + UI +
                // restore the allow-lan/dns.listen overrides Gateway applied).
                if !want && gatewayModeOn {
                    _ = await engine.setGatewayMode(enabled: false)
                    gatewayModeOn = false
                    // The user never asked for Gateway to stop — TUN did. Remember
                    // it so the next successful enable brings the LAN back up with
                    // the tunnel instead of stranding every downstream client.
                    gatewayPendingTunRestore = true
                    logKernel("网关中枢随 TUN 一同关闭，已记录状态，TUN 重新开启后会自动恢复")
                    gatewayDevices.removeAll(keepingCapacity: false)
                    // Restore config.yaml overrides so a later config switch /
                    // Gateway re-enable doesn't read stale snapshot values.
                    let restores: [String: Any] = [
                        "allow-lan": preGatewayAllowLan ?? false,
                        "dns": [
                            "enable": true,
                            "listen": preGatewayDNSListen ?? Self.defaultDNSListen,
                            "enhanced-mode": "fake-ip"
                        ]
                    ]
                    preGatewayAllowLan = nil; preGatewayBindAddress = nil; preGatewayDNSListen = nil
                    engine.setTopLevelScalars(restores)
                    noteConfigContentChanged()
                }
                // No auto-stopEngine when both proxy faces are off — keep the core
                // warm so re-enabling TUN is a PATCH, not a full root restart.
                if want {
                    showToast("TUN 模式已开启", kind: .ok)
                    // Gateway rides on TUN: if a teardown took it down with the
                    // tunnel, bring it back now that the tunnel is up again.
                    await restoreGatewayAfterTUNIfPending()
                    // Delayed acceptance: wait for the settle window to close, then
                    // prove the data plane actually answers. A utun that exists but
                    // whose fd is already stale would otherwise look healthy until
                    // the next 30 s poll.
                    scheduleTUNDataPlaneProbe(reason: "开启验收", delay: 2.0)
                } else if !systemProxyOn && reachable {
                    showToast("TUN 模式已关闭（内核仍在运行，可在侧栏停止）", kind: .ok)
                } else {
                    showToast("TUN 模式已关闭", kind: .ok)
                }
                if !want {
                    // TUN is now off — restore system DNS before anything else.
                    // The TUN fake-ip gateway (198.18.0.0) only answers while
                    // the tunnel is up; a downed utun black-holes all DNS.
                    // refreshConfigs also does this on the tunOn transition, but
                    // calling it here too is a belt-and-suspenders guarantee:
                    // if refreshConfigs short-circuits (inflight task, stale
                    // cache) the user is still left with working DNS.
                    // 按属主判断：TUN 关闭只收 `.tun` 属主的账。`.proxy` 属主
                    // （redir-host 模式的 127.0.0.1）在系统代理仍开着时必须留着，
                    // 否则关 TUN 会顺手拆掉代理模式的防污染解析。
                    // record(for:) 含 pending：写入已发起但未确认的崩溃窗口同样要还原。
                    if TunnelDNSLedger.record(for: .tun) != nil {
                        await restoreTunnelDNS()
                    }
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

    // MARK: - TUN data-plane probe & recovery
    //
    // Interface-table / route-table health is not enough: macOS can re-mount
    // `utun100` under mihomo and leave a stale TUN fd that still looks UP. The
    // probe round-trips a one-packet DNS query to the fake-ip gateway; recovery
    // is a full process restart (PATCH cannot re-open the fd). See
    // `Sources/Model/TUNDataPlaneProbe.swift` and the matching EngineControl
    // helpers. Third-party routes stay untouched — only our own residual cleanup
    // and coexistence provenance run during recovery.

    /// Cancel any in-flight data-plane probe. Optionally reset the failure
    /// counter (user-driven TUN off / completed recovery).
    func cancelTUNDataPlaneProbe(resetHealth: Bool = false) {
        tunDataPlaneProbeTask?.cancel()
        tunDataPlaneProbeTask = nil
        tunProbeScheduledFireDate = nil
        if resetHealth { tunDataPlaneHealth.reset() }
    }

    /// Schedule a debounced data-plane probe. Multiple triggers within the
    /// settle/cooldown windows collapse onto one Task. Never restarts the
    /// kernel by itself — only a failed probe cycle may escalate to recovery.
    ///
    /// 2026-10-14（审查中-9 修复）：合并调度替代 cancel+重建。旧实现每个
    /// 事件都把倒计时清零重排——高频事件风暴（NWPathMonitor/path-update，
    /// 间隔 < delay）下探针被无限顺延、永不执行，且零日志：整条数据面
    /// 防线静默失效。现语义：
    /// - 已有轮在跑：并入该轮（维持「至多一轮在跑」不变量），不并行；
    /// - 已有在排任务：触发时刻取 min(既有, now+delay)——风暴只能把探针
    ///   拉早或保持不变，永远推不晚；时刻不变时完全复用既有 Task，不
    ///   取消重建；
    /// - 仅在需要拉早（或触发饿死保底）时才重建 Task；
    /// - 保底：距上次实际开跑超过 2×delay 仍没跑成 → 强制立即排一次
    ///   （覆盖任务被外部取消等丢失路径）。
    /// 合并与保底路径都打日志（合并限频 10s 一条防风暴刷屏；保底不限频）：
    /// 饿死曾经完全静默，可见性本身就是排查价值。
    func scheduleTUNDataPlaneProbe(reason: String, delay: TimeInterval = 0) {
        guard tunOn, reachable, !sleeping else { return }
        guard !tunDataPlaneRecoveryInFlight else { return }
        guard !engine.isBusy, !tunAutoTeardownInFlight else { return }
        guard Date() >= tunStateSettleUntil else { return }
        guard Date() >= tunDataPlaneRecoveryCooldownUntil else { return }

        let now = Date()
        // 饿死保底判据：距上次实际开跑超过 2×delay。delay==0 的调用本身
        // 就是立即排程，无饿死可言；lastRunDate==nil（从未跑过）也不算——
        // 首次调度后合并逻辑已保证任务不会被推晚。
        let starved = delay > 0
            && tunProbeLastRunDate.map { now.timeIntervalSince($0) > delay * 2 } == true

        // 已有轮在跑：并入该轮。旧实现会 cancel 运行中的轮再重排——既打断
        // 取证又继续顺延，两个毛病一起修掉。
        if tunProbeRunning {
            logProbeScheduleMerge("已有探测轮执行中，事件并入该轮（原因：\(reason)）", now: now)
            return
        }

        if let existing = tunDataPlaneProbeTask, !existing.isCancelled,
           let existingFire = tunProbeScheduledFireDate {
            let target = starved ? now : min(existingFire, now.addingTimeInterval(delay))
            if !starved, target >= existingFire {
                // 合并：既有触发时刻更早或相等，任务原样保留。
                logProbeScheduleMerge("合并调度：保留既有触发时刻（原因：\(reason)）", now: now)
                return
            }
            if starved { logProbeScheduleStarved(now: now, delay: delay, reason: reason) }
            existing.cancel()
            startTUNDataPlaneProbeTask(fireAfter: max(0, target.timeIntervalSince(now)), reason: reason)
            return
        }

        if starved { logProbeScheduleStarved(now: now, delay: delay, reason: reason) }
        startTUNDataPlaneProbeTask(fireAfter: starved ? 0 : delay, reason: reason)
    }

    /// 实际建探针 Task 并登记预定触发时刻（fireAfter=0 表示立即执行）。
    /// 「预定时刻 → 执行中」的交接在 MainActor 的同一同步段内完成
    /// （置 nil 与置 running 之间无挂起点），不给并行调度留缝隙。
    private func startTUNDataPlaneProbeTask(fireAfter: TimeInterval, reason: String) {
        tunProbeScheduledFireDate = Date().addingTimeInterval(fireAfter)
        tunDataPlaneProbeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if fireAfter > 0 {
                try? await Task.sleep(nanoseconds: UInt64(fireAfter * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self.tunProbeScheduledFireDate = nil
            self.tunProbeRunning = true
            await self.runTUNDataPlaneProbe(reason: reason)
            self.tunProbeRunning = false
        }
    }

    /// 合并日志限频：风暴期同一形态每 10s 至多一条，避免刷爆 app.log。
    private func logProbeScheduleMerge(_ msg: String, now: Date) {
        guard now.timeIntervalSince(tunProbeMergeLogAt) >= 10 else { return }
        tunProbeMergeLogAt = now
        logKernel("TUN 数据面探针\(msg)")
    }

    /// 保底日志不限频：真实饿死是稀有且重要的事件，条条都要留痕。
    private func logProbeScheduleStarved(now: Date, delay: TimeInterval, reason: String) {
        let since = tunProbeLastRunDate.map { Int(now.timeIntervalSince($0)) } ?? -1
        logKernel("TUN 数据面探针饿死保底触发：距上次实际执行 \(since)s（>2×delay=\(Int(delay * 2))s），强制立即排程（原因：\(reason)）")
    }

    /// Kernel log-storm watchdog — runs on the verifyTUNConfig cadence
    /// (30 s foreground; background only every 4th tick, so worst-case
    /// detection is a few minutes — still two orders of magnitude below
    /// the 63 GB/h the incident burned).
    ///
    /// Why this exists when the data-plane probe already does: the 2026-09-12
    /// incident burned 1.3 cores at ~118k CSW/s with zero traffic and ~18MB/s
    /// of `batch read packet: bad file descriptor` spam, while *every*
    /// existing health signal stayed green — the control API answered in 22ms,
    /// fake-ip DNS round-tripped, the route table was correct. A read loop
    /// pinned to an fd that died at device creation keeps serving traffic
    /// through its healthy neighbours, so packet-level probes cannot see it;
    /// the log sink it is hammering is the one signal it cannot fake.
    ///
    /// Escalation ladder (each rung = one detection window; remedies in order
    /// of cost, both measured during the incident):
    ///   1. in-place device rebuild (tun enable false→true) — this is what
    ///      actually healed the machine;
    ///   2. full-process rebuild via the proven data-plane recovery path;
    ///   3. stop acting, point at the log. A remedy that does not land must
    ///      never become a restart loop.
    func observeKernelLogStorm() async {
        guard kernelLogStormTrips < 3, !tunDataPlaneRecoveryInFlight,
              !engine.isBusy, !tunAutoTeardownInFlight else { return }
        let bytes = engine.kernelLogBytes()
        let now = Date()
        defer { kernelLogBytesLastSample = bytes; kernelLogSampleAt = now }
        guard let last = kernelLogSampleAt, kernelLogBytesLastSample >= 0 else { return }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed >= 10 else { return }
        let rate = Double(bytes - kernelLogBytesLastSample) / elapsed
        // 300KB/s sustained is orders of magnitude above anything normal
        // operation writes (idle: ~0; busy info-level: KB/min), and far below
        // the observed storm. Negative deltas (helper/user spawn caps truncate
        // the sinks on a fresh kernel) simply do not trip.
        guard rate > 300_000 else { return }
        kernelLogStormTrips += 1
        let human = "\(Int(rate / 1024))KB/s"
        switch kernelLogStormTrips {
        case 1:
            logKernel("检测到内核日志风暴（\(human)）：批量读 fd 已半死（数据面探测不可见），原地翻转 tun enable 重建设备")
            showToast("检测到内核异常空转，正在自动重建 TUN 设备…", kind: .warn)
            await rebuildTUNDeviceInPlace()
        case 2:
            logKernel("设备重建后日志风暴仍复现（\(human)）：升级为整进程重建")
            showToast("内核异常仍在，正在整进程重建…", kind: .warn)
            await performTUNDataPlaneRecovery(gateway: tunnelDNSAddress())
        default:
            logKernel("内核日志风暴连续第 \(kernelLogStormTrips) 次（\(human)）——已停止自动处置，请检查 /Library/Logs/ClashHalo/mihomo-root.log")
            showToast("内核持续写入错误日志，请查看内核日志", kind: .error)
        }
    }

    /// In-place TUN device rebuild: disable then re-enable the running
    /// kernel's tun block, forcing mihomo to close and recreate the utun
    /// device and restart its read loops — without touching the process, and
    /// while `tunOn` intent and route/DNS ownership flags stay as they are.
    /// The whole-file `recvmsgx`/`stack` user intent survives because every
    /// body goes through `tunPatchBody`'s full restatement.
    ///
    /// The window where the utun is gone fires NWPath updates that the
    /// interface-missing auto-teardown would read as loss and cascade
    /// `applyTUNState(false)` behind our back — hold `engine.isBusy` for the
    /// flip (manual + defer per the auto-teardown convention; `withEngineBusy`
    /// is fire-and-forget and would release before the re-enable lands) and
    /// open a settle window so refreshConfigs cannot derive tunOn false.
    private func rebuildTUNDeviceInPlace() async {
        engine.isBusy = true
        // 60s = settle 最长档：就地重建走 disable→1.5s→enable 两段 PATCH +
        // configd 重挂设备（各档用途见 tunStateSettleUntil 声明处取值地图）。
        tunStateSettleUntil = Date().addingTimeInterval(60)
        defer { engine.isBusy = false }
        _ = await engine.patchConfig(["tun": tunPatchBody(enable: false)])
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        // A cancelled task makes every URLSession await below fail, which —
        // combined with a dropped re-enable — strands the kernel at tun OFF
        // while the system DNS still points at a fake-ip gateway whose utun
        // is gone: a whole-machine blackhole that is WORSE than the storm we
        // set out to heal, and invisible to this watchdog (the dead fd died
        // with the device, so the log stops growing and nothing re-trips).
        // Never leave the flip half-done: an unconfirmed enable escalates to
        // the full-process rebuild on the spot. (Do not write this as
        // `!Task.isCancelled && await …` — autoclosure `&&` does not support
        // concurrency, same constraint noted in performTUNDataPlaneRecovery.)
        var revived = false
        if !Task.isCancelled {
            revived = await engine.patchConfig(["tun": tunPatchBody(enable: true)])
        }
        if revived {
            NetScanner.invalidateTunCache()
            return
        }
        logKernel("TUN 原地重建：重新启用未确认，立即升级整进程重建（不得停在半关状态）")
        tunStateSettleUntil = .distantPast
        engine.isBusy = false   // recovery's entry guard demands an idle
        // engine; same MainActor segment, so the guard+flag inside it engage
        // atomically behind this line — no window for a user toggle to claim
        // the lock in between.
        await performTUNDataPlaneRecovery(gateway: tunnelDNSAddress())
    }

    // MARK: - Config-OFF zombie TUN & self-loop recovery
    //
    // 2026-09-16 incident forensics: `tun.enable: false`, system-proxy mode,
    // yet `utun100` was UP holding 211 auto-route splits (17.248.x — Apple
    // ranges being the exact tripwire). dataaccessd's UDP packets were pulled
    // into the tunnel, mihomo sent them "DIRECT", the OS delivered them right
    // back into utun100, and every lap counted AGAINST THE SAME CONNECTION as
    // download: ~104 MB/s of counter growth, zero bytes on the physical NIC,
    // ~10.8 TB of phantom bytes in 26 hours. No existing watchdog sees this
    // shape: every TUN guard is gated on `tunOn`, and here the *config* side
    // is off while the *interface* side is on.

    /// 30 s zombie sweep. Runs when — and only when — TUN is logically OFF;
    /// it is the deliberate complement of `verifyTUNConfig` (which requires
    /// `tunOn`). Detection is strict by construction
    /// (`NetScanner.upDetachedMihomoTun`: pinned device name + UP + owning
    /// routes), because the remedy restarts the kernel. Two consecutive
    /// strikes before acting: a settle-window blip must not cost a restart.
    func sweepZombieTUN() async {
        // v1.3.4 故意的反向门控：tunOn=true 时僵尸形态归配置管理路径
        // （applyTUNState / 数据面探针）处置，本巡检不介入——该行为不变。
        // 盲区日志（2026-10-14 审查低级项）：tunOn=true 且内核不可达、
        // 而 pin 住的 utun 仍 UP 持路由 = 「配置说开、内核已死、隧道仍在
        // 劫持流量」的夹缝——配置管理路径的前提（reachable）已不成立，
        // 该形态此前完全静默。只记日志方便排查，不做任何处置。
        // 判据必须带 !reachable：upDetachedMihomoTun 对健康 TUN 同样返回
        // utun100（UP + 持路由正是健康形态），裸判会每轮巡检误报。
        if tunOn {
            if !reachable, await NetScanner.upDetachedMihomoTun() != nil {
                logKernel("僵尸 TUN 巡检盲区记录：tunOn=true 但内核不可达且 \(kPinnedTunDevice) 仍 UP 持路由——按设计本巡检不介入，等待配置管理路径/数据面探针处置")
            }
            return
        }
        guard reachable, !sleeping else { return }
        guard !engine.isBusy, !tunAutoTeardownInFlight, !tunDataPlaneRecoveryInFlight,
              !zombieTunRepairInFlight, !tunLoopTripInFlight else { return }
        guard Date() >= tunStateSettleUntil, Date() >= zombieTunCooldownUntil else { return }

        guard await NetScanner.upDetachedMihomoTun() != nil else {
            if zombieTunStrikes != 0 { zombieTunStrikes = 0 }
            return
        }
        zombieTunStrikes += 1
        guard zombieTunStrikes >= 2 else {
            logKernel("疑似僵尸 TUN：配置已关但 \(kPinnedTunDevice) 仍 UP 且承载路由（第 1 击，待复查确认）")
            return
        }
        logKernel("确认僵尸 TUN：配置已关但 \(kPinnedTunDevice) 仍 UP 且承载路由（第 \(zombieTunStrikes) 击）")
        // Claim the repair slot *before* the next suspension point. The guard at
        // the top of this function reads `zombieTunRepairInFlight`, but the flag
        // used to be set only inside `healDetachedTUN` — i.e. after this line's
        // `await`. Two sweeps landing in that window both passed the guard and
        // both called heal: observed live as
        //
        //     17:23:58 确认僵尸 TUN …（第 2 击）
        //     17:23:58 僵尸 TUN 自愈：重建内核清除隧道残留（巡检，第 1 次）
        //     17:23:58 确认僵尸 TUN …（第 3 击）
        //     17:23:58 僵尸 TUN 自愈：重建内核清除隧道残留（巡检，第 2 次）
        //
        // i.e. two kernel rebuilds for one zombie — and while hidden this can be
        // two *concurrent* `engine.restart` calls. Setting it here (and having
        // `healDetachedTUN` leave the release to its own defer) closes the window
        // regardless of which caller gets there first.
        zombieTunRepairInFlight = true
        await healDetachedTUN(reason: "巡检")
    }

    /// The surgical remedy: a process restart. Killing mihomo releases its
    /// utun fd, and the device — with every auto-route split that still
    /// diverts packets — dies with it. `cleanupTUNResidual` stays a
    /// post-restart fallback ONLY: it sweeps *every* 198.18.x utun, so
    /// calling it while a co-resident proxy VPN is healthy would tear down
    /// that app's tunnel too. Mirrors the user-facing 「重启内核」 pattern:
    /// system proxy is temporarily cleared so a dead kernel behind a stale
    /// proxy setting cannot black-hole the Mac, and restored through the
    /// verified path only when the kernel is back.
    private func healDetachedTUN(reason: String) async {
        guard zombieTunRestarts < 3 else {
            logKernel("僵尸 TUN 已重启内核 \(zombieTunRestarts) 次仍未清除，停止自动重建（请检查共存 VPN 或在网络页手动重启内核）")
            showToast("僵尸 TUN 无法自动清除，请在「网络」页手动重启内核", kind: .error)
            zombieTunStrikes = 0
            // 1800s = 熔断冷却（与下方 120s 的两次自愈最小间隔用途不同）：
            // 连续 3 次补救无效说明自动手段已尽，长停防止「治不好的补救」
            // 变成无限重启循环——补救本身成为新故障源。
            zombieTunCooldownUntil = Date().addingTimeInterval(1800)
            return
        }
        zombieTunRestarts += 1
        zombieTunRepairInFlight = true
        defer {
            zombieTunRepairInFlight = false
            zombieTunStrikes = 0
            // 120s = 两次僵尸自愈的最小间隔：重启自身会产生 path 风暴，
            // 巡检不能追自己的尾巴（三次无效后的 1800s 熔断档在上方）。
            zombieTunCooldownUntil = Date().addingTimeInterval(120)
        }
        logKernel("僵尸 TUN 自愈：重建内核清除隧道残留（\(reason)，第 \(zombieTunRestarts) 次）")
        showToast("检测到已关闭的 TUN 仍在劫持路由，正在自动重启内核清除…", kind: .warn)
        engine.isBusy = true
        // 45s = 内核重启档 settle：restart + waitForKernelReady 全程（取值
        // 地图见 tunStateSettleUntil 声明处；勿与 bring-up 的 10s 档混淆）。
        tunStateSettleUntil = Date().addingTimeInterval(45)
        defer { engine.isBusy = false }
        let wasProxy = systemProxyOn
        let port = proxyPort
        if wasProxy {
            _ = await engine.setSystemProxy(enabled: false, port: port)
            systemProxyOn = false
        }
        await engine.restart(preferRoot: engine.runningAsRoot)
        let ready = await waitForKernelReady(maxAttempts: 12)
        await reconnect()
        guard ready else {
            if wasProxy { _ = await restoreSystemProxy(reason: "僵尸 TUN 自愈（内核未就绪）") }
            showToast("内核重启超时，请在「网络」页检查内核状态", kind: .warn)
            return
        }
        // Pinned-name residue that survived its holder's death can only be
        // a configd-held ghost; at that point the broad physical sweep is
        // justified (and the restart cap above keeps it from looping).
        NetScanner.invalidateTunCache()
        if await NetScanner.upDetachedMihomoTun() != nil {
            logKernel("内核重启后 \(kPinnedTunDevice) 仍 UP，请求特权服务物理清理残留")
            let ok = await XPCManager.shared.callCleanupTUNResidual()
            logKernel("僵尸 TUN 残留清理: \(ok == true ? "完成" : "特权服务不可达/失败")")
        }
        if wasProxy {
            _ = await restoreSystemProxy(reason: "僵尸 TUN 自愈")
        }
        showToast("僵尸 TUN 已清除，内核重建完成", kind: .ok)
    }

    /// A sentinel-flagged trip (from `recordHistoryOnly`), confirmed through
    /// route forensics before healing: the counter shape (DIRECT + frozen
    /// upload + massive downlink growth) cannot by itself separate "our own
    /// route is re-injecting into us" from a genuinely push-heavy download —
    /// the route resolving to *our* tunnel is what makes it certain.
    func handleTUNLoopTrip(_ trip: TUNLoopTrip) async {
        guard !tunLoopTripInFlight else { return }
        tunLoopTripInFlight = true
        defer {
            tunLoopTripInFlight = false
            tunLoopSentinel.reset()
        }
        guard !trip.destinationIP.isEmpty else {
            logKernel("疑似 TUN 自循环（\(trip.host)）无目的地 IP，无法路由取证，跳过")
            return
        }
        let tunName = await NetScanner.mihomoTunInterface(maxAge: 0)
        let target = await NetScanner.routeTargetInterface(trip.destinationIP)
        guard let tunName, target == tunName else {
            logKernel("TUN 自循环指纹命中但路由取证排除：\(trip.destinationIP) → \(target ?? "?")（隧道：\(tunName ?? "无")）")
            return
        }
        let phantomGB = String(format: "%.1f", Double(trip.phantomBytes) / 1e9)
        logKernel("确认 TUN 自循环：\(trip.host) (\(trip.destinationIP)) DIRECT 回注隧道 \(tunName)，"
                  + "上行归零下连续 \(trip.ticks) 拍下行膨胀 \(phantomGB) GB")
        if tunOn {
            // User intent is ON: full data-plane recovery keeps TUN desired
            // (stop, residual clean, root restart, re-probe, fall back only
            // if acceptance still fails).
            await performTUNDataPlaneRecovery(gateway: tunnelDNSAddress())
        } else {
            // Config OFF: the tunnel is detached — a route-confirmed trip is
            // stronger evidence than one sweep strike, so act on it directly.
            zombieTunStrikes = 2
            await healDetachedTUN(reason: "自循环取证")
        }
    }

    /// One probe cycle. On threshold failure, escalates to at most one recovery.
    private func runTUNDataPlaneProbe(reason: String) async {
        // 到达 runner 即视为调度机制没有饿死——即使下面的 guard 弹回本轮，
        // 也记录「实际开跑」时刻（中-9 饿死保底以此为准：它要抓的是「任务
        // 永远排不上、倒计时被事件风暴无限顺延」，不是 guard 弹回）。
        tunProbeLastRunDate = Date()
        guard tunOn, reachable, !sleeping else { return }
        guard !tunDataPlaneRecoveryInFlight else { return }
        guard !engine.isBusy, !tunAutoTeardownInFlight else { return }
        guard Date() >= tunStateSettleUntil else { return }
        guard Date() >= tunDataPlaneRecoveryCooldownUntil else { return }

        // The interface must still exist — if it is gone, the existing B10 /
        // verifyTUNConfig teardown path owns the response. Probing a missing
        // gateway would only produce false "data plane dead" noise.
        //
        // Its NAME is also the probe's identity predicate: the socket is bound
        // to this device and only a reply arriving on it counts. Without that
        // the probe accepted mihomo's `any:53` hijack answer over the default
        // route and reported the tunnel healthy against `198.18.0.0` — the
        // network address of `198.18.0.0/30`, which no host owns — for 1400
        // consecutive rounds while the data plane was unusable.
        guard let tunDevice = await NetScanner.mihomoTunInterface(maxAge: 0) else { return }

        let gateway = tunnelDNSAddress()
        logKernel("TUN 数据面探测开始（\(reason)）→ \(gateway):53 @\(tunDevice)")
        let outcomes = await engine.runTUNDataPlaneProbeCycle(gateway: gateway,
                                                              interface: tunDevice)
        // Feed every attempt into the sliding-window state machine on this
        // actor — never pass actor-isolated state as `inout` into an async
        // helper. A success does NOT reset the window: a half-dead fd can
        // round-trip an occasional probe and that one good packet must not
        // erase an in-flight bad burst. Only a full healthy cycle clears it.
        var trip = false
        var sawAnyFailure = false
        var sawAnySuccess = false
        for (i, ok) in outcomes.enumerated() {
            if ok {
                sawAnySuccess = true
                logKernel("TUN 数据面探测 \(i + 1)/\(outcomes.count): DNS gateway \(gateway) 应答")
            } else {
                sawAnyFailure = true
                logKernel("TUN 数据面探测 \(i + 1)/\(outcomes.count) 失败: DNS gateway \(gateway) timeout")
            }
            if tunDataPlaneHealth.record(success: ok) {
                trip = true
            }
        }
        // Only a completely clean cycle (every attempt answered) clears the
        // window. A half-dead fd will still see `sawAnyFailure == true` after
        // the burst, so the bad evidence persists across cycles until either
        // the recovery threshold trips or the fd genuinely returns to 100%.
        if !sawAnyFailure, sawAnySuccess, !trip {
            tunDataPlaneHealth.reset()
        }
        guard trip else { return }

        logKernel("TUN 数据面窗口失败 \(tunDataPlaneHealth.consecutiveFailures)/\(tunDataPlaneHealth.threshold)：准备重建 mihomo")
        await performTUNDataPlaneRecovery(gateway: gateway)
    }

    /// Full process rebuild after a confirmed data-plane fault.
    ///
    /// Order mirrors the documented recovery path and reuses existing stop /
    /// start / residual / coexistence helpers — no second process-manager.
    /// At most one recovery per anomaly; on secondary probe failure after the
    /// rebuild, TUN is closed and the system returns to direct connectivity.
    private func performTUNDataPlaneRecovery(gateway: String) async {
        // A lagging probe cycle can arrive here while the watchdog's flip
        // holds isBusy; both paths reset the flag via their own defer, and the
        // flip's would release recovery's lock mid-restart. Foreign holders
        // bounce (the next window re-derives the need); the watchdog's
        // escalation path calls in from a synchronously-released section and
        // always passes.
        guard !engine.isBusy else { return }
        guard !tunDataPlaneRecoveryInFlight else { return }
        tunDataPlaneRecoveryInFlight = true
        engine.isBusy = true
        let t0 = Date()
        defer {
            engine.isBusy = false
            tunDataPlaneRecoveryInFlight = false
            // Cool-down so a recovery-induced path storm cannot immediately
            // re-enter. Also covers the failure path where we closed TUN.
            // 30s 与 settle 窗（10/45/60s）刻意不同轴：settle 门「状态推导」，
            // 本冷却门「补救重演」——自愈自身重启内核产生新风暴，风暴到达时
            // 窗口失败计数还没滑出，无此门会立刻触发下一次自愈（取值地图见
            // tunStateSettleUntil 声明处）。
            tunDataPlaneRecoveryCooldownUntil = Date().addingTimeInterval(30)
            tunDataPlaneHealth.reset()
        }

        logKernel("TUN 自愈阶段: 停止内核")
        showToast("检测到 TUN 数据面异常，正在自动重建…", kind: .warn)

        // Best-effort logical disable so the kernel releases its TUN fd before
        // the process is killed. Failure is fine — stopKernel is the authority.
        _ = await engine.patchConfig(["tun": tunPatchBody(enable: false)])
        engine.setTunEnabled(false)

        await engine.stopKernel()
        reachable = false
        // Do not flip tunOn=false here: user intent is still ON. refreshConfigs
        // will re-derive from reality after the rebuild; if we closed it, the
        // fallback path writes tunOn explicitly.

        // Only our residual. Helper refuses peer-owned routes; hasDowned gate
        // keeps a co-resident 198.18 VPN untouched when nothing of ours remains.
        logKernel("TUN 自愈阶段: 清理残留")
        // Do not put `await` on the RHS of `||` — Swift autoclosure there does
        // not support concurrency (same constraint as stopEngine).
        var residualVisible = NetScanner.hasDownedMihomoTun()
        if !residualVisible {
            residualVisible = await NetScanner.mihomoTunInterface(maxAge: 0) != nil
        }
        if residualVisible {
            let ok = await XPCManager.shared.callCleanupTUNResidual()
            logKernel("TUN 自愈阶段: 清理残留完成（\(ok == true ? "成功" : "跳过/失败")）")
        } else {
            logKernel("TUN 自愈阶段: 无残留可清理")
        }

        // Rebuild as root — TUN requires it. Persist enable + device so the
        // cold start brings the tunnel up during init (same race the normal
        // enable path already solved).
        logKernel("TUN 自愈阶段: 启动内核")
        engine.persistTunState(enabled: true, device: pinnedTunDevice)
        await engine.ensureRunningAsync(preferRoot: true, allowRootUpgradeRestart: true)
        let ready = await waitForKernelReady(maxAttempts: 18)
        let readyElapsed = String(format: "%.1f", Date().timeIntervalSince(t0))
        guard ready else {
            logKernel("TUN 自愈失败: 内核就绪超时 +\(readyElapsed)s")
            await fallbackCloseTUNAfterFailedRecovery(reason: "内核重启后未就绪")
            return
        }
        logKernel("TUN 自愈阶段: 内核就绪 +\(readyElapsed)s")
        await reconnect()
        if !engine.runningAsRoot { await engine.syncRunningAsRootIfNeeded() }

        // Ensure TUN is on (cold start from persisted enable usually already is).
        // Use the full apply path only if the interface is still missing — it
        // reuses coexistence injection and the restart-fallback already proven.
        NetScanner.invalidateTunCache()
        var up = await waitForTUNInterface(maxAttempts: 20)
        if !up {
            logKernel("TUN 自愈阶段: utun 未出现，走 applyTUNState 重建")
            await applyTUNState(true, allowRestartFallback: true)
            let ifacePresent = await NetScanner.mihomoTunInterface(maxAge: 0) != nil
            up = tunOn && ifacePresent
        } else {
            // Interface is up from cold start — still re-sync coexistence routes
            // the stop may have left stale, without a second full TUN rebuild.
            tunOn = true
            tunStateSettleUntil = Date().addingTimeInterval(10)
            await enableTunnelDNS()
            await reconcileCoexistenceIfChanged()
            // Force a coexistence push even if fingerprint matches the pre-crash
            // plan: static routes may have been wiped with the residual cleanup.
            lastCoexistenceFingerprint = ""
            await reconcileCoexistenceIfChanged()
        }
        let ifaceElapsed = String(format: "%.1f", Date().timeIntervalSince(t0))
        logKernel("TUN 自愈阶段: utun\(up ? "就绪" : "仍缺失") +\(ifaceElapsed)s")

        guard up, tunOn else {
            await fallbackCloseTUNAfterFailedRecovery(reason: "重建后 utun 未出现")
            return
        }

        // Secondary acceptance: 2–3 short probes. Any success unlocks the lock.
        // All fail → close TUN, restore direct, stop looping.
        //
        // Probe identity matters most here: this is the acceptance step that
        // decides whether a rebuilt tunnel is declared healthy. Binding to the
        // device (rather than trusting the default route) is what stops an
        // `any:53` hijack answer from being accepted as proof the new fd works.
        guard let acceptanceDevice = await NetScanner.mihomoTunInterface(maxAge: 0) else {
            logKernel("TUN 自愈验收无法进行：无法确定隧道设备名")
            await fallbackCloseTUNAfterFailedRecovery(reason: "重建后无法确认隧道设备")
            return
        }
        var accepted = false
        for attempt in 1...3 {
            if await engine.probeTUNDataPlane(gateway: gateway,
                                              interface: acceptanceDevice,
                                              timeout: 0.8) {
                accepted = true
                break
            }
            logKernel("TUN 自愈验收失败 \(attempt)/3: DNS gateway \(gateway)@\(acceptanceDevice) 无响应")
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }

        let total = String(format: "%.1f", Date().timeIntervalSince(t0))
        if accepted {
            logKernel("TUN 自愈成功: DNS 数据面恢复，总耗时 \(total)s")
            showToast("TUN 数据面已自动恢复", kind: .ok)
            return
        }

        logKernel("TUN 自愈失败: 重建后数据面仍不可用，总耗时 \(total)s — 关闭 TUN 并恢复直连")
        await fallbackCloseTUNAfterFailedRecovery(reason: "重建后 DNS 数据面仍失败")
    }

    /// Terminal failure path of recovery: stop auto-restart, close TUN, clear
    /// residual, restore direct connectivity, and surface a clear notice.
    /// System proxy is intentionally left alone — only TUN is the broken face.
    private func fallbackCloseTUNAfterFailedRecovery(reason: String) async {
        logKernel("TUN 自愈回退: \(reason)")
        // applyTUNState(false) also cancels probes / resets health via the OFF path.
        await applyTUNState(false, allowRestartFallback: false)
        engine.setTunEnabled(false)
        if NetScanner.hasDownedMihomoTun() {
            _ = await XPCManager.shared.callCleanupTUNResidual()
        }
        showToast("TUN 数据面异常，自动重建后仍未恢复。已关闭 TUN 并恢复直连，请稍后重试。", kind: .error, duration: 8)
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

    // 系统 DNS 重定向的记账 key。**唯一真相源在 `DNSRedirectOwner`**
    // （Sources/Model/TunnelDNSLedger.swift），这里只是历史别名：读写一律走
    // `TunnelDNSLedger` 的 API，不要再直接碰这些 key —— 两个写者共用一套裸 key
    // 正是审查高-1/高-2 的成因。
    static let kDNSOverriddenKey = DNSRedirectOwner.tun.overriddenKey
    static let kDNSSavedKey = DNSRedirectOwner.tun.savedKey
    /// N9: the network service the redirect was written to, so restore targets
    /// the same service even if the system default changed in between.
    static let kDNSServiceKey = DNSRedirectOwner.tun.serviceKey

    /// The TUN gateway to use as the system resolver. Prefers the live config's
    /// `tun.inet4-address` gateway; falls back to mihomo's default fake-ip gateway.
    ///
    /// The configured value is a PREFIX (mihomo's default is `198.18.0.0/30`),
    /// and the address inside it is the *network* address — the all-zero host
    /// part. Stripping the `/30` and using the remainder verbatim hands the
    /// system a resolver that can never answer: .0 is not a host in that subnet
    /// (only .1 and .2 are), so every query to it is dropped. Measured live
    /// before this fix: `dig @198.18.0.0 www.baidu.com` → "connection timed
    /// out; no servers could be reached" and `ping 198.18.0.0` → 100% loss,
    /// while the tunnel itself was up. That is the whole-system DNS blackhole.
    ///
    /// The answerable gateway is the first *host* of the prefix, so advance past
    /// the network address. Falls back to mihomo's default fake-ip gateway when
    /// the config has no usable prefix.
    func tunnelDNSAddress() -> String {
        let addrs = (configs["tun"] as? [String: Any])?["inet4-address"] as? [String] ?? []
        // Prefer the address the interface ACTUALLY holds over the one the config
        // prefix implies. Measured 2026-10-09: mihomo ignores `tun.inet4-address`
        // outright (PATCH / config.yaml / PUT ?force=true all left
        // `ifconfig utun100` at `inet 198.18.0.0`), so the prefix-derived `.1` and
        // the kernel's real `.0` inevitably diverge — the app was redirecting
        // system DNS to an address the interface never carried, and only the
        // `dns-hijack: any:53` subnet-wide answer kept it working. Observe the
        // live address; fall back to the prefix only when observation is empty.
        let observed = NetScanner.mihomoTunInterfaceSync()
            .flatMap { name in NetScanner.interfaces().first(where: { $0.id == name })?.ipv4 } ?? []
        return TUNDNSAddress.gateway(observed: observed, fromInet4Addresses: addrs)
    }

    /// Redirect system DNS into the tunnel (idempotent). Saves the pre-existing
    /// DNS once so a manual user setting is restored later, not clobbered.
    ///
    /// 记账走 `TunnelDNSLedger`（.tun 属主）：pending → 写入 → committed 两段式，
    /// 写失败回滚、恢复失败保留账本。详见该文件顶部的不变量说明与本函数尾部注释。
    ///
    /// 本函数只负责**写入前提的三重守卫**（接口在 / 地址是合法主机 / 地址确实被
    /// 路由进自家隧道且 dns.enable），守卫全部通过后才把记账与写入交给 Ledger。
    func enableTunnelDNS() async {
        // Invariant asserted AT THE WRITE POINT, not just at callers: the
        // redirect target is the TUN fake-ip gateway, which only answers while
        // the tunnel interface exists. Upstream gates (refreshConfigs' tunOn
        // derivation, applyTUNState's post-PATCH wait) can race or regress —
        // a redirect written without the interface is a whole-system DNS
        // blackhole, the exact failure class the proxy-mode incident belonged
        // to (an unasserted premise at a system-state write that a fixed bug
        // elsewhere then activated). Cheap to check: 1.5 s TTL cache.
        guard await NetScanner.mihomoTunInterface() != nil else {
            logKernel("TUN DNS 重定向跳过：fake-ip 网关接口不存在（此时写入 198.18.0.1 即全网解析黑洞），待接口就绪后由对账重试")
            return
        }
        let gateway = tunnelDNSAddress()
        // Second invariant at the same write point: the address must be a HOST.
        // `198.18.0.0/30`'s network address (.0) is not answerable, so writing it
        // blackholes every lookup the moment the tunnel is not carrying DNS.
        // tunnelDNSAddress() already advances past it; this refuses to write
        // anything non-host-shaped even if the config grows an exotic prefix.
        guard TUNDNSAddress.firstHostAddress(inPrefix: gateway) != nil else {
            logKernel("TUN DNS 重定向跳过：网关地址 \(gateway) 不是合法主机地址，拒绝写入")
            return
        }
        // Third invariant at the same write point: mihomo must actually be
        // serving DNS. The first two gates prove the tunnel interface exists and
        // that the address is host-shaped — but *neither* asks whether anything
        // will answer on it. Measured live on this machine with TUN up and
        // `config.yaml` carrying `dns.enable: false`:
        //
        //     curl /configs → dns = null
        //     dig @198.18.0.1 www.baidu.com → status: SERVFAIL
        //     dig @198.18.0.0 www.baidu.com → status: SERVFAIL
        //     nslookup www.baidu.com        → ** server can't find ...: SERVFAIL
        //
        // i.e. the whole system lost name resolution while the redirect stood.
        // That is the same failure class as the .0 gateway bug: an unasserted
        // premise at a system-state write. Pointing the system resolver into a
        // tunnel whose DNS core is off is a guaranteed blackhole — strictly
        // worse than leaving the user's original (working) resolver in place,
        // because every lookup is then hijacked into a resolver that cannot
        // answer instead of merely bypassing the tunnel.
        //
        // Read from config.yaml, not `/configs`: mihomo's API does not return
        // the dns block at all (it reported `dns = null` even with enable:true
        // pushed via PATCH), so the persisted file is the only truthful source.
        // Same accessor the neighbouring `ensureProxyDNS` gate uses.
        let dnsBlock = (engine.readConfigFile()?["dns"] as? [String: Any]) ?? [:]
        let dnsEnabled = (dnsBlock["enable"] as? Bool) ?? false
        // And the address must actually be routed into our tunnel — the gate that
        // replaced the falsified "host bits are zero ⇒ network address ⇒ no reply"
        // rule. Measured 2026-10-09: with TUN up both .0 and .1 answer (the tunnel
        // takes the whole 198.18.0.0/15 via auto-route and dns-hijack replies on
        // it); with TUN down both time out. What separates a working redirect from
        // a blackhole is the route, not the address's host bits.
        let tunnelName = NetScanner.mihomoTunInterfaceSync()
        let routed = NetScanner.routedInterface(for: gateway)
        guard TUNDNSAddress.shouldRedirectSystemDNS(dnsEnabled: dnsEnabled,
                                                    interfacePresent: true,
                                                    gateway: gateway,
                                                    routedInterface: routed,
                                                    tunnel: tunnelName) else {
            logKernel("TUN DNS 重定向跳过：config.yaml 的 dns.enable=\(dnsEnabled ? "true" : "false")、"
                      + "网关 \(gateway) 实际出口 \(routed ?? "无路由")/隧道 \(tunnelName ?? "未找到")；"
                      + "此时写入会让全部解析进入无法应答的隧道，保持系统原 DNS 不变，待条件满足后由对账重试")
            return
        }
        // 第四道守卫（审查中-1 的配对项）：数据面探针已判定不健康时不写重定向。
        //
        // 前三道守卫证明的是「接口在 / 地址合法 / 地址被路由进自家隧道」，但
        // **路由正确不代表 fd 还能收发包** —— configd 在 mihomo 底下重挂 utun100
        // 之后，接口表与路由表都正常，mihomo 握着失效 fd（见 TUNDataPlaneProbe
        // 文档）。此时写入 198.18.x 与前三道守卫要拦的是同一类故障：把全系统解析
        // 指进一个不会应答的隧道。
        //
        // 这道守卫同时是 `sweepOrphanedTunnelDNS` 放宽前置条件的**必要配对**：
        // sweep 在数据面不健康时会清掉残留，如果这里照写，两个自愈路径就会每拍
        // 互相拆台（清掉→写回→清掉）。两边看同一份证据（窗口失败数达阈值），
        // 探针恢复后 `reset()` 同时放开，重定向由 reconcile 补写。
        //
        // 判据不用 `!allHealthy`：窗口为空（刚启动/刚 reset）时它也为真，会把
        // 健康的开启流程误拦。
        if tunDataPlaneHealth.consecutiveFailures >= tunDataPlaneHealth.threshold {
            logKernel("TUN DNS 重定向跳过：数据面探针判定不健康（窗口失败 "
                      + "\(tunDataPlaneHealth.consecutiveFailures)/\(tunDataPlaneHealth.threshold)），"
                      + "此时写入 198.18.x 等于把全系统解析指进不应答的隧道；待探针恢复后由对账补写")
            return
        }
        // 记账与写入交给 TunnelDNSLedger（系统 DNS 重定向的唯一属主）。
        //
        // 顺序由 Ledger 保证：先落 pending 记录（含 pin 的服务 + 原 DNS 快照），
        // 再写系统 DNS，写成功才把 pending 转成 committed，写失败立即回滚删账。
        // 这同时满足两条互相拉扯的不变量 ——
        //   · 不留「有账无写」：写失败即回滚，后续 teardown 不会去「还原」一次
        //     从未发生的重定向（旧实现把 flag 放在写入之后正是为了这个）；
        //   · 不留「有写无账」：pending 在写入**之前**落盘，进程在写入与记账之间
        //     被杀时，下次启动仍能看见 pending 并还原（2026-10-09 现场就是这种
        //     无账残留：Wi-Fi 上钉着 198.18.0.0 而三个 key 全空）。
        //
        // N9：pin 住写入时的那个网络服务。默认服务会在 enable/restore 之间漂移
        // （Wi-Fi ↔ 以太网），Ledger 检测到漂移会先还原旧服务再接管新服务，
        // 不再把旧服务的重定向晾成无主残留。
        let service = await EngineControl.defaultNetworkService()
        let ok = await TunnelDNSLedger.redirect(owner: .tun,
                                                servers: [gateway],
                                                service: service,
                                                log: { self.logKernel($0) })
        if !ok {
            logKernel("TUN DNS 重定向未完成（读取原 DNS 失败或写入失败），保持原状态待下次巡检重试")
        }
    }

    /// Restore the system DNS saved before TUN took over (no-op if we never
    /// overrode it). Idempotent — safe to call from every teardown path.
    ///
    /// 实现整体下沉到 `TunnelDNSLedger.restore(owner: .tun)`：按 pin 的服务还原
    /// 快照（pin 服务不可用时回退当前默认服务），**只在写成功后清账**，写失败
    /// 保留记录待下一拍重试。
    func restoreTunnelDNS() async {
        await TunnelDNSLedger.restore(owner: .tun, log: { self.logKernel($0) })
    }

    /// Throttle for `sweepOrphanedTunnelDNS`'s scan (see its doc comment).
    private static var lastOrphanSweepAt: Date = .distantPast
    private static let orphanSweepMinInterval: TimeInterval = 30
    /// Sticky across passes: set when a sweep finds a fake-ip resolver it could
    /// not clear, so the throttle cannot silence a live blackhole.
    private static var dnsRepairNeeded = false

    /// Withdraw a TUN fake-ip resolver that is still sitting in the system DNS
    /// while no tunnel is up, **regardless of the `tun.dns.overridden` flag**.
    ///
    /// Throttled: the reconcile that calls this runs on every refresh, and each
    /// pass costs a `networksetup -getdnsservers` fork per candidate service. The
    /// throttle only suppresses the *scan*; a detected residue is always fixed
    /// immediately, so the guard can never leave a blackhole in place.
    ///
    /// The flag is a single bit of bookkeeping, and it desyncs: a redirect
    /// written before the flag-setting line was reached (crash, kill, or a
    /// teardown that raced the write) leaves the address on the service with
    /// `overridden = 0`. `restoreTunnelDNS()` opens with
    /// `guard d.bool(forKey: kDNSOverriddenKey) else { return }`, so from then
    /// on **neither** branch of the reconcile at `refreshConfigs` runs
    /// (`tunOn && !dnsRedirected` is false while TUN is off;
    /// `!tunOn && dnsRedirected` is false because the flag is clear) and the
    /// stale resolver is never cleaned. Observed live 2026-10-09: Wi-Fi still
    /// carried `198.18.0.0` with TUN off, `tun.dns.saved`/`tun.dns.service`
    /// absent. It only stayed harmless because the default interface happened
    /// to be Ethernet — the moment Wi-Fi became primary, every lookup died.
    ///
    /// So the decision is made on **observed system state**, not on the flag:
    /// if a network service's DNS is a fake-ip address and no mihomo tunnel is
    /// up, that resolver is a guaranteed blackhole and gets removed. This is the
    /// same idempotent shape `ensureProxyDNS` uses for its residual revert.
    ///
    /// 2026-10-14（审查中-1/中-2）两处放宽与收紧：
    /// - **放宽**：前置守卫不再要求「TUN 关且自家隧道接口消失」。接口在、但数据面
    ///   探针已判定不健康（失效 fd）时同样清扫 —— 那种形态下 198.18.x 就是个不应答
    ///   的黑洞，而旧守卫会一路放行到探针重建内核为止。`enableTunnelDNS` 加了同源
    ///   守卫，两个自愈路径不会互相拆台。
    /// - **收紧**：共存隧道 UP 不再自动豁免无来源证据的残留，必须逐地址取证
    ///   （`routedInto`）证明它确实进了对方隧道才收手。
    ///
    /// 记账读写一律经 `TunnelDNSLedger`（`.tun` 属主）：本函数只清 TUN 的账，
    /// 不动 `.proxy` 属主（127.0.0.1 与 fake-ip 残留无关）。
    func sweepOrphanedTunnelDNS() async {
        // 数据面已判定不健康（滑动窗口失败数达到阈值）—— 这是审查中-1 的关键补充。
        //
        // 「接口在」不等于「数据面活着」：configd 在 mihomo 底下重挂 utun100 后，
        // 接口表与路由表都正常，mihomo 却握着失效 fd（见 TUNDataPlaneProbe 文档）。
        // 此时下面那两道守卫（tunOn / 自家隧道接口存在）会**全部放行**，系统 DNS
        // 仍钉在 198.18.x 上，而那个地址已经收不到应答 —— 用户看到的就是「TUN 开着
        // 但全网打不开」，且没有任何一条自愈路径会去动 DNS（探针的重建/回退要几秒
        // 到几十秒，这期间黑洞一直挂着）。
        //
        // 判据用 `consecutiveFailures >= threshold`（窗口内失败数已达触发线），
        // 不用 `!allHealthy`：后者在窗口为空（刚启动/刚 reset）时也为真，会把健康
        // 机器上的重定向误清。
        let dataPlaneUnhealthy = tunDataPlaneHealth.consecutiveFailures >= tunDataPlaneHealth.threshold
        // Only meaningful with the tunnel down: with it up the redirect is live
        // and correct (that is `enableTunnelDNS`'s job). 例外：数据面已判定不健康时，
        // 即使 tunOn 为真也要清扫 —— 那个重定向此刻只是黑洞，不是「live and correct」。
        guard !tunOn || dataPlaneUnhealthy else { return }
        // Identity-strict on purpose, and the opposite of the liveness tolerance
        // used elsewhere: this decides whether *our* fake-ip redirect is now
        // orphaned. A co-resident proxy's healthy 198.18 tunnel must not suppress
        // the sweep — the system resolver we wrote points at the mihomo gateway,
        // and if our own tunnel is gone that resolver is still a blackhole no
        // matter what another app has up.
        //
        // 中-1 放宽：自家隧道接口存在**但数据面已判定不健康**时同样清扫。
        // 与 `enableTunnelDNS` 新增的同名守卫配对 —— 两边看同一份证据，所以不会
        // 出现「sweep 清掉、reconcile 立刻写回」的乒乓。探针恢复后 reset() 窗口，
        // 两处守卫同时放开，重定向由 reconcile 补写。
        let ownTunnel = await NetScanner.ownMihomoTunInterface()
        guard ownTunnel == nil || dataPlaneUnhealthy else { return }
        if ownTunnel != nil, dataPlaneUnhealthy {
            logKernel("TUN DNS 残留清理：自家隧道 \(ownTunnel ?? "?") 接口在但数据面探针判定不健康"
                      + "（窗口失败 \(tunDataPlaneHealth.consecutiveFailures)/\(tunDataPlaneHealth.threshold)），"
                      + "此时 198.18.x 解析器只是黑洞，一并清扫")
        }

        // A tunnel exists but is not ours — a co-resident proxy. Not a reason
        // to stop sweeping (our residue is still ours to clear), but a reason
        // to be careful about services we have no provenance for, because that
        // other kernel may legitimately own the fake-ip range for its own
        // resolver. `ownMihomoTunInterface()` returning nil above only proves
        // *our* tunnel is down, not that the machine has none.
        //
        // 中-2：记下这些活隧道的**接口名**，而不只是一个布尔。豁免必须逐地址取证
        // （见下面 `residueRoutedIntoOtherTunnel`）—— 旧实现只要机器上有任何一条
        // proxyTun 处于 UP，就把所有「无来源证据 + 非默认服务」上的残留逐轮跳过，
        // 哪怕那条残留根本没有路由进对方的隧道。用户把默认服务切到残留所在服务的
        // 那一刻即全网黑洞（2026-10-09 实测的残留正是这种无 key 形态）。
        let otherLiveTunnels = NetScanner.interfaces()
            .filter { $0.kind == .proxyTun && $0.isUp && $0.id != ownTunnel }
            .map(\.id)
        let otherTunnelIsUp = !otherLiveTunnels.isEmpty

        // 记账一律走 Ledger（不再裸读 key）：sweep 关心的是 `.tun` 属主 ——
        // fake-ip 残留只可能来自 TUN 重定向。`.proxy` 属主写的是 127.0.0.1，
        // 不在本函数的清理范围里，也不该被这里清账。
        let tunRecord = TunnelDNSLedger.record(for: .tun)
        let pinnedService = tunRecord?.service ?? ""
        // Cheap skip on the overwhelmingly common path (healthy machine, no
        // redirect ever written): with no recorded service AND no flag, there is
        // nothing we ever wrote, so there is nothing to withdraw. Still checks
        // the current default below, because a redirect from an older build has
        // neither the flag nor the recorded service.
        let flagged = tunRecord != nil
        let pinned = !pinnedService.isEmpty

        // Throttle the scan, but never the FIX: once something is written here,
        // `dnsRepairNeeded` pins the throttle open until the residue is gone.
        // Re-arming the window only on a clean pass means a persistently failing
        // write keeps retrying rather than being throttled into silence.
        let now = Date()
        guard flagged || Self.dnsRepairNeeded
                || now.timeIntervalSince(Self.lastOrphanSweepAt) >= Self.orphanSweepMinInterval else {
            return
        }
        Self.lastOrphanSweepAt = now

        // Sweep *every* service, not just the one we pinned plus the current
        // default. Those two are not the set a redirect can strand on: a
        // redirect written while Wi-Fi was primary outlives a switch to
        // Ethernet, and the service that is not the default at sweep time is
        // exactly the one the old two-entry scan could not see. One
        // `networksetup` fork returns the whole list, so this costs a single
        // process however many services the machine has.
        var services: [String] = []
        if pinned, !pinnedService.isEmpty { services.append(pinnedService) }
        let current = await EngineControl.defaultNetworkService()
        for name in await EngineControl.allNetworkServices() {
            if name == current { continue }
            if !services.contains(name) { services.append(name) }
        }
        if let current, !services.contains(current) { services.append(current) }
        guard !services.isEmpty else { return }

        // Whether any residue survived this pass. Tracked separately from
        // `dnsRepairNeeded` because that flag is now decided once, after the
        // loop: clearing it inside the loop let an early success erase the
        // record of a later failure, which is exactly the shape a widened
        // sweep must not have.
        var residueRemains = false

        for service in services {
            // 三态语义：nil = 读取失败。失败既不能当"无残留"跳过（会让黑洞
            // 留在系统里），也不能当"有残留"动手（会在未知状态下改写 DNS）。
            // 跳过本轮该服务，由 30s 节流后的下一拍重试。
            guard let servers = await EngineControl.currentSystemDNS(service: service) else {
                logKernel("TUN DNS 残留清理：服务 \(service) 的 DNS 读取失败，本轮跳过（不当作干净，下拍重试）")
                continue
            }
            guard let stale = servers.first(where: { TUNDNSAddress.isFakeIPResolver($0) }) else { continue }
            // An address inside the fake-ip range is residue whoever wrote it:
            // no user types `198.18.x.x` as a resolver by hand, and with no
            // mihomo tunnel up to serve it, it is a guaranteed blackhole.
            //
            // The old guard (`!flagged && !pinned && service != services.last`)
            // tried to avoid touching config we did not write, but the price
            // was leaving a dead resolver in place: residue from a build that
            // recorded neither the flag nor the pinned service, sitting on a
            // non-default interface, was invisible *and* skipped. Provenance
            // is already established by the address itself, so gate on that
            // instead — the rule lives in TUNDNSAddress so it can be tested.
            let isDefaultService = (service == current)
            let hasProvenance = flagged || pinned
            // 中-2：豁免前逐地址取证 —— 这条残留**此刻是否真的被路由进某条活着的
            // 共存隧道**。只有取证成立才可能是对方内核的解析器；否则它就是个没有
            // 路由的死地址，照清不误。判据与 `enableTunnelDNS` 的可达性守卫同源
            // （`TUNDNSAddress.routedInto`），不引入第二套关于「谁的地址」的猜测。
            let routedIface = otherTunnelIsUp ? NetScanner.routedInterface(for: stale) : nil
            let residueRoutedIntoOtherTunnel = otherTunnelIsUp
                && otherLiveTunnels.contains { TUNDNSAddress.routedInto(routedIface, tunnel: $0) }
            guard TUNDNSAddress.shouldSweepResidueOn(hasProvenance: hasProvenance,
                                                     isDefaultService: isDefaultService,
                                                     otherTunnelIsUp: otherTunnelIsUp,
                                                     residueRoutedIntoOtherTunnel: residueRoutedIntoOtherTunnel) else {
                logKernel("TUN DNS 残留清理：服务 \(service) 上的 \(stale) 确实被路由进共存隧道 "
                          + "\(routedIface ?? "?")，疑似其他内核所有，跳过")
                continue
            }

            // Residue found and the write is about to be attempted: provisionally
            // leave the throttle open. It is cleared below only on success.
            residueRemains = true

            // Prefer the snapshot we saved at enable time; fall back to clearing
            // the service so it returns to DHCP-provided resolvers. 解码走 Ledger
            // 的 codec：它会剔除快照里被污染的 fake-ip 地址（旧版本把 198.18.x
            // 当「用户原值」存过），剔完为空则回到 "Empty"（DHCP）。
            let target = DNSLedgerCodec.sanitizedRestoreTarget(fromSnapshot: tunRecord?.snapshot ?? "")

            // The snapshot belongs to the service we originally pinned; applying
            // it to a *different* service would smear one interface's DNS onto
            // another. For any other service, just clear the stale entry.
            let useSnapshot = pinned && service == pinnedService
            let ok = await EngineControl.applySystemDNS(useSnapshot ? target : ["Empty"], service: service)
            guard ok else {
                // Keep the signal set: a failed write must survive to the end
                // of the sweep even if a later service clears cleanly.
                logKernel("TUN DNS 残留清理写入失败：服务 \(service)（下次巡检重试）")
                continue
            }
            logKernel("TUN DNS 残留清理：服务 \(service) 上的 \(stale) 已回退（"
                      + (ownTunnel == nil ? "TUN 未开启" : "TUN 数据面不健康")
                      + "，该地址此刻必然黑洞）")
        }

        // Decided once, after the whole sweep: the throttle stays exempt only
        // if some service still carries residue, or a write failed. Folding
        // this per-service let an early success mask a later failure.
        Self.dnsRepairNeeded = residueRemains

        // The flag no longer describes reality once the sweep has run — but
        // only once it has actually *finished* the job. A failed write clears
        // nothing: dropping the recorded service would discard the one clue
        // that points at where the residue lives, and the next sweep would
        // have to rediscover it from the default interface alone (which is the
        // gap this sweep was widened to close).
        //
        // 只清 `.tun` 属主的账：sweep 处理的是 fake-ip 残留，与 `.proxy` 属主
        // （127.0.0.1）无关，清错属主会把代理模式的重定向记录抹成无主状态。
        if flagged && !Self.dnsRepairNeeded {
            TunnelDNSLedger.clear(owner: .tun)
        }
    }

    /// Deep-merge config overrides into the running config via the engine
    /// (validate + rollback). The primitive behind all settings forms.
    ///
    /// Returns whether the kernel accepted the change. Callers that record
    /// side effects (coexistence provenance, fingerprints) must gate those on
    /// the return value — a dropped PATCH must not be treated as applied.
    @discardableResult
    func patch(_ overrides: [String: Any]) async -> Bool {
        guard reachable else {
            showToast("内核未连接，无法修改配置", kind: .error)
            return false
        }

        let ok = await engine.patchConfig(overrides)
        if ok {
            await refreshConfigs()
            showToast("配置已更新", kind: .ok)
            return true
        } else {
            // Check if it just died
            await api.probe(timeout: 0.5)
            if api.reachable {
                showToast("内核拒绝了该配置修改", kind: .error)
                // Optimistic UI writers (NToggle…) already rendered the value
                // the kernel refused — resync from runtime truth so the
                // rejected value doesn't linger until some unrelated refresh.
                await refreshConfigs()
            } else {
                reachable = false
                showToast("内核已断开，配置写入失败", kind: .error)
            }
            return false
        }
    }

    /// Apply load-time-only settings that mihomo ignores on a runtime PATCH
    /// (geodata-*, unified-delay, keep-alive…): write them to config.yaml and
    /// reload — as one transaction (backup → write → `mihomo -t` → reload →
    /// rollback on any failure). See `patchPersistentTransactional` for the
    /// ordering contract.
    ///
    /// 旧实现把文件改了就直接 reload，失败只在 catch 里弹一条 toast：写坏的
    /// config.yaml 留在磁盘上，用户要等下次启动内核起不来才发现。同文件的
    /// `saveProxyProviders` 早就是“备份→校验→回滚”的完整事务 —— 同一个功能
    /// 两套实现，这一份就是漏掉保护的那半。
    ///
    /// Returns whether the disk file **and** the running kernel both took the
    /// change. Callers holding local edit state (`@State` text/items) must
    /// revert it on `false`.
    @discardableResult
    func patchPersistent(_ rawOverrides: [String: Any]) async -> Bool {
        guard reachable else { showToast("内核未连接，无法修改配置", kind: .error); return false }

        // 访问控制 and 局域网网关 write the same fields — see the reconcile.
        let (overrides, blocked, warnings) = reconcileAccessControlWithGateway(rawOverrides)
        for w in warnings { logKernel("访问控制：\(w)"); showToast(w, kind: .warn) }
        if !blocked.isEmpty {
            let what = blocked.joined(separator: "、")
            logKernel("访问控制：网关中枢运行中，拒绝写入 \(what)")
            showToast("网关中枢运行中，\(what) 不可更改；请先关闭网关", kind: .warn)
            // Put the UI back on the kernel's actual values — the row already
            // rendered the write it never got.
            await refreshConfigs()
            if overrides.isEmpty { return false }
        }

        let ok = await patchPersistentTransactional(overrides)
        // 成功提示只在这一层弹：级联调用方（切换配置、TUN 保留）各有自己的
        // 收尾文案，多弹一条只会盖掉信息量更高的那条。
        if ok { showToast("配置已更新", kind: .ok) }
        return ok
    }

    /// Transactional core behind every persistent (config.yaml) write.
    ///
    /// 顺序是硬约束，不是风格：
    /// 1. 备份当前文件 —— 读不到就**不写**，没有备份就没有回滚；
    /// 2. 写盘，并把运行中的 TUN 状态一并写回（reload 会重读文件）；
    /// 3. `mihomo -t` 校验 —— 这正是内核启动时读的那份文件，写坏了必须当场发现；
    /// 4. 需要重启内核的分支（`secret` / `external-controller` 只能在进程启动时绑定）；
    /// 5. 否则 reload + `refreshConfigs`；
    /// 6. 任何一步失败 → 还原备份、说清原因、返回 false。
    ///
    /// 失败一律在这里自己弹错误 toast（含“已回滚”字样），调用方不要叠加第二条。
    @discardableResult
    func patchPersistentTransactional(_ overrides: [String: Any]) async -> Bool {
        guard !overrides.isEmpty else { return true }
        let path = engine.configFilePath
        guard let backup = try? String(contentsOfFile: path, encoding: .utf8) else {
            // 读不到就没有回滚能力。宁可拒绝写入，也不能把一份没法还原的文件改坏。
            logKernel("持久化写入取消：无法读取 \(path) 作为回滚备份")
            showToast("无法读取当前配置，已取消修改", kind: .error)
            return false
        }

        engine.setTopLevelScalars(overrides)
        persistTunStateForReload()

        if let err = await engine.validateConfig() {
            await restoreConfigSnapshot(backup, at: path)
            // 区分“这一笔写入写坏了”和“文件本来就不合法”：两者都必须回滚，
            // 但责任方不同，用户看到的措辞必须能分辨，否则改个日志级别也会被
            // 告知“配置无效”却不知道是谁弄坏的。
            if await engine.validateConfig() != nil {
                logKernel("持久化写入回滚：config.yaml 本身校验不通过（\(err)）")
                showToast("配置本身校验不通过，已回滚：\(err)", kind: .error)
            } else {
                logKernel("持久化写入回滚：写入导致配置无效（\(err)）")
                showToast("配置无效，已回滚：\(err)", kind: .error)
            }
            await refreshConfigs()
            return false
        }

        // The control-plane secret and listen address are bound once when the
        // REST server starts. A config reload re-applies proxies/rules/DNS to
        // the already-running process but never touches its listener/auth, so
        // a changed secret here would silently never take effect — the kernel
        // keeps answering to the old one until the process itself restarts.
        if overrides.keys.contains("external-controller") || overrides.keys.contains("secret") {
            await engine.restart(preferRoot: engine.isRoot)
            _ = await waitForKernelReady(maxAttempts: 8)
            await reconnect()
            guard reachable else {
                // 内核没起来 = 这笔改动不可用。还原文件，让下一次启动至少还能用
                // 改动前的配置；这里不再自动重启重试，避免“失败即重试”的循环。
                await restoreConfigSnapshot(backup, at: path)
                logKernel("持久化写入回滚：内核重启后未响应，已还原改动前的配置")
                showToast("内核重启后未响应，已回滚原配置", kind: .error)
                return false
            }
            noteConfigContentChanged()
            return true
        }

        do {
            try await api.reloadConfig(path: path)
            await refreshConfigs()
            noteConfigContentChanged()
            return true
        } catch {
            // 内核明确拒绝了这份配置：文件已经改过，必须还原，否则下次启动
            // 内核读到的正是它刚才拒绝过的内容（用户只会看到一闪而过的 toast）。
            await restoreConfigSnapshot(backup, at: path)
            logKernel("持久化写入回滚：内核拒绝重载（\(error.localizedDescription)）")
            showToast("更新失败，已回滚：\(error.localizedDescription)", kind: .error)
            // 运行态仍是内核手里的旧配置，UI 按真值重同步，别停在乐观写入值上。
            await refreshConfigs()
            return false
        }
    }

    /// Put a backed-up config.yaml back on disk (keeping its 0600 mode) and
    /// resync the UI from runtime truth. Used by both transactional writers.
    private func restoreConfigSnapshot(_ text: String, at path: String) async {
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            // atomic write 会重建文件，权限跟着默认值走 —— config.yaml 必须
            // 保持 0600（订阅 URL 等敏感内容在别的文件里，但这条规则不能破）。
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            logKernel("配置回滚写入失败：\(error.localizedDescription)")
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
        persistTunStateForReload()    // preserve running TUN across reload
        if let err = await engine.validateConfig() {
            if let b = backup { await restoreConfigSnapshot(b, at: path) }
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
            if let b = backup { await restoreConfigSnapshot(b, at: path) }
            showToast("保存失败，已回滚：\(error.localizedDescription)", kind: .error)
            return false
        }
    }

    func stopEngine() async {
        logKernel("正在停止核心...")
        cancelTUNDataPlaneProbe(resetHealth: true)
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
        // Stopping the core is an explicit teardown of everything — no TUN enable
        // afterwards should silently resurrect Gateway.
        gatewayPendingTunRestore = false
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
            switch ok {
            case .some(true):
                staticRoutesInjected = false
                logKernel("XPC Helper 清理静态路由: 成功")
            case .some(false):
                // Helper 明确拒绝：路由可能还在。保留标记，让下一拍 refreshConfigs
                // 的清理分支（`!tunOn && staticRoutesInjected`）继续续清。
                logKernel("XPC Helper 清理静态路由: 失败（特权服务拒绝执行），保留标记待续清")
            case .none:
                // P1-4：nil 只表示“Helper 不可达”，**不等于**“没有路由要清”。
                // 旧代码在这里把标记置假，退出留下的孤儿静态路由就再也没人认领
                // （Helper 升级后出现过同类事故）。保留标记：Helper 恢复后它自身会
                // 回收孤儿路由，本进程下一拍的清理分支也会继续尝试。
                logKernel("XPC Helper 清理静态路由: 失败（特权服务不可达），保留标记待下次续清")
                if throttleAllows("routes.exitCleanup", interval: 120) {
                    showToast("退出时未能清理静态路由（特权服务不可达），已留待续清", kind: .warn)
                }
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
        if let r = try? await api.fetchRules(), rules != r.rules { rules = r.rules }
    }
}
