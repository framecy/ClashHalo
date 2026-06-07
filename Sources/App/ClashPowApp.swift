import SwiftUI

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.performCleanup()
    }

    /// Synchronous teardown: kill kernel + clear system proxy.
    /// Called from both the app delegate (normal quit) and signal handlers (SIGTERM/INT).
    /// Thread-safe and idempotent via a one-shot semaphore.
    static func performCleanup() {
        // One-shot: the first caller proceeds, subsequent callers return immediately
        guard _cleanupOnce.wait(timeout: .now()) == .success else { return }

        // Kill kernel immediately — no graceful shutdown at exit time
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["-9", "mihomo"]
        kill.standardOutput = Pipe(); kill.standardError = Pipe()
        try? kill.run(); kill.waitUntilExit()

        // Restore system DNS if TUN had redirected it into the (now dead) tunnel —
        // otherwise all DNS black-holes after quit. Synchronous; networksetup is fast.
        let d = UserDefaults.standard
        if d.bool(forKey: AppModel.kDNSOverriddenKey) {
            let saved = (d.string(forKey: AppModel.kDNSSavedKey) ?? "")
                .split(separator: ",").map(String.init)
            EngineControl.applySystemDNS(saved)
            d.set(false, forKey: AppModel.kDNSOverriddenKey)
            d.removeObject(forKey: AppModel.kDNSSavedKey)
        }

        // Clear system proxy via helper XPC (helper is a persistent daemon, survives app exit)
        let sema = DispatchSemaphore(value: 0)
        if let helper = XPCManager.shared.helper() {
            helper.setSystemProxy(enabled: false, port: 0) { _ in sema.signal() }
            _ = sema.wait(timeout: .now() + 2)
        }
    }

    private static let _cleanupOnce = DispatchSemaphore(value: 1)
}

// MARK: - App

@main
struct ClashPowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // Single-instance window: `WindowGroup` spawns a NEW window on every
        // openWindow(id:) call (it supports multiple windows), which piled up
        // duplicate windows from the menu-bar navigation. `Window` is a singleton
        // scene — openWindow(id:) fronts the existing one, or recreates it if closed.
        Window("ClashPow", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 620)
                // Locked to dark: the design tokens (DS.Palette.cardBg/…) are
                // dark-only fixed colors, so a light scheme would render dark
                // cards on a light background. Re-introduce a light theme only
                // once the palette uses scheme-adaptive colors.
                .preferredColorScheme(.dark)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.titleBar)

        MenuBarExtra {
            MenuBarPanel().environmentObject(model)
        } label: {
            Image(systemName: model.reachable ? "bolt.fill" : "bolt.slash")
        }
        .menuBarExtraStyle(.window)
    }
}
