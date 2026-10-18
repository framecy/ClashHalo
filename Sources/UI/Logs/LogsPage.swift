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
            // P2-3：手搓顶栏改为共享 PageToolbar —— 左侧级别分段器 + 搜索，
            // 右侧暂停/导出/行数，高度与分割线与其它页同一条契约。
            PageToolbar(leading: {
                // P1-8：选项集合只有一份（AppModel.logLevelOptions），与设置页
                // 完全同源；`SILENT` 也在段里，选了它日志就停止追加，而不是让
                // 四个段全都不选中、界面看起来坏掉。
                DSSegmentedControl(selection: Binding(get: { VM.logLevel }, set: { VM.changeLogLevel($0) }),
                                   choices: AppModel.logLevelOptions.map { DSChoice($0.label, $0.value) })
                .frame(width: 320)
                .help("日志订阅级别（服务端过滤）。默认 WARN，避免每条连接刷屏；SILENT 停止日志推送。")

                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.dsBody)
                    TextField("过滤日志内容…", text: $q)
                        .textFieldStyle(.plain)
                        .font(.dsBody)
                }
                .dsSearchFieldChrome(maxWidth: 220)
            }, actions: {
                Button { paused.toggle(); if paused { frozen = VM.logs } } label: {
                    Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill")
                }
                .dsButton()

                Button { exportLogs(rows) } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .dsButton()

                HStack(spacing: DS.Spacing.s - 2) {
                    Circle().fill(paused ? Color.secondary : DS.Palette.accent).frame(width: 6, height: 6)
                    Text("\(rows.count) 行").font(.dsMono).foregroundColor(.secondary)
                }
            })
            if source.isEmpty {
                ContentUnavailable("等待日志流…", "doc.text.magnifyingglass")
            } else {
                ScrollViewReader { sp in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DS.Spacing.xs / 2) {
                            ForEach(rows.reversed()) { l in
                                HStack(alignment: .top, spacing: DS.Spacing.s) {
                                    Text(l.time).font(.dsMono).foregroundColor(.secondary)
                                    Text(l.level.uppercased()).font(.dsBodyBold)
                                        .foregroundColor(logColor(l.level)).frame(width: 46, alignment: .leading)
                                    Text(l.text).font(.dsMono).textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, DS.Spacing.m)
                                .padding(.vertical, 1)
                                .id(l.id)
                            }
                        }.padding(.vertical, DS.Spacing.xs)
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

    func changeLogLevel(_ level: String) {
        guard level != logLevel else { return }

        logs.removeAll(keepingCapacity: true)
        logBuffer.removeAll(keepingCapacity: true)
        logWS?.cancel()

        // 写入内核持久化（log-level 是 load-time-only，需 patchPersistent）
        Task {
            // 返回值不在这里用：失败时事务已回滚并弹了错误 toast，而 logLevel
            // 仍读 M.configs 里的旧级别，下面照样要重订阅 —— 上面已经把列表
            // 清空、WS 取消了，不重订阅才会让界面看起来“日志坏了”。
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
            logs.removeFirst(logs.count - 300)
        }
    }
}

