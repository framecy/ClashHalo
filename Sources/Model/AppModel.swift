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
    let updater = AppUpdater.shared

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
    @Published var proxiesLoading = false
    @Published var proxiesError: String?
    /// Maps proxy node name → proxy-provider name for nodes sourced from proxy-providers.
    /// Used by the test engine to route healthcheck via /providers/proxies/{provider}/healthcheck.
    var nodeToProvider: [String: String] = [:]

    // Connections (temporary caches for compatibility)
    @Published var activeConnectionsCount = 0
    var cachedConns: [Conn] = []
    var cachedClosedConnections: [Conn] = []
    var prevConnBytes: [String: (up: Int64, down: Int64)] = [:]
    var activeConnsSet: Set<String> = []
    var totalConnsCount = 0

    // Traffic rate (numbers only, sparkline moved to DashboardViewModel)
    @Published var curDown: Int64 = 0
    @Published var curUp: Int64 = 0
    @Published var downSeries: [Double] = Array(repeating: 0, count: 120)
    @Published var upSeries: [Double] = Array(repeating: 0, count: 120)
    @AppStorage("trafficRefreshInterval") public var trafficRefreshInterval: Double = 1.0
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
        let line = "[\(Self.logDF.string(from: Date()))] \(msg)"
        kernelLogs.append(line)
        if kernelLogs.count > 100 { kernelLogs.removeFirst() }
        print("KernelLog: \(msg)")
    }

    // Master switches
    @Published var systemProxyOn = false
    @Published var tunOn = false
    var staticRoutesInjected = false
    /// In-flight guard so the B10 auto-teardown (config says TUN on but interface
    /// gone) and the verifyTUNConfig 30 s probe don't both fire `applyTUNState`
    /// concurrently with a user toggle / restart. Re-arming it to `false`
    /// happens once that teardown lands and refreshConfigs reconciles `tunOn`.
    /// Internal (not `private`) so the `AppModel+Config` extension can access it.
    var tunAutoTeardownInFlight = false
    @Published var gatewayModeOn = false
    /// Snapshot of allow-lan / dns.listen before Gateway mode overrode them,
    /// used to restore config.yaml when Gateway is disabled.
    var preGatewayAllowLan: Bool?
    var preGatewayDNSListen: String?

    /// The proxy port from the running config. Centralises the repeated
    /// `(configs["mixed-port"] ?? configs["port"] ?? 7890)` lookup.
    var proxyPort: Int {
        (configs["mixed-port"] as? Int) ?? (configs["port"] as? Int) ?? 7890
    }

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
    private var preSleepGatewayOn = false
    /// One-shot guard — `start()` must run exactly once per app lifetime.
    private var started = false
    /// System proxy was auto-disabled by the network-offline handler; restore on reconnect.
    private var proxyAutoDisabled = false

    private var trafficWS: WSHandle?

    private var logWS: WSHandle?
    private var memWS: WSHandle?
    private var pollTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var bgTickCount = 0

    private static let logDF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    /// Smart wait for kernel to be ready using exponential backoff.
    /// Returns true if kernel is reachable, false if timeout.
    func waitForKernelReady(maxAttempts: Int = 8) async -> Bool {
        await api.probe(timeout: 0.1)
        if api.reachable {
            return true
        }
        let delays: [UInt64] = [20_000_000, 50_000_000, 100_000_000, 200_000_000,
                                300_000_000, 500_000_000, 1_000_000_000, 1_000_000_000]
        for i in 0..<min(maxAttempts, delays.count) {
            try? await Task.sleep(nanoseconds: delays[i])
            await api.probe(timeout: 0.2)
            if api.reachable {
                return true
            }
        }
        return false
    }

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
        updater.onLog = { [weak self] msg in self?.logKernel(msg) }
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
                _ = await engine.setSystemProxy(enabled: false, port: proxyPort)
                await restoreTunnelDNS()
                syncSystemProxyState()
                await reconnect()
            }

            startNetworkMonitor()
            installSignalHandlers()
            observeSleepWake()

            // 稍后检查 Helper 版本是否过旧，自动进行升级（延迟减少为2秒）
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await engine.checkAndUpgradeHelperIfNeeded()

            // 后台检查应用更新（延迟10秒，避免影响启动速度）
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            _ = await updater.checkForUpdates()
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
                    _ = await engine.setSystemProxy(enabled: true, port: proxyPort)
                    systemProxyOn = true
                    proxyAutoDisabled = false
                    showToast("网络恢复，已自动恢复系统代理")
                }
            }
        }

        guard reachable else {
            // Core unreachable — TUN/Gateway can't be active, so clear the
            // switches to keep the UI consistent (tunOn is normally driven by
            // refreshConfigs, which won't run while disconnected, leaving the
            // toggles stuck "on").
            tunOn = false
            gatewayModeOn = false
            
            // Only auto-disable proxy/DNS if the kernel WAS reachable and just crashed,
            // NOT when it's just intentionally turned off by the user.
            if wasReachable && !engine.isBusy {
                await restoreTunnelDNS()
                if systemProxyOn {
                    proxyAutoDisabled = true
                    _ = await engine.setSystemProxy(enabled: false, port: proxyPort)
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
        await refreshProxies()
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
            Task {
                await refreshProxies()
            }
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

        // 后台慢速轮询：仅在窗口不可见且连接页未激活时运行
        // 可见时 startPolling() + ConnectionsViewModel 已覆盖所有数据更新，无需重复
        if !activeUI && !isConnectionsPageActive {
            bgTickCount = 0
            pollTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    guard !self.sleeping && self.networkOnline else { return }

                    // Record traffic history
                    do {
                        let snapshot = try await self.api.fetchConnectionsSnapshot()
                        await self.recordHistoryOnly(from: snapshot)
                    } catch { }

                    // Health check every 2 minutes (every 4 ticks at 30s interval)
                    self.bgTickCount += 1
                    if self.bgTickCount >= 4 {
                        if self.gatewayModeOn && self.reachable {
                            await self.verifyGatewayConfig()
                        }
                        if self.tunOn && self.reachable {
                            await self.verifyTUNConfig()
                        }
                        self.bgTickCount = 0
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
            var checkCounter = 0
            while let self, !Task.isCancelled, self.reachable, self.isMainWindowVisible || self.isMenuBarVisible {
                // Only refresh configs periodically; proxies are refreshed on-demand
                // (mode/profile switch, manual test-all) to avoid triggering @Published
                // groups diff every 3s when nothing changes.
                await self.refreshConfigs()

                // Health check every 30 seconds (every 10th poll at 3s interval)
                checkCounter += 1
                if checkCounter >= 10 {
                    if self.gatewayModeOn {
                        await self.verifyGatewayConfig()
                    }
                    if self.tunOn {
                        await self.verifyTUNConfig()
                    }
                    checkCounter = 0
                }

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
        preSleepGatewayOn = gatewayModeOn

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
            // Network interfaces need a moment to re-associate after wake (reduced from 2s to 1s)
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            // Probe kernel health
            await api.probe(timeout: 1.0)

            if !api.reachable {
                // Kernel died during sleep — restart it
                logKernel("唤醒后内核未响应，正在重启...")
                engine.ensureRunning()

                // Wait for kernel to come up using smart backoff (reduced from 8 attempts)
                if await waitForKernelReady(maxAttempts: 6) {
                    logKernel("内核已重启")
                } else {
                    logKernel("内核重启超时")
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
                let ok = await engine.setSystemProxy(enabled: true, port: proxyPort)
                if ok {
                    systemProxyOn = true
                    logKernel("系统代理已恢复")
                }
            }

            // Restore Gateway config overrides if it was active before sleep.
            // A kernel restart during sleep re-reads config.yaml from disk,
            // which has the original profile values — the Gateway overrides
            // (allow-lan + dns.listen=0.0.0.0:53) are lost. Re-inject them
            // and reload so Gateway clients keep working.
            if preSleepGatewayOn && reachable {
                logKernel("恢复网关中枢配置...")
                engine.setTopLevelScalars(AppModel.gatewayOverrides)

                // Retry reload up to 3 times with exponential backoff
                var restored = false
                for attempt in 1...3 {
                    do {
                        try await api.reloadConfig(path: engine.configFilePath)
                        await refreshConfigs()
                        // Only enable sysctl IP forwarding after config is confirmed reloaded
                        let ok = await engine.setGatewayMode(enabled: true)
                        gatewayModeOn = ok
                        restored = ok
                        logKernel(ok ? "网关中枢已恢复" : "网关中枢恢复失败")
                        break
                    } catch {
                        logKernel("网关配置重载失败（尝试 \(attempt)/3）：\(error.localizedDescription)")
                        if attempt < 3 {
                            try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                        }
                    }
                }

                if !restored {
                    logKernel("网关中枢恢复失败，已放弃重试")
                    gatewayModeOn = false
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
                        let ok = await engine.setSystemProxy(enabled: true, port: proxyPort)
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
                            // Manual isBusy + defer (not `withEngineBusy`) because this runs
                            // fire-and-forget inside a Task whose caller cannot await the body —
                            // `withEngineBusy`'s guard would clear before applyTUNState(true)
                            // truly completes, and a Task cancellation mid-await would otherwise
                            // leak isBusy=true forever and block all later toggles (see the
                            // analogous teardown pattern in verifyTUNConfig / refreshConfigs B10).
                            engine.isBusy = true
                            defer { engine.isBusy = false }
                            await applyTUNState(true)
                        }
                    }

                    // Gateway health check: verify config is still intact after network change
                    if gatewayModeOn && reachable {
                        await verifyGatewayConfig()
                    }
                }
            }
        } else if onlineChanged {
            // Network offline: disable system proxy to prevent traffic being
            // blocked by a proxy pointing at a (potentially) dead kernel.
            if systemProxyOn {
                proxyAutoDisabled = true
                Task {
                    _ = await engine.setSystemProxy(enabled: false, port: proxyPort)
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

        systemProxyOn = httpOn && httpHost == "127.0.0.1" && httpPort == proxyPort

        // If our system proxy is active but the bypass domains are stale (missing
        // LAN private ranges, e.g. upgraded from a build that only wrote
        // localhost/127.0.0.1/*.local), silently re-apply the full bypass list so
        // LAN hosts (NAS/routers at 10.x/192.168.x/172.16-31.x) stop being tunneled
        // into mihomo (which returns 502). Idempotent — only acts when a gap is
        // detected. This is how an app upgrade reaches "proxy already on" users
        // without asking them to toggle the switch off and on.
        if systemProxyOn {
            reconcileProxyBypassIfNeeded()
        }
    }

    /// Re-apply the full bypass-domain list if the current one is missing any
    /// essential local range. Writes directly via `networksetup` on the GUI side
    /// (the user can change their own network services without root) — does NOT
    /// route through the XPC Helper, so a stale installed Helper carrying the old
    /// 3-entry list cannot clobber a correct one back to stale. Idempotent.
    private func reconcileProxyBypassIfNeeded() {
        // Probe via networksetup since the authoritative host list is not in the
        // SCDynamicStore proxy dictionary.
        struct BypassProbe {
            static let required = ["10.*", "192.168.*", "172.16.*", "169.254.*"]
            static func current() -> [String] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                p.arguments = ["-getproxybypassdomains", "Wi-Fi"]
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
                do {
                    try p.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    let out = String(data: data, encoding: .utf8) ?? ""
                    return out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                } catch { return [] }
            }
        }
        let current = Set(BypassProbe.current())
        let missing = BypassProbe.required.contains { !current.contains($0) }
        guard missing else { return }
        logKernel("检测到系统代理 bypass 缺少局域网网段，正在本地直接补齐（不经过 Helper）...")
        Task.detached(priority: .utility) {
            // Write directly via `networksetup` on the GUI side (the user can
            // change their own network services without root), NOT through the
            // XPC Helper. An out-of-date installed Helper still carries the old
            // bypass list and would silently overwrite a correct one back to the
            // stale 3-entry list — perpetuating the 502 instead of fixing it.
            let list = Process()
            list.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            list.arguments = ["-listallnetworkservices"]
            let listPipe = Pipe(); list.standardOutput = listPipe; list.standardError = Pipe()
            do {
                try list.run()
                let data = listPipe.fileHandleForReading.readDataToEndOfFile()
                list.waitUntilExit()
                let out = String(data: data, encoding: .utf8) ?? ""
                // dropFirst() skips the "An asterisk (*) ..." header line
                let services = out.split(separator: "\n").dropFirst().compactMap { line -> String? in
                    let s = String(line).trimmingCharacters(in: .whitespaces)
                    return (s.isEmpty || s.hasPrefix("*")) ? nil : s
                }
                let bypass = kProxyBypassDomains
                for svc in services {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                    p.arguments = ["-setproxybypassdomains", svc] + bypass
                    p.standardOutput = Pipe(); p.standardError = Pipe()
                    try? p.run(); p.waitUntilExit()
                }
                await MainActor.run {
                    self.logKernel("系统代理 bypass 已本地补齐局域网网段（共 \(services.count) 个网络服务）")
                }
            } catch {
                await MainActor.run { self.logKernel("bypass 补齐失败：\(error.localizedDescription)") }
            }
        }
    }

    /// Verify Gateway config integrity and restore if needed.
    /// Called after network changes and periodically to ensure long-running
    /// Gateway mode stays healthy (config persists, sysctl stays set).
    private func verifyGatewayConfig() async {
        guard gatewayModeOn && reachable else { return }

        // Check if config still has the Gateway overrides
        let allowLan = (configs["allow-lan"] as? Bool) == true
        let dnsListen = (configs["dns"] as? [String: Any])?["listen"] as? String
        let configOK = allowLan && dnsListen == "0.0.0.0:53"

        if !configOK {
            logKernel("检测到网关配置丢失，正在恢复...")
            engine.setTopLevelScalars(Self.gatewayOverrides)
            do {
                try await api.reloadConfig(path: engine.configFilePath)
                await refreshConfigs()
                logKernel("网关配置已自动恢复")
            } catch {
                logKernel("网关配置恢复失败：\(error.localizedDescription)")
            }
        }

        // ALWAYS verify and enforce sysctl IP forwarding when Gateway Mode is on
        let sysctlOK = await engine.setGatewayMode(enabled: true)
        if !sysctlOK {
            logKernel("网关 sysctl 启用失败，请检查特权服务状态")
        }
    }

    /// Verify TUN DNS redirection and interface existence, re-apply or disable if issues detected.
    /// This catches two failure modes:
    /// 1. DNS drift: system DNS was reset by macOS (e.g. network change)
    /// 2. Interface loss: mihomo's utun disappeared while other utun interfaces remain
    private func verifyTUNConfig() async {
        guard tunOn && reachable && !sleeping else { return }

        // Check 1: Verify the TUN interface actually exists
        if await NetScanner.mihomoTunInterface() == nil {
            // Share the in-flight guard with refreshConfigs' B10 auto-teardown so
            // the 3 s poll and this 30 s probe never both fire `applyTUNState`.
            // Also hold `engine.isBusy` for the duration so a user toggle / restart
            // landing mid-teardown is rejected (P2 root-cause: the detached
            // teardown previously raced the user's applyTUNState). We bypass
            // `withEngineBusy` here because it is fire-and-forget — the caller
            // cannot await its body, so the in-flight guard would clear before
            // the teardown actually finishes. Manual isBusy + defer guarantees
            // the guard clears only after applyTUNState(false) truly completes.
            guard !engine.isBusy, !tunAutoTeardownInFlight else { return }
            tunAutoTeardownInFlight = true
            engine.isBusy = true
            defer {
                engine.isBusy = false
                tunAutoTeardownInFlight = false
            }
            logKernel("检测到 TUN 接口丢失（可能与其他 utun 服务并存导致冲突），正在自动关闭...")
            showToast("TUN 接口异常，已自动关闭")
            await applyTUNState(false)
            return
        }

        // Check 2: Verify DNS redirection is still active
        let gateway = tunnelDNSAddress()
        let current = await EngineControl.currentSystemDNS()
        if !current.contains(gateway) {
            logKernel("检测到 TUN DNS 发生漂移，正在重新重定向...")
            await enableTunnelDNS()
        }
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
        let port = proxyPort
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

                // Gateway cascade: reload re-reads config.yaml from disk, which
                // has the original profile values. If Gateway was on, re-inject
                // the overrides (allow-lan + dns.listen=0.0.0.0:53) so it keeps working.
                if gatewayModeOn {
                    engine.setTopLevelScalars(AppModel.gatewayOverrides)
                    try await api.reloadConfig(path: engine.configFilePath)
                    await refreshConfigs()
                }

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
            var successCount = 0
            var failNames: [String] = []
            for p in remotes {
                let ok = await store.updateRemote(p.id)
                if ok {
                    successCount += 1
                } else {
                    failNames.append(p.name)
                }
            }
            if !store.activeID.isEmpty { selectForApply(store.activeID) }
            if failNames.isEmpty {
                showToast("订阅已全部更新成功")
            } else {
                let failedList = failNames.joined(separator: ", ")
                showToast("更新完成: 成功 \(successCount) 个, 失败 \(failNames.count) 个 (\(failedList))")
            }
        }
    }

    /// Reveal the data/config directory in Finder.
    func openConfigDir() {
        let dir = NSHomeDirectory() + "/Library/Application Support/ClashHalo"
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
import Foundation
import AppKit

/// Manages application updates from GitHub Releases.
/// Checks for new versions, downloads updates, and handles installation.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    @Published var isChecking = false
    @Published var updateAvailable = false
    @Published var latestVersion: String?
    @Published var downloadURL: String?
    @Published var releaseNotes: String?
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false

    let repoOwner = "framecy"
    let repoName = "ClashHalo"
    private var downloadTask: URLSessionDownloadTask?
    private var lastLoggedProgress = -1
    private var downloadContinuation: CheckedContinuation<URL?, Never>?

    var onLog: ((String) -> Void)?

    private init() {}

    /// Current app version from Info.plist
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Current app build number from Info.plist
    var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    /// Helper to extract build number from filename (e.g. ClashHalo_v1.0.1_build_29_mac.dmg -> 29)
    private func parseBuildNumber(from filename: String) -> Int? {
        let pattern = "build_(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsString = filename as NSString
        let results = regex.matches(in: filename, options: [], range: NSRange(location: 0, length: nsString.length))
        guard let match = results.first, match.numberOfRanges > 1 else { return nil }
        let buildStr = nsString.substring(with: match.range(at: 1))
        return Int(buildStr)
    }

    /// Check GitHub Releases for updates
    func checkForUpdates() async -> Bool {
        guard !isChecking else { return false }
        isChecking = true
        defer { isChecking = false }

        let currentDisplay = currentBuild > 0 ? "\(currentVersion) (\(currentBuild))" : currentVersion
        onLog?("检查更新：当前版本 \(currentDisplay)")

        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            onLog?("更新检查失败：无效的 URL")
            return false
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                onLog?("更新检查失败：服务器响应异常")
                return false
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                onLog?("更新检查失败：解析响应失败")
                return false
            }

            guard let tagName = json["tag_name"] as? String else {
                onLog?("更新检查失败：未找到版本标签")
                return false
            }

            // Remove 'v' prefix if present
            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            latestVersion = version
            releaseNotes = json["body"] as? String

            // Find the asset and parse its build number
            var targetAsset: [String: Any]? = nil
            var remoteBuild: Int? = nil

            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       let downloadURLStr = asset["browser_download_url"] as? String,
                       (name.hasSuffix(".dmg") || name.hasSuffix(".zip")) {
                        targetAsset = asset
                        remoteBuild = parseBuildNumber(from: name)
                        break
                    }
                }
            }

            // Compare versions and builds
            if isNewer(newVersion: version, newBuild: remoteBuild, than: currentVersion, currentBuild: currentBuild) {
                let displayVersion = remoteBuild != nil ? "\(version) (\(remoteBuild!))" : version
                onLog?("发现新版本：\(displayVersion)")

                if let asset = targetAsset, let downloadURLStr = asset["browser_download_url"] as? String {
                    downloadURL = downloadURLStr
                    updateAvailable = true
                    onLog?("找到更新包：\(asset["name"] as? String ?? "")")
                    return true
                } else {
                    onLog?("未找到可下载的更新包")
                    return false
                }
            } else {
                onLog?("当前已是最新版本")
                updateAvailable = false
                return false
            }
        } catch {
            onLog?("更新检查失败：\(error.localizedDescription)")
            return false
        }
    }

    /// Compare two semantic versions and build numbers
    private func isNewer(newVersion: String, newBuild: Int?, than currentVersion: String, currentBuild: Int) -> Bool {
        let newParts = newVersion.split(separator: ".").compactMap { Int($0) }
        let currentParts = currentVersion.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(newParts.count, currentParts.count) {
            let newVal = i < newParts.count ? newParts[i] : 0
            let currentVal = i < currentParts.count ? currentParts[i] : 0

            if newVal > currentVal { return true }
            if newVal < currentVal { return false }
        }

        // Semantic versions are equal, compare build numbers
        if let newB = newBuild {
            return newB > currentBuild
        }
        return false
    }

    /// Download the update package using custom delegate for dynamic progress reports
    func downloadUpdate() async -> URL? {
        guard let downloadURLString = downloadURL,
              let url = URL(string: downloadURLString) else {
            onLog?("下载失败：无效的下载链接")
            return nil
        }

        isDownloading = true
        downloadProgress = 0
        lastLoggedProgress = -1
        defer { isDownloading = false }

        onLog?("开始下载更新包...")

        return await withCheckedContinuation { cont in
            self.downloadContinuation = cont
            let delegate = DownloadDelegate(
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress = progress
                        let pct = Int(progress * 100)
                        if pct % 10 == 0 && pct != self?.lastLoggedProgress {
                            self?.lastLoggedProgress = pct
                            self?.onLog?("下载进度：\(pct)%")
                        }
                    }
                },
                onComplete: { [weak self] result in
                    Task { @MainActor in
                        switch result {
                        case .success(let dest):
                            self?.downloadProgress = 1.0
                            self?.onLog?("下载完成：\(dest.path)")
                            cont.resume(returning: dest)
                        case .failure(let error):
                            self?.onLog?("下载失败：\(error.localizedDescription)")
                            cont.resume(returning: nil)
                        }
                        self?.downloadContinuation = nil
                    }
                }
            )

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 45
            config.timeoutIntervalForResource = 600

            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: OperationQueue())
            let task = session.downloadTask(with: url)
            self.downloadTask = task
            task.resume()

            session.finishTasksAndInvalidate()
        }
    }

    /// Verify downloaded file integrity (basic size check)
    func verifyDownload(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            onLog?("文件验证失败：文件不存在")
            return false
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? UInt64, size > 1_000_000 { // At least 1MB
                onLog?("文件验证通过：大小 \(size / 1_000_000) MB")
                return true
            } else {
                onLog?("文件验证失败：文件过小")
                return false
            }
        } catch {
            onLog?("文件验证失败：\(error.localizedDescription)")
            return false
        }
    }

    /// Open the downloaded file for user to install
    func installUpdate(from url: URL) {
        onLog?("打开更新包：\(url.path)")
        NSWorkspace.shared.open(url)
    }

    /// Full update flow: check → download → verify → prompt install
    func performUpdate() async -> Bool {
        guard await checkForUpdates() else {
            return false
        }

        guard updateAvailable else {
            return false
        }

        guard let downloadedURL = await downloadUpdate() else {
            return false
        }

        guard verifyDownload(at: downloadedURL) else {
            try? FileManager.default.removeItem(at: downloadedURL)
            return false
        }

        // Install (open the dmg/zip)
        installUpdate(from: downloadedURL)

        return true
    }

    /// Cancel ongoing download
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        downloadContinuation?.resume(returning: nil)
        downloadContinuation = nil
        onLog?("下载已取消")
    }

    /// Reset update state
    func reset() {
        updateAvailable = false
        latestVersion = nil
        downloadURL = nil
        releaseNotes = nil
        downloadProgress = 0
    }
}

/// A private delegate helper that handles the downloading callbacks and updates progress dynamically
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    let onComplete: (Result<URL, Error>) -> Void
    private let lock = NSLock()
    private var isCompleted = false

    init(onProgress: @escaping (Double) -> Void, onComplete: @escaping (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        onProgress(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        lock.unlock()

        let tmpDir = FileManager.default.temporaryDirectory
        let fileName = downloadTask.originalRequest?.url?.lastPathComponent ?? "ClashHalo_Update.dmg"
        let destination = tmpDir.appendingPathComponent(fileName)

        try? FileManager.default.removeItem(at: destination)

        do {
            try FileManager.default.moveItem(at: location, to: destination)
            onComplete(.success(destination))
        } catch {
            onComplete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        lock.unlock()

        let err = error ?? NSError(domain: "AppUpdater", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载未完成"])
        onComplete(.failure(err))
    }
}
