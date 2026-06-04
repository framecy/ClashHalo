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
            let conn = NSXPCConnection(machServiceName: "com.clashpow.helper", options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            conn.interruptionHandler = { [weak self] in
                self?.onLog?("XPC 通讯中断")
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
    
    /// Whether the helper *plist* is installed on disk. NOTE: this is NOT proof
    /// the helper is loaded/running — use `verifyConnectivity()` for that.
    public func checkStatus() -> SMAppService.Status {
        let fm = FileManager.default
        if fm.fileExists(atPath: "/Library/LaunchDaemons/com.clashpow.helper.plist") {
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
        let conn = NSXPCConnection(machServiceName: "com.clashpow.helper", options: .privileged)
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
    
    public func installDaemon() async -> Bool {
        let bundlePath = Bundle.main.bundlePath
        let helperSrc = "\(bundlePath)/Contents/MacOS/com.clashpow.helper"
        let helperDst = "/Library/PrivilegedHelperTools/com.clashpow.helper"
        let plistDst = "/Library/LaunchDaemons/com.clashpow.helper.plist"
        
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.clashpow.helper</string>
            <key>MachServices</key><dict><key>com.clashpow.helper</key><true/></dict>
            <key>ProgramArguments</key><array><string>\(helperDst)</string></array>
            <key>SMAuthorizedClients</key><array><string>identifier "com.clashpow.app"</string></array>
            <key>KeepAlive</key><true/>
            <key>RunAtLoad</key><true/>
            <key>StandardOutPath</key><string>/Library/Logs/ClashPow/helper.out.log</string>
            <key>StandardErrorPath</key><string>/Library/Logs/ClashPow/helper.err.log</string>
        </dict>
        </plist>
        """
        
        let tempPlist = NSTemporaryDirectory() + "com.clashpow.helper.plist"
        try? plistContent.write(toFile: tempPlist, atomically: true, encoding: .utf8)
        
        let script = """
        mkdir -p /Library/PrivilegedHelperTools; \
        mkdir -p /Library/Logs/ClashPow; \
        chmod 755 /Library/Logs/ClashPow; \
        cp "\(helperSrc)" "\(helperDst)"; \
        xattr -rd com.apple.quarantine "\(helperDst)" 2>/dev/null || true; \
        xattr -cr "\(helperDst)" 2>/dev/null || true; \
        chown root:wheel "\(helperDst)"; \
        chmod 755 "\(helperDst)"; \
        cp "\(tempPlist)" "\(plistDst)"; \
        chown root:wheel "\(plistDst)"; \
        chmod 644 "\(plistDst)"; \
        launchctl bootout system "\(plistDst)" 2>/dev/null || true; \
        launchctl enable system/com.clashpow.helper; \
        launchctl bootstrap system "\(plistDst)"; \
        launchctl kickstart -k system/com.clashpow.helper
        """
        
        let ok = await EngineControl.runAdmin(script)
        if ok {
            connection = nil // Force reconnect
        }
        return ok
    }
    
    /// Full upgrade: uninstall old binary + install new one.
    /// Used when the running helper version is older than kExpectedHelperVersion.
    public func upgradeDaemon() async -> Bool {
        _ = await uninstallDaemon()
        // Give launchd a moment to fully remove the service before reinstalling
        try? await Task.sleep(nanoseconds: 800_000_000)
        connection = nil
        return await installDaemon()
    }

    public func uninstallDaemon() async -> Bool {
        let plistDst = "/Library/LaunchDaemons/com.clashpow.helper.plist"
        let helperDst = "/Library/PrivilegedHelperTools/com.clashpow.helper"
        
        // Use bootout (NOT `unload -w`): the -w flag persistently writes the
        // service into launchd's disabled database, after which a later
        // bootstrap loads the plist but launchd refuses to start it. bootout
        // tears down without poisoning future installs.
        let script = """
        launchctl bootout system "\(plistDst)" 2>/dev/null || true; \
        rm -f "\(plistDst)"; \
        rm -f "\(helperDst)"
        """
        
        let ok = await EngineControl.runAdmin(script)
        if ok {
            connection = nil
        }
        return ok
    }
}
