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
            HStack(alignment: .center, spacing: DS.Spacing.m) {
                DSSegmentedControl(selection: Binding(get: { VM.logLevel }, set: { VM.changeLogLevel($0) }), choices: [
                    DSChoice("DEBUG", "debug"),
                    DSChoice("INFO", "info"),
                    DSChoice("WARN", "warning"),
                    DSChoice("ERROR", "error")
                ])
                .frame(width: 240)
                .help("日志订阅级别（服务端过滤）。默认 WARN，避免每条连接刷屏。")

                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.dsBody)
                    TextField("过滤日志内容…", text: $q)
                        .textFieldStyle(.plain)
                        .font(.dsBody)
                }
                .dsSearchFieldChrome(maxWidth: 220)

                Spacer(minLength: 0)

                HStack(spacing: DS.Spacing.s) {
                    Button { paused.toggle(); if paused { frozen = VM.logs } } label: {
                        Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill")
                    }
                    .dsButton()

                    Button { exportLogs(rows) } label: { Label("导出", systemImage: "square.and.arrow.up") }
                        .dsButton()

                }

                HStack(spacing: DS.Spacing.s - 2) {
                    Circle().fill(paused ? Color.secondary : DS.Palette.accent).frame(width: 6, height: 6)
                    Text("\(rows.count) 行").font(.dsMono).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.vertical, DS.Spacing.m)
            .frame(height: DS.Layout.chromeHeight, alignment: .center)
            .background(DS.Palette.chromeBg)
            Divider().overlay(DS.Palette.separator)
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

