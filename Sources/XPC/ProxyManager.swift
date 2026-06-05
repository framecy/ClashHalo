import Foundation
import SystemConfiguration

public class ProxyManager {
    /// Set/clear the macOS system proxy via `networksetup`.
    ///
    /// Replaces the previous SCPreferences implementation: a root LaunchDaemon is
    /// not attached to the user's GUI/preferences session, so SCPreferences
    /// commit/apply ran but never took effect (helper logged the call, yet
    /// `scutil --proxy` stayed HTTPEnable:0 and the call returned false →
    /// "系统代理设置失败"). `networksetup` mutates the same preferences reliably
    /// from any root context and applies immediately.
    public static func setSystemProxy(enabled: Bool, port: Int) -> Bool {
        let services = enabledNetworkServices()
        guard !services.isEmpty else { return false }
        var anyOK = false
        for svc in services {
            let ok: Bool
            if enabled {
                ok = run(["-setwebproxy", svc, "127.0.0.1", "\(port)"])
                    && run(["-setsecurewebproxy", svc, "127.0.0.1", "\(port)"])
                    && run(["-setsocksfirewallproxy", svc, "127.0.0.1", "\(port)"])
                    && run(["-setproxybypassdomains", svc, "localhost", "127.0.0.1", "*.local"])
            } else {
                ok = run(["-setwebproxystate", svc, "off"])
                    && run(["-setsecurewebproxystate", svc, "off"])
                    && run(["-setsocksfirewallproxystate", svc, "off"])
            }
            if ok { anyOK = true }
        }
        return anyOK
    }

    /// All enabled network services (skips the header line and `*`-disabled ones).
    private static func enabledNetworkServices() -> [String] {
        guard let out = runOutput(["-listallnetworkservices"]) else { return [] }
        return out.split(separator: "\n").compactMap { line -> String? in
            let s = String(line)
            if s.hasPrefix("An asterisk") { return nil }   // header
            if s.hasPrefix("*") { return nil }             // disabled service
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
    }

    @discardableResult
    private static func run(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    private static func runOutput(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Read the effective system proxy state (no root required). Returns true
    /// when HTTP proxy is enabled and points to 127.0.0.1 — i.e. "our" proxy.
    public static func readCurrentState() -> Bool {
        guard let dict = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return false }
        let httpOn = dict[kCFNetworkProxiesHTTPEnable as String] as? Int == 1
        let httpHost = dict[kCFNetworkProxiesHTTPProxy as String] as? String
        return httpOn && httpHost == "127.0.0.1"
    }
}
