import Foundation
import Security

let kHelperVersion = "1.0.5"

private let kClientRequirement = "identifier \"com.clashpow.app\""

/// Validate that an incoming XPC peer is the ClashPow app.
/// Three layers, each more permissive than the last, to handle all signing variants:
///   1. Security framework: identifier check with basic-validate-only flags
///   2. SecCodeCopyPath: bundle-root URL check
///   3. proc_pidpath: raw executable path check (most reliable for ad-hoc builds)
func isAuthorizedClient(_ conn: NSXPCConnection) -> Bool {
    let pid = conn.processIdentifier
    guard pid > 0 else { return false }

    // Layer 1: Security framework requirement check.
    // kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources (== kSecCSBasicValidateOnly)
    // skips hash and seal verification — only the code-signing metadata (identifier) is
    // checked. This handles developer-signed and most ad-hoc builds.
    var code: SecCode?
    let attrs = [kSecGuestAttributePid: pid] as CFDictionary
    if SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code {
        var req: SecRequirement?
        if SecRequirementCreateWithString(kClientRequirement as CFString, [], &req) == errSecSuccess,
           let req {
            let flags = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
            if SecCodeCheckValidity(code, flags, req) == errSecSuccess { return true }
        }

        // Layer 2: bundle-root URL from SecStaticCode (SecCodeCopyPath returns the .app bundle root)
        var staticCode: SecStaticCode?
        if SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
           let sc = staticCode {
            var pathURL: CFURL?
            if SecCodeCopyPath(sc, SecCSFlags(rawValue: 0), &pathURL) == errSecSuccess,
               let path = (pathURL as URL?)?.path,
               (path.contains("/ClashPow.app") || path.hasSuffix("/ClashPow")) {
                log("isAuthorizedClient: SecCode-path fallback accepted pid \(pid)")
                return true
            }
        }
    }

    // Layer 3: proc_pidpath — returns the actual executable path regardless of signing.
    // Most reliable for ad-hoc builds where Security framework may reject the code object.
    var pathBuf = [Int8](repeating: 0, count: 4096)
    if proc_pidpath(pid, &pathBuf, 4096) > 0 {
        let path = String(cString: pathBuf)
        if path.contains("/ClashPow.app/") || path.hasSuffix("/ClashPow") {
            log("isAuthorizedClient: proc_pidpath fallback accepted pid \(pid): \(path)")
            return true
        }
    }

    log("isAuthorizedClient: REJECTED pid \(pid)")
    return false
}

/// Only permit launching a binary at the canonical ClashPow kernel path.
func isAllowedKernelPath(_ path: String) -> Bool {
    let std = (path as NSString).standardizingPath
    guard !std.contains(".."),
          std.hasSuffix("/Library/Application Support/ClashPow/bin/mihomo") else { return false }
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: std, isDirectory: &isDir), !isDir.boolValue else { return false }
    if let type = (try? fm.attributesOfItem(atPath: std))?[.type] as? FileAttributeType,
       type == .typeSymbolicLink { return false }
    return true
}

func log(_ msg: String) {
    let logDir = "/Library/Logs/ClashPow"
    let logFile = "\(logDir)/helper.log"
    let line = "[\(Date())] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    let fm = FileManager.default
    try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logDir)
    if !fm.fileExists(atPath: logFile) { fm.createFile(atPath: logFile, contents: nil) }
    if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logFile)) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(data)
    }
}

class Helper: NSObject, HelperProtocol {
    private var mihomoProcess: Process?

    func getVersion(withReply reply: @escaping (String) -> Void) {
        log("getVersion called")
        reply(kHelperVersion)
    }

    func setSystemProxy(enabled: Bool, port: Int, withReply reply: @escaping (Bool) -> Void) {
        log("setSystemProxy(enabled: \(enabled), port: \(port))")
        let ok = ProxyManager.setSystemProxy(enabled: enabled, port: port)
        reply(ok)
    }

    func startMihomo(binPath: String, homeDir: String, withReply reply: @escaping (Bool) -> Void) {
        log("startMihomo(binPath: \(binPath), homeDir: \(homeDir))")
        guard isAllowedKernelPath(binPath) else {
            log("startMihomo REJECTED: binPath not in allowlist: \(binPath)")
            reply(false); return
        }

        // Terminate any tracked process first
        if let existing = mihomoProcess, existing.isRunning {
            existing.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if existing.isRunning { kill(existing.processIdentifier, SIGKILL) }
        }
        mihomoProcess = nil

        // Kill ALL mihomo processes (handles untracked processes from previous
        // helper instances or session remnants that would block the port)
        let killAll = Process()
        killAll.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killAll.arguments = ["-9", "mihomo"]
        killAll.standardOutput = Pipe(); killAll.standardError = Pipe()
        try? killAll.run(); killAll.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.3)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binPath)
        process.arguments = ["-d", homeDir]

        let logDir = "/Library/Logs/ClashPow"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let logFile = "\(logDir)/mihomo-root.log"
        FileManager.default.createFile(atPath: logFile, contents: nil)
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logFile)) {
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
            mihomoProcess = process
            log("startMihomo: started pid \(process.processIdentifier)")
            reply(true)
        } catch {
            log("startMihomo: failed to start: \(error)")
            reply(false)
        }
    }

    func stopMihomo(withReply reply: @escaping (Bool) -> Void) {
        log("stopMihomo called")
        if let process = mihomoProcess, process.isRunning {
            process.terminate()
            // Wait up to 1.5s for graceful exit, then SIGKILL
            let deadline = Date().addingTimeInterval(1.5)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                log("stopMihomo: SIGTERM timeout, sending SIGKILL to pid \(process.processIdentifier)")
                kill(process.processIdentifier, SIGKILL)
            }
            mihomoProcess = nil
        }
        // killall as final safety net (catches processes not owned by this instance)
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        t.arguments = ["-9", "mihomo"]
        t.standardOutput = Pipe(); t.standardError = Pipe()
        try? t.run(); t.waitUntilExit()
        reply(true)
    }
}

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        log("New connection attempt from pid: \(newConnection.processIdentifier)")
        guard isAuthorizedClient(newConnection) else {
            log("REJECTED unauthorized connection from pid \(newConnection.processIdentifier)")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = Helper()
        newConnection.resume()
        return true
    }
}

log("Helper starting up (v\(kHelperVersion))...")
let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: "com.clashpow.helper")
listener.delegate = delegate
log("Listener resuming...")
listener.resume()
log("Helper entering main loop.")
RunLoop.main.run()
