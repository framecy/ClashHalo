import Foundation

// MARK: - AppModel · Connections & Traffic
// Live traffic ticks, connection snapshots, single-pass dashboard aggregation,
// and connection / DNS cache management.

extension AppModel {
    func onTraffic(_ t: TrafficTick) {
        if t.up != curUp { curUp = t.up }
        if t.down != curDown { curDown = t.down }
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
        
        let items = s.connections ?? []
        var bytes: [String: (up: Int64, down: Int64)] = [:]
        var activeIDs = Set<String>()
        let hour = Calendar.current.component(.hour, from: Date())
        
        for c in items {
            activeIDs.insert(c.id)
            if prevConnsMap[c.id] == nil { totalConnsCount += 1 }
            let prev = prevConnBytes[c.id]
            let upRate = prev.map { max(0, c.upload - $0.up) } ?? 0
            let downRate = prev.map { max(0, c.download - $0.down) } ?? 0
            bytes[c.id] = (c.upload, c.download)
            
            // attribute this connection's byte delta to its category → history
            let cat = (c.chains.first == "DIRECT" || c.chains.contains("DIRECT")) ? "direct"
                    : (c.chains.first == "REJECT" || c.chains.contains("REJECT")) ? "reject" : "proxy"
            history.record(category: cat, down: Int64(downRate), up: Int64(upRate), hour: hour)
        }
        prevConnBytes = bytes
        
        // Clean up prevConnsMap for closed connections to keep count accurate
        var nextConnsMap: [String: Conn] = [:]
        for id in activeIDs {
            if let existing = prevConnsMap[id] {
                nextConnsMap[id] = existing
            } else {
                // Dummy Conn just to track seen IDs in map
                nextConnsMap[id] = Conn(
                    id: id, host: "", dstIP: "", srcIP: "", port: "", network: "",
                    process: "", processPath: "", chain: "", group: "", node: "",
                    rule: "", ruleType: "", up: 0, down: 0, upRate: 0, downRate: 0, start: ""
                )
            }
        }
        prevConnsMap = nextConnsMap
        
        activeConnectionsCount = activeIDs.count
        closedConns = max(0, totalConnsCount - activeIDs.count)
        history.flushIfNeeded()
        lastDownTotal = s.downloadTotal
        appMemoryMB = Double(Self.residentMemoryBytes()) / 1_000_000
    }

    /// Single-pass dashboard aggregation (runs once per connections snapshot,
    /// not per SwiftUI render — the key fix for dashboard stutter).
    static func computeDash(_ conns: [Conn]) -> DashStats {
        var pg = [String: Double](), hosts = [String: Double](), nodes = [String: Double]()
        var procs = [String: Double](), rules = [String: Double]()
        var direct = 0.0, proxy = 0.0, reject = 0.0
        var hostSet = Set<String>()
        for c in conns {
            let b = Double(c.up + c.down)
            if c.group != "?" && !c.group.isEmpty { pg[c.group, default: 0] += b }
            if c.host != "?" { hosts[c.host, default: 0] += b; hostSet.insert(c.host) }
            if c.node != "?" { nodes[c.node, default: 0] += b }
            if c.process != "—" { procs[c.process, default: 0] += b }
            rules[c.ruleType, default: 0] += 1
            switch c.category { case "direct": direct += b; case "reject": reject += b; default: proxy += b }
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
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
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
