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
                                    var fix = M.tunPatchBody(enable: M.tunOn)
                                    if let excludes = M.coexistenceRouteBody(plan) {
                                        fix["route-exclude-address"] = excludes
                                    }
                                    await M.patch(["tun": fix])
                                    Coexistence.commitProvenance(
                                        field: "route-exclude-address",
                                        injected: plan.routeExcludes
                                    )
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

                    // interfaces
                    Card(title: "网络接口拓扑 · \(ifaces.count)", icon: "network") {
                        VStack(spacing: 4) {
                            if ifaces.isEmpty { Text("正在扫描接口…").font(.dsBody).foregroundColor(.secondary).padding() }
                            ForEach(ifaces.indices, id: \.self) { idx in
                                ifaceRow(ifaces[idx]).padding(.vertical, DS.Spacing.xs)
                                if idx < ifaces.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }

                    // utun routes
                    Card(title: "UTUN 路由表 · \(routes.count)", icon: "list.bullet.indent") {
                        VStack(spacing: 4) {
                            if routes.isEmpty { Text("无 utun 路由").font(.dsBody).foregroundColor(.secondary).padding() }
                            ForEach(routes.indices, id: \.self) { idx in
                                let route = routes[idx]
                                let iface = ifaces.first(where: { $0.name == route.iface })
                                let kind = iface?.kind ?? .otherTun

                                HStack {
                                    Text(route.dest).font(.dsMono)
                                    Spacer()
                                    Image(systemName: "arrow.right").font(.dsBody).foregroundColor(.secondary)

                                    // 带分类图标和颜色的接口名
                                    HStack(spacing: 4) {
                                        Image(systemName: icon(kind))
                                            .foregroundColor(color(kind))
                                            .font(.dsCaption)
                                        Text(route.iface)
                                            .font(.dsMono)
                                            .foregroundColor(color(kind))
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(color(kind).opacity(0.12))
                                    )
                                }
                                .padding(.vertical, DS.Spacing.xs)
                                if idx < routes.count - 1 {
                                    Divider()
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

    private func ifaceRow(_ i: NetIface) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: icon(i.kind)).foregroundColor(color(i.kind)).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(i.name).font(.dsMonoBold)
                    Text(i.kind.rawValue).font(.dsBody)
                        .padding(.horizontal, DS.Spacing.s - 2).padding(.vertical, 1)
                        .background(Capsule().fill(color(i.kind).opacity(0.15))).foregroundColor(color(i.kind))
                }
                Text(i.ipv4.joined(separator: ", ").isEmpty ? "无 IPv4" : i.ipv4.joined(separator: ", "))
                    .font(.dsMono).foregroundColor(.secondary)
            }
            Spacer()
            Circle().fill(i.isUp ? DS.Palette.ok : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
        }
        .padding(.vertical, DS.Spacing.xs - 1)
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
}

