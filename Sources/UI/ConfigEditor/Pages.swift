// Pages.swift — All screens. Engine data via @EnvironmentObject AppState.
import SwiftUI

// ── Helpers ────────────────────────────────────────────────────
func fr(_ b: Double) -> String {
    if b >= 1_000_000 { return String(format: "%.1f MB/s", b / 1_000_000) }
    if b >= 1_000 { return String(format: "%.1f KB/s", b / 1_000) }
    return String(format: "%.0f B/s", b)
}
func fb(_ b: Double) -> String {
    if b >= 1_000_000_000 { return String(format: "%.2f GB", b / 1_000_000_000) }
    if b >= 1_000_000 { return String(format: "%.1f MB", b / 1_000_000) }
    if b >= 1_000 { return String(format: "%.1f KB", b / 1_000) }
    return "\(Int(b)) B"
}
func fl(_ ms: Int) -> String { ms > 0 ? "\(ms)ms" : "—" }
func lc(_ ms: Int) -> Color { ms <= 0 ? .secondary : ms < 80 ? .green : ms < 160 ? .orange : .red }

// ── Dashboard ──────────────────────────────────────────────────
struct DashboardPage: View {
    @EnvironmentObject var S: AppState
    var body: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                StatCard("下载", fr(S.traffic.down.last ?? 0), S.accentColor)
                StatCard("上传", fr(S.traffic.up.last ?? 0), nil)
                StatCard("连接", "\(S.stats.connections)", nil)
                StatCard("在线", S.stats.uptime, nil)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("实时流量").font(.caption).fontWeight(.semibold).foregroundColor(.secondary).padding(.horizontal, 12).padding(.top, 10)
                    ChartView(model: S.traffic, accent: S.accentColor).frame(height: 200).padding(6)
                }.background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                VStack(alignment: .leading, spacing: 6) {
                    Text("引擎").font(.caption).fontWeight(.semibold).foregroundColor(.secondary).padding(.horizontal, 12).padding(.top, 10)
                    VStack(spacing: 8) {
                        HStack { Text("版本").font(.caption).foregroundColor(.secondary); Spacer(); Text("v\(S.stats.version)").font(.caption.monospaced()) }
                        HStack { Text("模式").font(.caption).foregroundColor(.secondary); Spacer(); Text(S.mode).font(.caption) }
                        HStack { Text("TUN").font(.caption).foregroundColor(.secondary); Spacer(); Text(S.realConfig["tun"] is [String:Any] ? "enabled" : "off").font(.caption) }
                    }.padding(.horizontal, 12).padding(.bottom, 10)
                }.background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            }
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer").font(.caption).foregroundColor(.secondary)
                Text("代理链路").font(.caption).foregroundColor(.secondary)
                Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                Text(S.selectedNodes.first?.value ?? "—").font(.caption).fontWeight(.semibold).foregroundColor(S.accentColor)
                Spacer()
            }.padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }
}

func StatCard(_ label: String, _ value: String, _ c: Color?) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(label).font(.caption).foregroundColor(.secondary)
        Text(value).font(.title2.monospaced()).fontWeight(.bold).foregroundColor(c ?? .primary)
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
}

struct ChartView: View {
    @ObservedObject var model: TrafficModel; let accent: Color
    var body: some View {
        Canvas { ctx, size in
            guard model.down.count > 2 else { return }
            let data = Array(model.down.suffix(120)); let mx = data.max() ?? 1
            let h = size.height; let w = size.width; let sx = w / CGFloat(data.count - 1)
            var p = Path()
            for (i, v) in data.enumerated() {
                let x = CGFloat(i) * sx; let y = h - (CGFloat(v) / CGFloat(mx) * h * 0.9)
                if i == 0 { p.move(to: CGPoint(x: 0, y: h)) }; p.addLine(to: CGPoint(x: x, y: y))
            }
            p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath()
            ctx.fill(p, with: .linearGradient(Gradient(colors: [accent.opacity(0.3), accent.opacity(0.02)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: 1)))
        }
    }
}

// ── Proxies ────────────────────────────────────────────────────
struct ProxiesPage: View {
    @EnvironmentObject var S: AppState
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: { S.testNodes(S.nodes.map(\.id)) }) { Label("全部测速", systemImage: "bolt.fill") }
                Spacer()
            }
            if S.groups.isEmpty { Text("正在加载…").foregroundColor(.secondary).padding() }
            ForEach(S.groups) { g in
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.name).font(.callout).fontWeight(.semibold)
                            Text(g.kind + " → " + (S.selectedNodes[g.id] ?? g.now)).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer(); Text("\(g.members.count)").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.08)))
                    }.padding(.horizontal, 14).padding(.vertical, 10)
                    Divider().padding(.leading, 14)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 2) {
                        ForEach(g.members, id: \.self) { mid in
                            let p = S.resolveProxy(mid); let on = (S.selectedNodes[g.id] ?? g.now) == mid
                            Button(action: { S.selectNode(groupID: g.id, nodeID: mid) }) {
                                HStack(spacing: 6) {
                                    VStack(alignment: .leading) { Text(p?.name ?? mid).font(.caption).fontWeight(on ? .bold : .regular).foregroundColor(on ? S.accentColor : .primary); if let t = p?.type { Text(t).font(.caption2).foregroundColor(.secondary) } }
                                    Spacer()
                                    if let ms = S.latencies[mid] { Text(fl(ms)).font(.caption2.monospaced()).foregroundColor(lc(ms)) }
                                    if on { Image(systemName: "checkmark").font(.caption).foregroundColor(S.accentColor) }
                                }.padding(.horizontal, 14).padding(.vertical, 5).background(on ? S.accentColor.opacity(0.08) : Color.clear).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 4)
                }.background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            }
        }
    }
}

// ── Connections ────────────────────────────────────────────────
struct ConnectionsPage: View {
    @EnvironmentObject var S: AppState; @State private var q = ""; @State private var f = "all"
    var body: some View {
        let rows = S.connections.filter { c in
            if f == "proxy" && c.node == "DIRECT" { return false }; if f == "direct" && c.node != "DIRECT" { return false }
            if !q.isEmpty && !"\(c.host)\(c.ip)\(c.proc)".localizedCaseInsensitiveContains(q) { return false }; return true
        }
        VStack(spacing: 10) {
            HStack { TextField("搜索…", text: $q).textFieldStyle(.roundedBorder).frame(width: 200); Picker("", selection: $f) { Text("全部(\(S.connections.count))").tag("all"); Text("代理").tag("proxy"); Text("直连").tag("direct") }.pickerStyle(.segmented).frame(width: 180); Spacer(); Text("\(rows.count) 条").font(.caption).foregroundColor(.secondary) }
            if rows.isEmpty { Text("无活跃连接").foregroundColor(.secondary).padding() }
            else { Table(rows) { TableColumn("目标") { c in VStack(alignment:.leading) { Text(c.host).font(.caption).fontWeight(.medium); Text("\(c.ip):\(c.port)").font(.caption2.monospaced()).foregroundColor(.secondary) } }; TableColumn("进程", value: \.proc); TableColumn("链路") { c in Text(c.chain).font(.caption).foregroundColor(c.node=="DIRECT" ? .secondary : S.accentColor) }; TableColumn("速率") { c in Text(fr(Double(c.dlSpeed))).font(.caption.monospaced()) }; TableColumn("总量") { c in Text(fb(Double(c.up+c.down))).font(.caption.monospaced()).foregroundColor(.secondary) } }.tableStyle(.bordered) }
        }
    }
}

// ── DNS ────────────────────────────────────────────────────────
struct DnsPage: View { var body: some View { Text("DNS 缓存需引擎启用 fake-ip").foregroundColor(.secondary).padding() } }

// ── Logs ───────────────────────────────────────────────────────
struct LogsPage: View {
    @State private var logs: [LogLine] = []; @State private var paused = false; @State private var lv = "all"; @State private var q = ""; @State private var ctr = 0
    var body: some View {
        let shown = logs.filter { (lv == "all" || $0.level.rawValue == lv) && (q.isEmpty || $0.msg.localizedCaseInsensitiveContains(q)) }
        VStack(spacing: 8) {
            HStack { TextField("过滤…", text: $q).textFieldStyle(.roundedBorder).frame(width: 200); Picker("", selection: $lv) { ForEach(["all","info","debug","warning","error"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).frame(width: 280); Button(paused ? "继续" : "暂停") { paused.toggle() }.font(.caption).buttonStyle(.bordered); Spacer() }
            ScrollViewReader { proxy in ScrollView { LazyVStack(alignment:.leading,spacing:1) { ForEach(shown) { l in HStack(spacing:6) { Text(l.time).font(.system(size:10,design:.monospaced)).foregroundColor(.secondary).frame(width:80); Text(l.level.rawValue.uppercased()).font(.system(size:9,weight:.bold)).padding(.horizontal,5).padding(.vertical,1).background(Capsule().fill(lvCol(l.level).opacity(0.15))).foregroundColor(lvCol(l.level)); Text(l.msg).font(.system(size:11,design:.monospaced)).lineLimit(2) }.id(l.id) } }.padding(6) }.onChange(of: logs.count) { if !paused, let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) } } }.background(RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(0.02))) }.onAppear { gen() }
    }
    func gen() { Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { _ in guard !self.paused else { return }; self.ctr += 1; let msgs = ["[TCP] connect","[DNS] resolve -> fake-ip","[Sniffer] TLS SNI","[Pool] readv batch","[Proxy] failover"]; let lvls: [LogLine.LogLevel] = [.info,.info,.debug,.warning,.error]; let df = DateFormatter(); df.dateFormat = "HH:mm:ss.SSS"; self.logs.append(LogLine(id: self.ctr, time: df.string(from: Date()), level: lvls[self.ctr % lvls.count], msg: msgs[self.ctr % msgs.count])); if self.logs.count > 250 { self.logs.removeFirst(min(self.logs.count, self.logs.count - 250)) } } }
    func lvCol(_ l: LogLine.LogLevel) -> Color { switch l { case .debug: return .gray; case .info: return .blue; case .warning: return .orange; case .error: return .red } }
}

// ── Config ─────────────────────────────────────────────────────
struct ConfigPage: View {
    @EnvironmentObject var S: AppState; @State private var vm = "yaml"; @State private var showImporter = false; @State private var manualYAML = ""
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Picker("", selection: $vm) { Text("YAML").tag("yaml"); Text("表单").tag("form") }.pickerStyle(.segmented).frame(width: 160)
                Spacer()
                Button("导入本地 YAML…") { showImporter = true }.buttonStyle(.bordered)
                Button("应用") { Task { if let ok = try? await S.engineClient.setConfig(yaml: manualYAML.isEmpty ? S.configYAML : manualYAML), ok { S.toast("配置已热重载") } } }.buttonStyle(.borderedProminent).tint(S.accentColor)
            }
            if vm == "yaml" {
                TextEditor(text: $manualYAML).font(.system(size: 11, design: .monospaced)).frame(minHeight: 500)
                    .onAppear { if manualYAML.isEmpty && !S.configYAML.isEmpty { manualYAML = S.configYAML } }
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    FormCard(t: "端口") { KVR("Mixed", "\(S.realConfig["mixed-port"] ?? "—")"); KVR("SOCKS", "\(S.realConfig["socks-port"] ?? "—")") }
                    FormCard(t: "模式") { Text(S.mode).font(.caption) }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.yaml, .plainText]) { result in
            if case .success(let url) = result, url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? String(contentsOf: url, encoding: .utf8) {
                    manualYAML = data
                    Task { if let ok = try? await S.engineClient.setConfig(yaml: data), ok { S.toast("已导入: \(url.lastPathComponent)") } }
                }
            }
        }
    }
}

func KVR(_ l: String, _ v: String) -> some View {
    HStack { Text(l).font(.caption).foregroundColor(.secondary); Spacer(); Text(v).font(.caption.monospaced()) }
}

struct FormCard<Content: View>: View {
    let t: String; @ViewBuilder let c: () -> Content
    var body: some View { VStack(alignment:.leading,spacing:6) { Text(t).font(.caption).fontWeight(.semibold).foregroundColor(.secondary); c() }.padding(12).background(RoundedRectangle(cornerRadius:10).fill(Color.primary.opacity(0.04))) }
}

// ── Settings ──────────────────────────────────────────────────
struct SettingsPage: View {
    @EnvironmentObject var S: AppState; @State private var ks = "运行中"
    var body: some View {
        VStack(spacing: 14) {
            FormCard(t: "内核控制") {
                HStack { HStack(spacing:6) { Circle().fill(ks=="运行中" ? .green : .red).frame(width:8,height:8); Text(ks).font(.callout).fontWeight(.semibold) }; Spacer(); Button("重启",systemImage:"arrow.triangle.2.circlepath"){ks="重启中…";Task{try? await S.engineClient.shutdownEngine();try? await Task.sleep(nanoseconds:3_000_000_000);ks="运行中"}}.buttonStyle(.bordered).tint(.orange); Button("停止",systemImage:"stop.fill"){ks="已停止";S.running=false;S.traffic.stop()}.buttonStyle(.bordered).tint(.red) }
            }
            FormCard(t: "系统代理") {
                Toggle("HTTP 代理", isOn: .constant(true))
                HStack { Text("地址").font(.caption).foregroundColor(.secondary); Spacer(); Text("127.0.0.1:\(S.realConfig["mixed-port"] ?? "7890")").font(.caption.monospaced()) }
            }
            FormCard(t: "外观") {
                Toggle("深色模式", isOn: $S.isDark)
                HStack { Text("强调色").font(.caption).foregroundColor(.secondary); Spacer(); ForEach([Color.green,.blue,.purple,.orange],id:\.self){c in Circle().fill(c).frame(width:20,height:20).overlay(Circle().stroke(Color.white.opacity(c==S.accentColor ? 1:0),lineWidth:2)).onTapGesture{S.accentColor=c} } }
            }
        }
    }
}

// ── MenuBar ───────────────────────────────────────────────────
struct MenuBarPanel: View {
    @EnvironmentObject var S: AppState
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack { Image(systemName:"bolt.fill").foregroundColor(S.accentColor).font(.title3); VStack(alignment:.leading){Text("ClashPow").fontWeight(.bold);HStack(spacing:4){Circle().fill(S.running ? .green:.orange).frame(width:5,height:5);Text(S.running ? "运行中":"已暂停").font(.caption2);Text("· v\(S.stats.version)").font(.caption2).foregroundColor(.secondary)}};Spacer();Toggle("",isOn:Binding(get:{S.running},set:{_,_ in S.togglePause()})).scaleEffect(0.8) }.padding(14)
            Divider()
            VStack(spacing:6){ HStack{Circle().fill(S.accentColor).frame(width:5,height:5);Text("下载").font(.caption).foregroundColor(.secondary);Text(fr(S.traffic.down.last ?? 0)).font(.caption.monospaced()).fontWeight(.bold);Spacer()};HStack{Text("代理").font(.caption2).foregroundColor(.secondary);Spacer();Text(S.selectedNodes.first?.value ?? "—").font(.caption).foregroundColor(S.accentColor)} }.padding(14)
            Divider()
            HStack{Button(action:S.togglePause){Label(S.running ? "暂停":"恢复",systemImage:S.running ? "pause.fill":"play.fill")}.buttonStyle(.borderedProminent).tint(.secondary).controlSize(.small);Button(action:S.repairNet){Label("修复",systemImage:"wrench.fill")}.buttonStyle(.borderedProminent).controlSize(.small)}.padding(14)
            Button("退出 ClashPow"){NSApplication.shared.terminate(nil)}.font(.caption).frame(maxWidth:.infinity).padding(.bottom,8)
        }.frame(width:280)
    }
}
