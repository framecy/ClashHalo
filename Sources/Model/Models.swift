// AppModel — central app state. Owns the MihomoClient, manages live data.
//
// Data sources:
//   - WebSocket /traffic     → live up/down (chart)
//   - WebSocket /connections → live connection list + totals + memory
//   - WebSocket /logs        → live log stream
//   - Poll /proxies (3s)     → groups, nodes, selections, latencies
//   - Poll /configs (3s)     → mode, ports, dns, tun

import Foundation
import SwiftUI
import Security

// MARK: - View models

struct ProxyGroup: Identifiable, Equatable {
    let id: String        // group name
    let name: String
    let type: String      // Selector / URLTest / Fallback / LoadBalance
    var now: String
    let all: [String]
    var selectable: Bool { type == "Selector" || type == "Fallback" }
}

struct Node: Identifiable, Equatable {
    let id: String        // proxy name
    let name: String
    let type: String      // Shadowsocks / Vmess / Direct / ...
    var delay: Int        // ms, 0 = untested/timeout
}

struct Conn: Identifiable, Equatable {
    let id: String
    let host: String
    let dstIP: String
    let srcIP: String
    let port: String
    let network: String   // tcp / udp
    let process: String
    let processPath: String
    let chain: String     // "GroupA → node"
    let group: String     // first chain element (policy group)
    let node: String      // last chain element (leaf proxy)
    let rule: String
    let ruleType: String
    var up: Int64
    var down: Int64
    var upRate: Int64     // bytes/s (diffed)
    var downRate: Int64
    let start: String
    var category: String {  // direct / proxy / reject
        if node == "DIRECT" || chain.contains("DIRECT") { return "direct" }
        if node == "REJECT" || chain.contains("REJECT") { return "reject" }
        return "proxy"
    }
}

struct Log: Identifiable {
    let id: Int
    let time: String
    let level: String     // info / warning / error / debug
    let text: String
}

struct GatewayDevice: Identifiable, Equatable {
    var id: String { ip }
    let ip: String
    var activeConnections: Int
    var uploadRate: Int64
    var downloadRate: Int64
    var totalUpload: Int64
    var totalDownload: Int64
    var firstSeen: Date
    var lastSeen: Date
    var durationString: String {
        let secs = Int(lastSeen.timeIntervalSince(firstSeen))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs/60)m \(secs%60)s" }
        return "\(secs/3600)h \((secs%3600)/60)m"
    }
}

/// Semantic kind for the global toast channel (`AppModel.showToast`).
enum ToastKind: Equatable {
    case info, ok, warn, error
}

/// Single-slot toast payload. Identity is generation-free; replacement is
/// wholesale via `showToast` (old dismiss Task is cancelled).
struct ToastPayload: Equatable {
    let text: String
    let kind: ToastKind
}

// MARK: - AppModel



// MARK: - Keychain Security Helper

struct KeychainHelper {
    static let service = "com.clashhalo.secrets"

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        guard status == errSecSuccess, let data = dataTypeRef as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }
}

// MARK: - Config profiles (multi-config management)

struct Profile: Identifiable, Codable {
    let id: String
    var name: String
    var source: String       // "local" | "remote"
    var url: String?
    var importedAt: Date
    var updatedAt: Date
    /// NEW: profile lifecycle flag — `nil` for legacy manifests, treated as
    /// fully Applied to preserve the pre-isolation user experience.
    /// - `false` → imported but not yet pushed to the running kernel.
    /// - `true`  → successfully hot-reloaded into engine.config.yaml.
    var isApplied: Bool? = nil
    /// Hash of the YAML content last sent to `engine.setConfig`. Lets us
    /// skip reloads when a Profile is re-activated with identical content.
    var appliedHash: String? = nil
}

extension Profile {
    /// True when the profile has been imported but the kernel has not yet
    /// been told to use it. UI surfaces this as a "待应用" badge on the
    /// profile card and a primary "应用此配置" action button.
    var needsApply: Bool { isApplied == false }
}



// MARK: - Traffic history (persisted per-day category + hourly totals)



// MARK: - SD-WAN network scanning (read-only, no root)

enum IfaceKind: String {
    case physical = "物理网卡", proxyTun = "代理 TUN", tailscale = "Tailscale"
    case zerotier = "ZeroTier", oray = "蒲公英", otherTun = "虚拟接口", loopback = "环回"
    var sdwan: Bool { self == .tailscale || self == .zerotier || self == .oray }
}

struct NetIface: Identifiable {
    let id: String          // interface name
    var name: String { id }
    let ipv4: [String]
    let isUp: Bool
    let kind: IfaceKind
    var primaryIP: String { ipv4.first ?? "—" }
}

/// A route table entry parsed from netstat -rn
struct RouteEntry {
    let dest: String       // destination CIDR e.g. "100.64/10" or "default"
    let gateway: String
    let iface: String
    let flags: String
}

/// Result of conflict detection: a SD-WAN route that is shadowed by TUN.
struct RouteConflict {
    let sdwanRoute: String    // e.g. "100.64/10"
    let sdwanIface: String    // e.g. "utun1" (Tailscale)
    let tunRoute: String      // e.g. "100/10" (the mihomo TUN route shadowing it)
    let tunIface: String      // e.g. "utun9"
    /// Human-readable CIDR form of the TUN shadow route.
    var shadowCIDR: String { tunRoute }
}

enum NetScanner {
    // MARK: - Interface enumeration

    // System-proxy bypass domains live in `Sources/XPC/HelperProtocol.swift` as
    // `kProxyBypassDomains` (single source of truth shared by the XPC Helper,
    // the local fallback, and the GUI-side reconcile). This enum previously
    // held a duplicate copy that could drift; it was unreferenced and has been
    // removed. Reference `kProxyBypassDomains` directly — it is visible here
    // without import (same app-target compilation module).

    /// Enumerate IPv4 interfaces via getifaddrs (no shell, no privileges).
    static func interfaces() -> [NetIface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var ips: [String: [String]] = [:]
        var flags: [String: Int32] = [:]
        var order: [String] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let nm = String(cString: cur.pointee.ifa_name)
            if flags[nm] == nil { flags[nm] = Int32(cur.pointee.ifa_flags); order.append(nm) }
            if let a = cur.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                ips[nm, default: []].append(String(cString: host))
            }
            p = cur.pointee.ifa_next
        }
        return order.compactMap { nm -> NetIface? in
            let f = flags[nm] ?? 0
            let up = (f & Int32(IFF_UP)) != 0 && (f & Int32(IFF_RUNNING)) != 0
            let addrs = ips[nm] ?? []
            let kind = classify(name: nm, flags: f, ips: addrs)
            if kind == .loopback { return nil }
            if addrs.isEmpty && !nm.hasPrefix("utun") { return nil }
            return NetIface(id: nm, ipv4: addrs, isUp: up, kind: kind)
        }
    }

    private static func classify(name: String, flags: Int32, ips: [String]) -> IfaceKind {
        if (flags & Int32(IFF_LOOPBACK)) != 0 { return .loopback }
        let isTun = name.hasPrefix("utun") || (flags & Int32(IFF_POINTOPOINT)) != 0
        if isTun {
            for ip in ips {
                if ip.hasPrefix("198.18.") || ip.hasPrefix("198.19.") { return .proxyTun }
                if isCGNAT(ip) { return .tailscale }
                if ip.hasPrefix("10.147.") { return .zerotier }
            }
            return .otherTun
        }
        if name.hasPrefix("en") || name.hasPrefix("bridge") { return .physical }
        return .otherTun
    }

    /// 100.64.0.0/10 carrier-grade NAT (Tailscale).
    private static func isCGNAT(_ ip: String) -> Bool {
        let p = ip.split(separator: ".")
        guard p.count == 4, p[0] == "100", let o2 = Int(p[1]) else { return false }
        return o2 >= 64 && o2 <= 127
    }

    // MARK: - Route table parsing

    /// Full IPv4 route table scan (netstat -rn -f inet). Returns all entries.
    static func allRoutes() async -> [RouteEntry] {
        await Task.detached(priority: .userInitiated) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
            task.arguments = ["-rn", "-f", "inet"]
            let pipe = Pipe(); task.standardOutput = pipe; task.standardError = Pipe()
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let out = String(data: data, encoding: .utf8) ?? ""
                var rows: [RouteEntry] = []
                for line in out.split(separator: "\n") {
                    let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    // Columns: Destination Gateway Flags [Refs Use] Netif [Expire]
                    guard cols.count >= 4 else { continue }
                    let dest = cols[0]; let gw = cols[1]; let flags = cols[2]
                    let iface = cols.last ?? ""
                    // Skip header lines
                    if dest == "Destination" || dest == "Internet:" { continue }
                    rows.append(RouteEntry(dest: dest, gateway: gw, iface: iface, flags: flags))
                }
                return rows
            } catch { return [] }
        }.value
    }

    /// Routes touching utun interfaces only (used by the SD-WAN topology view).
    static func tunRoutes() async -> [(dest: String, iface: String)] {
        let all = await allRoutes()
        return all.filter { $0.iface.hasPrefix("utun") }.map { ($0.dest, $0.iface) }
    }

    // MARK: - CIDR overlap detection

    /// Parse a macOS netstat destination string into (baseAddress as UInt32, prefixLength).
    /// Handles: "default" -> (0, 0), "100.64/10" -> abbreviated, "192.168.1.0/24" -> full,
    /// bare host IPs, and single-octet shorthand like "100/10".
    static func parseCIDR(_ dest: String) -> (UInt32, Int)? {
        if dest == "default" { return (0, 0) }
        let parts = dest.split(separator: "/", maxSplits: 1)
        let prefix = parts.count == 2 ? Int(parts[1]) : nil

        // Expand abbreviated IP (e.g. "100" -> "100.0.0.0", "100.64" -> "100.64.0.0")
        var ipStr = String(parts[0])
        let octets = ipStr.split(separator: ".").map(String.init)
        if octets.count < 4 {
            ipStr = (octets + Array(repeating: "0", count: 4 - octets.count)).joined(separator: ".")
        }

        guard let ip = ipToUInt32(ipStr) else { return nil }
        // If no prefix length given, treat as host route (/32)
        let pl = prefix ?? 32
        guard pl >= 0 && pl <= 32 else { return nil }
        let mask: UInt32 = pl == 0 ? 0 : (0xFFFFFFFF << (32 - pl))
        return (ip & mask, pl)
    }

    private static func ipToUInt32(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    /// Returns true if CIDR `a` overlaps with CIDR `b` (either contains or is contained).
    /// Two CIDRs overlap iff one's network contains the other's network base address.
    static func cidrsOverlap(_ a: String, _ b: String) -> Bool {
        guard let (aBase, aLen) = parseCIDR(a),
              let (bBase, bLen) = parseCIDR(b) else { return false }
        // default route overlaps everything
        if aLen == 0 || bLen == 0 { return true }
        // Check if A's network contains B's base: apply A's mask to B's base
        let aMask: UInt32 = 0xFFFFFFFF << (32 - aLen)
        if (bBase & aMask) == (aBase & aMask) { return true }
        // Check if B's network contains A's base: apply B's mask to A's base
        let bMask: UInt32 = 0xFFFFFFFF << (32 - bLen)
        if (aBase & bMask) == (bBase & bMask) { return true }
        return false
    }

    // MARK: - Conflict detection

    /// Detect SD-WAN routes that are shadowed by mihomo TUN auto-route prefixes.
    /// Returns list of conflicts, each describing which SD-WAN route is masked.
    static func conflictingRoutes() async -> [RouteConflict] {
        let all = await allRoutes()
        let ifaces = interfaces()

        // Identify TUN proxy interface names (e.g. utun9 with 198.18.x.x)
        let tunIfaceNames = Set(ifaces.filter { $0.kind == .proxyTun }.map { $0.id })
        // Identify SD-WAN interface names (Tailscale, ZeroTier, etc.)
        let sdwanIfaceNames = Set(ifaces.filter { $0.kind.sdwan }.map { $0.id })

        // Gather TUN routes
        let tunRoutes = all.filter { tunIfaceNames.contains($0.iface) }
        // Gather SD-WAN routes
        let sdwanRoutes = all.filter { sdwanIfaceNames.contains($0.iface) }

        var conflicts: [RouteConflict] = []
        for sdwan in sdwanRoutes {
            for tun in tunRoutes {
                if cidrsOverlap(sdwan.dest, tun.dest) {
                    // Check if TUN route would win (shorter prefix = wider, takes priority
                    // in a split-tunnel scenario where mihomo injects many /3-/32 aggregates)
                    if let (_, sdwanPfx) = parseCIDR(sdwan.dest),
                       let (_, tunPfx) = parseCIDR(tun.dest),
                       tunPfx <= sdwanPfx {
                        let conflict = RouteConflict(
                            sdwanRoute: sdwan.dest,
                            sdwanIface: sdwan.iface,
                            tunRoute: tun.dest,
                            tunIface: tun.iface
                        )
                        // Deduplicate by sdwanRoute+sdwanIface pair
                        if !conflicts.contains(where: { $0.sdwanRoute == conflict.sdwanRoute && $0.sdwanIface == conflict.sdwanIface }) {
                            conflicts.append(conflict)
                        }
                    }
                }
            }
        }
        return conflicts
    }

    // MARK: - SD-WAN exclude prefix collection

    /// Collect all CIDR prefixes belonging to active SD-WAN / virtual interfaces
    /// so they can be injected into `tun.route-exclude-address`.
    static func sdwanExcludePrefixes() async -> [String] {
        let routes = await sdwanExcludeRoutes()
        return Array(routes.keys).sorted()
    }

    /// Check if mihomo's TUN interface actually exists by scanning for a utun
    /// with the fake-ip range (198.18.x.x / 198.19.x.x per `classify`).
    ///
    /// Beyond a bare 198.18 match, this arbitrates among *multiple* proxyTun
    /// candidates by consulting the route table. A live mihomo TUN (auto-route)
    /// always has route entries pointing at its utun (default / fake-ip range /
    /// split 0.0.0.0/1 + 128.0.0.0/1). A zombie utun — left behind after mihomo
    /// crashed or rebuilt onto a new utun, but whose 198.18 address lingers —
    /// has no routes. Returning the zombie would make callers believe TUN is
    /// healthy, pinning system DNS at 198.18.0.1 on a dead interface → total
    /// DNS blackout. So with multiple candidates we pick the one the route table
    /// actually references.
    ///
    /// Conservative by design: with a single candidate we trust it as-is
    /// (no route scan → no netstat fork on the common 3 s poll, and never risk
    /// tearing down a healthy TUN on an API hiccup). With multiple candidates
    /// but no route evidence either way (e.g. netstat failed), we fall back to
    /// the first candidate rather than return nil — prefer a missed teardown
    /// this tick to wrongly declaring the interface gone.
    /// - Parameter maxAge: Cache tolerance. The default suits the periodic
    ///   health polls; the TUN bring-up wait loop passes a near-zero value so a
    ///   cached negative from just before the utun appeared doesn't stall the
    ///   enable flow ~1.5s (nil results are cached like any other).
    static func mihomoTunInterface(maxAge: TimeInterval = 1.5) async -> String? {
        // Short TTL cache: refreshConfigs used to call this every 3s; even after
        // poll layering, verify paths can still stack. 1.5s is well under the
        // health-check period and avoids repeated getifaddrs/route forks.
        if let cached = tunCache, Date().timeIntervalSince(cached.at) < maxAge {
            return cached.name
        }
        let name = await mihomoTunInterfaceUncached()
        tunCache = (name, Date())
        return name
    }

    private static var tunCache: (name: String?, at: Date)?

    private static func mihomoTunInterfaceUncached() async -> String? {
        let ifaces = interfaces()
        let candidates = ifaces.filter { $0.kind == .proxyTun }
        if candidates.isEmpty { return nil }
        if candidates.count == 1 {
            // Single candidate — historically trusted as-is to avoid a netstat
            // fork on the common 3 s poll and to never wrongly tear down a healthy
            // TUN on an API hiccup (see the doc comment above).
            //
            // BUT: a zombie utun whose 198.18 address lingers after mihomo died,
            // with no other proxyTun candidate present, would be returned here
            // and pin system DNS at 198.18.0.1 on a dead interface → total DNS
            // blackout that no auto-teardown path would self-heal.
            //
            // Cheap conservative check before trusting it: `route -n get` the
            // fake-ip gateway 198.18.0.1 — a live mihomo TUN (auto-route) always
            // resolves it through its own utun. Require BOTH route divergence
            // (route-get's interface != the candidate) AND the candidate's flags
            // already down (IFF_UP/IFF_RUNNING cleared) before declaring it a
            // zombie. The dual criteria sidesteps the TUN-just-enabled race
            // window (route not yet injected but interface still up → still
            // trusted) and keeps the worst-case behavior "miss a teardown this
            // tick" rather than "wrongly tear down".
            let only = candidates[0]
            if !only.isUp,
               case let resolved = await routeTargetInterface("198.18.0.1"),
               resolved != only.id {
                return nil
            }
            return only.id
        }
        let routes = await allRoutes()
        let routed = Set(routes.map { $0.iface })
        if let live = candidates.first(where: { routed.contains($0.id) }) {
            return live.id
        }
        return candidates.first?.id
    }

    /// True if a proxyTun utun bearing a mihomo 198.18/198.19 address still
    /// exists in the interface table but is already DOWN (IFF_UP/IFF_RUNNING
    /// cleared) — i.e. the zombie residue `mihomoTunInterface` would have
    /// declared gone. Synchronous (no fork): relies only on `interfaces()`'s
    /// getifaddrs flags. Used by the auto-teardown paths as the gate for the
    /// XPC `cleanupTUNResidual` fallback — so the privilege-required physical
    /// teardown (ifconfig down + delete IP + route flush) only fires when there
    /// is an actual residual mihomo utun to neutralize, never when a healthy
    /// TUN simply went away cleanly. This keeps the 198.18.x shared-address
    /// space safe for co-resident VPN apps (Shadowrocket etc.) that keep their
    /// own utun UP.
    static func hasDownedMihomoTun() -> Bool {
        interfaces().contains { $0.kind == .proxyTun && !$0.isUp }
    }

    /// Resolve which interface the kernel routes `ip` through, via a read-only
    /// non-privileged `route -n get <ip>`. Returns the BSD interface name from the
    /// `interface:` line, or nil if route-get fails / the line is absent. Mirrors
    /// the parsing in `EngineControl.defaultInterface()`, kept here in NetScanner so
    /// the TUN-health probe stays self-contained.
    private static func routeTargetInterface(_ ip: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/route")
            p.arguments = ["-n", "get", ip]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let out = String(data: data, encoding: .utf8) else { return nil }
            for line in out.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("interface:") {
                    let name = t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { return name }
                }
            }
            return nil
        }.value
    }

    /// Collect all routes that should bypass TUN and their corresponding utun interface.
    /// This includes:
    /// - The host IP (/32) of the interfaces
    /// - Known allocation ranges (Tailscale 100.64.0.0/10, ZeroTier 10.147.0.0/16)
    /// - Routing table entries going through these interfaces
    static func sdwanExcludeRoutes() async -> [String: String] {
        let ifaces = interfaces()
        // Filter out all virtual interfaces (utun*) except proxyTun (Clash's own TUN)
        let targetIfaces = ifaces.filter { $0.id.hasPrefix("utun") && $0.kind != .proxyTun }
        guard !targetIfaces.isEmpty else { return [:] }

        var routes = [String: String]()

        // 1. Map each interface's IPs
        for iface in targetIfaces {
            for ip in iface.ipv4 {
                routes["\(ip)/32"] = iface.id
                // If it is CGNAT IP, it is definitely Tailscale
                if isCGNAT(ip) {
                    routes["100.64.0.0/10"] = iface.id
                    routes["100.100.100.100/32"] = iface.id
                }
            }
            
            // Add defaults based on classified kind
            switch iface.kind {
            case .tailscale:
                routes["100.64.0.0/10"] = iface.id
                routes["100.100.100.100/32"] = iface.id
            case .zerotier:
                routes["10.147.0.0/16"] = iface.id
            default:
                break
            }
        }

        // 2. Scan routing table to associate existing routes with target interfaces
        let targetIfaceNames = Set(targetIfaces.map { $0.id })
        let all = await allRoutes()
        for route in all where targetIfaceNames.contains(route.iface) {
            let d = route.dest
            if d == "default" { continue }
            if let (base, pl) = parseCIDR(d) {
                let o1 = (base >> 24) & 0xFF
                let o2 = (base >> 16) & 0xFF
                let o3 = (base >> 8) & 0xFF
                let o4 = base & 0xFF
                let normalizedDest = "\(o1).\(o2).\(o3).\(o4)/\(pl)"
                routes[normalizedDest] = route.iface
                
                // If the routing dest points to MagicDNS or tailscale CIDR, bind it
                if d == "100.100.100.100/32" || d.hasPrefix("100.100.100.100") {
                    routes["100.64.0.0/10"] = route.iface
                    routes["100.100.100.100/32"] = route.iface
                }
            }
        }

        // 3. Fallback: if we found some utun interfaces but Tailscale CIDR was not mapped
        // (e.g., interface has no IP yet or routing table is clean), map it to the first utun interface
        if !routes.keys.contains(where: { $0.hasPrefix("100.64.") }) {
            if let firstUtun = targetIfaces.first {
                routes["100.64.0.0/10"] = firstUtun.id
                routes["100.100.100.100/32"] = firstUtun.id
            }
        }

        return routes
    }
}

// MARK: - Formatting helpers (single source of truth)

func fmtRate(_ b: Double) -> String {
    if b >= 1_000_000 { return String(format: "%.1f MB/s", b / 1_000_000) }
    if b >= 1_000 { return String(format: "%.0f KB/s", b / 1_000) }
    return String(format: "%.0f B/s", b)
}
func fmtBytes(_ b: Double) -> String {
    if b >= 1_000_000_000 { return String(format: "%.2f GB", b / 1_000_000_000) }
    if b >= 1_000_000 { return String(format: "%.1f MB", b / 1_000_000) }
    if b >= 1_000 { return String(format: "%.0f KB", b / 1_000) }
    return "\(Int(b)) B"
}
func fmtDelay(_ ms: Int) -> String { ms > 0 ? "\(ms)" : "—" }
func delayColor(_ ms: Int) -> Color { ms <= 0 ? .secondary : ms < 100 ? DS.Palette.ok : ms < 250 ? DS.Palette.warn : DS.Palette.error }
func modeLabel(_ m: String) -> String { ["rule":"规则","global":"全局","direct":"直连"][m] ?? m }

// MARK: - Extensions

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
