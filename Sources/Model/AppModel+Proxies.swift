import Foundation

// MARK: - AppModel · Proxies
// Proxy groups, nodes, selection and latency testing.

extension AppModel {
    /// Parse the order of proxy-groups from the active profile's YAML text.
    private func parseProxyGroupsOrder(from yaml: String) -> [String] {
        var order: [String] = []
        guard let range = yaml.range(of: #"(?m)^proxy-groups:\s*$"#, options: .regularExpression) else {
            return []
        }
        let sub = yaml[range.upperBound...]
        var groupBlock = ""
        if let endRange = sub.range(of: #"(?m)^\S+:"#, options: .regularExpression) {
            groupBlock = String(sub[..<endRange.lowerBound])
        } else {
            groupBlock = String(sub)
        }
        let pattern = #"-\s*name:\s*["']?([^"'\n\r]+)["']?"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let ns = groupBlock as NSString
            let matches = regex.matches(in: groupBlock, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches {
                if m.numberOfRanges >= 2 {
                    let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    order.append(name)
                }
            }
        }
        return order
    }

    func refreshProxies() async {
        guard reachable else {
            proxiesLoading = false
            proxiesError = "内核未连接"
            return
        }
        proxiesLoading = true
        defer { proxiesLoading = false }

        let p: ProxiesPayload
        do {
            p = try await api.fetchProxies()
            proxiesError = nil
        } catch {
            proxiesError = error.localizedDescription
            logKernel("代理列表刷新失败：\(error.localizedDescription)")
            return
        }

        var gs: [ProxyGroup] = []
        var ns: [String: Node] = [:]
        var n2p: [String: String] = [:]  // nodeName -> providerName

        for (name, e) in p.proxies {
            if let all = e.all {
                gs.append(ProxyGroup(id: name, name: name, type: e.type, now: e.now ?? "", all: all))
            } else {
                let delay = e.history?.last?.delay ?? 0
                ns[name] = Node(id: name, name: name, type: e.type, delay: delay)
            }
        }

        // Also merge proxy-provider nodes (these are NOT in /proxies but in /providers/proxies)
        if let providers = try? await api.fetchProviders() {
            for (provName, prov) in providers.providers {
                // Skip built-in "default" and rule providers
                guard prov.vehicleType != "Compatible", let proxies = prov.proxies else { continue }
                for e in proxies {
                    let name = e.name
                    // Skip if already registered as a proxy group or built-in
                    if gs.contains(where: { $0.id == name }) { continue }
                    if ["DIRECT", "REJECT", "REJECT-DROP", "PASS"].contains(name) { continue }
                    let delay = e.history?.last?.delay ?? 0
                    ns[name] = Node(id: name, name: name, type: e.type, delay: delay)
                    n2p[name] = provName
                }
            }
        }

        // Preserve existing measured delays for nodes that report 0 now
        for (k, v) in nodes where ns[k]?.delay == 0 && v.delay > 0 { ns[k]?.delay = v.delay }

        // Store provider mapping for use by the test engine
        nodeToProvider = n2p

        // Retrieve order from current active profile configuration file
        let yaml = store.content(store.activeID)
        let order = parseProxyGroupsOrder(from: yaml)

        // Update only if changed to avoid unnecessary SwiftUI re-evaluations (RSS optimization)
        let sortedGroups = gs.sorted { a, b in
            let idxA = order.firstIndex(of: a.name) ?? 999
            let idxB = order.firstIndex(of: b.name) ?? 999
            if idxA != idxB {
                return idxA < idxB
            }
            if a.name == "GLOBAL" { return false }
            if b.name == "GLOBAL" { return true }
            return a.name < b.name
        }

        if sortedGroups != groups { groups = sortedGroups }
        if ns != nodes { nodes = ns }
    }

    func select(group: String, name: String) {
        // optimistic
        if let i = groups.firstIndex(where: { $0.id == group }) { groups[i].now = name }
        Task {
            try? await api.selectProxy(group: group, name: name)
            // Optionally drop existing connections so live traffic re-dials through
            // the freshly selected node instead of sticking to the old one.
            if closeOnSwitch { try? await api.closeAllConnections() }
            await refreshProxies()
        }
    }

    func testGroup(_ group: ProxyGroup) {
        let targets = group.all.filter { nodes[$0] != nil }
        test(names: targets)
    }

    func testAll() {
        test(names: Array(nodes.keys))
    }

    private func test(names: [String]) {
        guard !names.isEmpty else { return }
        testing.formUnion(names)

        // Partition: direct proxies vs proxy-provider nodes
        var directNames: [String] = []
        var providerNames: [String] = []   // unique provider names to healthcheck
        var providerNodeNames: [String] = [] // which node names belong to providers

        for name in names {
            if let prov = nodeToProvider[name] {
                providerNodeNames.append(name)
                if !providerNames.contains(prov) { providerNames.append(prov) }
            } else {
                directNames.append(name)
            }
        }

        // Test direct proxies individually via /proxies/{name}/delay
        for name in directNames {
            Task {
                if let d = try? await api.testDelay(name: name) {
                    nodes[name]?.delay = d
                }
                testing.remove(name)
            }
        }

        // Test provider nodes by triggering provider-level healthcheck,
        // then reading updated delay from the provider's proxy history.
        for provName in providerNames {
            Task {
                try? await api.healthCheckProvider(provName)
                // Re-fetch provider to get updated delays
                if let updated = try? await api.fetchProviders() {
                    if let prov = updated.providers[provName], let proxies = prov.proxies {
                        for px in proxies {
                            let delay = px.history?.last?.delay ?? 0
                            if nodes[px.name] != nil {
                                nodes[px.name]?.delay = delay
                            }
                            testing.remove(px.name)
                        }
                    }
                } else {
                    // Fallback: clear testing state for all nodes in this provider
                    for n in providerNodeNames where nodeToProvider[n] == provName {
                        testing.remove(n)
                    }
                }
            }
        }
    }

    func currentProxyName() -> String {
        // Follow GLOBAL or the primary selector chain to a leaf node
        let primary = groups.first(where: { $0.name == "默认代理" || $0.name == "GLOBAL" || $0.selectable })
        guard var cur = primary?.now else { return "—" }
        var guard0 = 0
        while let g = groups.first(where: { $0.id == cur }), guard0 < 6 { cur = g.now; guard0 += 1 }
        if cur == "DIRECT" { return "直连" }
        if cur == "REJECT" { return "拒绝" }
        return cur
    }
}
