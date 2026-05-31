// ContentView.swift — NavigationSplitView sidebar + content area
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var S: AppState
    var body: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(220)
        } detail: {
            VStack(spacing: 0) {
                // Title bar
                HStack(spacing: 8) {
                    Text(titles[S.route] ?? "ClashPow").font(.headline).fontWeight(.semibold)
                    Spacer()
                    HStack(spacing: 4) {
                        Circle().fill(S.running ? Color.green : Color.orange).frame(width: 6, height: 6)
                        Text("v\(S.stats.version)").font(.caption2.monospaced()).foregroundColor(.secondary)
                    }
                    Button(action: S.togglePause) {
                        Image(systemName: S.running ? "pause.fill" : "play.fill")
                    }
                    Button(action: { S.route = "settings" }) { Image(systemName: "gearshape") }
                }
                .padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)

                // Page content
                ScrollView(showsIndicators: false) {
                    pageContent.padding(16)
                }
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .overlay(alignment: .bottom) {
            if let m = S.toastMessage {
                Text(m).font(.caption).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    let titles = ["dashboard":"仪表盘","proxies":"代理","connections":"连接","dns":"DNS 缓存","logs":"日志","config":"配置编辑","settings":"设置"]

    @ViewBuilder var pageContent: some View {
        switch S.route {
        case "proxies": ProxiesPage().environmentObject(S)
        case "connections": ConnectionsPage().environmentObject(S)
        case "dns": DnsPage()
        case "logs": LogsPage()
        case "config": ConfigPage().environmentObject(S)
        case "settings": SettingsPage().environmentObject(S)
        default: DashboardPage().environmentObject(S)
        }
    }
}

// ── Sidebar ────────────────────────────────────────────────────
struct SidebarView: View {
    @EnvironmentObject var S: AppState
    struct Item: Identifiable { let id: String; let label: String; let icon: String; let group: String }
    let items: [Item] = [
        .init(id:"dashboard",label:"仪表盘",icon:"gauge.with.dots.needle.33percent",group:"概览"),
        .init(id:"proxies",label:"代理",icon:"paperplane.fill",group:"代理"),
        .init(id:"connections",label:"连接",icon:"point.3.connected.trianglepath.dotted",group:"代理"),
        .init(id:"dns",label:"DNS 缓存",icon:"server.rack",group:"网络"),
        .init(id:"logs",label:"日志",icon:"doc.text.magnifyingglass",group:"网络"),
        .init(id:"config",label:"配置编辑",icon:"slider.horizontal.3",group:"配置"),
        .init(id:"settings",label:"设置",icon:"gearshape.fill",group:"配置"),
    ]
    var body: some View {
        List(selection: $S.route) {
            Section {
                VStack(alignment:.leading,spacing:4) {
                    HStack(spacing:6) {
                        Circle().fill(S.running ? Color.green : Color.orange).frame(width:6,height:6)
                        Text(S.running ? "运行中" : "已暂停").font(.caption)
                        Spacer()
                        Text(S.mode).font(.caption2).padding(.horizontal,6).padding(.vertical,2).background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    Text(S.selectedNodes.first?.value ?? "代理").font(.callout).fontWeight(.semibold).foregroundColor(S.accentColor)
                    Text(frate(S.traffic.down.last ?? 0)).font(.caption).monospaced().foregroundColor(.secondary)
                }.padding(.vertical,4)
            }
            ForEach(["概览","代理","网络","配置"],id:\.self){g in
                Section(g){ ForEach(items.filter{$0.group==g}){it in Label(it.label,systemImage:it.icon).tag(it.id) } }
            }
        }.listStyle(.sidebar).navigationTitle("ClashPow")
    }
}

// ── Helpers ─────────────────────────────────────────────────────
func frate(_ b:Double)->String {
    if b>=1_000_000{return String(format:"%.1f MB/s",b/1_000_000)}
    if b>=1_000{return String(format:"%.1f KB/s",b/1_000)}
    return String(format:"%.0f B/s",b)
}
func fbytes(_ b:Double)->String {
    if b>=1_000_000_000{return String(format:"%.2f GB",b/1_000_000_000)}
    if b>=1_000_000{return String(format:"%.1f MB",b/1_000_000)}
    if b>=1_000{return String(format:"%.1f KB",b/1_000)}
    return "\(Int(b)) B"
}
func flat(_ ms:Int)->String{ms>0 ? "\(ms)ms":"—"}
func lcolor(_ ms:Int)->Color{ms<=0 ? .secondary:ms<80 ? .green:ms<160 ? .orange:.red}
