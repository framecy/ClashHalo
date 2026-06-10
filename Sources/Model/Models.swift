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

struct Conn: Identifiable {
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

// MARK: - AppModel



// MARK: - Keychain Security Helper

struct KeychainHelper {
    static let service = "com.clashpow.secrets"

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

enum NetScanner {
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
            // hide empty bridge/thunderbolt ports and loopback
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

    /// Routes touching utun interfaces (netstat, no root). Returns (dest, iface).
    static func tunRoutes() async -> [(dest: String, iface: String)] {
        await Task.detached(priority: .userInitiated) {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
            task.arguments = ["-rn", "-f", "inet"]
            let pipe = Pipe(); task.standardOutput = pipe
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let out = String(data: data, encoding: .utf8) ?? ""
                var rows: [(String, String)] = []
                for line in out.split(separator: "\n") {
                    let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    guard cols.count >= 4 else { continue }
                    let iface = cols.last ?? ""
                    if iface.hasPrefix("utun") { rows.append((cols[0], iface)) }
                }
                return rows
            } catch {
                return []
            }
        }.value
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
