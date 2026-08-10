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
                    persistTunStateForReload()
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
        if await engine.setSystemProxy(enabled: true, port: restorePort) {
            systemProxyOn = true
            logKernel("\(reason)：已恢复系统代理 (port \(restorePort))")
        } else {
            syncSystemProxyState()
            logKernel("\(reason)：系统代理恢复失败")
            showToast("系统代理恢复失败，请重新开启", kind: .error)
        }
        return result
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
                    "listen": preGatewayDNSListen ?? "127.0.0.1:1053",
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
    /// (`liveTunBlock`), never from a literal, and only truly kernel-derived
    /// values (`file-descriptor`, `inet4-address`, `gso-max-size`, `recvmsgx`)
    /// are left out — echoing those back is not ours to do.
    func tunPatchBody(enable: Bool, extra: [String: Any] = [:]) -> [String: Any] {
        let live = liveTunBlock()
        var body: [String: Any] = [
            "enable": enable,
            "stack": live["stack"] ?? "gvisor",
            "auto-route": live["auto-route"] ?? true,
            "auto-detect-interface": live["auto-detect-interface"] ?? true
        ]
        // Restate the user-owned fields that would otherwise be dropped by the
        // replace semantics. Only when actually present — inventing a key the
        // config never had would be its own kind of surprise.
        for key in ["dns-hijack", "route-exclude-address", "mtu", "strict-route",
                    "endpoint-independent-nat", "include-package", "exclude-package"] {
            if let v = live[key] { body[key] = v }
        }
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

    /// Persist the *current* runtime TUN state (enable + pinned device) so a
    /// config reload or kernel restart that re-reads `config.yaml` brings back
    /// the same tunnel, on the same interface name.
    ///
    /// Call this before every `reloadConfig` / `restart`. See
    /// `EngineControl.persistTunState` for why writing only `tun.enable` is a
    /// network-outage bug rather than a partial fix.
    func persistTunStateForReload() {
        engine.persistTunState(enabled: tunOn, device: pinnedTunDevice)
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
        let excludeRoutes = Coexistence.excludeRouteMap(peers)
        if !excludeRoutes.isEmpty {
            let routesOK = await XPCManager.shared.callSetupExcludeRoutes(excludeRoutes)
            logKernel("TUN 共存：静态路由同步 \(routesOK == true ? "成功" : "失败")（\(excludeRoutes.count) 条）")
            staticRoutesInjected = routesOK == true
        } else {
            _ = await XPCManager.shared.callCleanupAllExcludeRoutes()
            staticRoutesInjected = false
        }
        lastCoexistenceFingerprint = fp
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
            await restoreTunnelDNS()
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
                            "listen": preGatewayDNSListen ?? "127.0.0.1:1053",
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
        if resetHealth { tunDataPlaneHealth.reset() }
    }

    /// Schedule a debounced data-plane probe. Multiple triggers within the
    /// settle/cooldown windows collapse onto one Task. Never restarts the
    /// kernel by itself — only a failed probe cycle may escalate to recovery.
    func scheduleTUNDataPlaneProbe(reason: String, delay: TimeInterval = 0) {
        guard tunOn, reachable, !sleeping else { return }
        guard !tunDataPlaneRecoveryInFlight else { return }
        guard !engine.isBusy, !tunAutoTeardownInFlight else { return }
        guard Date() >= tunStateSettleUntil else { return }
        guard Date() >= tunDataPlaneRecoveryCooldownUntil else { return }

        // Coalesce concurrent schedules onto one Task so a path-update storm
        // cannot spawn three parallel probe cycles that all race into recovery.
        tunDataPlaneProbeTask?.cancel()
        tunDataPlaneProbeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self.runTUNDataPlaneProbe(reason: reason)
        }
    }

    /// One probe cycle. On threshold failure, escalates to at most one recovery.
    private func runTUNDataPlaneProbe(reason: String) async {
        guard tunOn, reachable, !sleeping else { return }
        guard !tunDataPlaneRecoveryInFlight else { return }
        guard !engine.isBusy, !tunAutoTeardownInFlight else { return }
        guard Date() >= tunStateSettleUntil else { return }
        guard Date() >= tunDataPlaneRecoveryCooldownUntil else { return }

        // The interface must still exist — if it is gone, the existing B10 /
        // verifyTUNConfig teardown path owns the response. Probing a missing
        // gateway would only produce false "data plane dead" noise.
        guard await NetScanner.mihomoTunInterface(maxAge: 0) != nil else { return }

        let gateway = tunnelDNSAddress()
        logKernel("TUN 数据面探测开始（\(reason)）→ \(gateway):53")
        let outcomes = await engine.runTUNDataPlaneProbeCycle(gateway: gateway)
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
        guard !tunDataPlaneRecoveryInFlight else { return }
        tunDataPlaneRecoveryInFlight = true
        engine.isBusy = true
        let t0 = Date()
        defer {
            engine.isBusy = false
            tunDataPlaneRecoveryInFlight = false
            // Cool-down so a recovery-induced path storm cannot immediately
            // re-enter. Also covers the failure path where we closed TUN.
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
        var accepted = false
        for attempt in 1...3 {
            if await engine.probeTUNDataPlane(gateway: gateway, timeout: 0.8) {
                accepted = true
                break
            }
            logKernel("TUN 自愈验收失败 \(attempt)/3: DNS gateway \(gateway) 无响应")
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
            } else {
                reachable = false
                showToast("内核已断开，配置写入失败", kind: .error)
            }
            return false
        }
    }

    /// Apply load-time-only settings that mihomo ignores on a runtime PATCH
    /// (geodata-*, unified-delay, keep-alive…): write them to config.yaml and
    /// reload. The current runtime TUN state is written back first so the reload
    /// (which re-reads the file) doesn't drop a running root TUN.
    func patchPersistent(_ rawOverrides: [String: Any]) async {
        guard reachable else { showToast("内核未连接，无法修改配置", kind: .error); return }

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
            if overrides.isEmpty { return }
        }

        engine.setTopLevelScalars(overrides)
        persistTunStateForReload()

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
        persistTunStateForReload()    // preserve running TUN across reload
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
