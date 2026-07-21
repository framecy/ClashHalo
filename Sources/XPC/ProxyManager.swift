import Foundation
import SystemConfiguration

public class ProxyManager {
    private static func log(_ msg: String) {
        NSLog("[ClashHalo Helper ProxyManager] %@", msg)
    }

    /// Set/clear the macOS system proxy via `networksetup`.
    ///
    /// Performance notes (XPC budget): the GUI's `callSystemProxy` used to time
    /// out at 5s while this method walked *every* enabled service (Wi-Fi +
    /// Ethernet + USB LAN + Thunderbolt + VPN clients like Shadowrocket) with
    /// 7 serial `networksetup` forks each — 40–50 spawns easily exceeded the
    /// client timeout and surfaced as "Couldn't communicate with a helper
    /// application" even though the helper was healthy. We now:
    /// 1. Prefer only real active physical-ish services (skip VPN/virtual names)
    /// 2. Cap at a small number of services (primary uplink is enough)
    /// 3. Use a shorter per-command timeout
    public static func setSystemProxy(enabled: Bool, port: Int) -> Bool {
        let services = preferredProxyServices()
        guard !services.isEmpty else {
            log("setSystemProxy: no network services")
            return false
        }
        var anyOK = false
        for svc in services {
            let ok: Bool
            if enabled {
                // Proxy bypass domains: localhost + loopback + mDNS + RFC1918
                // private ranges + link-local + CGNAT (kProxyBypassDomains). LAN/
                // intranet/SD-WAN hosts bypass the proxy so they never hit mihomo
                // (which can't route to them, surfacing as 502).
                //
                // `-setwebproxy` writes host/port but on some macOS builds does NOT
                // flip the enable bit by itself — always follow with `-*proxystate on`
                // (same as the GUI fallback path in EngineControl).
                ok = run(["-setwebproxy", svc, "127.0.0.1", "\(port)"])
                    && run(["-setsecurewebproxy", svc, "127.0.0.1", "\(port)"])
                    && run(["-setsocksfirewallproxy", svc, "127.0.0.1", "\(port)"])
                    && run(["-setproxybypassdomains", svc] + kProxyBypassDomains)
                    && run(["-setwebproxystate", svc, "on"])
                    && run(["-setsecurewebproxystate", svc, "on"])
                    && run(["-setsocksfirewallproxystate", svc, "on"])
            } else {
                ok = run(["-setwebproxystate", svc, "off"])
                    && run(["-setsecurewebproxystate", svc, "off"])
                    && run(["-setsocksfirewallproxystate", svc, "off"])
            }
            if ok {
                anyOK = true
            } else {
                log("setSystemProxy(\(enabled)) failed for service: \(svc)")
            }
        }
        log("setSystemProxy(enabled: \(enabled), port: \(port)) services=\(services) anyOK=\(anyOK)")
        return anyOK
    }

    /// Services we should actually configure for system proxy.
    /// Prefer active physical links; never touch VPN/virtual client services
    /// (Shadowrocket, WireGuard UIs, etc.) which inflate the networksetup loop
    /// and often fail or hang.
    private static func preferredProxyServices() -> [String] {
        let skipSubstrings = [
            "shadowrocket", "wireguard", "tailscale", "zerotier", "oray",
            "utun", "vpn", "ipsec", "l2tp", "pptp", "cisco", "openvpn",
            "clash", "surge", "quantumult", "v2ray"
        ]
        func isSkippable(_ name: String) -> Bool {
            let lower = name.lowercased()
            return skipSubstrings.contains { lower.contains($0) }
        }

        var services = activeNetworkServices().filter { !isSkippable($0) }
        if services.isEmpty {
            services = enabledNetworkServices().filter { !isSkippable($0) }
        }
        // Prefer Wi-Fi / Ethernet first — that's what users mean by "system proxy".
        let preferred = services.filter {
            let l = $0.lowercased()
            return l.contains("wi-fi") || l.contains("wifi") || l.contains("ethernet") || l.contains("以太网")
        }
        let ordered = preferred.isEmpty ? services : preferred + services.filter { !preferred.contains($0) }
        // Cap: configuring more than 2 services is almost never useful and blows the XPC budget.
        return Array(ordered.prefix(2))
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

    /// Per-command timeout. Keep well under the GUI XPC budget (15s for proxy).
    private static let cmdTimeout: TimeInterval = 1.2

    @discardableResult
    private static func run(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + cmdTimeout)
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
        timer.schedule(deadline: .now() + cmdTimeout)
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

    /// Restore DNS only for services whose resolver is pinned at the mihomo
    /// fake-ip gateway (198.18.x / 198.19.x). Client-death cleanup uses this
    /// instead of the blanket `restoreDNS()` so a user's custom DNS — or the
    /// saved DNS the GUI already restored during a normal quit — is never
    /// clobbered back to "Empty" when the tunnel redirect wasn't even active.
    @discardableResult
    public static func restoreDNSIfTunnelPinned() -> Bool {
        var anyOK = false
        for svc in enabledNetworkServices() {
            guard let out = runOutput(["-getdnsservers", svc]) else { continue }
            let pinned = out.split(separator: "\n").contains {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("198.18.") || t.hasPrefix("198.19.")
            }
            guard pinned else { continue }
            var ok = run(["-setdnsservers", svc, "Empty"])
            if !ok { ok = run(["-setdnsservers", svc, "223.5.5.5"]) }
            log("restoreDNSIfTunnelPinned: \(svc) was tunnel-pinned, reset \(ok ? "ok" : "FAILED")")
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

    /// Whether any enabled network service currently routes HTTP/HTTPS/SOCKS
    /// through a loopback proxy — i.e. a proxy that can only be ours (or another
    /// local proxy app), and which black-holes traffic once the kernel is gone.
    ///
    /// Queried via `networksetup` rather than `SCDynamicStoreCopyProxies` because
    /// this runs inside a root LaunchDaemon with no user session, where the
    /// dynamic-store proxy snapshot is not a reliable view of per-service state.
    /// Used as the reality-based fallback for client-death cleanup: the helper's
    /// in-memory session flags are lost whenever the helper itself restarts
    /// (e.g. right after its own upgrade), and without this a force-quit then
    /// left a stale 127.0.0.1 proxy pointing at a dead kernel — total blackout.
    public static func anyServiceProxiesToLoopback() -> Bool {
        for svc in enabledNetworkServices() {
            for cmd in ["-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy"] {
                guard let out = runOutput([cmd, svc]) else { continue }
                var enabled = false, loopback = false
                for line in out.split(separator: "\n") {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("Enabled:") { enabled = t.hasSuffix("Yes") }
                    if t.hasPrefix("Server:") {
                        let host = t.dropFirst("Server:".count).trimmingCharacters(in: .whitespaces)
                        loopback = (host == "127.0.0.1" || host == "::1" || host == "localhost")
                    }
                }
                if enabled && loopback { return true }
            }
        }
        return false
    }

    /// Clean up TUN residual after mihomo exits: delete default routes pointing
    /// to utun interfaces bearing mihomo's 198.18.x.x addresses, bring those
    /// interfaces down, and remove their IP addresses. macOS utun interfaces
    /// created via AF_SYSTEM sockets cannot be destroyed with `ifconfig destroy`
    /// — they persist until their controlling socket FD is closed. Bringing them
    /// down + removing addresses neutralizes their Supplemental DNS resolvers
    /// and prevents traffic from routing into a dead tunnel.
    /// - Parameter downedOnly: When true, only neutralize interfaces whose
    ///   flags no longer carry UP — i.e. true zombie residue. Client-death
    ///   cleanup passes true so a *healthy* co-resident VPN tunnel sharing the
    ///   198.18.x space (e.g. Shadowrocket, still UP) is never torn down.
    @discardableResult
    public static func cleanupTUNResidual(downedOnly: Bool = false) -> Bool {
        // 1. Find utun interfaces with 198.18.x.x addresses (mihomo TUN signature)
        let ifconfigOut = runGeneric("/sbin/ifconfig", ["-a"])
        guard let output = ifconfigOut else {
            log("cleanupTUNResidual: ifconfig failed")
            return false
        }

        var mihomoUtuns: [(iface: String, addr: String)] = []
        var currentIface: String?
        var currentIfaceUp = false
        for line in output.split(separator: "\n") {
            let s = String(line)
            // Interface header line: "utunN: flags=8051<UP,POINTOPOINT,...>"
            if !s.hasPrefix("\t") && !s.hasPrefix(" "), s.contains(": flags=") {
                currentIface = String(s.prefix(while: { $0 != ":" }))
                // UP flag lives in the <...> segment of the header line.
                if let lt = s.firstIndex(of: "<"), let gt = s.firstIndex(of: ">"), lt < gt {
                    let flags = s[s.index(after: lt)..<gt].split(separator: ",")
                    currentIfaceUp = flags.contains("UP")
                } else {
                    currentIfaceUp = false
                }
            }
            // inet line with 198.18.x.x → this is mihomo's TUN
            if let iface = currentIface, iface.hasPrefix("utun"),
               s.contains("198.18."), s.contains("inet ") {
                if downedOnly && currentIfaceUp {
                    log("cleanupTUNResidual: skip \(iface) — still UP (downedOnly)")
                    continue
                }
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
