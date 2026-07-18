import Foundation
import ServiceManagement

/// Ensures a CheckedContinuation is resumed exactly once across the
/// reply / error / timeout race in `verifyConnectivity`.
private final class ResumeBox {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<Bool, Never>
    init(_ c: CheckedContinuation<Bool, Never>) { cont = c }
    func finish(_ v: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !done { done = true; cont.resume(returning: v) }
    }
}

public class XPCManager {
    public static let shared = XPCManager()

    private var connection: NSXPCConnection?
    /// Injected log sink (set by AppModel). Lets this layer report XPC events
    /// without referencing AppModel directly (decouples helper layer from GUI).
    public var onLog: (@Sendable (String) -> Void)?

    private init() {}

    public func helper() -> HelperProtocol? {
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: "com.clashhalo.helper", options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            conn.interruptionHandler = { [weak self] in
                self?.onLog?("XPC 通讯中断")
                self?.connection?.invalidate()
                self?.connection = nil
            }
            conn.invalidationHandler = { [weak self] in
                self?.onLog?("XPC 通讯失效")
                self?.connection = nil
            }
            conn.resume()
            connection = conn
        }
        return connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.onLog?("XPC 错误: \(error.localizedDescription)")
            self?.connection = nil
        }) as? HelperProtocol
    }

    /// Force-invalidate the cached connection. Called before sleep or after
    /// wake to ensure stale Mach ports are torn down cleanly.
    public func resetConnection() {
        connection?.invalidate()
        connection = nil
    }
    
    /// Whether the helper *plist* **and binary** are installed on disk. NOTE: this
    /// is still NOT proof the helper is loaded/running — use
    /// `verifyConnectivity()` for that. Requiring both avoids the false-positive
    /// where a leftover LaunchDaemon plist points at a missing binary (launchd
    /// EX_CONFIG) and every XPC call logs "Couldn't communicate with a helper".
    public func checkStatus() -> SMAppService.Status {
        let fm = FileManager.default
        let plistOK = fm.fileExists(atPath: "/Library/LaunchDaemons/com.clashhalo.helper.plist")
        let binaryOK = fm.fileExists(atPath: "/Library/PrivilegedHelperTools/com.clashhalo.helper")
        if plistOK && binaryOK {
            return .enabled
        }
        return .notFound
    }

    /// Actively verify the helper is reachable, not merely installed (B3/B4).
    /// Performs a low-timeout `getVersion` XPC handshake over a throwaway
    /// connection; returns false on connection error or timeout. A stale/broken
    /// plist (installed but not loaded) therefore correctly reports unavailable.
    public func verifyConnectivity(timeout: TimeInterval = 1.5) async -> Bool {
        guard checkStatus() == .enabled else { return false }
        let conn = NSXPCConnection(machServiceName: "com.clashhalo.helper", options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let box = ResumeBox(cont)
            let finish: (Bool) -> Void = { ok in box.finish(ok); conn.invalidate() }
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in finish(false) }) as? HelperProtocol else {
                finish(false); return
            }
            proxy.getVersion { v in finish(!v.isEmpty) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
    
    /// Set the macOS system proxy via the helper over a *fresh* connection.
    /// Returns true/false on a real helper reply, or nil if the helper is
    /// unreachable / errored / timed out (so the caller can fall back).
    ///
    /// Uses a throwaway connection instead of the cached `helper()` proxy: the
    /// cached connection silently drops calls in practice (the helper logs the
    /// 5 s getVersion handshakes from verifyConnectivity's fresh connections, but
    /// never the setSystemProxy sent over the cached one), so a fresh connection
    /// — the same pattern verifyConnectivity proves reliable — is used here too.
    public func callSystemProxy(enabled: Bool, port: Int, timeout: TimeInterval = 5.0) async -> Bool? {
        guard checkStatus() == .enabled else { return nil }
        let conn = NSXPCConnection(machServiceName: "com.clashhalo.helper", options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool?, Never>) in
            let lock = NSLock(); var done = false
            let finish: (Bool?) -> Void = { v in
                lock.lock(); defer { lock.unlock() }
                if !done { done = true; cont.resume(returning: v); conn.invalidate() }
            }
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] error in
                self?.onLog?("setSystemProxy XPC 错误: \(error.localizedDescription)")
                finish(nil)
            }) as? HelperProtocol else { finish(nil); return }
            proxy.setSystemProxy(enabled: enabled, port: port) { ok in finish(ok) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    public func callGatewayMode(enabled: Bool, timeout: TimeInterval = 5.0) async -> Bool? {
        guard checkStatus() == .enabled else { return nil }
        let conn = NSXPCConnection(machServiceName: "com.clashhalo.helper", options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool?, Never>) in
            let lock = NSLock(); var done = false
            let finish: (Bool?) -> Void = { v in
                lock.lock(); defer { lock.unlock() }
                if !done { done = true; cont.resume(returning: v); conn.invalidate() }
            }
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] error in
                self?.onLog?("setGatewayMode XPC 错误: \(error.localizedDescription)")
                finish(nil)
            }) as? HelperProtocol else { finish(nil); return }
            proxy.setGatewayMode(enabled: enabled) { ok in finish(ok) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// Physically neutralize a lingering mihomo utun (down + delete IP + route
    /// flush) via the helper over a *fresh* connection. Returns true on a helper
    /// reply confirming success, false on a helper reply reporting failure, or
    /// nil if the helper is unreachable / errored / timed out. Fresh connection
    /// (not the cached `helper()` proxy) for the same reason callSystemProxy /
    /// callGatewayMode use one — cached connections silently drop calls.
    public func callCleanupTUNResidual(timeout: TimeInterval = 5.0) async -> Bool? {
        guard checkStatus() == .enabled else { return nil }
        let conn = NSXPCConnection(machServiceName: "com.clashhalo.helper", options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool?, Never>) in
            let lock = NSLock(); var done = false
            let finish: (Bool?) -> Void = { v in
                lock.lock(); defer { lock.unlock() }
                if !done { done = true; cont.resume(returning: v); conn.invalidate() }
            }
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] error in
                self?.onLog?("cleanupTUNResidual XPC 错误: \(error.localizedDescription)")
                finish(nil)
            }) as? HelperProtocol else { finish(nil); return }
            proxy.cleanupTUNResidual { ok in finish(ok) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// Start mihomo as root via the helper over a *fresh* connection.
    /// Returns true/false on a real helper reply, or nil if unreachable /
    /// errored / timed out. Must not use the cached `helper()` proxy — that
    /// connection silently drops start/stop calls after long-lived use, which
    /// left `ensureRunning` with `isRoot=true` as a complete no-op and made
    /// TUN re-enable look like "权限不足 / 启动超时".
    public func callStartMihomo(binPath: String, homeDir: String, timeout: TimeInterval = 8.0) async -> Bool? {
        guard checkStatus() == .enabled else { return nil }
        let conn = NSXPCConnection(machServiceName: "com.clashhalo.helper", options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool?, Never>) in
            let lock = NSLock(); var done = false
            let finish: (Bool?) -> Void = { v in
                lock.lock(); defer { lock.unlock() }
                if !done { done = true; cont.resume(returning: v); conn.invalidate() }
            }
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] error in
                self?.onLog?("startMihomo XPC 错误: \(error.localizedDescription)")
                finish(nil)
            }) as? HelperProtocol else { finish(nil); return }
            proxy.startMihomo(binPath: binPath, homeDir: homeDir) { ok in finish(ok) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// Inject SD-WAN exclude static routes via a *fresh* helper connection.
    public func callSetupExcludeRoutes(_ routes: [String: String], timeout: TimeInterval = 5.0) async -> Bool? {
        guard checkStatus() == .enabled else { return nil }
        let conn = NSXPCConnection(machServiceName: "com.clashhalo.helper", options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool?, Never>) in
            let lock = NSLock(); var done = false
            let finish: (Bool?) -> Void = { v in
                lock.lock(); defer { lock.unlock() }
                if !done { done = true; cont.resume(returning: v); conn.invalidate() }
            }
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] error in
                self?.onLog?("setupExcludeRoutes XPC 错误: \(error.localizedDescription)")
                finish(nil)
            }) as? HelperProtocol else { finish(nil); return }
            proxy.setupExcludeRoutes(routes) { ok in finish(ok) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// Clear injected exclude static routes via a *fresh* helper connection.
    public func callCleanupAllExcludeRoutes(timeout: TimeInterval = 5.0) async -> Bool? {
        guard checkStatus() == .enabled else { return nil }
        let conn = NSXPCConnection(machServiceName: "com.clashhalo.helper", options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool?, Never>) in
            let lock = NSLock(); var done = false
            let finish: (Bool?) -> Void = { v in
                lock.lock(); defer { lock.unlock() }
                if !done { done = true; cont.resume(returning: v); conn.invalidate() }
            }
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] error in
                self?.onLog?("cleanupAllExcludeRoutes XPC 错误: \(error.localizedDescription)")
                finish(nil)
            }) as? HelperProtocol else { finish(nil); return }
            proxy.cleanupAllExcludeRoutes { ok in finish(ok) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// Install / replace the privileged helper LaunchDaemon.
    /// - Parameter prompt: Optional explanation shown before the admin password sheet.
    public func installDaemon(prompt: String? = nil) async -> Bool {
        let bundlePath = Bundle.main.bundlePath
        let helperSrc = "\(bundlePath)/Contents/MacOS/com.clashhalo.helper"
        let helperDst = "/Library/PrivilegedHelperTools/com.clashhalo.helper"
        let plistDst = "/Library/LaunchDaemons/com.clashhalo.helper.plist"
        let legacyHelperDst = "/Library/PrivilegedHelperTools/com.clashpow.helper"
        let legacyPlistDst = "/Library/LaunchDaemons/com.clashpow.helper.plist"

        // Preflight: never tear down a working LaunchDaemon if the source helper
        // binary is missing from this app bundle. A plain `xcodebuild` Debug run
        // does not embed com.clashhalo.helper (only make.sh / Scripts/build-debug.sh
        // do). Without this guard, `cp` fails then `bootout` still runs and leaves
        // the system with a plist pointing at a deleted binary (EX_CONFIG loop).
        guard FileManager.default.fileExists(atPath: helperSrc) else {
            onLog?("安装特权服务失败：App 内未找到 Helper 二进制（\(helperSrc)）。请用 Scripts/build-debug.sh 或 make.sh 构建后再安装。")
            return false
        }

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.clashhalo.helper</string>
            <key>MachServices</key><dict><key>com.clashhalo.helper</key><true/></dict>
            <key>ProgramArguments</key><array><string>\(helperDst)</string></array>
            <key>SMAuthorizedClients</key><array><string>identifier "com.clashhalo.app"</string></array>
            <key>KeepAlive</key><true/>
            <key>RunAtLoad</key><true/>
            <key>StandardOutPath</key><string>/Library/Logs/ClashHalo/helper.out.log</string>
            <key>StandardErrorPath</key><string>/Library/Logs/ClashHalo/helper.err.log</string>
        </dict>
        </plist>
        """

        let tempPlist = NSTemporaryDirectory() + "com.clashhalo.helper.plist"
        try? plistContent.write(toFile: tempPlist, atomically: true, encoding: .utf8)

        // Stage the new binary/plist first; only bootout the old service after
        // the destination files are in place. `set -e` aborts on any hard error
        // so a failed cp never reaches bootout.
        // This path also covers upgrades: replace-in-place needs no separate uninstall.
        let script = """
        set -e; \
        test -f "\(helperSrc)"; \
        mkdir -p /Library/PrivilegedHelperTools; \
        mkdir -p /Library/Logs/ClashHalo; \
        chmod 755 /Library/Logs/ClashHalo; \
        cp "\(helperSrc)" "\(helperDst).new"; \
        xattr -rd com.apple.quarantine "\(helperDst).new" 2>/dev/null || true; \
        xattr -cr "\(helperDst).new" 2>/dev/null || true; \
        chown root:wheel "\(helperDst).new"; \
        chmod 755 "\(helperDst).new"; \
        cp "\(tempPlist)" "\(plistDst).new"; \
        chown root:wheel "\(plistDst).new"; \
        chmod 644 "\(plistDst).new"; \
        launchctl bootout system "\(legacyPlistDst)" 2>/dev/null || true; \
        rm -f "\(legacyPlistDst)" "\(legacyHelperDst)"; \
        launchctl bootout system "\(plistDst)" 2>/dev/null || true; \
        mv -f "\(helperDst).new" "\(helperDst)"; \
        mv -f "\(plistDst).new" "\(plistDst)"; \
        launchctl enable system/com.clashhalo.helper; \
        launchctl bootstrap system "\(plistDst)"; \
        launchctl kickstart -k system/com.clashhalo.helper
        """

        let ok = await EngineControl.runAdmin(script, prompt: prompt ?? Self.defaultInstallPrompt)
        if ok {
            connection = nil // Force reconnect
        }
        return ok
    }

    /// Default explanation for a first-time Helper install.
    public static let defaultInstallPrompt = """
    ClashHalo 需要安装特权辅助服务（Helper v\(kSharedHelperVersion)）。

    用途：
    · 系统代理开关
    · TUN 虚拟网卡（Root 模式）
    · 网关中枢 IP 转发
    · 网络拓扑静态路由与僵尸 TUN 清理

    点击「继续」后将请求管理员密码完成安装。
    """

    /// Build the pre-auth explanation for a forced Helper upgrade.
    public static func upgradePrompt(from current: String, to target: String) -> String {
        """
        ClashHalo 需要更新特权辅助服务（Helper）。

        当前版本：v\(current)
        目标版本：v\(target)

        更新说明：
        · 保持 Helper 与客户端协议一致，避免 XPC 通信失败
        · 修复安装/升级过程中可能出现的服务残留与连通问题
        · 保障 TUN、系统代理、网关中枢、网络拓扑等特权能力可用

        点击「继续」后将请求管理员密码，一次授权完成更新。
        """
    }

    /// Full upgrade: replace the installed helper with the bundled one.
    /// Uses a single admin authorization (installDaemon already replaces in place);
    /// no separate uninstall pass — that used to force two password prompts.
    public func upgradeDaemon(prompt: String? = nil) async -> Bool {
        let helperSrc = Bundle.main.bundlePath + "/Contents/MacOS/com.clashhalo.helper"
        guard FileManager.default.fileExists(atPath: helperSrc) else {
            onLog?("升级特权服务失败：App 内未找到 Helper 二进制。请用 Scripts/build-debug.sh 或 make.sh 构建后再升级。")
            return false
        }
        connection = nil
        return await installDaemon(prompt: prompt)
    }

    public func uninstallDaemon(prompt: String? = nil) async -> Bool {
        let plistDst = "/Library/LaunchDaemons/com.clashhalo.helper.plist"
        let helperDst = "/Library/PrivilegedHelperTools/com.clashhalo.helper"
        let legacyPlistDst = "/Library/LaunchDaemons/com.clashpow.helper.plist"
        let legacyHelperDst = "/Library/PrivilegedHelperTools/com.clashpow.helper"

        // Use bootout (NOT `unload -w`): the -w flag persistently writes the
        // service into launchd's disabled database, after which a later
        // bootstrap loads the plist but launchd refuses to start it. bootout
        // tears down without poisoning future installs.
        let script = """
        launchctl bootout system "\(plistDst)" 2>/dev/null || true; \
        launchctl bootout system "\(legacyPlistDst)" 2>/dev/null || true; \
        rm -f "\(plistDst)"; \
        rm -f "\(helperDst)"; \
        rm -f "\(legacyPlistDst)"; \
        rm -f "\(legacyHelperDst)"
        """

        let uninstallPrompt = prompt ?? """
        ClashHalo 将卸载特权辅助服务（Helper）。

        卸载后 TUN、网关中枢与部分系统代理能力将不可用，可随时在设置中重新安装。

        点击「继续」后将请求管理员密码。
        """

        let ok = await EngineControl.runAdmin(script, prompt: uninstallPrompt)
        if ok {
            connection = nil
        }
        return ok
    }
}
