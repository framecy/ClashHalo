import SwiftUI

// MARK: - Logs

struct LogsPage: View {
    @EnvironmentObject var M: AppModel
    @State private var q = ""
    @State private var paused = false
    @State private var frozen: [Log] = []

    var body: some View {
        let source = paused ? frozen : M.logs
        let rows = source.filter {
            q.isEmpty || $0.text.localizedCaseInsensitiveContains(q)
        }
        VStack(spacing: 0) {
            PageHead(title: "实时日志", desc: "结构化日志流 · 核心运行状态") {
                Button { paused.toggle(); if paused { frozen = M.logs } } label: {
                    Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill")
                }.controlSize(.small)
                Button { exportLogs(rows) } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .controlSize(.small)
            }

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("过滤日志内容…", text: $q).textFieldStyle(.plain).frame(maxWidth: 200)
                }
                Picker("", selection: Binding(get: { M.logLevel }, set: { M.changeLogLevel($0) })) {
                    Text("DEBUG").tag("debug"); Text("INFO").tag("info")
                    Text("WARN").tag("warning"); Text("ERROR").tag("error")
                }.pickerStyle(.segmented).frame(width: 300).labelsHidden()
                    .help("日志订阅级别（服务端过滤）。默认 WARN，避免每条连接刷屏。")
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(paused ? Color.secondary : M.accent).frame(width: 6, height: 6)
                    Text("\(rows.count) 行").font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
            Divider()
            ScrollViewReader { sp in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { l in
                            HStack(alignment: .top, spacing: 8) {
                                Text(l.time).font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
                                Text(l.level.uppercased()).font(.system(size: 12, weight: .bold))
                                    .foregroundColor(logColor(l.level)).frame(width: 46, alignment: .leading)
                                Text(l.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 1)
                            .id(l.id)
                        }
                    }.padding(.vertical, 6)
                }
                .onChange(of: M.logs.count) {
                    if !paused, let last = rows.last { withAnimation { sp.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if source.isEmpty {
                ContentUnavailable("等待日志流…", "doc.text.magnifyingglass").frame(maxHeight: .infinity)
            }
        }
    }

    private func exportLogs(_ rows: [Log]) {
        let text = rows.map { "\($0.time) [\($0.level.uppercased())] \($0.text)" }.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clashpow-logs.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            M.showToast("已导出 \(rows.count) 行日志")
        }
    }
    private func logColor(_ l: String) -> Color {
        switch l { case "warning": return .orange; case "error": return .red; case "debug": return .secondary; default: return .blue }
    }
}

