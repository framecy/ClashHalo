import SwiftUI

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.performCleanup()
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
    /// mihomo (TUN mode), which used to survive a normal quit together with its
    /// utun until the helper's client-death watchdog eventually caught it.
    static func performCleanup() {
        // One-shot: the first caller proceeds, subsequent callers return immediately
        guard _cleanupOnce.wait(timeout: .now()) == .success else { return }

        // 1. System proxy OFF (privileged, fresh connection).
        _ = callHelperSync { helper, done in
            helper.setSystemProxy(enabled: false, port: 0) { _ in done() }
        }

        // 2. Restore system DNS if TUN had redirected it into the (now dying)
        //    tunnel — otherwise all DNS black-holes after quit.
        let d = UserDefaults.standard
        if d.bool(forKey: AppModel.kDNSOverriddenKey) {
            let saved = (d.string(forKey: AppModel.kDNSSavedKey) ?? "")
                .split(separator: ",").map(String.init)
            let sema = DispatchSemaphore(value: 0)
            Task {
                await EngineControl.applySystemDNS(saved)
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + 2)
            d.set(false, forKey: AppModel.kDNSOverriddenKey)
            d.removeObject(forKey: AppModel.kDNSSavedKey)
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
