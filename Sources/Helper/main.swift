import Foundation
import Security

// Single source of truth for the helper version (B10 — was duplicated as literals).
let kHelperVersion = "1.0.4"

// Code-signing requirement a connecting client must satisfy (B5). Restricts the
// root helper to the ClashPow app only, instead of accepting every local process.
private let kClientRequirement = "identifier \"com.clashpow.app\""

/// Validate that an incoming XPC peer is the ClashPow app, by checking its code
/// signature against `kClientRequirement`.
/// NOTE: [TECH_DEBT] uses pid→SecCode (kSecGuestAttributePid); a malicious peer
/// could in theory exploit pid reuse. Upgrade to auditToken-based lookup when the
/// helper moves to SMAppService/SMJobBless. Reason: auditToken needs private API
/// plumbing. Expiry: next signing/distribution overhaul.
func isAuthorizedClient(_ conn: NSXPCConnection) -> Bool {
    let pid = conn.processIdentifier
    guard pid > 0 else { return false }
    var code: SecCode?
    let attrs = [kSecGuestAttributePid: pid] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
    var req: SecRequirement?
    guard SecRequirementCreateWithString(kClientRequirement as CFString, [], &req) == errSecSuccess, let req else { return false }
    return SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), req) == errSecSuccess
}

/// Only permit launching a binary that lives at the canonical ClashPow kernel
/// path. Prevents the root helper from being coerced into running an arbitrary
/// executable (B5 — the core local-privilege-escalation fix).
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

// Append-only logger. Always ensures the file exists first, then opens it for
// appending — the previous version's fallback `write(to:)` overwrote the whole
// file, so only the last line survived (looked like "running but no logs").
func log(_ msg: String) {
    let logDir = "/Library/Logs/ClashPow"
    let logFile = "\(logDir)/helper.log"
    let line = "[\(Date())] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    let fm = FileManager.default
    try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    if !fm.fileExists(atPath: logFile) { fm.createFile(atPath: logFile, contents: nil) }
    guard let handle = FileHandle(forWritingAtPath: logFile) else { return }
    defer { try? handle.close() }
    handle.seekToEndOfFile()
    handle.write(data)
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
        if let existing = mihomoProcess, existing.isRunning {
            existing.terminate()
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binPath)
        process.arguments = ["-d", homeDir]
        
        let logDir = "/Library/Logs/ClashPow"
        let logFile = "\(logDir)/mihomo-root.log"
        FileManager.default.createFile(atPath: logFile, contents: nil)
        if let handle = FileHandle(forWritingAtPath: logFile) {
            process.standardOutput = handle
            process.standardError = handle
        }
        
        do {
            try process.run()
            mihomoProcess = process
            reply(true)
        } catch {
            log("Failed to start mihomo: \(error)")
            reply(false)
        }
    }
    
    func stopMihomo(withReply reply: @escaping (Bool) -> Void) {
        log("stopMihomo called")
        if let process = mihomoProcess, process.isRunning {
            process.terminate()
            mihomoProcess = nil
            reply(true)
        } else {
            reply(true)
        }
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
