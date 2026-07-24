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
            PageHead(title: "日志") {
                Button { paused.toggle(); if paused { frozen = VM.logs } } label: {
                    Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill")
                }
                .dsButton(paused ? .prominent : .secondary)

                Button { VM.clear(); frozen = [] } label: { Label("清空", systemImage: "xmark") }
                    .dsButton()

                Button { exportLogs(rows) } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .dsButton()
            }

            // 搜索 + 级别 chips（chips 为订阅级别，服务端过滤）
            HStack(alignment: .center, spacing: DS.Spacing.s) {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.dsBody)
                    TextField("过滤日志内容…", text: $q)
                        .textFieldStyle(.plain)
                        .font(.dsBody)
                }
                .dsSearchFieldChrome(maxWidth: 240)

                ForEach(Self.levels, id: \.0) { key, label in
                    DSFilterChip(title: label, selected: VM.logLevel == key) {
                        VM.changeLogLevel(key)
                    }
                }
                .help("日志订阅级别（服务端过滤）。DEBUG 最全，WARN 可避免每条连接刷屏。")

                Spacer(minLength: DS.Spacing.s)

                HStack(spacing: 5) {
                    DSDot(color: paused ? DS.Palette.textFaint : DS.Palette.accent, size: 6)
                    Text(paused ? "已暂停" : "实时")
                        .font(.dsCaption).foregroundColor(.secondary)
                    Text("· \(rows.count) 行")
                        .font(.dsMonoSm).monospacedDigit().foregroundColor(DS.Palette.textFaint)
                }
            }
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.bottom, DS.Spacing.m)

            // 日志流 — 原型 `.log-stream`：recessed 面板 + mono 11.5 行
            Group {
                if source.isEmpty {
                    ContentUnavailable("等待日志流…", "doc.text.magnifyingglass")
                } else {
                    ScrollViewReader { sp in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(rows.reversed()) { l in
                                    logRow(l).id(l.id)
                                }
                            }
                            .padding(.vertical, DS.Spacing.s)
                        }
                        .onChange(of: VM.logs.count) {
                            // Newest-first: keep the latest line pinned to the top.
                            if !paused, let newest = rows.last {
                                withAnimation { sp.scrollTo(newest.id, anchor: .top) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Shape.card().fill(DS.Palette.inputBg))
            .overlay(DS.Shape.card().strokeBorder(DS.Palette.border, lineWidth: 0.5))
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.bottom, DS.Spacing.l)
        }
        .onAppear {
            VM.start()
        }
        .onDisappear {
            VM.stop()
        }
    }

    /// 订阅级别 chips — 键为 mihomo `log-level` 取值。
    private static let levels: [(String, String)] = [
        ("debug", "DEBUG"), ("info", "INFO"), ("warning", "WARN"), ("error", "ERROR")
    ]

    /// 单行日志 — 原型 `.log-line`：time(faint) · level(58pt 定宽粗体) · msg(dim)。
    private func logRow(_ l: Log) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(l.time)
                .font(.dsMonoSm)
                .foregroundColor(DS.Palette.textFaint)
            Text(l.level.uppercased())
                .font(.dsMonoSmBold)
                .foregroundColor(logColor(l.level))
                .frame(width: 58, alignment: .leading)
            Text(l.text)
                .font(.dsMonoSm)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exportLogs(_ rows: [Log]) {
        let text = rows.map { "\($0.time) [\($0.level.uppercased())] \($0.text)" }.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clashhalo-logs.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            M.showToast("已导出 \(rows.count) 行日志", kind: .ok)
        }
    }
    private func logColor(_ l: String) -> Color {
        switch l { case "warning": return DS.Palette.warn; case "error": return DS.Palette.error; case "debug": return .secondary; default: return DS.Palette.info }
    }
}

@MainActor final class LogsViewModel: ObservableObject {
    @Published var logs: [Log] = []

    private var logWS: WSHandle?
    private var logBuffer: [Log] = []
    private var logFlushTimer: Timer?
    private var logSeq = 0
    private let api = MihomoClient.shared
    private let M = AppModel.shared

    /// 日志级别从 M.configs["log-level"] 读取，修改时写回内核
    var logLevel: String {
        (M.configs["log-level"] as? String) ?? "warning"
    }

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

    /// 清空当前已缓冲的日志（不影响订阅）。
    func clear() {
        logs.removeAll(keepingCapacity: true)
        logBuffer.removeAll(keepingCapacity: true)
    }

    func changeLogLevel(_ level: String) {
        guard level != logLevel else { return }

        logs.removeAll(keepingCapacity: true)
        logBuffer.removeAll(keepingCapacity: true)
        logWS?.cancel()

        // 写入内核持久化（log-level 是 load-time-only，需 patchPersistent）
        Task {
            await M.patchPersistent(["log-level": level])
            subscribeLogs()
        }
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

        if logs.count > 300 {
            logs = Array(logs.suffix(300))
        }
    }
}

