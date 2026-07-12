import Foundation
import SystemConfiguration

public class ProxyManager {
    private static func log(_ msg: String) {
        NSLog("[ClashHalo Helper ProxyManager] %@", msg)
    }

    /// Set/clear the macOS system proxy via `networksetup`.
    public static func setSystemProxy(enabled: Bool, port: Int) -> Bool {
        let services = activeNetworkServices()
        guard !services.isEmpty else { return false }
        var anyOK = false
        for svc in services {
            let ok: Bool
            if enabled {
                // Proxy bypass domains: localhost + loopback + mDNS + RFC1918
                // private ranges + link-local + CGNAT (kProxyBypassDomains). LAN/
                // intranet/SD-WAN hosts bypass the proxy so they never hit mihomo
                // (which can't route to them, surfacing as 502).
                ok = run(["-setwebproxy", svc, "127.0.0.1", "\(port)"])
                    && run(["-setsecurewebproxy", svc, "127.0.0.1", "\(port)"])
                    && run(["-setsocksfirewallproxy", svc, "127.0.0.1", "\(port)"])
                    && run(["-setproxybypassdomains", svc] + kProxyBypassDomains)
            } else {
                ok = run(["-setwebproxystate", svc, "off"])
                    && run(["-setsecurewebproxystate", svc, "off"])
                    && run(["-setsocksfirewallproxystate", svc, "off"])
            }
            if ok { anyOK = true }
        }
        return anyOK
    }

    /// Filter services to only target the actually active network interfaces
    private static func activeNetworkServices() -> [String] {
        guard let listOut = runOutput(["-listnetworkserviceorder"]) else { return [] }
        var activeServices: [String] = []
        var currentService: String? = nil
        for line in listOut.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("(") {
                if let firstIdx = s.firstIndex(of: ")") {
                    let start = s.index(after: firstIdx)
                    currentService = s[start...].trimmingCharacters(in: .whitespaces)
                }
            } else if s.hasPrefix("(Hardware Port:") {
                if let devRange = s.range(of: "Device:"),
                   let endBracket = s.firstIndex(of: ")") {
                    let devStart = devRange.upperBound
                    let dev = s[devStart..<endBracket].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !dev.isEmpty && isInterfaceActive(dev) {
                        if let svc = currentService {
                            activeServices.append(svc)
                        }
                    }
                }
            }
        }
        if activeServices.isEmpty {
            return enabledNetworkServices()
        }
        return activeServices
    }

    private static func isInterfaceActive(_ iface: String) -> Bool {
        guard !iface.isEmpty else { return false }
        guard let out = runOutput("/sbin/ifconfig", [iface]) else { return false }
        return out.contains("status: active") || out.contains("inet ")
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
        
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 3.0)
        timer.setEventHandler {
            if p.isRunning {
                p.terminate()
            }
        }
        
        do {
            try p.run()
            timer.resume()
            p.waitUntilExit()
            timer.cancel()
            return p.terminationStatus == 0
        } catch {
            timer.cancel()
            return false
        }
    }

    private static func runOutput(_ args: [String]) -> String? {
        return runOutput("/usr/sbin/networksetup", args)
    }

    private static func runOutput(_ binPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binPath)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 3.0)
        timer.setEventHandler {
            if p.isRunning {
                p.terminate()
            }
        }
        
        do {
            try p.run()
            timer.resume()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            return String(data: data, encoding: .utf8)
        } catch {
            timer.cancel()
            return nil
        }
    }

    /// Restore DNS settings for all active services to "Empty" (DHCP auto) or a fallback resolver (223.5.5.5).
    @discardableResult
    public static func restoreDNS() -> Bool {
        let services = enabledNetworkServices()
        guard !services.isEmpty else { return false }
        var anyOK = false
        for svc in services {
            // First attempt: restore to DHCP default (Empty)
            var ok = run(["-setdnsservers", svc, "Empty"])
            if !ok {
                // Fallback attempt: if Empty fails, use a public resolver like 223.5.5.5
                ok = run(["-setdnsservers", svc, "223.5.5.5"])
            }
            if ok { anyOK = true }
        }
        return anyOK
    }

    /// Read the effective system proxy state (no root required). Returns true
    /// when HTTP proxy is enabled and points to 127.0.0.1 — i.e. "our" proxy.
    public static func readCurrentState() -> Bool {
        guard let dict = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return false }
        let httpOn = dict[kCFNetworkProxiesHTTPEnable as String] as? Int == 1
        let httpHost = dict[kCFNetworkProxiesHTTPProxy as String] as? String
        return httpOn && httpHost == "127.0.0.1"
    }

    /// Clean up TUN residual after mihomo exits: delete default routes pointing
    /// to utun interfaces bearing mihomo's 198.18.x.x addresses, bring those
    /// interfaces down, and remove their IP addresses. macOS utun interfaces
    /// created via AF_SYSTEM sockets cannot be destroyed with `ifconfig destroy`
    /// — they persist until their controlling socket FD is closed. Bringing them
    /// down + removing addresses neutralizes their Supplemental DNS resolvers
    /// and prevents traffic from routing into a dead tunnel.
    @discardableResult
    public static func cleanupTUNResidual() -> Bool {
        // 1. Find utun interfaces with 198.18.x.x addresses (mihomo TUN signature)
        let ifconfigOut = runGeneric("/sbin/ifconfig", ["-a"])
        guard let output = ifconfigOut else {
            log("cleanupTUNResidual: ifconfig failed")
            return false
        }

        var mihomoUtuns: [(iface: String, addr: String)] = []
        var currentIface: String?
        for line in output.split(separator: "\n") {
            let s = String(line)
            // Interface header line: "utunN: flags=..."
            if !s.hasPrefix("\t") && !s.hasPrefix(" "), s.contains(": flags=") {
                currentIface = String(s.prefix(while: { $0 != ":" }))
            }
            // inet line with 198.18.x.x → this is mihomo's TUN
            if let iface = currentIface, iface.hasPrefix("utun"),
               s.contains("198.18."), s.contains("inet ") {
                // Extract the IP address: "inet 198.18.0.1 --> ..."
                let parts = s.trimmingCharacters(in: .whitespaces).split(separator: " ")
                if let idx = parts.firstIndex(of: "inet"), idx + 1 < parts.count {
                    mihomoUtuns.append((iface: iface, addr: String(parts[idx + 1])))
                } else {
                    mihomoUtuns.append((iface: iface, addr: "198.18.0.1"))
                }
            }
        }

        guard !mihomoUtuns.isEmpty else {
            log("cleanupTUNResidual: no mihomo utun interfaces found")
            return true  // nothing to clean
        }

        let ifaceNames = mihomoUtuns.map(\.iface)
        log("cleanupTUNResidual: found mihomo utun interfaces: \(ifaceNames)")

        // 2. Delete default routes pointing to these utun interfaces
        for (iface, _) in mihomoUtuns {
            // IPv4 default route (try both -ifscope and -interface forms)
            _ = runGeneric("/sbin/route", ["-n", "delete", "default", "-ifscope", iface])
            _ = runGeneric("/sbin/route", ["-n", "delete", "default", "-interface", iface])
            // IPv6 default route
            _ = runGeneric("/sbin/route", ["-n", "delete", "-inet6", "default", "-ifscope", iface])
            _ = runGeneric("/sbin/route", ["-n", "delete", "-inet6", "default", "-interface", iface])
        }

        // 3. Delete any residual 198.18.0.0/15 routes (mihomo fake-ip range)
        _ = runGeneric("/sbin/route", ["-n", "delete", "198.18.0.0/15"])

        // 4. Bring interfaces down and remove their IP addresses to neutralize
        //    Supplemental DNS resolvers. utun can't be `destroy`ed, but down +
        //    address removal makes the system stop using it for DNS/routing.
        for (iface, addr) in mihomoUtuns {
            _ = runGeneric("/sbin/ifconfig", [iface, "down"])
            _ = runGeneric("/sbin/ifconfig", [iface, "inet", addr, "delete"])
            log("cleanupTUNResidual: \(iface) down + deleted \(addr)")
        }

        // 5. Flush the routing table cache to apply changes immediately
        _ = runGeneric("/sbin/route", ["-n", "flush"])

        return true
    }

    /// Run an arbitrary command and return its stdout (nil on failure). 5s timeout.
    private static func runGeneric(_ executable: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 5.0)
        timer.setEventHandler {
            if p.isRunning {
                log("runGeneric timeout: killing \(executable) \(args)")
                p.terminate()
            }
        }

        do {
            try p.run()
            timer.resume()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            return String(data: data, encoding: .utf8)
        } catch {
            timer.cancel()
            return nil
        }
    }
}
