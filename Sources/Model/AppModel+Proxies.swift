import Foundation

// MARK: - AppModel · Proxies
// Proxy groups, nodes, selection and latency testing.

extension AppModel {
    /// Parse the order of proxy-groups from the active profile's YAML text.
    ///
    /// 口径统一到 `ProviderUsage.groupNames(in:)`（同一套行扫描）：这里原先自带一份
    /// 正则，规则表单的存在性校验又需要同一份「组名从哪来」的理解，两份实现迟早会漂。
    /// 顺带的差异是现在会剥掉行尾注释——旧正则会把 `# 备注` 一起当成组名的一部分。
    private func parseProxyGroupsOrder(from yaml: String) -> [String] {
        ProviderUsage.groupNames(in: yaml)
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

    /// 规则的「目标」在配置里真实可用的名字集合：策略组 + 节点 + 内置策略 + config.yaml 里的组。
    ///
    /// 用途：规则表单保存前的存在性校验（`ValidationService.validate(node:knownTargets:)`）。
    /// 注意目标既可以是策略组名，也可以是节点名（mihomo 允许规则直接指向节点），所以
    /// `nodes` 必须一并算进去，否则会误伤这类规则。
    ///
    /// **为什么要读 config.yaml**：内核 `/proxies` 只反映**运行中**的配置。手改配置新增了
    /// 策略组、还没 reload 时，新组不在 `/proxies` 里——只信内核的话，编辑那条刚手写的
    /// 规则会被误判成「目标已失效」。规则最终写进的就是这份 config.yaml，它的组名也算数。
    ///
    /// **代价与调用约定**：会读一次盘（当前 ~34 KB）。只在**打开规则弹窗那一刻**调用并
    /// 把结果存成快照，不要放进 `body` / sheet 闭包里反复求值。
    ///
    /// 拿不到任何一组名字（内核没起来 + 配置文件读不到）时返回空集合，调用方据此跳过校验
    /// ——绝不能把「没有数据」当成「所有目标都不存在」。
    var ruleTargetNames: Set<String> {
        var names = Set(groups.map { $0.name })
        names.formUnion(nodes.keys)
        let path = engine.configFilePath
        if !path.isEmpty, let yaml = try? String(contentsOfFile: path, encoding: .utf8) {
            names.formUnion(ProviderUsage.groupNames(in: yaml))
        }
        guard !names.isEmpty else { return [] }
        names.formUnion(["DIRECT", "REJECT", "REJECT-DROP", "PASS"])
        return names
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

        // Peer-only tailscale outbounds have no public egress: a URL delay test
        // fails without falling back to direct, painting the chip red forever.
        // Mark them with the peer-only sentinel and keep them out of the public
        // probe set. Exit-node tailscale still takes the regular URL test.
        let exitNode = tsEnabled ? tsSettings.exitNode : ""
        var peerOnly: [String] = []

        for name in names {
            if let node = nodes[name],
               !TailscaleLatency.usesPublicURLTest(nodeType: node.type, exitNode: exitNode) {
                peerOnly.append(name)
                continue
            }
            if let prov = nodeToProvider[name] {
                providerNodeNames.append(name)
                if !providerNames.contains(prov) { providerNames.append(prov) }
            } else {
                directNames.append(name)
            }
        }

        for name in peerOnly {
            nodes[name]?.delay = TailscaleLatency.peerOnlySentinel
            testing.remove(name)
        }

        // Test direct proxies individually via /proxies/{name}/delay, bounded
        // to 16 in flight — a 200-node subscription used to fire one Task per
        // node, hammering the kernel with simultaneous delay probes.
        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var inflight = 0
                for name in directNames {
                    if inflight >= 16 {
                        await group.next()
                        inflight -= 1
                    }
                    inflight += 1
                    group.addTask { @MainActor [weak self] in
                        guard let self else { return }
                        if let d = try? await self.api.testDelay(name: name) {
                            self.nodes[name]?.delay = d
                        }
                        self.testing.remove(name)
                    }
                }
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
