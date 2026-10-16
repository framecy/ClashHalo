import SwiftUI

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Boot the model here rather than from the main window's `.onAppear`.
    ///
    /// A login-item launch (SMAppService) starts ClashHalo in the background:
    /// SwiftUI does not instantiate a `Window` scene's content until that window
    /// is actually ordered on screen, so `.onAppear` never fired and `start()`
    /// never ran. The menu bar extra, however, is live from the first frame — so
    /// the user could open it and hit Proxy / TUN against a model that had never
    /// called `store.load()`. With `profiles` still empty both toggles take their
    /// "no profile" guard and answer "请先导入配置", for configs that are sitting
    /// on disk. Nothing else in `start()` had run either: no kernel auto-start,
    /// no polling, no helper check — the menu bar just sat disconnected until the
    /// user happened to open the main window.
    ///
    /// Launching is the right trigger for all of that; a window being drawn is
    /// not. `start()` is idempotent (guarded by `started`), so the `.onAppear`
    /// call below remains as a harmless backstop.
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.performCleanup()
    }

    /// Closing the last window keeps ordinary macOS behaviour and terminates the
    /// app — which is now safe, because `applicationShouldTerminate` holds the
    /// quit until the tunnel has been torn down properly.
    ///
    /// (AppKit semantics worth stating because they invert the obvious reading:
    /// returning `true` here *allows* termination. This method is deliberately not
    /// where the TUN policy lives; putting a `false` here is what previously kept
    /// the app resident against the user's wishes.)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quit is always a real quit — but with TUN up it *waits* for the tunnel to
    /// come down before the process exits.
    ///
    /// The danger this avoids: the Helper arms a client-death watchdog on every
    /// authenticated client (`Sources/Helper/main.swift`, `armClientWatch`), and
    /// `handleClientExit` calls `stopMihomoInternal()` whenever a root kernel
    /// exists. So any abrupt exit hands the root kernel to a ~2 s timer that stops
    /// it *without* the system-proxy disable and DNS restore `performCleanup()`
    /// runs first — leaving DNS pinned to a resolver that is no longer answering.
    ///
    /// `.terminateLater` is exactly the AppKit affordance for this: it says "I am
    /// not ready, hold the quit" and obliges us to call
    /// `reply(toApplicationShouldTerminate:)` when we are. Because AppKit keeps
    /// the app alive until that reply, the teardown below still has a live XPC
    /// client and a live helper connection — which is precisely what the abrupt
    /// path loses.
    ///
    /// Only TUN-on needs the wait. With TUN off there is nothing worth waiting for
    /// and `.terminateNow` keeps quit instant.
    ///
    /// This hook also catches the app-menu ⌘Q, the menu-bar power button, and
    /// `terminate(_:)` from anywhere — including AppKit's own auto-generated ⌘Q
    /// menu item, which calls `terminate(_:)` directly and never touches any
    /// ClashHalo code.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppDelegate.shouldKeepTunnelAlive() else { return .terminateNow }
        AppDelegate.teardownAndQuit()
        return .terminateLater
    }

    /// Drives the delayed reply for `.terminateLater`.
    ///
    /// Runs off the main thread on purpose: `performCleanup()` is synchronous and
    /// blocks on XPC round-trips, so running it on the main actor would freeze the
    /// UI for the duration of the teardown. The reply itself is delivered back on
    /// the main queue, as AppKit requires.
    ///
    /// The reply is one-shot and guarded by a timeout. That guard is not
    /// decoration: a `.terminateLater` that never gets its reply leaves the app
    /// alive but half-dead — windowless, unquittable, with the user forced to
    /// force-quit. `performCleanup()` waits on XPC with its own timeouts, but a
    /// wedged helper or a hung DNS restore must not be able to strand the quit,
    /// so whichever of the two arrives first wins and the other is a no-op.
    private static let _quitReplyOnce = DispatchSemaphore(value: 1)

    private static func replyQuitOnce() {
        guard _quitReplyOnce.wait(timeout: .now()) == .success else { return }
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private static func teardownAndQuit() {
        AppModel.appendAppLog("[退出] TUN 正在运行，正在关闭内核并还原系统代理与 DNS，完成后退出")
        DispatchQueue.global(qos: .userInitiated).async {
            performCleanup()
            DispatchQueue.main.async { AppDelegate.replyQuitOnce() }
        }
        // Belt and braces: never let a wedged teardown strand the quit. The
        // teardown normally finishes well inside this window (measured ~1 s), so
        // this only ever fires when something is genuinely stuck — and then
        // exiting is better than hanging, because `performCleanup()`'s remaining
        // steps are already covered by the Helper's client-death cleanup.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
            DispatchQueue.main.async {
                if _quitReplyOnce.wait(timeout: .now()) == .success {
                    AppModel.appendAppLog("[退出] 拆除超过 8 秒仍未完成，已强制退出（剩余清理交 Helper 与下次启动）")
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
    }

    /// Dock-click recovery for the ordinary case where the window was closed but
    /// the app is still running (menu-bar resident, no window).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        MainActor.assumeIsolated { AppModel.shared.activateApp() }
        return true
    }

    /// Does this exit have to tear the tunnel down?
    ///
    /// Quitting with TUN up is the case that needs the *waiting* teardown in
    /// `applicationShouldTerminate`: the root kernel owns a utun and has
    /// redirected system DNS into it, so exiting before that is undone lets the
    /// Helper's client-death watchdog kill the kernel ~2 s later with DNS still
    /// pointing into the dead tunnel. With TUN off there is nothing to undo and
    /// quit stays instant.
    ///
    /// `@MainActor` because it reads `AppModel.tunOn`; the delegate callbacks and
    /// the `MenuBarPanel` power button all run on the main thread.
    @MainActor
    static func shouldKeepTunnelAlive() -> Bool {
        AppModel.shared.tunOn
    }

    /// Synchronous teardown: kill kernel + clear system proxy.
    /// Called from both the app delegate (normal quit) and signal handlers (SIGTERM/INT).
    /// Thread-safe and idempotent via a one-shot semaphore.
    /// Ordering is leak-safe by design: system proxy OFF first (so there is never
    /// a window where the proxy points at a kernel we already killed), then DNS,
    /// then the kernel itself.
    ///
    /// Every privileged step goes through a *fresh* XPC connection. The cached
    /// `XPCManager.shared.helper()` proxy is documented throughout this codebase
    /// as silently dropping calls after long-lived use — using it here meant the
    /// quit-time proxy reset could quietly fail and leave a 127.0.0.1 proxy
    /// pointing at a dead kernel (observed: total blackout after the app exits).
    ///
    /// The kernel is stopped through the helper as well, not just `killall`:
    /// this process runs as the user and therefore *cannot* signal a root-owned
    /// mihomo (TUN mode), which is why the helper is asked first.
    ///
    /// This *does* now race the helper's own client-death cleanup
    /// (`Sources/Helper/main.swift`, `handleClientExit`, which stops root mihomo
    /// ~2 s after the GUI process dies) — but by design, not by accident: quit
    /// with TUN up returns `.terminateLater`, so this teardown runs while the
    /// process is still alive and the helper watchdog has not been triggered.
    /// The watchdog only fires if this teardown is itself wedged, and then its
    /// work is the fallback rather than a competitor.
    static func performCleanup() {
        // One-shot: the first caller proceeds, subsequent callers return immediately
        guard _cleanupOnce.wait(timeout: .now()) == .success else { return }

        // 0. Flush traffic history (best effort). save() is throttled to a 5 s
        //    cadence, so quitting right after activity would otherwise lose the
        //    last batch; it touches no network state, so it must not reorder or
        //    delay the steps below. On the main thread (willTerminate) run it
        //    synchronously — a semaphore wait there would block the very actor
        //    the Task needs, stalling quit by the full timeout. From the signal
        //    handler's background queue, hop via MainActor with a bounded wait.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                AppModel.shared.history.save()
            }
        } else {
            let historyFlush = DispatchSemaphore(value: 0)
            Task { @MainActor in
                AppModel.shared.history.save()
                historyFlush.signal()
            }
            _ = historyFlush.wait(timeout: .now() + 1)
        }

        // 1. System proxy OFF (privileged, fresh connection).
        _ = callHelperSync { helper, done in
            helper.setSystemProxy(enabled: false, port: 0) { _ in done() }
        }

        // 2. Restore system DNS if TUN had redirected it into the (now dying)
        //    tunnel — otherwise all DNS black-holes after quit. Targets the
        //    service recorded at redirect time (N9), falling back to default.
        //
        //    Runs unconditionally: every caller now reaches this with the tunnel
        //    meant to come down. Quit used to be the exception — TUN-on quit was
        //    cancelled and the app hid in the menu bar, so cleanup had to be
        //    skipped there. That behaviour is gone: `applicationShouldTerminate`
        //    now holds the quit (`.terminateLater`) until this teardown finishes,
        //    so there is no longer any keep-alive branch to guard against.
        //
        //    审查高-1 修复：恢复**失败/超时也必须保留账本**。旧实现无论成败都在
        //    最后无条件清掉三个 key —— 一次 2s 超时就让整个状态机永久失忆：
        //    系统 DNS 仍钉在 198.18.x，而 `restoreTunnelDNS()` 首行 guard 直接
        //    return、reconcile 两个分支同时失明，只剩自带盲区的 sweep 兜底，
        //    用户看到的正是「退出 ClashHalo 之后全网打不开」。
        //
        //    现在清账动作完全交给 `TunnelDNSLedger.restore`：它只在 networksetup
        //    写成功后清 key，失败则保留待重试。保留是安全的，有两条独立兜底：
        //      · Helper 的客户端死亡看门狗（kqueue NOTE_EXIT → handleClientExit
        //        → restoreDNSIfTunnelPinned），GUI 一死就会还原 DNS；
        //      · 下次启动的 reconcile / sweep，按账本与观测状态续修。
        //
        //    两个属主都要还原（TUN 的 198.18.x、代理 redir-host 模式的
        //    127.0.0.1）：退出后内核已停，两者指向的解析器都不会再应答。
        //    限时仍是 2s —— 退出不能挂住；超时现在只是「留着账本交给上面两条
        //    兜底」，不再是「失忆 + 黑洞」。
        //
        //    前置 `isAnyActive()`（同步读 UserDefaults，零 fork）：没有账就不必
        //    起 Task、也不必等信号量。信号处理路径上并发运行时可能已经不可用，
        //    无条件等待会让**每次退出**都白等满 2 秒。
        //    No keep-alive branch here, and none is possible: TUN intent is never
        //    persisted and the Helper stops any root kernel ~2 s after the GUI
        //    process dies (`handleClientExit` → `stopMihomoInternal`), so a
        //    tunnel cannot survive a quit no matter what this function does.
        //    Quit therefore always means "tear down", and both the DNS restore
        //    and the kernel stop below stay unconditional.
        if TunnelDNSLedger.isAnyActive() {
            let sema = DispatchSemaphore(value: 0)
            Task {
                await TunnelDNSLedger.restoreAll(log: { AppModel.appendAppLog($0) })
                sema.signal()
            }
            if sema.wait(timeout: .now() + 2) == .timedOut {
                AppModel.appendAppLog("[DNSLedger] 退出清理：DNS 还原限时未完成，**保留账本**交 Helper 死亡清理与下次启动续修")
            }
        }

        // 3. Stop the kernel: helper first (only it can signal a root-owned
        //    mihomo), then a user-level killall for a user-mode kernel the
        //    helper never started.
        _ = callHelperSync { helper, done in
            helper.stopMihomo { _ in done() }
        }
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["-9", "mihomo"]
        kill.standardOutput = Pipe(); kill.standardError = Pipe()
        try? kill.run(); kill.waitUntilExit()
    }

    /// One-shot privileged call over a throwaway XPC connection, bounded so quit
    /// can never hang. Returns false if the helper is absent/unreachable/slow.
    @discardableResult
    private static func callHelperSync(
        timeout: TimeInterval = 2.0,
        _ body: (HelperProtocol, @escaping () -> Void) -> Void
    ) -> Bool {
        guard XPCManager.shared.checkStatus() == .enabled else { return false }
        let conn = NSXPCConnection(machServiceName: "com.clashhalo.helper", options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()
        defer { conn.invalidate() }
        let sema = DispatchSemaphore(value: 0)
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in sema.signal() }) as? HelperProtocol else {
            return false
        }
        body(proxy) { sema.signal() }
        return sema.wait(timeout: .now() + timeout) == .success
    }

    private static let _cleanupOnce = DispatchSemaphore(value: 1)
}

// MARK: - App

@main
struct ClashHaloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // Single-instance window: `WindowGroup` spawns a NEW window on every
        // openWindow(id:) call (it supports multiple windows), which piled up
        // duplicate windows from the menu-bar navigation. `Window` is a singleton
        // scene — openWindow(id:) fronts the existing one, or recreates it if closed.
        Window("ClashHalo", id: "main") {
            ContentView()
                .environmentObject(model)
                .tint(DS.Palette.accent)
                .frame(minWidth: 940, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.titleBar)

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(model)
                .tint(DS.Palette.accent)
        } label: {
            Image(model.reachable ? "StatusBarConnected" : "StatusBarDisconnected")
        }
        .menuBarExtraStyle(.window)
    }
}
