import Foundation
import Combine
import SwiftUI
import AppKit
import Network
import SystemConfiguration
import ServiceManagement

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
    @Published var route = "dashboard" {
        didSet {
            reconcileActiveStreams()
        }
    }
    @Published var isMainWindowVisible = false {
        didSet {
            reconcileActiveStreams()
        }
    }
    @Published var isMenuBarVisible = false {
        didSet {
            reconcileActiveStreams()
        }
    }
    @Published var isConnectionsPageActive = false {
        didSet {
            reconcileActiveStreams()
        }
    }
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
    @Published var gatewayDevices: [String: GatewayDevice] = [:]

    // Proxies
    @Published var groups: [ProxyGroup] = []
    @Published var nodes: [String: Node] = [:]    // name → node
    @Published var testing: Set<String> = []

    // Connections (temporary caches for compatibility)
    @Published var activeConnectionsCount = 0
    var cachedConns: [Conn] = []
    var cachedClosedConnections: [Conn] = []
    var prevConnBytes: [String: (up: Int64, down: Int64)] = [:]
    var activeConnsSet: Set<String> = []
    var totalConnsCount = 0

    // Logs (level configuration is preserved)
    @AppStorage("ui.logLevel") var logLevel = "warning"

    // Traffic rate (numbers only, sparkline moved to DashboardViewModel)
    @Published var curDown: Int64 = 0
    @Published var curUp: Int64 = 0
    @Published var downSeries: [Double] = Array(repeating: 0, count: 120)
    @Published var upSeries: [Double] = Array(repeating: 0, count: 120)
    @Published var dash = DashStats()
    var lastUIUpdate = Date.distantPast


    // Config
    @Published var configs: [String: Any] = [:]

    // Rules
    @Published var rules: [RuleEntry] = []

    // Kernel Logs (Startup/Process logs)
    // Make this the canonical home for the in-flight apply flag.
    @Published var pendingApplyID: String? = nil
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
    @Published var gatewayModeOn = false

    // Menu-bar app preferences
    /// Show the Dock icon (.regular) vs menu-bar-only (.accessory).
    /// Toggle via `setShowDock(_:)` so the activation policy is re-applied — a
    /// `didSet` here would not fire when written through the `$showDock` binding.
    @AppStorage("ui.showDock") var showDock = true
    /// Mirror of SMAppService launch-at-login state (not @Published by the system).
    @Published var launchAtLoginOn = false
    /// Show the per-policy-group node selectors in the menu-bar panel. Off keeps
    /// the panel compact when a profile has many groups.
    @AppStorage("ui.menuBarGroups") var menuBarGroups = true
    /// When on, switching a proxy node closes all existing connections so live
    /// traffic immediately re-dials through the newly selected node instead of
    /// lingering on the old one.
    @AppStorage("proxies.closeOnSwitch") var closeOnSwitch = false

    // Dashboard session aggregates
    @Published var closedConns = 0
    @Published var appMemoryMB = 0.0
    var lastDownTotal: Int64 = 0
    var lastCacheFlush = Date.distantPast
    var lastInterface: String? = nil

    // Toast
    @Published var toast: String?

    // External Panels
    @AppStorage("ui.zashboardURL") var zashboardURL = "https://board.zash.run.place/"

    private var pathMonitor: NWPathMonitor?
    private var signalSources: [AnyObject] = []
    private var networkOnline = true
    /// True while the system is sleeping — gates background activity so
    /// wake-up callbacks don't race with half-restored subsystems.
    private var sleeping = false
    /// Saved state before sleep: used to restore after wake
    private var preSleepTunOn = false
    private var preSleepSystemProxyOn = false
    /// One-shot guard — `start()` must run exactly once per app lifetime.
    private var started = false
    /// System proxy was auto-disabled by the network-offline handler; restore on reconnect.
    private var proxyAutoDisabled = false

    private var trafficWS: WSHandle?

    private var logWS: WSHandle?
    private var memWS: WSHandle?
    private var pollTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private static let logDF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        // Migrate old dead Vercel URL to the new official one
        if zashboardURL.contains("zashboard.vercel.app") {
            zashboardURL = "https://board.zash.run.place/"
        }

        // Inject log sinks so the engine/helper layers report events without
        // referencing AppModel directly (decoupling — they no longer call
        // AppModel.shared).
        engine.onLog = { [weak self] msg in self?.logKernel(msg) }
        XPCManager.shared.onLog = { [weak self] msg in
            Task { @MainActor in self?.logKernel(msg) }
        }
        applyActivationPolicy()        // Dock icon visibility per saved preference
        refreshLaunchAtLogin()         // sync the launch-at-login mirror
        engine.ensureInstalled()
        api.applyController(fromConfigAt: engine.configFilePath)   // B1: discover endpoint before probing
        store.load()
        history.load()

        Task {
            // 探测内核是否存活，而非无条件杀死
            await api.probe()

            if api.reachable {
                // 内核存活 → 同步状态，不杀不停
                logKernel("启动探测：内核存活，同步状态…")
                await reconnect()
            } else {
                // 内核不存活 → 仅清理残留状态（DNS/代理），不 killall
                logKernel("启动探测：内核未响应，清理残留状态…")
                tunOn = false
                systemProxyOn = false
                reachable = false
                let port = (configs["mixed-port"] as? Int) ?? (configs["port"] as? Int) ?? 7890
                _ = await engine.setSystemProxy(enabled: false, port: port)
                await restoreTunnelDNS()
                syncSystemProxyState()
                await reconnect()
            }

            startNetworkMonitor()
            installSignalHandlers()
            observeSleepWake()

            // 稍后检查 Helper 版本是否过旧，自动进行升级
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
        let wasReachable = self.reachable
        await api.probe()
        reachable = api.reachable
        version = api.version
        
        if reachable && !wasReachable {
            // Just came online
            if !engine.isBusy {
                if proxyAutoDisabled {
                    let port = (configs["mixed-port"] as? Int) ?? (configs["port"] as? Int) ?? 7890
                    _ = await engine.setSystemProxy(enabled: true, port: port)
                    systemProxyOn = true
                    proxyAutoDisabled = false
                    showToast("网络恢复，已自动恢复系统代理")
                }
            }
        }

        guard reachable else {
            // Core unreachable — TUN can't be active, so clear the switch to keep
            // the UI consistent (tunOn is normally driven by refreshConfigs, which
            // won't run while disconnected, leaving the toggle stuck "on").
            tunOn = false
            
            // Only auto-disable proxy/DNS if the kernel WAS reachable and just crashed,
            // NOT when it's just intentionally turned off by the user.
            if wasReachable && !engine.isBusy {
                await restoreTunnelDNS()
                if systemProxyOn {
                    proxyAutoDisabled = true
                    let port = (configs["mixed-port"] as? Int) ?? (configs["port"] as? Int) ?? 7890
                    _ = await engine.setSystemProxy(enabled: false, port: port)
                    systemProxyOn = false
                    showToast("内核已断开，自动关闭系统代理以防断网")
                }
            }
            
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
        reconcileActiveStreams()
    }

    private func reconcileActiveStreams() {
        guard reachable && !sleeping else {
            stopStreams()
            return
        }

        let activeUI = isMainWindowVisible || isMenuBarVisible

        if activeUI {
            if trafficWS == nil {
                trafficWS = api.stream("/traffic", type: TrafficTick.self) { [weak self] t in
                    Task { @MainActor in self?.onTraffic(t) }
                }
            }
            if memWS == nil {
                memWS = api.stream("/memory", type: MemoryTick.self) { [weak self] m in
                    Task { @MainActor in
                        if m.inuse > 0 {
                            self?.memory = m.inuse
                            self?.appMemoryMB = Double(Self.residentMemoryBytes()) / 1_000_000
                        }
                    }
                }
            }
            startPolling()
        } else {
            trafficWS?.cancel()
            trafficWS = nil
            memWS?.cancel()
            memWS = nil
            pollTask?.cancel()
            pollTask = nil
        }

        pollTimer?.invalidate()
        pollTimer = nil

        if !isConnectionsPageActive {
            // 后台慢速轮询：降低频率到 10 秒，减少内存分配
            pollTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
                Task {
                    guard let self else { return }
                    // 睡眠中或网络离线时跳过轮询
                    guard !self.sleeping && self.networkOnline else { return }
                    do {
                        let snapshot = try await self.api.fetchConnectionsSnapshot()
                        await self.recordHistoryOnly(from: snapshot)
                    } catch {
                        // Ignore
                    }
                }
            }
        }
        
        if !isMainWindowVisible {
            cachedConns.removeAll(keepingCapacity: false)
            cachedClosedConnections.removeAll(keepingCapacity: false)
            prevConnBytes.removeAll(keepingCapacity: false)
            activeConnsSet.removeAll(keepingCapacity: false)
            logKernel("主窗口不可见，已释放 AppModel 内存缓存")
        }
    }

    private func stopStreams() {
        trafficWS?.cancel(); trafficWS = nil
        pollTimer?.invalidate(); pollTimer = nil
        pollTask?.cancel(); pollTask = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.reachable, self.isMainWindowVisible || self.isMenuBarVisible {
                await self.refreshProxies()
                await self.refreshConfigs()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private var pollTimer: Timer?

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

    // MARK: Sleep / Wake lifecycle

    private func observeSleepWake() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.prepareForSleep()
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recoverFromWake() }
        }
    }

    /// Gracefully suspend background activity before the system sleeps.
    /// Prevents reconnect storms and stale-proxy crashes on wake.
    private func prepareForSleep() {
        sleeping = true

        // Save current state
        preSleepTunOn = tunOn
        preSleepSystemProxyOn = systemProxyOn

        stopStreams()       // cancel WS — avoids 4× reconnect race on wake
        reconnectTask?.cancel()
        reconnectTask = nil

        // Proactively free memory: clear large connection tracking maps
        prevConnBytes.removeAll(keepingCapacity: false)
        activeConnsSet.removeAll(keepingCapacity: false)
        cachedConns.removeAll(keepingCapacity: false)
        cachedClosedConnections.removeAll(keepingCapacity: false)

        logKernel("系统即将休眠，已保存状态并释放内存")
    }

    /// Re-establish connectivity after system wake. Delays briefly to let
    /// the network stack come back up, then forces a clean reconnect.
    private func recoverFromWake() {
        sleeping = false
        XPCManager.shared.resetConnection()   // tear down stale Mach ports

        logKernel("系统唤醒，正在恢复连接与服务...")

        Task {
            // Network interfaces need a moment to re-associate after wake
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // Probe kernel health
            await api.probe(timeout: 2.0)

            if !api.reachable {
                // Kernel died during sleep — restart it
                logKernel("唤醒后内核未响应，正在重启...")
                engine.ensureRunning()

                // Wait for kernel to come up
                for i in 1...8 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await api.probe(timeout: 1.0)
                    if api.reachable {
                        logKernel("内核已重启 (尝试 \(i))")
                        break
                    }
                }
            }

            // Reconnect and restore state
            await reconnect()

            // Restore TUN if it was active before sleep
            if preSleepTunOn && !tunOn {
                logKernel("恢复 TUN 模式...")
                await applyTUNState(true)
            }

            // Restore system proxy if it was active before sleep
            if preSleepSystemProxyOn && !systemProxyOn {
                logKernel("恢复系统代理...")
                let port = (configs["mixed-port"] as? Int) ?? (configs["port"] as? Int) ?? 7890
                let ok = await engine.setSystemProxy(enabled: true, port: port)
                if ok {
                    systemProxyOn = true
                    logKernel("系统代理已恢复")
                }
            }

            logKernel("唤醒恢复完成")
        }
    }

    @MainActor private func handleNetworkChange(online: Bool) {
        guard !sleeping else { return }   // ignore transient state during sleep/wake
        let onlineChanged = networkOnline != online
        networkOnline = online
        
        if online {
            // Re-sync state when coming back online or when path changes
            Task {
                await api.probe()
                if api.reachable {
                    await refreshConfigs()
                    // Restore system proxy if it was auto-disabled by the offline handler
                    if proxyAutoDisabled && !systemProxyOn {
                        proxyAutoDisabled = false
                        let port = (configs["mixed-port"] as? Int) ?? (configs["port"] as? Int) ?? 7890
                        let ok = await engine.setSystemProxy(enabled: true, port: port)
                        if ok {
                            systemProxyOn = true
                            showToast("网络恢复，已自动恢复系统代理")
                        }
                    }
                    // If TUN is supposed to be on, ensure it's healthy and interface is pinned
                    if tunOn && !engine.isBusy {
                        let currentIface = await EngineControl.defaultInterface()
                        if onlineChanged || (currentIface != nil && currentIface != lastInterface) {
                            if let iface = currentIface { lastInterface = iface }
                            engine.isBusy = true
                            defer { engine.isBusy = false }
                            await applyTUNState(true)
                        }
                    }
                }
            }
        } else if onlineChanged {
            // Network offline: disable system proxy to prevent traffic being
            // blocked by a proxy pointing at a (potentially) dead kernel.
            if systemProxyOn {
                proxyAutoDisabled = true
                let port = (configs["mixed-port"] as? Int) ?? (configs["port"] as? Int) ?? 7890
                Task {
                    _ = await engine.setSystemProxy(enabled: false, port: port)
                    systemProxyOn = false
                    showToast("网络断开，已自动关闭系统代理")
                }
            }
            // Only restore DNS if the kernel is also gone — if TUN is still
            // alive the tunnel DNS should stay; refreshConfigs will reconcile.
            Task {
                await api.probe(timeout: 1.0)
                if !api.reachable { await restoreTunnelDNS() }
            }
            // Proactively free memory when going offline
            prevConnBytes.removeAll(keepingCapacity: false)
            activeConnsSet.removeAll(keepingCapacity: false)
            logKernel("网络离线，已释放连接追踪缓存")
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
        let httpPort = dict[kCFNetworkProxiesHTTPPort as String] as? Int
        
        let expectedPort = (configs["mixed-port"] as? Int) ?? (configs["port"] as? Int) ?? 7890
        systemProxyOn = httpOn && httpHost == "127.0.0.1" && httpPort == expectedPort
    }

    // MARK: Menu-bar app preferences

    /// Apply the Dock-icon policy: `.regular` shows the Dock icon, `.accessory`
    /// makes ClashHalo a menu-bar-only app (no Dock icon / Cmd-Tab entry).
    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }

    /// Persist the Dock-icon preference and apply it immediately.
    func setShowDock(_ on: Bool) {
        showDock = on
        applyActivationPolicy()
    }

    /// Bring the app (and its main window) to the front from the menu bar.
    /// Window (re)creation is handled by the caller via `openWindow(id:)`; this
    /// activates the app and fronts any existing titled window (works in
    /// `.accessory` mode too, where there is no Dock icon).
    func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.styleMask.contains(.titled) {
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// Sync the launch-at-login mirror from the system service (macOS 13+).
    func refreshLaunchAtLogin() {
        launchAtLoginOn = (SMAppService.mainApp.status == .enabled)
    }

    /// Copy a shell snippet that points a terminal at the local proxy.
    func copyProxyCommand() {
        let port = (configs["mixed-port"] as? Int) ?? (configs["port"] as? Int) ?? 7890
        let cmd = "export https_proxy=http://127.0.0.1:\(port) http_proxy=http://127.0.0.1:\(port) all_proxy=socks5://127.0.0.1:\(port)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        showToast("已复制终端代理命令")
    }

    /// Hot-reload the config the kernel is actually running (config.yaml on disk),
    /// via `/configs?force=true` — works whether or not a profile is managed.
    func reloadActiveConfig() {
        guard reachable else { showToast("内核未连接，无法重载"); return }
        showToast("正在重载配置…")
        Task {
            engine.setTunEnabled(tunOn)   // preserve running TUN across the reload
            do {
                try await api.reloadConfig(path: engine.configFilePath)
                await refreshConfigs()
                await refreshProxies()
                showToast("配置已重载")
            } catch {
                showToast("重载失败：\(error.localizedDescription)")
            }
        }
    }

    /// Update every remote (HTTP) subscription, then re-apply the active one.
    func updateAllSubscriptions() {
        let remotes = store.profiles.filter { $0.source == "remote" }
        guard !remotes.isEmpty else { showToast("无远程订阅"); return }
        showToast("正在更新订阅…")
        Task {
            for p in remotes { _ = await store.updateRemote(p.id) }
            if !store.activeID.isEmpty { selectForApply(store.activeID) }
            showToast("订阅已更新")
        }
    }

    /// Reveal the data/config directory in Finder.
    func openConfigDir() {
        let dir = NSHomeDirectory() + "/Library/Application Support/ClashPow"
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    /// Register/unregister the app as a login item via `SMAppService`.
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            showToast("开机自启动设置失败：\(error.localizedDescription)")
        }
        refreshLaunchAtLogin()
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
