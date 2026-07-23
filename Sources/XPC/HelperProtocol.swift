import Foundation

/// Single source of truth for the privileged helper version.
/// Shared by both the Helper binary (compiled via make.sh) and the main app
/// (Xcode target) since both include this file — prevents the two-location
/// version drift that caused infinite upgrade loops.
public let kSharedHelperVersion = "1.0.23"

/// The utun name mihomo is asked to take, instead of accepting whatever index
/// the kernel hands out. Shared with the Helper so it can tell a route our own
/// TUN grabbed (ours to correct) from one another tunnel owns (never ours to
/// touch). See the fuller rationale at the app-side usage.
public let kPinnedTunDevice = "utun100"

/// Reading the kernel routing table precisely enough to tell "this prefix is
/// routed" from "something answers for an address inside it".
///
/// `route -n get <addr>` always answers as long as *any* route matches, and for
/// an unrouted address that answer is the default route. Treating a reply as
/// proof that the prefix exists is what let the helper believe a peer subnet was
/// installed when the traffic was really going out the physical NIC — and,
/// worse, treat a route it never created as its own to delete. Every check here
/// therefore compares the matched route's destination *and* mask against what
/// was asked for.
public enum RouteTable {

    public struct Entry: Equatable {
        /// Canonical `a.b.c.d/len`.
        public let cidr: String
        public let interface: String
        public let flags: String
        /// Scoped routes (`RTF_IFSCOPE`) only apply to traffic already bound to
        /// the interface, so they are not an answer to "what carries this
        /// prefix".
        public var isScoped: Bool { flags.contains("I") }
    }

    /// Parse `netstat -rn -f inet` into entries with canonical CIDRs.
    ///
    /// The route table is read rather than `route -n get`, because route-get
    /// does not report an interface route's own prefix: for an entry whose
    /// gateway is a link — `2/7 link#42 utun8`, the shape every tunnel's
    /// auto-route aggregates take — `route -n get 2.0.0.0` answers
    /// `destination: default, mask: default, interface: utun8`. Read as an
    /// existence check, an installed prefix looks absent, and the helper would
    /// reinstall a route that is already there. 17 such aggregates were live on
    /// the machine this was verified against.
    public static func parse(netstat output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 4, cols[0] != "Destination", cols[0] != "Internet:",
                  let iface = interfaceColumn(cols), let cidr = normalizedCIDR(cols[0])
            else { return nil }
            return Entry(cidr: cidr, interface: iface, flags: cols[2])
        }
    }

    /// The `Netif` column. Not simply the last one: rows carry a trailing
    /// `Expire` column that renders as `!` for link-local ARP entries
    /// (`169.254 link#7 UCS en0 !`), so reading the last token yields `!` as the
    /// interface name — which then matches nothing and silently drops those
    /// routes out of every comparison built on top of this.
    ///
    /// Columns are `Destination Gateway Flags Netif [Expire]`, so the interface
    /// is the last token after the flags that looks like a name: it must contain
    /// a letter (rules out numeric expiry and IP gateways) and must not contain
    /// `:` or `#` (rules out MAC and `link#N` gateways).
    private static func interfaceColumn(_ cols: [String]) -> String? {
        cols.dropFirst(3).last { token in
            token.rangeOfCharacter(from: .letters) != nil
                && !token.contains(":") && !token.contains("#")
        }
    }

    /// The interface carrying exactly `cidr`, nil when the table has no such
    /// entry. A wider route that merely covers the prefix is not a match.
    public static func interface(exactly cidr: String) -> String? {
        guard let want = normalizedCIDR(cidr) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        p.arguments = ["-rn", "-f", "inet"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        return parse(netstat: out).first { $0.cidr == want && !$0.isScoped }?.interface
    }

    /// `netstat` destination → canonical `a.b.c.d/len`.
    ///
    /// The destination is abbreviated to the octets its mask covers, and `/len`
    /// appears only when that mask is *not* the natural one for that many
    /// octets: `192.168.3` is `192.168.3.0/24`, `126` is `126.0.0.0/8`, while
    /// `100.64/10` states its own length. A four-octet destination without a
    /// length really is a host route.
    public static func normalizedCIDR(_ dest: String) -> String? {
        guard let (base, len) = parseCIDR(dest) else { return nil }
        let o = [(base >> 24) & 0xFF, (base >> 16) & 0xFF, (base >> 8) & 0xFF, base & 0xFF]
        return "\(o[0]).\(o[1]).\(o[2]).\(o[3])/\(len)"
    }

    /// `(network base, prefix length)` for a route-table destination or a plain
    /// CIDR. `default` → `(0, 0)`.
    public static func parseCIDR(_ dest: String) -> (UInt32, Int)? {
        if dest == "default" { return (0, 0) }
        let parts = dest.split(separator: "/", maxSplits: 1)
        let stated = parts.count == 2 ? Int(parts[1]) : nil
        let octets = parts[0].split(separator: ".").map(String.init)
        guard !octets.isEmpty, octets.count <= 4 else { return nil }
        let padded = octets + Array(repeating: "0", count: 4 - octets.count)
        guard let ip = ipToUInt32(padded.joined(separator: ".")) else { return nil }
        let len = stated ?? (octets.count < 4 ? octets.count * 8 : 32)
        guard (0...32).contains(len) else { return nil }
        let mask: UInt32 = len == 0 ? 0 : (0xFFFFFFFF << (32 - len))
        return (ip & mask, len)
    }

    private static func ipToUInt32(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}

/// System-proxy bypass domains — single source of truth shared by the Helper
/// binary, the local shell fallback, and the GUI-side self-healing reconcile.
///
/// Includes localhost + loopback + mDNS + RFC1918 private ranges + link-local +
/// CGNAT, so LAN/intranet hosts and SD-WAN peers are never tunneled through the
/// proxy (which would fail or be rejected by the kernel, surfacing as HTTP 502
/// to LAN devices such as a NAS at 10.1.1.1). macOS bypass matching uses
/// shell-style wildcards per host/IP, so each private octet-prefix gets an
/// explicit entry. The CGNAT block (100.64.0.0/10) spans 64 octets (64..127).
public let kProxyBypassDomains: [String] = {
    var list = ["localhost", "127.0.0.1", "*.local", "10.*", "192.168.*", "169.254.*"]
    list += (16...31).map { "172.\($0).*" }
    list += (64...127).map { "100.\($0).*" }
    return list
}()

@objc(HelperProtocol)
public protocol HelperProtocol {
    func getVersion(withReply reply: @escaping (String) -> Void)
    func setSystemProxy(enabled: Bool, port: Int, withReply reply: @escaping (Bool) -> Void)
    func startMihomo(binPath: String, homeDir: String, withReply reply: @escaping (Bool) -> Void)
    func stopMihomo(withReply reply: @escaping (Bool) -> Void)
    func setGatewayMode(enabled: Bool, withReply reply: @escaping (Bool) -> Void)
    func setupExcludeRoutes(_ routes: [String: String], withReply reply: @escaping (Bool) -> Void)
    func cleanupAllExcludeRoutes(withReply reply: @escaping (Bool) -> Void)
    /// Physically neutralize lingering mihomo utun residue (down + delete IP +
    /// route flush) after a TUN teardown the kernel did not reclaim. Brought
    /// online as the privilege-side fallback for the GUI's zombie-utun probe.
    func cleanupTUNResidual(withReply reply: @escaping (Bool) -> Void)
}
