// DashboardPage — overview: traffic chart, totals, engine info, current chain.
import SwiftUI

struct DashboardPage: View {
    @EnvironmentObject var M: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Stat tiles
                HStack(spacing: 12) {
                    Tile("下载", fmtRate(Double(M.curDown)), "arrow.down.circle.fill", M.accent)
                    Tile("上传", fmtRate(Double(M.curUp)), "arrow.up.circle.fill", .blue)
                    Tile("连接", "\(M.conns.count)", "link.circle.fill", .purple)
                    Tile("内存", fmtBytes(Double(M.memory)), "memorychip.fill", .orange)
                }

                // Traffic chart — GPU-rendered (Metal, up to 120fps) from the
                // engine's high-res mmap stats; falls back to WS series if no engine.
                Card(title: "实时流量 · Metal") {
                    ZStack(alignment: .topLeading) {
                        MetalTrafficView(accent: NSColor(M.accent))
                            .frame(height: 210)
                        HStack(spacing: 12) {
                            Label(fmtRate(Double(M.curDown)), systemImage: "arrow.down").foregroundColor(M.accent)
                            Label(fmtRate(Double(M.curUp)), systemImage: "arrow.up").foregroundColor(.blue)
                        }
                        .font(.caption2.monospaced()).padding(8)
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    // Current chain
                    Card(title: "当前出口") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "desktopcomputer").foregroundColor(.secondary)
                                Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                                Text(modeLabel(M.mode)).font(.caption)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Capsule().fill(M.accent.opacity(0.15)))
                                    .foregroundColor(M.accent)
                                Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                                Text(M.currentProxyName()).font(.callout).fontWeight(.semibold).foregroundColor(M.accent)
                            }
                            HStack(spacing: 18) {
                                stat("累计下载", fmtBytes(Double(M.downloadTotal)))
                                stat("累计上传", fmtBytes(Double(M.uploadTotal)))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Engine info
                    Card(title: "内核") {
                        VStack(spacing: 9) {
                            kv("版本", M.version)
                            kv("模式", modeLabel(M.mode))
                            kv("代理组", "\(M.groups.count)")
                            kv("节点", "\(M.nodes.count)")
                            kv("规则", "\(M.configs["rules"] is [Any] ? (M.configs["rules"] as! [Any]).count : 0)")
                        }
                    }
                    .frame(width: 280)
                }

                Spacer(minLength: 0)
            }
            .padding(18)
        }
    }

    private func stat(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l).font(.caption2).foregroundColor(.secondary)
            Text(v).font(.callout.monospaced()).fontWeight(.medium)
        }
    }
    private func kv(_ l: String, _ v: String) -> some View {
        HStack { Text(l).font(.caption).foregroundColor(.secondary); Spacer(); Text(v).font(.caption.monospaced()) }
    }
}

// MARK: - Stat tile

struct Tile: View {
    let label: String, value: String, icon: String, color: Color
    init(_ l: String, _ v: String, _ i: String, _ c: Color) { label = l; value = v; icon = i; color = c }
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon).font(.title2).foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundColor(.secondary)
                Text(value).font(.title3.monospaced()).fontWeight(.semibold)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }
}

// MARK: - Traffic chart (filled area, download + upload)

struct TrafficChart: View {
    let down: [Double], up: [Double], accent: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxV = max(down.max() ?? 1, up.max() ?? 1, 1)
            ZStack {
                // grid
                ForEach(1..<4) { i in
                    let y = h * CGFloat(i) / 4
                    Path { p in p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: w, y: y)) }
                        .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                }
                area(down, w: w, h: h, maxV: maxV, color: accent)
                area(up, w: w, h: h, maxV: maxV, color: .blue)
            }
        }
    }
    private func area(_ data: [Double], w: CGFloat, h: CGFloat, maxV: Double, color: Color) -> some View {
        let n = max(data.count - 1, 1)
        return ZStack {
            Path { p in
                p.move(to: .init(x: 0, y: h))
                for (i, v) in data.enumerated() {
                    p.addLine(to: .init(x: w * CGFloat(i) / CGFloat(n), y: h - CGFloat(v / maxV) * h * 0.92))
                }
                p.addLine(to: .init(x: w, y: h)); p.closeSubpath()
            }
            .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            Path { p in
                for (i, v) in data.enumerated() {
                    let pt = CGPoint(x: w * CGFloat(i) / CGFloat(n), y: h - CGFloat(v / maxV) * h * 0.92)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            .stroke(color, lineWidth: 1.6)
        }
    }
}
