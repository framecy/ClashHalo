import Foundation
import Combine
import SwiftUI

@MainActor final class EngineControl: ObservableObject {
    static let shared = EngineControl()
    let socketPath = "/tmp/clashpow-engine.sock"

    @Published var present = false
    @Published var uptimeSec: Int64 = 0
    @Published var engineVersion = "?"
    @Published var isRoot = false          // engine running as root LaunchDaemon (TUN-capable)

    private let appSupport = NSHomeDirectory() + "/Library/Application Support/ClashPow"
    private let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.clashpow.engine.plist"
    private let rootPlistPath = "/Library/LaunchDaemons/com.clashpow.engine.plist"

    /// First-run bootstrap: install the bundled engine + geodata and the
    /// LaunchAgent so the kernel runs without any manual setup. Idempotent.
    func ensureInstalled() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        let engineDst = appSupport + "/clashpow-engine"

        let bundled = Bundle.main.resourceURL?.appendingPathComponent("clashpow-engine")
        if let bundled = bundled, fm.fileExists(atPath: bundled.path) {
            var needsCopy = false
            if !fm.fileExists(atPath: engineDst) {
                needsCopy = true
            } else {
                let bundledAttr = try? fm.attributesOfItem(atPath: bundled.path)
                let installedAttr = try? fm.attributesOfItem(atPath: engineDst)
                let bundledSize = bundledAttr?[.size] as? UInt64 ?? 0
                let installedSize = installedAttr?[.size] as? UInt64 ?? 0
                if bundledSize != installedSize {
                    needsCopy = true
                }
            }
            
            if needsCopy {
                try? fm.removeItem(atPath: engineDst)
                try? fm.copyItem(atPath: bundled.path, toPath: engineDst)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engineDst)
            }
        }

        // bundled geodata (optional)
        for f in ["GeoSite.dat", "geoip.metadb", "ASN.mmdb"] {
            if let g = Bundle.main.resourceURL?.appendingPathComponent(f), fm.fileExists(atPath: g.path) {
                let dst = appSupport + "/" + f
                var needsCopy = false
                if !fm.fileExists(atPath: dst) {
                    needsCopy = true
                } else {
                    let srcSize = (try? fm.attributesOfItem(atPath: g.path))?[.size] as? UInt64 ?? 0
                    let dstSize = (try? fm.attributesOfItem(atPath: dst))?[.size] as? UInt64 ?? 0
                    if srcSize != dstSize {
                        needsCopy = true
                    }
                }
                if needsCopy {
                    try? fm.removeItem(atPath: dst)
                    try? fm.copyItem(atPath: g.path, toPath: dst)
                }
            }
        }

        // Install + load the LaunchAgent if absent.
        if !fm.fileExists(atPath: plistPath), fm.fileExists(atPath: engineDst) {
            let logDir = NSHomeDirectory() + "/Library/Logs/ClashPow"
            try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>com.clashpow.engine</string>
              <key>ProgramArguments</key><array><string>\(engineDst)</string></array>
              <key>RunAtLoad</key><true/>
              <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/><key>Crashed</key><true/></dict>
              <key>ThrottleInterval</key><integer>3</integer>
              <key>ProcessType</key><string>Adaptive</string>
              <key>StandardOutPath</key><string>\(logDir)/clashpow-engine.log</string>
              <key>StandardErrorPath</key><string>\(logDir)/clashpow-engine.log</string>
            </dict></plist>
            """
            try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["load", plistPath]
            try? task.run(); task.waitUntilExit()
        }
    }

    /// One-shot newline-delimited JSON-RPC call over the UDS.
    private func call(_ method: String, params: String = "{}") async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global().async {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { cont.resume(returning: nil); return }
                defer { close(fd) }
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                _ = self.socketPath.withCString { src in
                    withUnsafeMutablePointer(to: &addr.sun_path) {
                        $0.withMemoryRebound(to: CChar.self, capacity: 104) { dst in strcpy(dst, src) }
                    }
                }
                let len = socklen_t(MemoryLayout<sockaddr_un>.size)
                let ok = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
                }
                guard ok == 0 else { cont.resume(returning: nil); return }

                // Set 10s receive timeout
                var tv = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                let payload = #"{"jsonrpc":"2.0","method":"\#(method)","params":\#(params),"id":1}"# + "\n"
                guard let payloadData = payload.data(using: .utf8) else { cont.resume(returning: nil); return }
                var sent = 0
                let total = payloadData.count
                var failed = false
                payloadData.withUnsafeBytes { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    while sent < total {
                        let n = send(fd, baseAddress + sent, total - sent, 0)
                        if n <= 0 { failed = true; break }
                        sent += n
                    }
                }
                guard !failed else { cont.resume(returning: nil); return }
                
                var data = Data()
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = recv(fd, &buf, buf.count, 0)
                    if n <= 0 { break }
                    data.append(contentsOf: buf[0..<n])
                    if buf[0..<n].contains(10) { break } // 10 is '\n'
                }
                cont.resume(returning: data.isEmpty ? nil : data)
            }
        }
    }

    private struct Envelope<T: Decodable>: Decodable { let result: T? }

    /// Probe engine + discover controller. Returns (addr, secret) when present.
    @discardableResult
    func refresh() async -> (addr: String, secret: String)? {
        guard let data = await call("get_status"),
              let env = try? JSONDecoder().decode(Envelope<EngineStatusRPC>.self, from: data),
              let s = env.result else {
            present = false
            isRoot = false
            engineVersion = "?"
            return nil
        }
        present = true
        uptimeSec = s.uptimeSec
        engineVersion = s.version
        isRoot = s.isRoot
        guard !s.controllerAddr.isEmpty else { return nil }
        return (s.controllerAddr, s.controllerSecret)
    }

    /// Promote the engine to a root LaunchDaemon so TUN works. Requires one
    /// administrator-auth prompt (osascript). Installs the engine + geodata to a
    /// system path, unloads the user LaunchAgent, writes /Library/LaunchDaemons,
    /// and bootstraps it as root. Returns true on success.
    @discardableResult
    func installPrivileged() async -> Bool {
        let engineBin = appSupport + "/clashpow-engine"
        guard FileManager.default.fileExists(atPath: engineBin) else { return false }
        let logDir = NSHomeDirectory() + "/Library/Logs/ClashPow"
        // The root daemon runs the engine binary copied to /Library/PrivilegedHelperTools but as root,
        // with the same app-support home so config/geodata/controller are unchanged.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>com.clashpow.engine</string>
          <key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/clashpow-engine</string></array>
          <key>EnvironmentVariables</key><dict><key>CLASHPOW_CONFIG</key><string>\(appSupport)/config.yaml</string></dict>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/><key>Crashed</key><true/></dict>
          <key>ThrottleInterval</key><integer>3</integer>
          <key>Umask</key><integer>0</integer>
          <key>StandardOutPath</key><string>\(logDir)/clashpow-engine.log</string>
          <key>StandardErrorPath</key><string>\(logDir)/clashpow-engine.log</string>
        </dict></plist>
        """
        // Write the plist to a temp file the privileged shell will move into place.
        let tmpPlist = NSTemporaryDirectory() + "com.clashpow.engine.plist"
        guard (try? plist.write(toFile: tmpPlist, atomically: true, encoding: .utf8)) != nil else { return false }

        // One privileged shell: stop user agent, copy engine to secure path & chmod, install root daemon, bootstrap it.
        let uid = getuid()
        let shell = [
            "/usr/bin/killall -9 mihomo clashpow-engine 2>/dev/null || true",
            "if /usr/sbin/lsof -t -iTCP:7890 -sTCP:LISTEN >/dev/null; then /bin/kill -9 $(/usr/sbin/lsof -t -iTCP:7890 -sTCP:LISTEN) 2>/dev/null || true; fi",
            "if /usr/sbin/lsof -t -iTCP:9092 -sTCP:LISTEN >/dev/null; then /bin/kill -9 $(/usr/sbin/lsof -t -iTCP:9092 -sTCP:LISTEN) 2>/dev/null || true; fi",
            "/sbin/route -n delete -net 1.0.0.0/8 2>/dev/null || true",
            "/sbin/route -n delete -net 198.18.0.0/15 2>/dev/null || true",
            "/bin/launchctl bootout gui/\(uid)/com.clashpow.engine 2>/dev/null || true",
            "/bin/launchctl unload '\(plistPath)' 2>/dev/null || true",
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/cp '\(engineBin)' /Library/PrivilegedHelperTools/clashpow-engine",
            "/usr/sbin/chown root:wheel /Library/PrivilegedHelperTools/clashpow-engine",
            "/bin/chmod 755 /Library/PrivilegedHelperTools/clashpow-engine",
            "/bin/cp '\(tmpPlist)' '\(rootPlistPath)'",
            "/usr/sbin/chown root:wheel '\(rootPlistPath)'",
            "/bin/chmod 644 '\(rootPlistPath)'",
            "/bin/launchctl bootout system/com.clashpow.engine 2>/dev/null || true",
            "/bin/launchctl bootstrap system '\(rootPlistPath)'",
        ].joined(separator: "; ")
        let ok = await Self.runAdmin(shell)
        if ok { isRoot = true }
        return ok
    }

    /// Demote back to the user LaunchAgent (removes the root daemon). Admin auth.
    @discardableResult
    func uninstallPrivileged() async -> Bool {
        let shell = [
            "/bin/launchctl bootout system/com.clashpow.engine 2>/dev/null || true",
            "/bin/rm -f '\(rootPlistPath)'",
            "/bin/rm -f /Library/PrivilegedHelperTools/clashpow-engine",
            "/usr/bin/killall -9 mihomo clashpow-engine 2>/dev/null || true",
            "if /usr/sbin/lsof -t -iTCP:7890 -sTCP:LISTEN >/dev/null; then /bin/kill -9 $(/usr/sbin/lsof -t -iTCP:7890 -sTCP:LISTEN) 2>/dev/null || true; fi",
            "if /usr/sbin/lsof -t -iTCP:9092 -sTCP:LISTEN >/dev/null; then /bin/kill -9 $(/usr/sbin/lsof -t -iTCP:9092 -sTCP:LISTEN) 2>/dev/null || true; fi",
            "/sbin/route -n delete -net 1.0.0.0/8 2>/dev/null || true",
            "/sbin/route -n delete -net 198.18.0.0/15 2>/dev/null || true",
        ].joined(separator: "; ")
        let ok = await Self.runAdmin(shell)
        if ok {
            isRoot = false
            // bring the user LaunchAgent back
            let t = Process(); t.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            t.arguments = ["load", plistPath]; try? t.run(); t.waitUntilExit()
        }
        return ok
    }

    /// Run a shell snippet with administrator privileges via one osascript prompt.
    static func runAdmin(_ shell: String) async -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                do { try p.run(); p.waitUntilExit(); cont.resume(returning: p.terminationStatus == 0) }
                catch { cont.resume(returning: false) }
            }
        }
    }

    /// Deep-merge config overrides into the running config (validate + rollback).
    @discardableResult
    func patchConfig(_ overrides: [String: Any]) async -> Bool {
        guard let pd = try? JSONSerialization.data(withJSONObject: overrides),
              let params = String(data: pd, encoding: .utf8) else {
            print("patchConfig: serialization failed")
            return false
        }
        print("patchConfig: sending overrides: \(params)")
        guard let data = await call("patch_config", params: params) else {
            print("patchConfig: UDS call returned nil")
            return false
        }
        if let str = String(data: data, encoding: .utf8) {
            print("patchConfig: received raw response: \(str)")
        }
        
        do {
            struct Resp: Decodable { struct R: Decodable { let ok: Bool? }; let result: R? }
            let resp = try JSONDecoder().decode(Resp.self, from: data)
            let ok = resp.result?.ok == true
            print("patchConfig: decoded success: \(ok)")
            return ok
        } catch {
            print("patchConfig: decode error: \(error)")
            if let str = String(data: data, encoding: .utf8) {
                print("patchConfig: raw data was: \(str)")
            }
            return false
        }
    }

    func restart() async { _ = await call("shutdown") }   // launchd KeepAlive respawns
    func startTUN() async { _ = await call("start_tun") }
    func stopTUN() async { _ = await call("stop_tun") }

    /// Ask the root engine daemon to set/clear the macOS system HTTP/HTTPS/SOCKS proxy.
    /// Since the engine runs as root, this does not pop up any authorization dialogs.
    @discardableResult
    func setSystemProxy(enabled: Bool, port: Int) async -> Bool {
        let params = #"{"enabled":\#(enabled),"port":\#(port)}"#
        guard let data = await call("set_system_proxy", params: params) else { return false }
        struct Resp: Decodable { struct R: Decodable { let ok: Bool? }; let result: R? }
        return (try? JSONDecoder().decode(Resp.self, from: data))?.result?.ok == true
    }

    /// Apply a full YAML config. The engine validates + applies with rollback;
    /// returns (ok, errorMessage). A non-nil error means validation failed and
    /// the engine kept the previous good config.
    func setConfig(_ yaml: String) async -> (ok: Bool, error: String?) {
        let pd = try? JSONSerialization.data(withJSONObject: ["config_yaml": yaml])
        let params = pd.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        guard let data = await call("set_config", params: params) else { return (false, "引擎无响应") }
        struct Resp: Decodable {
            struct R: Decodable { let ok: Bool? }
            struct E: Decodable { let message: String }
            let result: R?; let error: E?
        }
        guard let r = try? JSONDecoder().decode(Resp.self, from: data) else { return (false, "解析失败") }
        if let e = r.error { return (false, e.message) }
        return (r.result?.ok == true, nil)
    }
}
