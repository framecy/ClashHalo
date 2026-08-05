import SwiftUI

// MARK: - 网络拓扑 (topology + conflict detection)

struct LinkLine: View {
    let start: CGPoint
    let end: CGPoint
    let color: Color

    var body: some View {
        // Static dashed stroke only — decorative `repeatForever` loops are banned
        // by Docs/design.md §10 (progress/traffic stay data-driven, no attention theft).
        Path { path in
            path.move(to: start)
            let control1 = CGPoint(x: start.x + (end.x - start.x) * 0.5, y: start.y)
            let control2 = CGPoint(x: start.x + (end.x - start.x) * 0.5, y: end.y)
            path.addCurve(to: end, control1: control1, control2: control2)
        }
        .stroke(color.opacity(0.18), lineWidth: 1.5)
        .overlay(
            Path { path in
                path.move(to: start)
                let control1 = CGPoint(x: start.x + (end.x - start.x) * 0.5, y: start.y)
                let control2 = CGPoint(x: start.x + (end.x - start.x) * 0.5, y: end.y)
                path.addCurve(to: end, control1: control1, control2: control2)
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round, dash: [6, 6]))
        )
    }
}

struct SdwanTopologyView: View {
    @EnvironmentObject var M: AppModel
    let ifaces: [NetIface]
    let routes: [(dest: String, iface: String)]

    var body: some View {
        let activeIfaces = ifaces.filter { $0.isUp && !$0.ipv4.isEmpty }

        // Filter and limit destinations to max 4 to fit nicely inside the card without crowding/overflow.
        var rawDests = Array(Set(routes.map { $0.dest }))
        if rawDests.isEmpty {
            rawDests.append("0.0.0.0/0 (默认出口)")
        }
        let dests = Array(rawDests.sorted { a, b in
            let aIsDefault = a == "default" || a.contains("0.0.0.0")
            let bIsDefault = b == "default" || b.contains("0.0.0.0")
            if aIsDefault != bIsDefault { return aIsDefault }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.prefix(8))

        let calculatedHeight = max(200, CGFloat(max(activeIfaces.count, dests.count)) * 56 + 40)

        return GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            let hostPt = CGPoint(x: 55, y: h / 2)

            let ifaceCount = max(1, activeIfaces.count)
            let ifacePoints = (0..<activeIfaces.count).map { idx -> (String, CGPoint) in
                let y = h / 2 + CGFloat(idx - (ifaceCount - 1) / 2) * 54
                return (activeIfaces[idx].id, CGPoint(x: w * 0.44, y: y))
            }

            let destPoints = (0..<dests.count).map { idx -> (String, CGPoint) in
                let y = h / 2 + CGFloat(idx - (dests.count - 1) / 2) * 50
                return (dests[idx], CGPoint(x: w * 0.82, y: y))
            }

            ZStack {
                // Connections (Pan lines with flow simulation)
                ForEach(ifacePoints, id: \.0) { ifaceId, pt in
                    let color = lineColor(for: activeIfaces.first(where: { $0.id == ifaceId })?.kind ?? .physical)
                    LinkLine(start: hostPt, end: pt, color: color)
                }

                // Draw lines to destinations, only if they are visible in our top 8 limited dests.
                ForEach(routes.indices, id: \.self) { idx in
                    let r = routes[idx]
                    if dests.contains(r.dest),
                       let startPt = ifacePoints.first(where: { $0.0 == r.iface })?.1,
                       let endPt = destPoints.first(where: { $0.0 == r.dest })?.1 {
                        let color = lineColor(for: activeIfaces.first(where: { $0.id == r.iface })?.kind ?? .physical)
                        LinkLine(start: startPt, end: endPt, color: color)
                    }
                }

                if let eth = activeIfaces.first(where: { $0.kind == .physical }),
                   let ethPt = ifacePoints.first(where: { $0.0 == eth.id })?.1,
                   let defaultDestPt = destPoints.first(where: { $0.0.contains("0.0.0.0") || $0.0 == "default" })?.1 {
                    LinkLine(start: ethPt, end: defaultDestPt, color: DS.Palette.rolePhysical)
                }

                // Nodes
                VStack(spacing: 4) {
                    Image(systemName: "laptopcomputer").font(DS.Icon.font(DS.Icon.sm))
                    Text("本机 (Host)").font(.dsBodyBold)
                }
                .frame(width: 80, height: 48)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Palette.cardBg))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).stroke(DS.Palette.accent, lineWidth: 1.2))
                .position(hostPt)

                ForEach(0..<activeIfaces.count, id: \.self) { idx in
                    let iface = activeIfaces[idx]
                    let pt = ifacePoints[idx].1
                    let color = lineColor(for: iface.kind)
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: iface.kind))
                            .foregroundColor(color)
                            .font(.dsLabel)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(iface.name).font(.dsMonoBold).lineLimit(1)
                            Text(iface.primaryIP).font(.dsMono).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Spacing.m - 2).padding(.vertical, DS.Spacing.s - 2)
                    .frame(width: 144, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Palette.cardBg))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).stroke(color.opacity(0.7), lineWidth: 1.0))
                    .position(pt)
                }

                ForEach(0..<dests.count, id: \.self) { idx in
                    let dest = dests[idx]
                    let pt = destPoints[idx].1
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.circle.fill").foregroundColor(.secondary).font(.dsBody)
                        Text(dest).font(.dsMono).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Spacing.m - 2).padding(.vertical, DS.Spacing.s - 2)
                    .frame(width: 110, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Palette.cardBg))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).stroke(DS.Palette.border, lineWidth: 1.0))
                    .position(pt)
                }
            }
        }
        .frame(height: calculatedHeight)
        .padding(DS.Spacing.m - 2)
        .background(VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow).clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.fill))
        .clipped()
    }

    private func lineColor(for k: IfaceKind) -> Color {
        switch k {
        case .physical: return DS.Palette.rolePhysical
        case .proxyTun: return DS.Palette.accent
        case .tailscale: return DS.Palette.roleTailscale
        case .zerotier: return DS.Palette.roleZerotier
        case .oray: return DS.Palette.roleOray
        case .otherTun: return DS.Palette.roleOther
        default: return .secondary
        }
    }

    private func iconName(for k: IfaceKind) -> String {
        switch k {
        case .physical: return "wifi"
        case .proxyTun: return "shield.fill"
        case .tailscale: return "point.3.connected.trianglepath.dotted"
        case .zerotier: return "globe"
        case .oray: return "link"
        case .otherTun: return "network"
        default: return "questionmark.circle"
        }
    }
}

struct SdwanPage: View {
    @EnvironmentObject var M: AppModel
    @State private var ifaces: [NetIface] = []
    @State private var routes: [(dest: String, iface: String)] = []
    @State private var conflicts: [RouteConflict] = []
    @State private var dnsDrift: [Coexistence.ResolverDrift] = []
    @State private var repairingDNS = false
    @State private var subnetGaps: [Coexistence.PeerSubnetGap] = []
    /// Another tunnel holding the unscoped default route. Reported, never
    /// "repaired" — see `NetScanner.foreignDefaultRouteHolder`.
    @State private var defaultRouteHolder: String? = nil

    /// Repair timestamps only ever render as a wall clock, so the formatter is
    /// built once rather than per body evaluation.
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private var sdwanCount: Int { ifaces.filter { $0.kind.sdwan }.count }
    /// Faults the "一键修复" button can actually act on — it works by injecting
    /// `route-exclude-address`, which does nothing for an absent peer route, so
    /// subnet gaps deliberately stay out of this gate.
    private var hasConflicts: Bool { !conflicts.isEmpty || defaultRouteHolder != nil }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar {
                Button { rescan() } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
                    .dsButton()
            }

            ScrollView {
                VStack(spacing: DS.Spacing.m) {
                    // status banner
                    HStack(spacing: DS.Spacing.m) {
                        Image(systemName: "shield.lefthalf.filled").font(DS.Icon.font(DS.Icon.lg))
                            .foregroundColor(hasConflicts ? DS.Palette.warn : DS.Palette.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hasConflicts ? "检测到路由冲突" : "智能路由隔离已生效").font(.dsLabelBold)
                            if let holder = defaultRouteHolder {
                                Text("接口 \(holder) 持有全局默认路由（非作用域限定），与本机 TUN 争夺出口。"
                                     + "需在该隧道一侧处理——关闭本应用的自动路由只会让 TUN 失去全部路由。")
                                    .font(.dsBody).foregroundColor(.secondary)
                            } else if !conflicts.isEmpty {
                                let desc = conflicts.prefix(2)
                                    .map { "\($0.sdwanIface) \($0.sdwanRoute) 被 \($0.tunRoute) 遮蔽" }
                                    .joined(separator: "；")
                                Text("TUN 路由遮蔽网络拓扑网段：\(desc)。")
                                    .font(.dsBody).foregroundColor(.secondary)
                            } else if !subnetGaps.isEmpty {
                                // No shadowing, but a peer subnet is unreachable
                                // — the banner must not read "一切正常" for the
                                // exact fault that used to go unreported.
                                Text("代理未抢占路由，但有 \(subnetGaps.count) 个对端网段不可达，详见下方。")
                                    .font(.dsBody).foregroundColor(.secondary)
                            } else {
                                Text("代理仅注入精确网段，未抢占网络拓扑路由；\(sdwanCount) 个接口路由完整。")
                                    .font(.dsBody).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if hasConflicts {
                            Button("一键修复") {
                                Task {
                                    // Same planner the automatic path uses.
                                    let plan = Coexistence.plan(await Coexistence.detect())
                                    // A tun PATCH must restate the whole block:
                                    // `PATCH /configs` replaces nested objects, so
                                    // sending route-exclude-address alone comes back
                                    // with enable=false and tears TUN down.
                                    // Route exclusion only. Disabling auto-route
                                    // used to ride along here whenever a default
                                    // route was seen on any utun — including our
                                    // own, and including a peer's harmless
                                    // scoped one — and a TUN with auto-route off
                                    // installs no routes at all: the observed
                                    // "utun100 接管后无网络". A competing tunnel
                                    // is reported, not "fixed" by crippling us.
                                    // tunPatchBody already restates the exclusions
                                    // the config carries; this only *adds* what
                                    // the current peer set needs on top.
                                    var fix = M.tunPatchBody(enable: M.tunOn)
                                    var injected: [String] = []
                                    if let ex = M.coexistenceRouteBody(plan) {
                                        fix["route-exclude-address"] = ex.merged
                                        injected = ex.injected
                                    }
                                    // Claim provenance only for what we actually
                                    // *applied*. Recording on a dropped PATCH
                                    // mis-attributes the user's own entries as
                                    // ours (and the next withdrawal deletes them),
                                    // and also makes the automatic reconciler
                                    // think the plan is already live.
                                    let ok = await M.patch(["tun": fix])
                                    if ok {
                                        Coexistence.commitProvenance(
                                            field: "route-exclude-address",
                                            injected: injected
                                        )
                                    }
                                    try? await Task.sleep(nanoseconds: 800_000_000)
                                    rescan()
                                }
                            }
                            .dsButton(.warning)
                        } else {
                            VStack {
                                Text("0").font(.dsStatValue)
                                    .foregroundColor(DS.Palette.accent)
                                Text("路由冲突").font(.dsBody).foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(DS.Spacing.l)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Palette.cardBg))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.border))

                    // What the periodic audit last put back, and what it could
                    // not. Shown whenever a repair has run this session — a
                    // silent self-heal is indistinguishable from a self-heal
                    // that never happened, and the whole point of repairing at
                    // the route layer is that the user feels nothing.
                    if let r = M.lastRouteRepair {
                        Card(title: "自动路由修复 · \(Self.clock.string(from: r.at))",
                             icon: "wrench.and.screwdriver.fill") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(r.fixed, id: \.self) { line in
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(DS.Palette.accent).font(.dsBody).frame(width: 20)
                                        Text(line).font(.dsMono)
                                        Spacer()
                                        Text("已改回").font(.dsBody)
                                            .padding(.horizontal, DS.Spacing.s - 2).padding(.vertical, 2)
                                            .background(Capsule().fill(DS.Palette.accent.opacity(0.15)))
                                            .foregroundColor(DS.Palette.accent)
                                    }
                                }
                                ForEach(r.remaining, id: \.self) { line in
                                    HStack(spacing: 8) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(DS.Palette.warn).font(.dsBody).frame(width: 20)
                                        Text(line).font(.dsBody).foregroundColor(DS.Palette.warn)
                                        Spacer()
                                    }
                                }
                                if r.fixed.isEmpty && r.remaining.isEmpty {
                                    Text("本轮无需改动。").font(.dsBody).foregroundColor(.secondary)
                                }
                                Text("修复在路由表上逐条执行（route delete/add），不重载内核、不中断既有连接。"
                                     + "完整过程见\u{201C}日志\u{201D}页。")
                                    .font(.dsBody).foregroundColor(.secondary).padding(.top, 4)
                            }
                        }
                    }

                    // Conflict detail card (shown when prefix-shadowing detected)
                    if !conflicts.isEmpty {
                        Card(title: "路由遮蔽冲突 · \(conflicts.count)", icon: "exclamationmark.triangle.fill") {
                            VStack(spacing: 4) {
                                ForEach(conflicts.indices, id: \.self) { idx in
                                    let c = conflicts[idx]
                                    HStack(spacing: 8) {
                                        Image(systemName: "point.3.connected.trianglepath.dotted")
                                            .foregroundColor(DS.Palette.roleTailscale).font(.dsBody).frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(c.sdwanIface) → \(c.sdwanRoute)").font(.dsMono).foregroundColor(DS.Palette.roleTailscale)
                                            Text("被 \(c.tunIface) 的 \(c.tunRoute) 遮蔽")
                                                .font(.dsBody).foregroundColor(DS.Palette.warn)
                                        }
                                        Spacer()
                                        Text("路由冲突").font(.dsBody)
                                            .padding(.horizontal, DS.Spacing.s - 2).padding(.vertical, 2)
                                            .background(Capsule().fill(DS.Palette.warn.opacity(0.15)))
                                            .foregroundColor(DS.Palette.warn)
                                    }
                                    .padding(.vertical, DS.Spacing.xs)
                                    if idx < conflicts.count - 1 { Divider() }
                                }
                                Text("建议：点击\u{201C}一键修复\u{201D}将上述网络拓扑前缀注入 tun.route-exclude-address，防止 TUN 抢占。")
                                    .font(.dsBody).foregroundColor(.secondary).padding(.top, 4)
                            }
                        }
                    }

                    // Subnets the peer says it carries but the kernel does not
                    // route there. Invisible to route-table scanning by
                    // construction — an absent route contributes nothing to scan
                    // — so it gets its own card rather than joining the
                    // shadowing conflicts above.
                    if !subnetGaps.isEmpty {
                        Card(title: "对端网段不可达 · \(subnetGaps.count)", icon: "exclamationmark.triangle.fill") {
                            VStack(spacing: 4) {
                                ForEach(subnetGaps) { g in
                                    HStack(spacing: 8) {
                                        Image(systemName: "point.3.connected.trianglepath.dotted")
                                            .foregroundColor(DS.Palette.warn).font(.dsBody).frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(g.cidr)  ←  \(g.peer)").font(.dsMono)
                                                .foregroundColor(DS.Palette.warn)
                                            Text(g.isMissing
                                                 ? "对端广播了该网段，但本机路由表没有对应路由，流量会走物理网卡"
                                                 : "该网段当前指向 \(g.routedVia ?? "?")，而非 \(g.expected)")
                                                .font(.dsBody).foregroundColor(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, DS.Spacing.xs)
                                }
                                Text("路由由对端隧道自行下发，本页只做检测不代为安装——代装会与它的路由管理相互覆盖。"
                                     + "请检查该隧道是否开启「接受子网路由」，或重连以让它重新下发。")
                                    .font(.dsBody).foregroundColor(.secondary).padding(.top, 4)
                            }
                        }
                    }

                    // DNS resolver pins that outlived the interface they name.
                    // Separate card from the route conflicts above: this one is
                    // fixed by rewriting config.yaml + reload (drops connections),
                    // never by the runtime PATCH the route repair uses.
                    if !dnsDrift.isEmpty {
                        Card(title: "DNS 出口绑定漂移 · \(dnsDrift.count)", icon: "arrow.triangle.branch") {
                            VStack(spacing: 4) {
                                ForEach(dnsDrift) { d in
                                    HStack(spacing: 8) {
                                        Image(systemName: "questionmark.circle")
                                            .foregroundColor(DS.Palette.warn).font(.dsBody).frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(d.resolver)#\(d.from)").font(.dsMono).foregroundColor(DS.Palette.warn)
                                            Text("该解析器实际位于 \(d.to)，当前绑定已失效")
                                                .font(.dsBody).foregroundColor(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, DS.Spacing.xs)
                                }
                                HStack {
                                    Text("接口序号由内核按创建顺序分配，重启后会变。修复将改写 config.yaml 并重载配置（会断开当前连接）。")
                                        .font(.dsBody).foregroundColor(.secondary)
                                    Spacer()
                                    Button(repairingDNS ? "修复中…" : "修复出口绑定") {
                                        repairingDNS = true
                                        Task {
                                            await M.repairDNSInterfaceBindings()
                                            repairingDNS = false
                                            rescan()
                                        }
                                    }
                                    .dsButton(.warning)
                                    .disabled(repairingDNS)
                                }
                                .padding(.top, 4)
                            }
                        }
                    }

                    // Topology view of the network routing relation map
                    SdwanTopologyView(ifaces: ifaces, routes: routes)

                    // interfaces — agated by interface: each interface is
                    // one mini-card; its carried route prefixes flow inside it.
                    let ifaceGroups = aggregateByIface()
                    Card(title: "网络接口拓扑 · \(ifaces.count)", icon: "network") {
                        if ifaces.isEmpty {
                            Text("正在扫描接口…").font(.dsBody).foregroundColor(.secondary).padding()
                        } else {
                            VStack(spacing: DS.Spacing.s) {
                                ForEach(Array(ifaceGroups.enumerated()), id: \.offset) { _, g in
                                    SdwanAggregateRow(group: g) { dest in
                                        routeDestLabel(dest, kind: g.kind)
                                    }
                                }
                            }
                        }
                    }

                    // utun routes — same aggregate-by-egress style; here the
                    // group key is purely the utun egress and the body lists its
                    // prefixes, also wrapped in mini-cards.
                    let routeGroups = routeGroupsByIface()
                    Card(title: "UTUN 路由表 · \(routes.count)", icon: "list.bullet.indent") {
                        if routeGroups.isEmpty {
                            Text("无 utun 路由").font(.dsBody).foregroundColor(.secondary).padding()
                        } else {
                            VStack(spacing: DS.Spacing.s) {
                                ForEach(Array(routeGroups.enumerated()), id: \.offset) { _, g in
                                    SdwanAggregateRow(group: g) { dest in
                                        routeDestLabel(dest, kind: g.kind)
                                    }
                                }
                            }
                        }
                    }

                    Label("进程级分流 (SO_USER_COOKIE + PF) 与路由注入需特权 Helper（代码签名后于 v1.0 启用）",
                          systemImage: "lock.shield").font(.dsBody).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
                // 顶距与配置页一致，避免内容贴死 chrome 分割线
                .padding(.horizontal, DS.Layout.pageContentInset)
                .padding(.top, DS.Spacing.l)
                .padding(.bottom, DS.Spacing.xxl)
            }
        }
        .onAppear { rescan() }
    }

    private func rescan() {
        ifaces = NetScanner.interfaces()
        Task {
            async let r = NetScanner.tunRoutes()
            async let c = NetScanner.conflictingRoutes()
            let (routes_, conflicts_) = await (r, c)
            let drift_ = await M.dnsInterfaceDrift()
            let gaps_ = await M.peerSubnetGaps()
            let holder_ = await NetScanner.foreignDefaultRouteHolder()
            await MainActor.run {
                routes = routes_
                conflicts = conflicts_
                dnsDrift = drift_
                subnetGaps = gaps_
                defaultRouteHolder = holder_
            }
        }
    }
    private func icon(_ k: IfaceKind) -> String {
        switch k {
        case .physical: return "wifi"
        case .proxyTun: return "shield.fill"
        case .tailscale: return "point.3.connected.trianglepath.dotted"
        case .zerotier: return "globe"
        case .oray: return "link"
        case .otherTun: return "network"
        default: return "questionmark.circle"
        }
    }
    private func color(_ k: IfaceKind) -> Color {
        switch k {
        case .physical: return DS.Palette.rolePhysical
        case .proxyTun: return DS.Palette.accent
        case .tailscale: return DS.Palette.roleTailscale
        case .zerotier: return DS.Palette.roleZerotier
        case .oray: return DS.Palette.roleOray
        case .otherTun: return DS.Palette.roleOther
        default: return .secondary
        }
    }

    /// Build per-interface aggregate rows for the "网络接口拓扑" card.
    /// Each interface becomes one expandable row; dests seeded from routes
    /// routed via that interface (so a utun's bundled /22–/24 prefixes surface
    /// inline instead of as a separate flat list).
    private func aggregateByIface() -> [SdwanRouteGroup] {
        var groups: [String: SdwanRouteGroup] = [:]
        for i in ifaces {
            groups[i.id] = SdwanRouteGroup(
                ifaceName: i.name,
                primaryIP: i.primaryIP,
                kind: i.kind,
                isUp: i.isUp,
                dests: []
            )
        }
        for r in routes {
            var g = groups[r.iface, default: SdwanRouteGroup(
                ifaceName: r.iface, primaryIP: "—", kind: .otherTun, isUp: false, dests: [])]
            g.dests.append(r.dest)
            groups[r.iface] = g
        }
        // Order: utun (proxyTun > tailscale > zerotier > oray > otherTun) then physical,
        // then anything left, each bucket by name so the display is stable across refreshes.
        func rank(_ k: IfaceKind) -> Int {
            switch k {
            case .proxyTun: return 0
            case .tailscale: return 1
            case .zerotier: return 2
            case .oray:  return 3
            case .otherTun: return 4
            case .physical: return 5
            default: return 9
            }
        }
        return groups.values.sorted { lhs, rhs in
            let r = rank(lhs.kind) - rank(rhs.kind)
            if r != 0 { return r < 0 }
            return lhs.ifaceName.localizedStandardCompare(rhs.ifaceName) == .orderedAscending
        }
    }

    /// Per-utun-egress groups for the "UTUN 路由表" card: purely route-driven,
    /// so interfaces carrying no routes won't appear here.
    private func routeGroupsByIface() -> [SdwanRouteGroup] {
        var groups: [String: SdwanRouteGroup] = [:]
        for r in routes {
            let kind = ifaces.first(where: { $0.name == r.iface })?.kind ?? .otherTun
            if var g = groups[r.iface] {
                g.dests.append(r.dest)
                groups[r.iface] = g
            } else {
                groups[r.iface] = SdwanRouteGroup(
                    ifaceName: r.iface, primaryIP: "—", kind: kind, isUp: true, dests: [r.dest]
                )
            }
        }
        // Sort by kind (utun roles first) then name, same key as interface card
        // so the two cards visually mirror each other.
        func rank(_ k: IfaceKind) -> Int {
            switch k {
            case .proxyTun: return 0
            case .tailscale: return 1
            case .zerotier: return 2
            case .oray:  return 3
            case .otherTun: return 4
            default: return 9
            }
        }
        return groups.values.sorted { lhs, rhs in
            let r = rank(lhs.kind) - rank(rhs.kind)
            if r != 0 { return r < 0 }
            return lhs.ifaceName.localizedStandardCompare(rhs.ifaceName) == .orderedAscending
        }
    }

    /// Small inline row for one route destination — shown inside an expanded
    /// SdwanAggregateRow. Pure presentational.
    @ViewBuilder
    private func routeDestLabel(_ dest: String, kind: IfaceKind) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "arrow.up.right.circle.fill")
                .foregroundColor(color(kind))
                .font(.dsCaption)
            Text(dest)
                .font(.dsMono)
                .foregroundColor(.primary)
            Spacer(minLength: 0)
        }
        .padding(.leading, DS.Spacing.m + 6)
        // Looser vertical padding: each dest reads as its own line, not cramped stripes.
        .padding(.vertical, DS.Spacing.xs)
    }
}


// MARK: - Aggregated row (utun-egress group)

/// Per-egress group used by both the 网络接口拓扑 and UTUN 路由表 cards so they
/// share the same collapsed→expanded shape: an egress (iface) + the routes it
/// carries. Mirrors the ``ConnectionsPage.ConnGroup`` pattern.
struct SdwanRouteGroup: Identifiable {
    let id: String          // iface name
    let ifaceName: String
    let primaryIP: String
    let kind: IfaceKind
    let isUp: Bool
    var dests: [String]

    init(ifaceName: String, primaryIP: String, kind: IfaceKind, isUp: Bool, dests: [String]) {
        self.id = ifaceName
        self.ifaceName = ifaceName
        self.primaryIP = primaryIP
        self.kind = kind
        self.isUp = isUp
        self.dests = dests
    }
}

/// Collapsible egress card: egress header + (when expanded) the bundled
/// route prefixes, all wrapped in a single nested surface (`dsControlChrome`)
/// so each utun group reads as its own mini-card inside the parent `Card`.
/// Tapping anywhere on the header toggles the whole group.
struct SdwanAggregateRow<Dest: View>: View {
    let group: SdwanRouteGroup
    @ViewBuilder let destLabel: (String) -> Dest

    @State private var expanded = false

    private func icon(_ k: IfaceKind) -> String {
        switch k {
        case .physical: return "wifi"
        case .proxyTun: return "shield.fill"
        case .tailscale: return "point.3.connected.trianglepath.dotted"
        case .zerotier: return "globe"
        case .oray: return "link"
        case .otherTun: return "network"
        default: return "questionmark.circle"
        }
    }
    private func color(_ k: IfaceKind) -> Color {
        switch k {
        case .physical: return DS.Palette.rolePhysical
        case .proxyTun: return DS.Palette.accent
        case .tailscale: return DS.Palette.roleTailscale
        case .zerotier: return DS.Palette.roleZerotier
        case .oray: return DS.Palette.roleOray
        case .otherTun: return DS.Palette.roleOther
        default: return .secondary
        }
    }

    var body: some View {
        let tint = color(group.kind)
        return VStack(spacing: 0) {
            if group.dests.isEmpty {
                // Leaf egress (physical NIC carrying no tun routes) — no chevron,
                // not expandable, dashed (not solid) tinted border: signals
                // "this is a terminal endpoint, no bundled prefixes below".
                leafHeader
            } else {
                Button {
                    if #available(macOS 14.0, *) {
                        withAnimation(DS.Motion.micro) { expanded.toggle() }
                    } else {
                        expanded.toggle()
                    }
                } label: { expandableHeader }
                    .buttonStyle(.plain)

                if expanded && !group.dests.isEmpty {
                    // Body — bundled prefixes flow inside the same mini-card so
                    // the surface wraps both header and details.
                    VStack(alignment: .leading, spacing: DS.Spacing.s - 2) {
                        Rectangle().fill(tint.opacity(0.25)).frame(height: 0.6)
                        ForEach(Array(group.dests.enumerated()), id: \.offset) { _, dest in
                            destLabel(dest)
                        }
                    }
                    .padding(.vertical, DS.Spacing.xs)
                    .padding(.bottom, DS.Spacing.xs + 2)
                }
            }
        }
        .modifier(NestedControlSurface(tint: tint, dashed: group.dests.isEmpty))
    }

    /// Static (no-button) header for leaf egresses: only icon + name + IP +
    /// status dot; no chevron, no route-count pill, not tappable.
    private var leafHeader: some View {
        let tint = color(group.kind)
        return HStack(spacing: DS.Spacing.s) {
            // Reserve the chevron slot so leaf rows align with expandable ones.
            Color.clear.frame(width: 14)
            Image(systemName: icon(group.kind))
                .foregroundColor(tint)
                .font(.dsBody)
                .frame(width: 18)
            Text(group.ifaceName).font(.dsMonoBold)
            Spacer(minLength: 0)
            if group.primaryIP != "—" {
                Text(group.primaryIP)
                    .font(.dsMono)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Circle()
                .fill(group.isUp ? DS.Palette.ok : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }

    /// Button label for expandable egresses: chevron + icon + name + count
    /// pill + IP + status dot. Tapping the header toggles the whole group.
    private var expandableHeader: some View {
        let tint = color(group.kind)
        return HStack(spacing: DS.Spacing.s) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.dsBody)
                .foregroundColor(.secondary)
                .frame(width: 14)
            Image(systemName: icon(group.kind))
                .foregroundColor(tint)
                .font(.dsBody)
                .frame(width: 18)
            Text(group.ifaceName).font(.dsMonoBold)
            Spacer(minLength: 0)
            // Demoted count pill: 14% tinted fill + tinted text, same tier as
            // a header chip. Lets the colored border carry the visual lead.
            if group.dests.count > 0 {
                Text("\(group.dests.count)")
                    .font(.dsMono)
                    .foregroundColor(tint)
                    .padding(.horizontal, DS.Spacing.s)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(tint.opacity(0.14)))
            }
            if group.primaryIP != "—" {
                Text(group.primaryIP)
                    .font(.dsMono)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Circle()
                .fill(group.isUp ? DS.Palette.ok : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }
}

/// Wraps a view in a tinted control surface: card bg + 1.2pt stroke in the
/// egress's role color ("角色色描边"), no ambient shadow so the parent Card
/// keeps breathing. Replaces the textual role chip in the header — the border
/// now carries the "which egress am I" signal at a glance.
private struct NestedControlSurface: ViewModifier {
    let tint: Color
    /// Dashed border for leaf egresses (no bundled routes below):
    /// visually signals "terminal endpoint, nothing to expand".
    let dashed: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        return content
            .background(shape.fill(DS.Palette.cardBg))
            .overlay(
                shape.stroke(
                    tint.opacity(0.7),
                    style: StrokeStyle(
                        lineWidth: 1.2,
                        dash: dashed ? [4, 3] : []
                    )
                )
            )
    }
}
