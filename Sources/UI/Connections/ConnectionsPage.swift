import SwiftUI

// MARK: - Connections

struct ConnectionsPage: View {
    @EnvironmentObject var M: AppModel
    @State private var q = ""
    @State private var showConfirmDisconnect = false

    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "连接", desc: "\(M.conns.count) 个活跃连接 · 实时速率") {
                Button(role: .destructive) { showConfirmDisconnect = true } label: { Label("全部断开", systemImage: "xmark.circle") }
                    .controlSize(.small)
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索域名 / 进程 / 规则", text: $q).textFieldStyle(.plain)
                Spacer()
                Text("\(M.conns.filter { matches($0) }.count) 匹配").font(.dsBody).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
            Divider()

            let rows = M.conns.filter { matches($0) }
            if rows.isEmpty {
                ContentUnavailable(q.isEmpty ? "暂无活跃连接" : "无匹配结果", "point.3.connected.trianglepath.dotted")
                    .frame(maxHeight: .infinity)
            } else {
                Table(rows) {
                    TableColumn("目标") { c in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.host).font(.dsBodyMedium).lineLimit(1)
                            Text("\(c.dstIP):\(c.port)").font(.dsMono).foregroundColor(.secondary)
                        }
                    }.width(min: 180, ideal: 240)
                    TableColumn("进程") { c in Text(c.process).font(.dsBody).foregroundColor(.secondary).lineLimit(1) }.width(min: 80, ideal: 120)
                    TableColumn("规则") { c in Text(c.rule).font(.dsMono).foregroundColor(.secondary).lineLimit(1) }.width(min: 100, ideal: 150)
                    TableColumn("链路") { c in
                        HStack(spacing: 4) {
                            Text(c.chain).font(.dsBodySemibold).foregroundColor(c.category == "proxy" ? M.accent : .secondary).lineLimit(1)
                            Text(c.node).font(.dsMono).foregroundColor(.secondary)
                        }
                    }.width(min: 120, ideal: 180)
                    TableColumn("↓") { c in Text(fmtRate(Double(c.downRate))).font(.dsMono) }.width(70)
                    TableColumn("↑") { c in Text(fmtRate(Double(c.upRate))).font(.dsMono).foregroundColor(.secondary) }.width(70)
                    TableColumn("") { c in
                        Button { M.closeConnection(id: c.id) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).foregroundColor(.secondary).help("断开此连接")
                    }.width(36)
                }
            }
        }
        .confirmationDialog("确定要断开所有连接吗？", isPresented: $showConfirmDisconnect, titleVisibility: .visible) {
            Button("确定断开", role: .destructive) { M.closeAllConnections() }
        } message: {
            Text("这将中断所有正在进行的网络会话")
        }
    }

    private func matches(_ c: Conn) -> Bool {
        q.isEmpty || "\(c.host)\(c.process)\(c.chain)\(c.rule)".localizedCaseInsensitiveContains(q)
    }
}

