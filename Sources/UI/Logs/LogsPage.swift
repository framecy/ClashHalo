import SwiftUI

// MARK: - Logs

struct LogsPage: View {
    @EnvironmentObject var M: AppModel
    @StateObject private var VM = LogsViewModel()
    @State private var q = ""
    @State private var paused = false
    @State private var frozen: [Log] = []

    var body: some View {
        let source = paused ? frozen : VM.logs
        let rows = source.filter {
            q.isEmpty || $0.text.localizedCaseInsensitiveContains(q)
        }
        VStack(spacing: 0) {
            PageHead(title: "实时日志", desc: "结构化日志流 · 核心运行状态") {
                Button { paused.toggle(); if paused { frozen = VM.logs } } label: {
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
                Picker("", selection: Binding(get: { VM.logLevel }, set: { VM.changeLogLevel($0) })) {
                    Text("DEBUG").tag("debug"); Text("INFO").tag("info")
                    Text("WARN").tag("warning"); Text("ERROR").tag("error")
                }.pickerStyle(.segmented).frame(width: 300).labelsHidden()
                    .help("日志订阅级别（服务端过滤）。默认 WARN，避免每条连接刷屏。")
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(paused ? Color.secondary : M.accent).frame(width: 6, height: 6)
                    Text("\(rows.count) 行").font(.dsMono).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
            Divider()
            ScrollViewReader { sp in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows.reversed()) { l in
                            HStack(alignment: .top, spacing: 8) {
                                Text(l.time).font(.dsMono).foregroundColor(.secondary)
                                Text(l.level.uppercased()).font(.dsBodyBold)
                                    .foregroundColor(logColor(l.level)).frame(width: 46, alignment: .leading)
                                Text(l.text).font(.dsMono).textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 1)
                            .id(l.id)
                        }
                    }.padding(.vertical, 6)
                }
                .onChange(of: VM.logs.count) {
                    // Newest-first: keep the latest line pinned to the top.
                    if !paused, let newest = rows.last { withAnimation { sp.scrollTo(newest.id, anchor: .top) } }
                }
            }
            if source.isEmpty {
                ContentUnavailable("等待日志流…", "doc.text.magnifyingglass").frame(maxHeight: .infinity)
            }
        }
        .onAppear {
            VM.start()
        }
        .onDisappear {
            VM.stop()
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
        switch l { case "warning": return DS.Palette.warn; case "error": return DS.Palette.error; case "debug": return .secondary; default: return .blue }
    }
}

@MainActor final class LogsViewModel: ObservableObject {
    @Published var logs: [Log] = []
    
    // Mirror of UserPreferences
    @AppStorage("ui.logLevel") var logLevel = "warning"
    
    private var logWS: WSHandle?
    private var logBuffer: [Log] = []
    private var logFlushTimer: Timer?
    private var logSeq = 0
    private let api = MihomoClient.shared
    
    private static let logDF: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    
    func start() {
        guard api.reachable else { return }
        
        logs.removeAll()
        logBuffer.removeAll()
        
        // Subscribe to logs stream
        subscribeLogs()
        
        // Timer for flushing logs in batches (debounce)
        logFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.flushLogs()
            }
        }
    }
    
    func stop() {
        logWS?.cancel()
        logWS = nil
        logFlushTimer?.invalidate()
        logFlushTimer = nil
        
        // Completely clear memory
        logs.removeAll(keepingCapacity: false)
        logBuffer.removeAll(keepingCapacity: false)
    }
    
    func changeLogLevel(_ level: String) {
        guard level != logLevel else { return }
        logLevel = level
        
        logs.removeAll(keepingCapacity: true)
        logBuffer.removeAll(keepingCapacity: true)
        logWS?.cancel()
        
        subscribeLogs()
    }
    
    private func subscribeLogs() {
        guard api.reachable else { return }
        logWS = api.stream("/logs?level=\(logLevel)", type: LogTick.self) { [weak self] l in
            Task { @MainActor in
                self?.onLog(l)
            }
        }
    }
    
    private func onLog(_ l: LogTick) {
        logSeq += 1
        logBuffer.append(Log(id: logSeq, time: Self.logDF.string(from: Date()), level: l.type, text: l.payload))
    }
    
    private func flushLogs() {
        guard !logBuffer.isEmpty else { return }
        
        logs.append(contentsOf: logBuffer)
        logBuffer.removeAll(keepingCapacity: true)
        
        if logs.count > 150 {
            logs = Array(logs.suffix(150))
        }
    }
}

