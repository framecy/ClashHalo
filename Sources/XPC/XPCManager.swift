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

    /// F12: `connection` 被多线程读写——helper() 调用方、XPC 中断/失效回调、
    /// resetConnection、安装/升级/卸载流程。所有读写统一走 connectionLock。
    private let connectionLock = NSLock()
    private var connection: NSXPCConnection?
    /// Injected log sink (set by AppModel). Lets this layer report XPC events
    /// without referencing AppModel directly (decouples helper layer from GUI).
    public var onLog: (@Sendable (String) -> Void)?

    /// Timestamp of the last *successful* verifyConnectivity handshake. A short
    /// TTL lets multi-step privileged flows (TUN enable = verify → ensureRunning
    /// → re-verify) skip redundant XPC handshakes without ever caching failure.
    private var lastVerifiedAt: Date = .distantPast
    private let verifyCacheTTL: TimeInterval = 2.0

    private init() {}

    public func helper() -> HelperProtocol? {
        connectionLock.lock()
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: "com.clashhalo.helper", options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            conn.interruptionHandler = { [weak self] in
                self?.onLog?("XPC 通讯中断")
                self?.takeConnection()?.invalidate()
            }
            conn.invalidationHandler = { [weak self] in
                self?.onLog?("XPC 通讯失效")
                self?.clearConnection()
            }
            conn.resume()
            connection = conn
        }
        let conn = connection
        connectionLock.unlock()
        return conn?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.onLog?("XPC 错误: \(error.localizedDescription)")
            self?.clearConnection()
        }) as? HelperProtocol
    }

    /// F12: 锁内取出并清空当前连接。invalidate() 由调用方在**锁外**执行——
    /// 它可能触发 invalidationHandler，而 NSLock 不可重入，持锁调用会死锁。
    private func takeConnection() -> NSXPCConnection? {
        connectionLock.lock()
        let conn = connection
        connection = nil
        connectionLock.unlock()
        return conn
    }

    /// F12: 只丢弃缓存连接、不 invalidate（错误/失效回调路径——连接已死或
    /// 正在死，重复 invalidate 无意义）。
    private func clearConnection() {
        connectionLock.lock()
        connection = nil
        connectionLock.unlock()
    }

    /// Force-invalidate the cached connection. Called before sleep or after
    /// wake to ensure stale Mach ports are torn down cleanly.
    public func resetConnection() {
        takeConnection()?.invalidate()
        lastVerifiedAt = .distantPast
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

    /// Whether launchd currently has the helper service loaded — i.e. more than
    /// "files happen to be on disk". Lets the caller tell "not installed" apart
    /// from "installed but broken", which need different remedies.
    ///
    /// `launchctl print system/<label>` is readable as a normal user (verified on
    /// macOS 27.3); a 2 s timeout keeps a wedged launchd from stalling startup.
    public func isServiceLoaded() async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                p.arguments = ["print", "system/com.clashhalo.helper"]
                p.standardOutput = Pipe()
                p.standardError = Pipe()
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                timer.schedule(deadline: .now() + 2.0)
                timer.setEventHandler { if p.isRunning { p.terminate() } }
                timer.resume()
                do {
                    try p.run()
                    p.waitUntilExit()
                } catch {
                    timer.cancel()
                    cont.resume(returning: false)
                    return
                }
                timer.cancel()
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
    }

    /// Is the installed helper byte-for-byte the one bundled in this app?
    ///
    /// The version string only comes back over a successful XPC handshake — exactly
    /// the information missing when the helper is unreachable. Byte equality is the
    /// only version-independent, XPC-free signal (≈0.3 MB, once per launch), and it
    /// also covers the ordinary "new app, old helper" case.
    public func installedHelperMatchesBundle() -> Bool {
        let src = Bundle.main.bundlePath + "/Contents/MacOS/com.clashhalo.helper"
        let dst = "/Library/PrivilegedHelperTools/com.clashhalo.helper"
        let fm = FileManager.default
        guard let bundled = fm.contents(atPath: src), let installed = fm.contents(atPath: dst) else {
            return false
        }
        return bundled == installed
    }

    /// Actively verify the helper is reachable, not merely installed (B3/B4).
    /// Performs a low-timeout `getVersion` XPC handshake over a throwaway
    /// connection; returns false on connection error or timeout. A stale/broken
    /// plist (installed but not loaded) therefore correctly reports unavailable.
    ///
    /// A success within the last `verifyCacheTTL` seconds short-circuits (after
    /// the cheap on-disk install check) so a single TUN/Gateway flow doesn't pay
    /// 2–3 identical handshakes. Failures are never cached, and install /
    /// upgrade / uninstall / resetConnection all invalidate the cache.
    public func verifyConnectivity(timeout: TimeInterval = 1.5) async -> Bool {
        guard checkStatus() == .enabled else {
            lastVerifiedAt = .distantPast
            return false
        }
        if Date().timeIntervalSince(lastVerifiedAt) < verifyCacheTTL { return true }
        let conn = NSXPCConnection(machServiceName: "com.clashhalo.helper", options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let box = ResumeBox(cont)
            let finish: (Bool) -> Void = { ok in box.finish(ok); conn.invalidate() }
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in finish(false) }) as? HelperProtocol else {
                finish(false); return
            }
            proxy.getVersion { v in finish(!v.isEmpty) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
        lastVerifiedAt = ok ? Date() : .distantPast
        return ok
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
    ///
    /// Timeout is 60s (was 15s, before that 5s)：Helper 侧一次 enable 最坏是
    /// 「N 个服务 × 7 条 networksetup 写命令 × 5s 单条超时 × 1 次重试」（见
    /// ProxyManager.writeCmdTimeout），SC 动态存储锁竞争时单条即可打满 5s。
    /// 15s 实测仍会在 Helper 正常慢速写入时误判超时，随后本地回退与 Helper
    /// **并发写同一 SC 存储**——正是 XPC-9 修掉的半提交形态。60s 覆盖常见慢
    /// 形态（秒级~十几秒），不是理论上界（每条都打满 5s×2×N 时本地回退同样
    /// 会失败，此时宁可等满也不要抢跑并发写）。
    public func callSystemProxy(enabled: Bool, port: Int, timeout: TimeInterval = 60.0) async -> Bool? {
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
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                // Only log+fall back if the call hasn't completed yet. Without
                // this guard, the timer fires 15s after *every* call regardless
                // of whether it succeeded in 4s — the continuation is already
                // resumed (done=true) so finish(nil) is a no-op, but the log
                // still prints "XPC 超时" and misleads the user into thinking
                // the Helper was unreachable when it actually worked fine.
                lock.lock()
                let alreadyDone = done
                lock.unlock()
                if alreadyDone { return }
                self?.onLog?("setSystemProxy XPC 超时（\(Int(timeout))s 无响应），回退到本地 networksetup")
                finish(nil)
            }
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

    /// Stop root-owned mihomo via a *fresh* helper connection with a hard timeout.
    /// The previous path used the cached `helper()` proxy with an unbounded
    /// continuation — if Helper's stopMihomo blocked (Thread.sleep up to 1.5s
    /// plus killall), the MainActor kernel-switch flow could hang with system
    /// proxy still pointing at a dead 127.0.0.1 and black-hole the whole Mac.
    /// Returns true/false on a real reply, nil on unreachable / error / timeout.
    public func callStopMihomo(timeout: TimeInterval = 4.0) async -> Bool? {
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
                self?.onLog?("stopMihomo XPC 错误: \(error.localizedDescription)")
                finish(nil)
            }) as? HelperProtocol else { finish(nil); return }
            proxy.stopMihomo { ok in finish(ok) }
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

    /// XPC-2: POSIX shell 单引号转义。`'…'` 内一切字符（$、反引号、双引号、
    /// 反斜杠、换行）都是字面量，唯一要处理的是单引号本身，写成 `'\''`。
    /// runAdmin 只转义 AppleScript 层（\ 与 "），往返无损——已用无提权
    /// osascript 回环探针验证（含 $(…)/反引号/引号/反斜杠的恶意路径样本）。
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Install / replace the privileged helper LaunchDaemon.
    /// - Parameter prompt: Optional explanation shown before the admin password sheet.
    public func installDaemon(prompt: PrivilegedPromptContent? = nil) async -> Bool {
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

        // XPC-3: plist 不再写用户可写的 NSTemporaryDirectory() 固定名临时文件
        // （旧实现在密码框挂起的整个窗口内可被同用户进程替换 → root 装入攻击者
        // LaunchDaemon）。内容全是常量，直接在 root script 内用引号 heredoc
        // 生成到 stage 目标，不经任何用户可写中间文件。

        // Stage the new binary/plist first; only bootout the old service after
        // the destination files are in place. `set -e` aborts on any hard error
        // so a failed cp never reaches bootout.
        // This path also covers upgrades: replace-in-place needs no separate uninstall.
        //
        // XPC-2: 所有插值路径经 shellQuote 单引号转义——bundle 路径（DMG 卷名/
        // 文件夹名）携带 $(…)/反引号/引号时不再能向 root shell 注入命令。
        let script = """
        set -e
        test -f \(Self.shellQuote(helperSrc))
        mkdir -p /Library/PrivilegedHelperTools
        mkdir -p /Library/Logs/ClashHalo
        chmod 755 /Library/Logs/ClashHalo
        cp \(Self.shellQuote(helperSrc)) \(Self.shellQuote(helperDst + ".new"))
        xattr -rd com.apple.quarantine \(Self.shellQuote(helperDst + ".new")) 2>/dev/null || true
        xattr -cr \(Self.shellQuote(helperDst + ".new")) 2>/dev/null || true
        chown root:wheel \(Self.shellQuote(helperDst + ".new"))
        chmod 755 \(Self.shellQuote(helperDst + ".new"))
        cat > \(Self.shellQuote(plistDst + ".new")) <<'EOF'
        \(plistContent)
        EOF
        xattr -rd com.apple.quarantine \(Self.shellQuote(plistDst + ".new")) 2>/dev/null || true
        xattr -cr \(Self.shellQuote(plistDst + ".new")) 2>/dev/null || true
        chown root:wheel \(Self.shellQuote(plistDst + ".new"))
        chmod 644 \(Self.shellQuote(plistDst + ".new"))
        launchctl bootout system \(Self.shellQuote(legacyPlistDst)) 2>/dev/null || true
        rm -f \(Self.shellQuote(legacyPlistDst)) \(Self.shellQuote(legacyHelperDst))
        launchctl bootout system \(Self.shellQuote(plistDst)) 2>/dev/null || true
        mv -f \(Self.shellQuote(helperDst + ".new")) \(Self.shellQuote(helperDst))
        mv -f \(Self.shellQuote(plistDst + ".new")) \(Self.shellQuote(plistDst))
        launchctl enable system/com.clashhalo.helper
        launchctl bootstrap system \(Self.shellQuote(plistDst))
        launchctl kickstart -k system/com.clashhalo.helper
        """

        let ok = await EngineControl.runAdmin(script, prompt: prompt ?? Self.defaultInstallPrompt)
        if ok {
            clearConnection() // Force reconnect
        }
        lastVerifiedAt = .distantPast   // freshly (re)installed — force a real handshake
        return ok
    }

    /// Default explanation for a first-time Helper install.
    public static let defaultInstallPrompt = PrivilegedPromptContent(
        kind: .install,
        title: "安装特权辅助服务",
        subtitle: "ClashHalo 需要一个独立的后台服务来执行系统级网络操作。仅安装一次，可随时在「设置 → 权限」卸载。",
        versionFrom: nil,
        versionTo: "v\(kSharedHelperVersion)",
        bullets: [
            "开关 macOS 系统代理",
            "以 Root 模式启用 TUN 虚拟网卡",
            "网关中枢的 IP 转发",
            "网络拓扑静态路由与僵尸 TUN 清理"
        ],
        confirmTitle: "安装"
    )

    /// Build the pre-auth explanation for a forced Helper upgrade.
    public static func upgradePrompt(from current: String, to target: String) -> PrivilegedPromptContent {
        PrivilegedPromptContent(
            kind: .upgrade,
            title: "更新特权辅助服务",
            subtitle: "客户端已升级，需要将后台服务更新到匹配版本。一次授权即可完成，不会中断当前连接。",
            versionFrom: "v\(current)",
            versionTo: "v\(target)",
            bullets: [
                "保持 Helper 与客户端协议一致，避免 XPC 通信失败",
                "修复服务残留与连通性问题",
                "保障 TUN、系统代理、网关中枢等特权能力可用"
            ],
            confirmTitle: "更新"
        )
    }

    /// Full upgrade: replace the installed helper with the bundled one.
    /// Uses a single admin authorization (installDaemon already replaces in place);
    /// no separate uninstall pass — that used to force two password prompts.
    public func upgradeDaemon(prompt: PrivilegedPromptContent? = nil) async -> Bool {
        let helperSrc = Bundle.main.bundlePath + "/Contents/MacOS/com.clashhalo.helper"
        guard FileManager.default.fileExists(atPath: helperSrc) else {
            onLog?("升级特权服务失败：App 内未找到 Helper 二进制。请用 Scripts/build-debug.sh 或 make.sh 构建后再升级。")
            return false
        }
        clearConnection()
        return await installDaemon(prompt: prompt)
    }

    public func uninstallDaemon(prompt: PrivilegedPromptContent? = nil) async -> Bool {
        let plistDst = "/Library/LaunchDaemons/com.clashhalo.helper.plist"
        let helperDst = "/Library/PrivilegedHelperTools/com.clashhalo.helper"
        let legacyPlistDst = "/Library/LaunchDaemons/com.clashpow.helper.plist"
        let legacyHelperDst = "/Library/PrivilegedHelperTools/com.clashpow.helper"

        // Use bootout (NOT `unload -w`): the -w flag persistently writes the
        // service into launchd's disabled database, after which a later
        // bootstrap loads the plist but launchd refuses to start it. bootout
        // tears down without poisoning future installs.
        // F13: set -e——bootout 带 || true 不受影响，rm -f 对不存在文件不报错；
        // 真实删除失败（如权限异常）不再被静默吞掉、不再假报卸载成功。
        // 转义纪律（P1-5）：与 installDaemon 同口径，路径插值一律经 shellQuote
        // （XPC-2 单引号转义）——此处六处插值此前是裸双引号，路径虽是常量，
        // 但统一走 shellQuote 才能把「插值进 shell 必须转义」钉成纪律。
        let script = """
        set -e; \
        launchctl bootout system \(Self.shellQuote(plistDst)) 2>/dev/null || true; \
        launchctl bootout system \(Self.shellQuote(legacyPlistDst)) 2>/dev/null || true; \
        rm -f \(Self.shellQuote(plistDst)); \
        rm -f \(Self.shellQuote(helperDst)); \
        rm -f \(Self.shellQuote(legacyPlistDst)); \
        rm -f \(Self.shellQuote(legacyHelperDst))
        """

        let uninstallPrompt = prompt ?? PrivilegedPromptContent(
            kind: .uninstall,
            title: "卸载特权辅助服务",
            subtitle: "将移除后台服务及其 LaunchDaemon。可随时在「设置 → 权限」重新安装。",
            bullets: [
                "TUN 虚拟网卡将不可用",
                "网关中枢 IP 转发将不可用",
                "系统代理开关能力受限"
            ],
            confirmTitle: "卸载"
        )

        let ok = await EngineControl.runAdmin(script, prompt: uninstallPrompt)
        if ok {
            clearConnection()
        }
        lastVerifiedAt = .distantPast
        return ok
    }
}
