import Foundation

// MARK: - AppModel · Connections & Traffic
// Live traffic ticks, connection snapshots, single-pass dashboard aggregation,
// and connection / DNS cache management.

extension AppModel {
    func onTraffic(_ t: TrafficTick) {
        if t.up != live.curUp { live.curUp = t.up }
        if t.down != live.curDown { live.curDown = t.down }

        // Sparkline series only matters on the dashboard (or menu bar mini view).
        // Appending on every other route still publishes @Published arrays and
        // forces the whole EnvironmentObject tree to re-evaluate.
        guard isMenuBarVisible || (isMainWindowVisible && route == "dashboard") else { return }

        let now = Date()
        if now.timeIntervalSince(lastUIUpdate) >= trafficRefreshInterval {
            lastUIUpdate = now
            live.downSeries.append(Double(t.down))
            if live.downSeries.count > 120 { live.downSeries.removeFirst() }
            live.upSeries.append(Double(t.up))
            if live.upSeries.count > 120 { live.upSeries.removeFirst() }
        }
    }

    func recordHistoryOnly(from s: ConnectionsSnapshot) {
        if uploadTotal != s.uploadTotal { uploadTotal = s.uploadTotal }
        if downloadTotal != s.downloadTotal { downloadTotal = s.downloadTotal }
        // `s.memory` is deliberately unread now. It is mihomo's connection
        // accounting, not its footprint, and the guard that acted on it at
        // 512 MB neither fired on the way to 426 MB of real RSS nor would have
        // freed a byte had it done — the memory was in dead sockets, not in the
        // caches it flushed. Kernel memory is now sampled as RSS
        // (`sampleKernelMemory`) and reclaimed by closing the sockets that
        // hold it (`reapStaleConnections`).
        sampleKernelMemory()

        enforceAppMemoryGuard()

        let items = s.connections ?? []
        let hour = Calendar.current.component(.hour, from: Date())

        // Memory Optimization: Skip expensive single-connection diffing and classification
        // unless the user is actually looking at the dashboard or connections page.
        // history.record() calls within this loop are the main culprit for background CPU/memory churn.
        let needDetailedStats = isMainWindowVisible || isMenuBarVisible

        // Everything below allocates per connection — the byte dictionary, the id
        // set, and `computeDashRaw`'s five scratch dictionaries. Without an
        // explicit pool those temporaries sit in the main run loop's autorelease
        // pool until the next `await`, so at a 3 s cadence several ticks' worth of
        // garbage stays live at once. Draining per tick is what keeps the
        // footprint flat instead of sawtoothing upward.
        // Drained after the pool closes (route forensics forks `route -n
        // get`) — at most one trip per snapshot tick, see `handleTUNLoopTrip`.
        var loopTrip: TUNLoopTrip?
        let watchNow = Date()
        autoreleasepool {
        // Silence tracking runs ahead of the visibility branch on purpose: the
        // background branch is exactly where a closed lid accumulates corpses,
        // so a foreground-only feed would have been blind to the whole failure
        // mode — the same one-path bug `enforceAppMemoryGuard` documents below.
        var liveIDs = Set<String>(minimumCapacity: items.count)
        for c in items {
            liveIDs.insert(c.id)
            staleConnWatch.observe(id: c.id, bytes: c.upload + c.download,
                                   tcp: c.metadata.network == "tcp", now: watchNow)
        }
        staleConnWatch.reap(excluding: liveIDs)

        if needDetailedStats {
            var bytes: [String: (up: Int64, down: Int64)] = [:]
            bytes.reserveCapacity(items.count)
            var activeIDs = Set<String>(minimumCapacity: items.count)
            // Sum the tick locally and hand `history` a single write — see
            // `TrafficHistory.recordBatch` for why per-connection calls were
            // expensive out of all proportion to the three numbers they carry.
            var tickDirect = 0.0, tickProxy = 0.0, tickReject = 0.0, tickDown = 0.0

            for c in items {
                activeIDs.insert(c.id)
                if !activeConnsSet.contains(c.id) { totalConnsCount += 1 }
                let prev = prevConnBytes[c.id]
                let upRate = prev.map { max(0, c.upload - $0.up) } ?? 0
                let downRate = prev.map { max(0, c.download - $0.down) } ?? 0
                bytes[c.id] = (c.upload, c.download)

                // TUN self-loop sentinel. Cheap pre-gate first (only rows that
                // added ≥ one chunk of downlink touch the watch dictionary at
                // all); the sentinel re-checks the full fingerprint internally.
                // See `TUNLoopSentinel` for why this shape is impossible in
                // real traffic.
                if loopTrip == nil, downRate >= tunLoopSentinel.minTickDownBytes {
                    loopTrip = tunLoopSentinel.observe(
                        id: c.id, chains: c.chains,
                        host: c.metadata.host ?? "", destinationIP: c.metadata.destinationIP ?? "",
                        tickDownBytes: downRate, totalUploadBytes: c.upload)
                }

                // attribute this connection's byte delta to its category → history
                let delta = Double(upRate + downRate)
                if delta > 0 {
                    if c.chains.first == "DIRECT" || c.chains.contains("DIRECT") {
                        tickDirect += delta
                    } else if c.chains.first == "REJECT" || c.chains.contains("REJECT") {
                        tickReject += delta
                    } else {
                        tickProxy += delta
                    }
                    tickDown += Double(downRate)
                }
            }
            history.recordBatch(direct: tickDirect, proxy: tickProxy, reject: tickReject,
                                down: tickDown, hour: hour)

            // Must run before prevConnBytes is overwritten so per-tick rates stay correct.
            if gatewayModeOn {
                updateGatewayDevices(from: items)
            }

            prevConnBytes = bytes

            // Limit prevConnBytes growth: cap at 2000 entries by keeping only the
            // active connection IDs (which are already in `bytes`).
            if prevConnBytes.count > 2000 {
                let trimmed = prevConnBytes.prefix(2000)
                prevConnBytes = Dictionary(trimmed.map { ($0.key, $0.value) },
                                          uniquingKeysWith: { a, _ in a })
                logKernel("连接追踪字典过大，已裁剪至 2000 条")
            }

            activeConnsSet = activeIDs
            // Watches for connections that vanished from the snapshot must go
            // too — a loop that dies between ticks has nothing left to watch.
            tunLoopSentinel.reap(excluding: activeIDs)
            // Equal-value @Published writes still publish and invalidate the
            // whole view tree every snapshot tick; gate the hot counters.
            if activeConnectionsCount != activeIDs.count {
                activeConnectionsCount = activeIDs.count
            }

            if route == "dashboard" || route == "connections" {
                let next = Self.computeDashRaw(items)
                if next != dash { dash = next }
            }
        } else {
            // Background idle: only sync basic count + gateway devices (cheap).
            // Gateway aggregation stays on so the Network page isn't empty after
            // the window was backgrounded and reopened.
            if activeConnectionsCount != items.count {
                activeConnectionsCount = items.count
            }
            if gatewayModeOn {
                updateGatewayDevices(from: items)
                // Keep prevConnBytes for the next rate delta; only drop the
                // heavy active-set bookkeeping while UI is hidden.
                var bytes: [String: (up: Int64, down: Int64)] = [:]
                bytes.reserveCapacity(items.count)
                for c in items { bytes[c.id] = (c.upload, c.download) }
                prevConnBytes = bytes
            } else {
                if !prevConnBytes.isEmpty { prevConnBytes.removeAll(keepingCapacity: false) }
            }
            if !activeConnsSet.isEmpty { activeConnsSet.removeAll(keepingCapacity: false) }
        }
        }

        let closed = max(0, totalConnsCount - activeConnectionsCount)
        if closedConns != closed { closedConns = closed }
        history.flushIfNeeded()
        lastDownTotal = s.downloadTotal
        // Outside the autoreleasepool: route forensics forks `/sbin/route`.
        // The handler is self-guarded (`tunLoopTripInFlight`) and at most one
        // trip can be in flight, so this hop cannot stack up.
        if let trip = loopTrip {
            Task { @MainActor in await self.handleTUNLoopTrip(trip) }
        }
        // Opportunistic, and rate-limited inside: a wake or an offline→online
        // flip arms the watch, and the corpses that exposes should go back to
        // the kernel without first waiting for RSS to cross the guard's tier.
        reapStaleConnections(now: watchNow)
        // App memory is sampled by its own timer (`startAppMemorySampling()`),
        // not here: tying it to a connections snapshot meant it only refreshed
        // on pages that request detailed stats, leaving the dashboard stale.
        // Kernel memory deliberately *is* sampled here (top of this function):
        // the app timer that carries the app reading stops when no UI is on
        // screen, and the kernel's growth happens behind a closed lid — exactly
        // the hours that timer never runs. The snapshot loop is the only thing
        // that keeps ticking through them.
    }

    // MARK: - App memory guard

    /// Thresholds and tiering live in `AppMemoryGuardPolicy` so they can be
    /// tested without a kernel or a window — see `Tests/AppMemoryGuard`.
    static let appMemoryGuardPolicy = AppMemoryGuardPolicy()

    /// Trim local connection caches when this process' memory footprint gets high.
    ///
    /// Called from **every** snapshot consumer — `recordHistoryOnly`, the
    /// Connections page view model, and the foreground poll loop. It previously
    /// lived only inside `recordHistoryOnly`, which the Connections page (the
    /// most allocation-heavy path in the app, polling at 1.5 s) bypasses
    /// entirely; that page read the footprint purely to display it and never
    /// acted on it.
    ///
    /// Two tiers, because a blanket `removeAll` while the user is looking at the
    /// connections table blanks the table for a tick:
    ///
    ///  * **soft** — shed the closed-connection history and truncate the live
    ///    rows to a small working set. The table stays populated.
    ///  * **hard**, or UI not visible — release everything, including the
    ///    diffing bookkeeping, since nothing on screen can go blank.
    ///
    /// Rate-limited internally, so hot callers can invoke it every tick, and
    /// **self-suspending**: if the caches it can shed are not where the memory
    /// actually is, repeating the same work every 15 s forever helps nobody, so
    /// the policy gives up after a few ineffective attempts and only re-arms on
    /// genuine new growth. Logging follows transitions, not actions — a 2-hour
    /// capture of the previous build produced 463 identical lines.
    @discardableResult
    func enforceAppMemoryGuard() -> Bool {
        // Startup grace window: the launch burst transiently crosses the soft
        // tier and decays on its own — trimming during it is futile work and
        // noise (observed 383 MB at +15 s → 197 MB steady).
        if Date().timeIntervalSince(launchedAt) < 30 { return false }
        let now = Date()
        let rss = Self.residentMemoryBytes()
        let decision = Self.appMemoryGuardPolicy.decide(
            rss: rss,
            uiVisible: isMainWindowVisible || isMenuBarVisible,
            now: now,
            state: &appMemoryGuardState
        )

        let mb = rss / 1_000_000
        switch decision.transition {
        case .none:
            break
        case .engaged:
            logKernel("App 内存偏高 (RSS \(mb)MB)，开始缩减连接缓存")
        case let .suspended(afterActions):
            logKernel("App 内存缩减无效：连续 \(afterActions) 次清理后 RSS 仍为 \(mb)MB，已暂停自动缩减（不再清空缓存）."
                + " 占用再增长 \(Self.appMemoryGuardPolicy.reArmGrowth / 1_000_000)MB 时会自动恢复缩减。")
        case .reArmed:
            logKernel("App 内存较暂停时显著增长 (RSS \(mb)MB)，恢复缩减连接缓存")
        case .recovered:
            logKernel("App RSS 已回落至 \(mb)MB，恢复正常")
        }

        switch decision.action {
        case .skip:
            return false

        case let .hard(includingBookkeeping):
            cachedConns.removeAll(keepingCapacity: false)
            cachedClosedConnections.removeAll(keepingCapacity: false)
            if includingBookkeeping {
                prevConnBytes.removeAll(keepingCapacity: false)
                activeConnsSet.removeAll(keepingCapacity: false)
            }
            return true

        case let .soft(keepRows):
            // `cachedConns` is already sorted by rate by its producer, so a
            // prefix keeps the busiest slice — which is what the user is looking
            // at — and drops the idle tail.
            cachedClosedConnections.removeAll(keepingCapacity: false)
            if cachedConns.count > keepRows {
                cachedConns = Array(cachedConns.prefix(keepRows))
            }
            return true
        }
    }

    // MARK: - Kernel memory guard

    /// Thresholds and tiering live in `KernelMemoryGuardPolicy` so they can be
    /// exercised without a kernel or a connection stream — see
    /// `Tests/KernelMemoryGuard`.
    static let kernelMemoryGuardPolicy = KernelMemoryGuardPolicy()

    /// Minimum spacing between two reap rounds that nobody forced.
    static let staleReapInterval: TimeInterval = 600
    /// Ceiling on connections closed per round. The 2026-09-28 capture had 1039
    /// candidates; a round that wide would be a visible cliff on the connections
    /// page, and there is no reason to take the whole stack at once.
    static let staleReapMaxPerRun = 400
    /// Per-id `DELETE`s before the round pauses, so a mass reclaim cannot look
    /// like a request storm to the kernel's own API server.
    static let staleReapBatch = 50

    /// Act on the kernel's **resident size**.
    ///
    /// Replaces the guard that read mihomo's connection accounting at a 512 MB
    /// threshold and flushed caches. Both halves were inert against the failure
    /// it was meant to prevent: the accounting is not a footprint (it sat frozen
    /// at 363 MB while `ps` measured 148 MB), and the bytes were in dead sockets,
    /// which no cache flush touches.
    ///
    /// Tier one closes stale connections, which is the only action that reaches
    /// those bytes. Tier two adds the cache flush — kept because it is what the
    /// old guard did, and fake-ip/DNS tables do grow over weeks. There is no
    /// tier three: an automatic kernel restart is the reliable fix and the one
    /// thing the user would feel, so when both tiers fail the guard suspends and
    /// says so instead of looping.
    func enforceKernelMemoryGuard(rss: UInt64, now: Date) {
        let decision = Self.kernelMemoryGuardPolicy.decide(rss: rss, now: now,
                                                           state: &kernelGuardState)
        let mb = rss / 1_000_000

        switch decision.transition {
        case .none:
            break
        case .engaged:
            logKernel("内核内存偏高 (RSS \(mb)MB)，开始回收静默连接")
        case let .suspended(afterActions):
            logKernel("内核内存回收无效：连续 \(afterActions) 次处置后 RSS 仍为 \(mb)MB，已暂停自动回收。"
                + " 内存可能不在可回收的连接上；如需彻底释放，请在「网络」页重启内核。")
        case .reArmed:
            logKernel("内核内存较暂停时显著增长 (RSS \(mb)MB)，恢复回收")
        case .recovered:
            logKernel("内核 RSS 已回落至 \(mb)MB，恢复正常")
        }

        switch decision.action {
        case .skip:
            return
        case .reap:
            reapStaleConnections(now: now, force: true)
        case .reapAndFlush:
            reapStaleConnections(now: now, force: true)
            guard now.timeIntervalSince(lastCacheFlush) > 1800 else { return }
            lastCacheFlush = now
            clearAllCache()
            logKernel("内核 RSS \(mb)MB 超阈，已清空 DNS 与 Fake‑IP 缓存")
        }
    }

    /// Close the connections `StaleConnectionWatch` has condemned.
    ///
    /// Selective by construction: `DELETE /connections` (close everything) is
    /// one line shorter and would also drop every live session the user is
    /// relying on — an idle-but-alive SSH shell, a resuming download, an IM push
    /// socket. Only per-id closes, and only ids the watch proved silent.
    ///
    /// `forget`s the ids before dispatching so a snapshot that still lists them
    /// cannot propose the same batch twice while the closes are in flight.
    func reapStaleConnections(now: Date, force: Bool = false) {
        guard !kernelReapInFlight else { return }
        guard force || now.timeIntervalSince(lastStaleReap) >= Self.staleReapInterval
        else { return }
        let doomed = staleConnWatch.candidates(now: now)
        guard !doomed.isEmpty else { return }
        lastStaleReap = now

        let batch = Array(doomed.prefix(Self.staleReapMaxPerRun))
        staleConnWatch.forget(batch)
        kernelReapInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.kernelReapInFlight = false }
            var sent = 0
            var index = batch.startIndex
            while index < batch.endIndex {
                let end = Swift.min(index + Self.staleReapBatch, batch.endIndex)
                for id in batch[index..<end] {
                    // 计数口径只能到「请求成功送达」：实测 mihomo 对一个不存在
                    // 的 id 也回 204，所以 2xx 不能证明真关掉了什么。真正消失
                    // 与否交给下一拍的 `reap(excluding:)` 收敛，这里不虚报。
                    if (try? await self.api.closeConnection(id: id)) != nil { sent += 1 }
                }
                index = end
                if index < batch.endIndex {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            let remaining = doomed.count - batch.count
            logKernel("已对 \(sent)/\(batch.count) 条静默连接发出关闭（候选 \(doomed.count)\(remaining > 0 ? "，本轮上限 \(Self.staleReapMaxPerRun)，剩余 \(remaining) 条下轮处理" : "")）")
        }
    }

    /// Clamp `cachedConns` / `cachedClosedConnections` to their ceilings.
    ///
    /// `Array(_:prefix:)` allocates a right-sized buffer, which also lets go of
    /// capacity over-provisioned during a connection spike — assigning a
    /// 5000-element array and later a 200-element one otherwise keeps the 5000
    /// slots alive for the lifetime of the process.
    func clampConnectionCaches() {
        if cachedConns.count > Self.maxCachedConns {
            cachedConns = Array(cachedConns.prefix(Self.maxCachedConns))
        }
        if cachedClosedConnections.count > Self.maxClosedConns {
            cachedClosedConnections = Array(cachedClosedConnections.prefix(Self.maxClosedConns))
        }
    }

    /// Aggregate LAN gateway clients from a connections snapshot.
    ///
    /// Filters out loopback / this host's own IPs, and also the TUN fake-ip
    /// address range (198.18.0.0/15) which mihomo reports as sourceIP for
    /// local processes under fake-ip mode.
    ///
    /// Two things this deliberately does *not* do any more, because both made
    /// the numbers disagree badly with the kernel's own:
    ///
    ///  * **Totals are not accumulated from per-tick deltas.** A delta needs a
    ///    previous sample, so the first tick of every connection contributed
    ///    zero — and most LAN traffic is short-lived connections that are born
    ///    and die between two polls, so the bulk of their bytes was never
    ///    counted at all. Bytes of connections that closed were dropped outright
    ///    for the same reason. Totals are now `Σ live connection bytes` (an
    ///    absolute figure straight from mihomo) plus a per-device accumulator
    ///    for connections that have since closed — continuous across a close,
    ///    because the bytes move from one term to the other rather than
    ///    vanishing.
    ///  * **Rates are not raw byte deltas.** They were displayed as B/s while
    ///    actually being "bytes since the previous poll", and the poll interval
    ///    is 1.5 s on the Connections page, 3 s elsewhere and 30 s in the
    ///    background — so the same traffic read 2×, 3× or 20× high depending on
    ///    which page happened to be open. Divided by measured elapsed time now.
    func updateGatewayDevices(from items: [ConnectionItem]) {
        let nowTime = Date()

        // Any of the several `gatewayDevices.removeAll()` sites (profile switch,
        // gateway off, kernel restart, memory guard) must also reset the byte
        // bookkeeping, or a device that comes back gets the old accumulator
        // added on top of its fresh live bytes. One check covers all of them.
        if gatewayDevices.isEmpty && !gatewayConnBytes.isEmpty {
            gatewayConnBytes.removeAll(keepingCapacity: false)
            gatewayClosedBytes.removeAll(keepingCapacity: false)
        }

        let elapsed = max(0.2, nowTime.timeIntervalSince(lastGatewaySampleAt))
        // A first sample has no interval to divide by; report totals, no rate.
        let hasBaseline = lastGatewaySampleAt != .distantPast
        lastGatewaySampleAt = nowTime

        let localIPs = Set(NetScanner.interfaces().flatMap { $0.ipv4 })
        var liveUp = [String: Int64](), liveDown = [String: Int64]()
        var liveConns = [String: Int]()
        var seenIDs = Set<String>()

        for c in items {
            let srcIP = c.metadata.sourceIP ?? ""
            guard !srcIP.isEmpty,
                  srcIP != "127.0.0.1",
                  srcIP != "::1",
                  !localIPs.contains(srcIP),
                  !Self.isFakeIP(srcIP) else { continue }
            seenIDs.insert(c.id)
            liveUp[srcIP, default: 0] += c.upload
            liveDown[srcIP, default: 0] += c.download
            liveConns[srcIP, default: 0] += 1
            gatewayConnBytes[c.id] = (srcIP, c.upload, c.download)
        }

        // Retire connections that were live last tick and are gone now, keeping
        // their final byte counts on the device they belonged to.
        for (id, rec) in gatewayConnBytes where !seenIDs.contains(id) {
            var acc = gatewayClosedBytes[rec.ip] ?? (0, 0)
            acc.up += rec.up
            acc.down += rec.down
            gatewayClosedBytes[rec.ip] = acc
            gatewayConnBytes.removeValue(forKey: id)
        }

        var newGatewayDevices = gatewayDevices
        for ip in Set(newGatewayDevices.keys).union(liveUp.keys) {
            let closed = gatewayClosedBytes[ip] ?? (up: Int64(0), down: Int64(0))
            let totalUp = closed.up + (liveUp[ip] ?? 0)
            let totalDown = closed.down + (liveDown[ip] ?? 0)
            let conns = liveConns[ip] ?? 0

            var dev = newGatewayDevices[ip] ?? GatewayDevice(
                ip: ip,
                activeConnections: 0,
                uploadRate: 0,
                downloadRate: 0,
                totalUpload: totalUp,
                totalDownload: totalDown,
                firstSeen: nowTime,
                lastSeen: nowTime
            )
            // `max(0, …)` is belt-and-braces: both terms are monotonic, so a
            // negative delta would mean the kernel reset its counters.
            let dUp = max(0, totalUp - dev.totalUpload)
            let dDown = max(0, totalDown - dev.totalDownload)
            dev.activeConnections = conns
            dev.uploadRate = hasBaseline ? Int64(Double(dUp) / elapsed) : 0
            dev.downloadRate = hasBaseline ? Int64(Double(dDown) / elapsed) : 0
            dev.totalUpload = totalUp
            dev.totalDownload = totalDown
            if conns > 0 { dev.lastSeen = nowTime }
            newGatewayDevices[ip] = dev
        }

        // Drop devices that have been idle for >10 minutes, and let go of their
        // accumulator at the same time so the two never drift apart.
        for (ip, dev) in newGatewayDevices
        where dev.activeConnections == 0 && nowTime.timeIntervalSince(dev.lastSeen) >= 600 {
            newGatewayDevices.removeValue(forKey: ip)
            gatewayClosedBytes.removeValue(forKey: ip)
        }
        if newGatewayDevices != gatewayDevices {
            gatewayDevices = newGatewayDevices
        }
    }

    /// mihomo fake-ip pool is 198.18.0.0/15 by default.
    private static func isFakeIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]) else { return false }
        return a == 198 && (b == 18 || b == 19)
    }

    /// Single-pass dashboard aggregation (runs once per connections snapshot,
    /// not per SwiftUI render — the key fix for dashboard stutter).
    static func computeDashRaw(_ conns: [ConnectionItem]) -> DashStats {
        var pg = [String: Double](), hosts = [String: Double](), nodes = [String: Double]()
        var procs = [String: Double](), rules = [String: Double]()
        var direct = 0.0, proxy = 0.0, reject = 0.0
        var hostSet = Set<String>()
        for c in conns {
            let b = Double(c.upload + c.download)
            let group = c.chains.last ?? "?"
            let host = c.metadata.host?.isEmpty == false ? c.metadata.host! : (c.metadata.destinationIP ?? "?")
            let node = c.chains.first ?? "?"
            let process = c.metadata.process ?? "—"
            let ruleType = c.rule
            
            if group != "?" && !group.isEmpty { pg[group, default: 0] += b }
            if host != "?" { hosts[host, default: 0] += b; hostSet.insert(host) }
            if node != "?" { nodes[node, default: 0] += b }
            if process != "—" { procs[process, default: 0] += b }
            rules[ruleType, default: 0] += 1
            
            let category: String
            if node == "DIRECT" || c.chains.contains("DIRECT") { category = "direct" }
            else if node == "REJECT" || c.chains.contains("REJECT") { category = "reject" }
            else { category = "proxy" }
            
            switch category { case "direct": direct += b; case "reject": reject += b; default: proxy += b }
        }
        func top(_ m: [String: Double]) -> [Rank] {
            m.sorted { $0.value > $1.value }.prefix(5).map { Rank(name: $0.key, value: $0.value) }
        }
        var d = DashStats()
        d.policyGroups = top(pg); d.hosts = top(hosts); d.nodes = top(nodes)
        d.procs = top(procs); d.rules = top(rules)
        d.directBytes = direct; d.proxyBytes = proxy; d.rejectBytes = reject
        d.uniqueHosts = hostSet.count
        return d
    }

    /// This process' **resident set size** (RSS) in bytes, via Mach
    /// `mach_task_basic_info.resident_size` — the same number `ps -o rss`
    /// reports.
    ///
    /// This was previously `task_vm_info.phys_footprint`, which also counts
    /// compressed memory and runs ~170–200 MB above RSS on this process. That
    /// mismatch made the v1.1.16 memory guard spin: the threshold (250 MB) was
    /// calibrated against RSS ("healthy idle 80–150 MB") but compared against
    /// `phys_footprint` (which read 309–317 MB at idle), so the guard fired
    /// every 15 s for 2 hours without ever bringing the number down — 463
    /// actions in one field capture, none of them effective, because the bulk
    /// of `phys_footprint` is compressed pages the guard cannot shed.
    ///
    /// Switching to RSS means the number the guard sees and the number the
    /// user sees in Activity Monitor are the same — and both reflect memory
    /// the guard's cache-trimming can actually affect.
    /// Uses `MACH_TASK_BASIC_INFO` rather than the older `TASK_BASIC_INFO`:
    /// the legacy flavour predates 64-bit and Apple documents the `mach_`
    /// variant as its replacement. Both report identical values here, so this
    /// costs nothing and removes a future-SDK hazard.
    ///
    /// Returning 0 on failure is deliberate and safe: `AppMemoryGuardPolicy`
    /// treats anything at or below `softLimit` as healthy, so a failed read
    /// makes the guard do nothing rather than wrongly wipe the caches the user
    /// is looking at.
    static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    func closeAllConnections() {
        Task {
            do { try await api.closeAllConnections(); showToast("已断开所有连接", kind: .ok) }
            catch { showToast("断开连接失败", kind: .error) }
        }
    }

    func closeConnection(id: String) {
        Task {
            try? await api.closeConnection(id: id)
        }
    }

    /// Close every *active* connection whose host (or dstIP when host is empty)
    /// equals `host`. mihomo has no per-host close endpoint, so we enumerate
    /// the cached active set and fire DELETE per id.
    func closeConnections(host: String) {
        let ids = cachedConns.filter { ($0.host.isEmpty ? $0.dstIP : $0.host) == host }.map { $0.id }
        guard !ids.isEmpty else { return }
        Task {
            for id in ids { try? await api.closeConnection(id: id) }
            showToast("已断开 \(ids.count) 条 \(host)", kind: .ok)
        }
    }

    func flushDnsCache() {
        Task {
            do { try await api.flushDnsCache(); showToast("DNS 缓存已刷新", kind: .ok) }
            catch { showToast("刷新 DNS 缓存失败", kind: .error) }
        }
    }

    func clearAllCache() {
        Task {
            do {
                try await api.flushDnsCache()
                try await api.flushFakeIpCache()
                showToast("DNS 及 Fake‑IP 缓存已清空", kind: .ok)
            } catch {
                showToast("清空缓存失败", kind: .error)
            }
        }
    }
}
