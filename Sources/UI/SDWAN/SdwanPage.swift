import SwiftUI

// MARK: - SD-WAN coexistence (topology + conflict detection)

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct LinkLine: View {
    let start: CGPoint
    let end: CGPoint
    let color: Color
    @State private var phase: CGFloat = 0

    var body: some View {
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
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round, miterLimit: 0, dash: [6, 6], dashPhase: phase))
        )
        .onAppear {
            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                phase = -24
            }
        }
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
                    LinkLine(start: ethPt, end: defaultDestPt, color: .blue)
                }

                // Nodes
                VStack(spacing: 4) {
                    Image(systemName: "laptopcomputer").font(.system(size: DS.Icon.sm))
                    Text("本机 (Host)").font(.dsBodyBold)
                }
                .frame(width: 80, height: 48)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.cardBg))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(M.accent, lineWidth: 1.2))
                .position(hostPt)

                ForEach(0..<activeIfaces.count, id: \.self) { idx in
                    let iface = activeIfaces[idx]
                    let pt = ifacePoints[idx].1
                    let color = lineColor(for: iface.kind)
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: iface.kind))
                            .foregroundColor(color)
                            .font(.system(size: 14))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(iface.name).font(.dsMono).fontWeight(.bold).lineLimit(1)
                            Text(iface.primaryIP).font(.dsMono).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(width: 144, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.cardBg))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(color.opacity(0.7), lineWidth: 1.0))
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
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(width: 110, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.cardBg))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(Color.primary.opacity(0.12), lineWidth: 1.0))
                    .position(pt)
                }
            }
        }
        .frame(height: calculatedHeight)
        .padding(10)
        .background(VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow).cornerRadius(DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(Color.primary.opacity(0.06)))
        .clipped()
    }

    private func lineColor(for k: IfaceKind) -> Color {
        switch k {
        case .physical: return .blue
        case .proxyTun: return M.accent
        case .tailscale: return .teal
        case .zerotier: return .orange
        case .oray: return .purple
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
        default: return "network"
        }
    }
}

struct SdwanPage: View {
    @EnvironmentObject var M: AppModel
    @State private var ifaces: [NetIface] = []
    @State private var routes: [(dest: String, iface: String)] = []

    private var sdwanCount: Int { ifaces.filter { $0.kind.sdwan }.count }
    private var hasDefaultViaTun: Bool { routes.contains { $0.dest == "default" } }

    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "SD-WAN 共存", desc: "网卡拓扑识别 · 路由冲突检测 · 多隧道并存分析") {
                Button { rescan() } label: { Label("重新扫描", systemImage: "arrow.clockwise") }.controlSize(.small)
            }

            ScrollView {
                VStack(spacing: 14) {
                    // status banner
                    HStack(spacing: 12) {
                        Image(systemName: "shield.lefthalf.filled").font(.title).foregroundColor(hasDefaultViaTun ? .orange : M.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hasDefaultViaTun ? "检测到 TUN 默认路由冲突" : "智能路由隔离已生效").font(.dsLabelBold)
                            if hasDefaultViaTun, let conflictIface = routes.first(where: { $0.dest == "default" || $0.dest.contains("0.0.0.0/0") })?.iface {
                                Text("接口 \(conflictIface) 接管了全局默认路由，与 SD-WAN 原生路由冲突。建议关闭自动路由。")
                                    .font(.dsBody).foregroundColor(.secondary)
                            } else {
                                Text("代理仅注入精确网段，未抢占默认路由；\(sdwanCount) 个 SD-WAN 接口路由保持完整。")
                                    .font(.dsBody).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if hasDefaultViaTun {
                            Button("一键修复") {
                                Task {
                                    await M.patch([
                                        "tun": [
                                            "auto-route": false,
                                            "auto-detect-interface": false
                                        ]
                                    ])
                                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                                    rescan()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        } else {
                            VStack {
                                Text("0").font(.system(size: 24, weight: .bold, design: .monospaced))
                                    .foregroundColor(M.accent)
                                Text("路由冲突").font(.dsBody).foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(DS.Spacing.l)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Palette.cardBg))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(DS.Palette.cardBgAlt))

                    // Topology view of the network routing relation map
                    SdwanTopologyView(ifaces: ifaces, routes: routes)

                    // interfaces
                    Card(title: "网络接口拓扑 · \(ifaces.count)", icon: "network") {
                        VStack(spacing: 4) {
                            if ifaces.isEmpty { Text("正在扫描接口…").font(.dsBody).foregroundColor(.secondary).padding() }
                            ForEach(ifaces.indices, id: \.self) { idx in
                                ifaceRow(ifaces[idx]).padding(.vertical, 4)
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
                                HStack {
                                    Text(routes[idx].dest).font(.dsMono)
                                    Spacer()
                                    Image(systemName: "arrow.right").font(.dsBody).foregroundColor(.secondary)
                                    Text(routes[idx].iface).font(.dsMono).foregroundColor(M.accent)
                                }
                                .padding(.vertical, 4)
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
                .padding(.horizontal, DS.Spacing.xl).padding(.bottom, DS.Spacing.xxl)
            }
        }
        .onAppear { rescan() }
    }

    private func ifaceRow(_ i: NetIface) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(i.kind)).foregroundColor(color(i.kind)).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(i.name).font(.dsMono).fontWeight(.medium)
                    Text(i.kind.rawValue).font(.dsBody)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(color(i.kind).opacity(0.15))).foregroundColor(color(i.kind))
                }
                Text(i.ipv4.joined(separator: ", ").isEmpty ? "无 IPv4" : i.ipv4.joined(separator: ", "))
                    .font(.dsMono).foregroundColor(.secondary)
            }
            Spacer()
            Circle().fill(i.isUp ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
        }
        .padding(.vertical, 3)
    }

    private func rescan() {
        ifaces = NetScanner.interfaces()
        routes = NetScanner.tunRoutes()
    }
    private func icon(_ k: IfaceKind) -> String {
        switch k {
        case .physical: return "wifi"
        case .proxyTun: return "shield.fill"
        case .tailscale: return "point.3.connected.trianglepath.dotted"
        case .zerotier: return "globe"
        case .oray: return "link"
        default: return "network"
        }
    }
    private func color(_ k: IfaceKind) -> Color {
        switch k {
        case .physical: return .blue
        case .proxyTun: return .green
        case .tailscale: return .teal
        case .zerotier: return .orange
        case .oray: return .purple
        default: return .secondary
        }
    }
}

