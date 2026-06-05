import Foundation
import Combine
import SwiftUI
import Network
import SystemConfiguration

// Central app state & orchestration hub. Domain logic is split into extensions:
//   AppModel+Proxies.swift      — groups / nodes / selection / latency
//   AppModel+Connections.swift  — traffic / connections / dashboard / cache
//   AppModel+Config.swift       — profiles / config / switches / rules
// This file keeps the shared state and the lifecycle (start/reconnect/streams).

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    let api = MihomoClient.shared
    let engine = EngineControl.shared
    let store = ConfigStore()
    let history = TrafficHistory()

    // Navigation + theme
    @Published var route = "dashboard"
    @AppStorage("ui.dark") var dark = true
    @AppStorage("ui.accent") var accentRaw = "green"
    var accent: Color {
        let colors: [String: Color] = [
            "green": Color(hex: "19c37d"),
            "blue": .blue,
            "purple": .purple,
            "orange": .orange
        ]
        return colors[accentRaw] ?? Color(hex: "19c37d")
    }

    // Connection status
    @Published var reachable = false
    @Published var version = "?"
    @Published var mode = "rule"          // rule / global / direct
    @Published var memory: Int64 = 0
    @Published var uploadTotal: Int64 = 0
    @Published var downloadTotal: Int64 = 0

    // Proxies
    @Published var groups: [ProxyGroup] = []
    @Published var nodes: [String: Node] = [:]    // name → node
    @Published var testing: Set<String> = []

    // Connections (prevConnBytes/seenConnIDs/lastDownTotal are read in AppModel+Connections)
    @Published var conns: [Conn] = []
    @Published var dash = DashStats()   // precomputed once per snapshot (perf)
    var prevConnBytes: [String: (up: Int64, down: Int64)] = [:]

    // Logs
    @Published var logs: [Log] = []
    /// Kernel log subscription level (server-side filter). Defaults to `warning`
    /// so the panel isn't flooded by one line per connection (info level).
    @AppStorage("ui.logLevel") var logLevel = "warning"
    private var logBuffer: [Log] = []
    private var logFlushTimer: Timer?
    private var logSeq = 0

    // Traffic chart (rolling window of download bytes/s)
    @Published var downSeries: [Double] = Array(repeating: 0, count: 120)
    @Published var upSeries: [Double] = Array(repeating: 0, count: 120)
    @Published var curDown: Int64 = 0
    @Published var curUp: Int64 = 0

    // Config
    @Published var configs: [String: Any] = [:]

    // Rules (read-only; populated by refreshRules in AppModel+Config)
    @Published var rules: [RuleEntry] = []

    // Kernel Logs (Startup/Process logs)
    @Published var kernelLogs: [String] = []
    func logKernel(_ msg: String) {
        Task { @MainActor in
            let line = "[\(Self.logDF.string(from: Date()))] \(msg)"
            kernelLogs.append(line)
            if kernelLogs.count > 100 { kernelLogs.removeFirst() }
            print("KernelLog: \(msg)")
        }
    }

    // Master switches
    @Published var systemProxyOn = false
    @Published var tunOn = false

    // Dashboard session aggregates
    @Published var closedConns = 0
    @Published var appMemoryMB = 0.0
    var seenConnIDs = Set<String>()
    var lastDownTotal: Int64 = 0

    // Toast
    @Published var toast: String?

    private var pathMonitor: NWPathMonitor?
    private var signalSources: [AnyObject] = []
    private var networkOnline = true

    private var trafficWS: WSHandle?
    private var connWS: WSHandle?
    private var logWS: WSHandle?
    private var memWS: WSHandle?
    private var pollTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private static let logDF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    // MARK: Lifecycle

    func start() {
        // Inject log sinks so the engine/helper layers report events without
        // referencing AppModel directly (decoupling — they no longer call
        // AppModel.shared).
        engine.onLog = { [weak self] msg in self?.logKernel(msg) }
        XPCManager.shared.onLog = { [weak self] msg in
            Task { @MainActor in self?.logKernel(msg) }
        }
        engine.ensureInstalled()
        api.applyController(fromConfigAt: engine.configFilePath)   // B1: discover endpoint before probing
        engine.ensureRunning()   // Auto-start kernel if not responding
        store.load()
        history.load()
        syncSystemProxyState()   // Read actual macOS proxy state so the toggle matches reality
        logFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushLogs() }
        }
        Task { await reconnect() }
        startNetworkMonitor()
        installSignalHandlers()
        // Check helper version after initial pollStatus has had time to fetch it
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await engine.checkAndUpgradeHelperIfNeeded()
        }
    }

    func reconnect() async {
        stopStreams()

        // B1: re-discover the controller endpoint each reconnect, so a profile
        // switch that changes external-controller/secret is picked up.
        api.applyController(fromConfigAt: engine.configFilePath)

        // Purely observation-based: Is the official mihomo REST API responding?
        await api.probe()

        reachable = api.reachable
        version = api.version

        guard reachable else {
            // Core unreachable — TUN can't be active, so clear the switch to keep
            // the UI consistent (tunOn is normally driven by refreshConfigs, which
            // won't run while disconnected, leaving the toggle stuck "on").
            tunOn = false
            // Cancel any previous retry to avoid parallel reconnect races.
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.reconnect()
            }
            return
        }
        reconnectTask = nil   // connected — no retry pending

        syncSystemProxyState()   // re-sync after reconnect in case proxy was toggled externally
        startStreams()
        startPolling()
    }

    private func startStreams() {
        trafficWS = api.stream("/traffic", type: TrafficTick.self) { [weak self] t in
            Task { @MainActor in self?.onTraffic(t) }
        }
        connWS = api.stream("/connections", type: ConnectionsSnapshot.self) { [weak self] s in
            Task { @MainActor in self?.onConnections(s) }
        }
        logWS = api.stream("/logs?level=\(logLevel)", type: LogTick.self) { [weak self] l in
            Task { @MainActor in self?.onLog(l) }
        }
        // mihomo only computes runtime memory while /memory is being subscribed;
        // without this stream the kernel reports memory=0 (both here and in the
        // /connections snapshot). First frame is 0, subsequent frames are real.
        memWS = api.stream("/memory", type: MemoryTick.self) { [weak self] m in
            Task { @MainActor in if m.inuse > 0 { self?.memory = m.inuse } }
        }
    }

    /// Change the log subscription level (server-side filter) and reconnect just
    /// the log stream. Clears the buffer so stale higher-volume lines don't linger.
    func changeLogLevel(_ level: String) {
        guard level != logLevel else { return }
        logLevel = level
        logs.removeAll(keepingCapacity: true)
        logBuffer.removeAll(keepingCapacity: true)
        logWS?.cancel()
        guard reachable else { return }
        logWS = api.stream("/logs?level=\(level)", type: LogTick.self) { [weak self] l in
            Task { @MainActor in self?.onLog(l) }
        }
    }

    private func stopStreams() {
        trafficWS?.cancel(); connWS?.cancel(); logWS?.cancel(); memWS?.cancel()
        trafficWS = nil; connWS = nil; logWS = nil; memWS = nil
        pollTask?.cancel(); pollTask = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.reachable {
                await self.refreshProxies()
                await self.refreshConfigs()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // MARK: Logs

    private func onLog(_ l: LogTick) {
        // Buffer; a 0.5s timer flushes to @Published in one batch so a chatty
        // log stream doesn't re-render the whole UI on every line.
        logSeq += 1
        logBuffer.append(Log(id: logSeq, time: Self.logDF.string(from: Date()), level: l.type, text: l.payload))
    }
    private func flushLogs() {
        guard !logBuffer.isEmpty else { return }
        logs.append(contentsOf: logBuffer)
        logBuffer.removeAll(keepingCapacity: true)
        if logs.count > 500 { logs = Array(logs.suffix(500)) }
    }

    // MARK: Toast

    func showToast(_ s: String) {
        toast = s
        Task { try? await Task.sleep(nanoseconds: 2_400_000_000); toast = nil }
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { [weak self] in
                await self?.handleNetworkChange(online: online)
            }
        }
        monitor.start(queue: .global(qos: .background))
        pathMonitor = monitor
    }

    @MainActor private func handleNetworkChange(online: Bool) {
        guard networkOnline != online else { return }
        networkOnline = online
        if !online && systemProxyOn {
            // Network offline: disable system proxy immediately to prevent
            // all traffic being blocked by a proxy pointing to a dead kernel.
            let port = (configs["mixed-port"] as? Int) ?? (configs["port"] as? Int) ?? 7890
            Task {
                _ = await engine.setSystemProxy(enabled: false, port: port)
                systemProxyOn = false
                showToast("网络断开，已自动关闭系统代理")
            }
        }
    }

    /// Read the current macOS system proxy state and sync the toggle. Uses
    /// SCDynamicStoreCopyProxies which works without root — reads the effective
    /// merged proxy settings for the primary interface.
    private func syncSystemProxyState() {
        // Read the effective macOS proxy state (no root) so the toggle matches
        // reality on launch / reconnect. GUI-side inline of the helper's
        // readCurrentState — ProxyManager is only in the Helper target.
        guard let dict = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return }
        let httpOn = dict[kCFNetworkProxiesHTTPEnable as String] as? Int == 1
        let httpHost = dict[kCFNetworkProxiesHTTPProxy as String] as? String
        systemProxyOn = httpOn && httpHost == "127.0.0.1"
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                AppDelegate.performCleanup()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }
}
