import Foundation

// MARK: - AppModel · Connections & Traffic
// Live traffic ticks, connection snapshots, single-pass dashboard aggregation,
// and connection / DNS cache management.

extension AppModel {
    func onTraffic(_ t: TrafficTick) {
        if t.up != curUp { curUp = t.up }
        if t.down != curDown { curDown = t.down }
        
        let now = Date()
        if now.timeIntervalSince(lastUIUpdate) >= trafficRefreshInterval {
            lastUIUpdate = now
            downSeries.append(Double(t.down))
            if downSeries.count > 120 { downSeries.removeFirst() }
            upSeries.append(Double(t.up))
            if upSeries.count > 120 { upSeries.removeFirst() }
        }
    }

    func recordHistoryOnly(from s: ConnectionsSnapshot) {
        uploadTotal = s.uploadTotal; downloadTotal = s.downloadTotal
        if let m = s.memory, m > 0 {
            memory = m
            // Core Memory Guard: If core usage > 512MB, flush caches (max once per 30 mins)
            if m > 512 * 1024 * 1024 && Date().timeIntervalSince(lastCacheFlush) > 1800 {
                lastCacheFlush = Date()
                clearAllCache()
                logKernel("核心内存占用过高 (\(m / 1_000_000)MB)，已自动清空 DNS 与 Fake‑IP 缓存")
            }
        }

        // App Memory Guard: If app RSS > 400MB, aggressively free local caches
        let appRSS = Self.residentMemoryBytes()
        if appRSS > 400 * 1_000_000 {
            cachedConns.removeAll(keepingCapacity: false)
            cachedClosedConnections.removeAll(keepingCapacity: false)
            if !isMainWindowVisible && !isMenuBarVisible {
                prevConnBytes.removeAll(keepingCapacity: false)
                activeConnsSet.removeAll(keepingCapacity: false)
            }
            logKernel("App 内存占用过高 (\(appRSS / 1_000_000)MB)，已释放缓存")
        }

        let items = s.connections ?? []
        let hour = Calendar.current.component(.hour, from: Date())

        // Memory Optimization: Skip expensive single-connection diffing and classification
        // unless the user is actually looking at the dashboard or connections page.
        // history.record() calls within this loop are the main culprit for background CPU/memory churn.
        let needDetailedStats = isMainWindowVisible || isMenuBarVisible
        
        if needDetailedStats {
            var bytes: [String: (up: Int64, down: Int64)] = [:]
            var activeIDs = Set<String>()
            var newGatewayDevices = gatewayDevices
            for ip in newGatewayDevices.keys {
                newGatewayDevices[ip]?.activeConnections = 0
                newGatewayDevices[ip]?.uploadRate = 0
                newGatewayDevices[ip]?.downloadRate = 0
            }
            
            let nowTime = Date()
            for c in items {
                activeIDs.insert(c.id)
                if !activeConnsSet.contains(c.id) { totalConnsCount += 1 }
                let prev = prevConnBytes[c.id]
                let upRate = prev.map { max(0, c.upload - $0.up) } ?? 0
                let downRate = prev.map { max(0, c.download - $0.down) } ?? 0
                bytes[c.id] = (c.upload, c.download)
                
                // attribute this connection's byte delta to its category → history
                let cat = (c.chains.first == "DIRECT" || c.chains.contains("DIRECT")) ? "direct"
                        : (c.chains.first == "REJECT" || c.chains.contains("REJECT")) ? "reject" : "proxy"
                history.record(category: cat, down: Int64(downRate), up: Int64(upRate), hour: hour)
                
                // Track LAN Gateway devices
                let proc = c.metadata.process ?? "—"
                let srcIP = c.metadata.sourceIP ?? ""
                if (proc == "—" || proc.isEmpty) && srcIP != "127.0.0.1" && srcIP != "::1" && !srcIP.isEmpty {
                    var dev = newGatewayDevices[srcIP] ?? GatewayDevice(ip: srcIP, activeConnections: 0, uploadRate: 0, downloadRate: 0, totalUpload: 0, totalDownload: 0, firstSeen: nowTime, lastSeen: nowTime)
                    dev.activeConnections += 1
                    dev.uploadRate += Int64(upRate)
                    dev.downloadRate += Int64(downRate)
                    dev.totalUpload += Int64(upRate)
                    dev.totalDownload += Int64(downRate)
                    dev.lastSeen = nowTime
                    newGatewayDevices[srcIP] = dev
                }
            }
            prevConnBytes = bytes

            // Limit prevConnBytes growth: cap at 2000 entries by keeping only the
            // active connection IDs (which are already in `bytes`).
            if prevConnBytes.count > 2000 {
                prevConnBytes = Dictionary(uniqueKeysWithValues: prevConnBytes.prefix(2000))
                logKernel("连接追踪字典过大，已裁剪至 2000 条")
            }

            // Clean up old inactive devices (>10 mins)
            newGatewayDevices = newGatewayDevices.filter { $0.value.activeConnections > 0 || nowTime.timeIntervalSince($0.value.lastSeen) < 600 }
            gatewayDevices = newGatewayDevices
            
            
            activeConnsSet = activeIDs
            activeConnectionsCount = activeIDs.count
            
            if route == "dashboard" || route == "connections" {
                dash = Self.computeDashRaw(items)
            }
        } else {
            // Background idle: Only sync basic count
            activeConnectionsCount = items.count
            // Clear maps to free up heap space immediately when going background
            if !prevConnBytes.isEmpty { prevConnBytes.removeAll(keepingCapacity: false) }
            if !activeConnsSet.isEmpty { activeConnsSet.removeAll(keepingCapacity: false) }
        }
        
        closedConns = max(0, totalConnsCount - activeConnectionsCount)
        history.flushIfNeeded()
        lastDownTotal = s.downloadTotal
        // 仅在窗口可见时更新内存显示（避免后台轮询触发 task_info 系统调用）
        if needDetailedStats {
            appMemoryMB = Double(Self.residentMemoryBytes()) / 1_000_000
        }
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

    /// Resident set size of this process (bytes) via mach task_info.
    static func residentMemoryBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    func closeAllConnections() {
        Task {
            do { try await api.closeAllConnections(); showToast("已断开所有连接") }
            catch { showToast("断开连接失败") }
        }
    }

    func closeConnection(id: String) {
        Task {
            try? await api.closeConnection(id: id)
        }
    }

    func flushDnsCache() {
        Task {
            do { try await api.flushDnsCache(); showToast("DNS 缓存已刷新") }
            catch { showToast("刷新 DNS 缓存失败") }
        }
    }

    func clearAllCache() {
        Task {
            do {
                try await api.flushDnsCache()
                try await api.flushFakeIpCache()
                showToast("DNS 及 Fake‑IP 缓存已清空")
            } catch {
                showToast("清空缓存失败")
            }
        }
    }
}
