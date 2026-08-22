import Foundation

/// Single source of truth for the privileged helper version.
/// Shared by both the Helper binary (compiled via make.sh) and the main app
/// (Xcode target) since both include this file — prevents the two-location
/// version drift that caused infinite upgrade loops.
///
/// 1.0.27: client-death cleanup scopes its loopback-proxy reality check to the
/// port the helper last wrote, so quitting ClashHalo no longer wipes a
/// co-resident proxy app's system-proxy settings. 1.0.26: cleanup re-checks
/// session takeover before its destructive steps (quit/relaunch race).
/// 1.0.25: system-proxy rework (shared ProxyServicePlan, branch-order fix, no
/// 2-service cap, full-success-only Bool).
public let kSharedHelperVersion = "1.0.27"

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
        /// The Gateway column verbatim.
        public let gateway: String
        /// Scoped routes (`RTF_IFSCOPE`) only apply to traffic already bound to
        /// the interface, so they are not an answer to "what carries this
        /// prefix".
        public var isScoped: Bool { flags.contains("I") }
        /// Shape of a route installed as `route add -net X -interface utunN`:
        /// the Gateway column repeats the interface name. A tunnel's *own*
        /// routes name their link instead (`link#32`), so this distinguishes
        /// what this app added from what the peer added — the distinction that
        /// decides whether a route is ours to withdraw.
        public var isInterfaceRoute: Bool { gateway == interface }
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
            return Entry(cidr: cidr, interface: iface, flags: cols[2], gateway: cols[1])
        }
    }

    /// Read and parse the live IPv4 route table.
    public static func current() -> [Entry] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        p.arguments = ["-rn", "-f", "inet"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }
        return parse(netstat: out)
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
        return current().first { $0.cidr == want && !$0.isScoped }?.interface
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

    /// A prefix of either family, as network bytes plus a length.
    ///
    /// The IPv4 path keeps its own `parseCIDR`/`UInt32` implementation because it
    /// also has to undo netstat's destination abbreviation (`100.64/10`, `126`),
    /// which is a v4-only notation. This type is what lets the *rules* built on
    /// top — overlap, the link-only list, attached subnets — stop being v4-only.
    public struct IPPrefix: Equatable {
        public let bytes: [UInt8]      // 4 for v4, 16 for v6
        public let length: Int
        public var isV6: Bool { bytes.count == 16 }

        /// Parse a CIDR of either family. IPv6 goes through `inet_pton`, so `::`
        /// compression and every other textual form the RFC allows are handled by
        /// the system rather than by a hand-rolled parser.
        public init?(_ cidr: String) {
            if cidr.contains(":") {
                let parts = cidr.split(separator: "/", maxSplits: 1)
                let len = parts.count == 2 ? Int(parts[1]) : 128
                guard let len, (0...128).contains(len) else { return nil }
                var addr = in6_addr()
                guard String(parts[0]).withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1
                else { return nil }
                var raw = withUnsafeBytes(of: addr) { Array($0) }
                guard raw.count == 16 else { return nil }
                Self.maskInPlace(&raw, length: len)
                self.bytes = raw
                self.length = len
            } else {
                guard let (base, len) = RouteTable.parseCIDR(cidr) else { return nil }
                self.bytes = [UInt8((base >> 24) & 0xFF), UInt8((base >> 16) & 0xFF),
                              UInt8((base >> 8) & 0xFF), UInt8(base & 0xFF)]
                self.length = len
            }
        }

        private static func maskInPlace(_ b: inout [UInt8], length: Int) {
            for i in 0..<b.count {
                let bitsBefore = i * 8
                if bitsBefore >= length { b[i] = 0 }
                else if bitsBefore + 8 > length {
                    b[i] &= UInt8(truncatingIfNeeded: 0xFF << (8 - (length - bitsBefore)))
                }
            }
        }

        /// True when the first `n` bits of both addresses agree.
        fileprivate func sharesPrefix(_ other: IPPrefix, bits n: Int) -> Bool {
            guard bytes.count == other.bytes.count else { return false }
            let whole = n / 8, rest = n % 8
            for i in 0..<whole where bytes[i] != other.bytes[i] { return false }
            guard rest > 0 else { return true }
            let m = UInt8(truncatingIfNeeded: 0xFF << (8 - rest))
            return (bytes[whole] & m) == (other.bytes[whole] & m)
        }
    }

    /// True when `a` and `b` overlap — either contains the other.
    ///
    /// A prefix whose actual carrier disagrees with what the coexistence plan
    /// says should carry it.
    public struct Drift: Equatable {
        public enum Kind: Equatable {
            /// Our own TUN has taken a prefix that belongs to a peer.
            case hijackedByOurTun
            /// Nothing carries the prefix at all.
            case missing
        }
        public let cidr: String
        /// Interface that should carry it, e.g. `utun8`.
        public let expected: String
        /// Interface that does, or nil when nothing does.
        public let actual: String?
        public let kind: Kind

        public init(cidr: String, expected: String, actual: String?, kind: Kind) {
            self.cidr = cidr; self.expected = expected
            self.actual = actual; self.kind = kind
        }
    }

    /// Compare a plan's route ownership against a route table.
    ///
    /// Pure, so the caller supplies the table — the app passes `current()` on a
    /// timer, and the tests pass a real failing machine's table verbatim. Lives
    /// here beside `PeerRouteGuard` for the same reason that does: this decides
    /// what gets *asked for*, `setupExcludeRoutes` decides what gets *installed*,
    /// and the two disagreeing is how a prefix slips through.
    ///
    /// Two verdicts, and the narrowness is deliberate. A prefix carried by some
    /// *third* interface is left alone: overriding another owner's routing
    /// decision is exactly what tore down peer tunnels before. Scoped routes are
    /// filtered out first — they only apply to traffic already bound to their
    /// interface, so they are never an answer to "what carries this prefix".
    public static func drift(expected: [String: String],
                             in table: [Entry],
                             pinned: String = kPinnedTunDevice) -> [Drift] {
        guard !expected.isEmpty else { return [] }
        var carrier = [String: String]()
        for e in table where !e.isScoped && carrier[e.cidr] == nil {
            carrier[e.cidr] = e.interface
        }
        return expected.compactMap { cidr, want -> Drift? in
            guard let have = carrier[cidr] else {
                return Drift(cidr: cidr, expected: want, actual: nil, kind: .missing)
            }
            guard have != want, have == pinned else { return nil }
            return Drift(cidr: cidr, expected: want, actual: have, kind: .hijackedByOurTun)
        }.sorted { $0.cidr < $1.cidr }
    }

    /// Prefixes of different families never overlap: an IPv6 prefix cannot be
    /// contained in an IPv4 one, and treating an unparseable pair as "overlapping"
    /// would make the guard reject prefixes at random.
    public static func overlaps(_ a: String, _ b: String) -> Bool {
        guard let pa = IPPrefix(a), let pb = IPPrefix(b) else { return false }
        guard pa.isV6 == pb.isV6 else { return false }
        if pa.length == 0 || pb.length == 0 { return true }
        return pa.sharesPrefix(pb, bits: min(pa.length, pb.length))
    }
}

/// The single rule deciding whether a prefix may be routed into a peer tunnel.
///
/// It lives here, in the file both the GUI and the privileged helper compile,
/// because the two enforce it at different distances from the damage: the GUI
/// decides what to *ask* for, the helper decides what to *install*. A prefix
/// getting past one of them and not the other is how the machine this was
/// diagnosed on ended up with its own LAN (`10.1.1.0/24`), all IPv4 multicast
/// and the broadcast address pointed at a Tailscale utun — with the record of
/// having done so lost in a helper restart, so nothing ever took them back.
public enum PeerRouteGuard {

    /// Prefixes that are link-scoped by definition and can never be carried by a
    /// tunnel: this-network, loopback, link-local, multicast, broadcast.
    /// Routing them into a utun does not exclude them from anything — it removes
    /// them from the local segment, taking mDNS/Bonjour, DHCP and SSDP with them.
    ///
    /// The IPv6 entries have the same standing as their v4 counterparts, and are
    /// listed even though route *harvesting* is still IPv4-only. The rules and the
    /// harvester fail differently: a missing rule is a hole that opens silently the
    /// day the harvester widens, whereas a rule with nothing to match is inert.
    /// `fe80::/10` and `ff00::/8` are also exactly what users hand-write into
    /// `route-exclude-address`, and `isProtectiveExclusion` must recognise them or
    /// a withdrawal pass can delete the user's own entries — the v4 form of that
    /// bug is what took multicast down earlier in this work.
    public static let linkOnlyPrefixes = [
        "0.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "224.0.0.0/4",
        "255.255.255.255/32",
        "::/128",             // unspecified
        "::1/128",            // loopback
        "fe80::/10",          // link-local (AWDL / Handoff live here)
        "ff00::/8"            // multicast
    ]

    /// True when `cidr` must never point at a peer tunnel: it is link-only, or it
    /// overlaps a subnet this machine is directly attached to. Directly attached
    /// always wins — a peer advertising the local LAN (a subnet router on the same
    /// segment) has nothing to offer that the physical NIC does not already reach.
    public static func isForbidden(_ cidr: String, localSubnets: [String]) -> Bool {
        if linkOnlyPrefixes.contains(where: { RouteTable.overlaps(cidr, $0) }) { return true }
        return localSubnets.contains(where: { RouteTable.overlaps(cidr, $0) })
    }

    /// `cidr → interface` for every directly-attached subnet. The owner matters
    /// when a tunnel route over such a subnet is withdrawn: the prefix has to end
    /// up back on the NIC that actually reaches it.
    public static func localSubnetOwners() -> [String: String] {
        var out: [String: String] = [:]
        forEachAttachedSubnet { cidr, iface in
            if out[cidr] == nil { out[cidr] = iface }
        }
        return out
    }

    /// Subnets this host is directly attached to, in `a.b.c.d/len` form, read
    /// straight from `getifaddrs`. Point-to-point and host masks yield nothing —
    /// only real subnets are of interest — and tunnels are skipped so a peer
    /// cannot make its own prefixes look locally attached.
    public static func localAttachedSubnets() -> [String] {
        var out = Set<String>()
        forEachAttachedSubnet { cidr, _ in out.insert(cidr) }
        return out.sorted()
    }

    private static func forEachAttachedSubnet(_ body: (String, String) -> Void) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("lo") else { continue }
            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & Int32(IFF_LOOPBACK)) == 0,
                  (flags & Int32(IFF_POINTOPOINT)) == 0,
                  (flags & Int32(IFF_UP)) != 0 else { continue }
            guard let a = cur.pointee.ifa_addr, let m = cur.pointee.ifa_netmask,
                  a.pointee.sa_family == m.pointee.sa_family else { continue }

            switch Int32(a.pointee.sa_family) {
            case AF_INET:
                let addr = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                let mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                let len = mask.nonzeroBitCount
                // Contiguous, non-host masks only.
                guard len > 0, len < 32, mask == (UInt32.max << (32 - len)) else { continue }
                let base = addr & mask
                body("\((base >> 24) & 255).\((base >> 16) & 255).\((base >> 8) & 255).\(base & 255)/\(len)",
                     name)

            case AF_INET6:
                let addr = a.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                }
                let mask = m.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                }
                guard addr.count == 16, mask.count == 16 else { continue }
                let len = mask.reduce(0) { $0 + $1.nonzeroBitCount }
                // Contiguous, non-host masks only — same rule as v4.
                guard len > 0, len < 128 else { continue }
                let whole = len / 8, rest = len % 8
                var expected = [UInt8](repeating: 0, count: 16)
                for i in 0..<whole { expected[i] = 0xFF }
                if rest > 0 { expected[whole] = UInt8(truncatingIfNeeded: 0xFF << (8 - rest)) }
                guard mask == expected else { continue }
                // Link-local is per-interface, never a routable attached subnet;
                // admitting it would let `isForbidden` reject every v6 prefix.
                guard !(addr[0] == 0xFE && (addr[1] & 0xC0) == 0x80) else { continue }
                let base = zip(addr, expected).map { $0 & $1 }
                var buf = base
                var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &buf, &out, socklen_t(INET6_ADDRSTRLEN)) != nil
                else { continue }
                body("\(String(cString: out))/\(len)", name)

            default:
                continue
            }
        }
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
    // Tailscale control plane + DERP relays + MagicDNS address.
    //
    // Scope: **system proxy only**. `kProxyBypassDomains` is consumed by
    // ProxyManager / the local shell fallback / `reconcileProxyBypassIfNeeded`.
    // It does NOT affect pure TUN traffic — that path is carved out by
    // `tun.route-exclude-address` (`100.64.0.0/10`, `100.100.100.100/32`) and
    // the DNS half reported via `CoexistencePlan.dnsAdvice` (`+.ts.net`). Do
    // not read a bypass entry here as a TUN fix.
    //
    // When the system proxy is ON, sending `login.tailscale.com` and
    // `*.derp.tailscale.com` through mihomo routinely times out the QUIC
    // probe (`Connection exceeded max PTO count`) and tailscaled flaps.
    // Bypass is unconditional: a host running Tailscale needs these even
    // before any keys are entered in Settings, and these are stable public
    // domains (not user secrets), so the single-source const is the right
    // home — Helper, fallback and reconcile all inherit them with no second
    // list to drift.
    //
    // `100.100.100.100` is already covered by the CGNAT `100.100.*` wildcard
    // above; the explicit entry is kept as a readable anchor for MagicDNS
    // (and is harmless to duplicate in the macOS bypass list).
    list += ["*.tailscale.com", "100.100.100.100"]
    return list
}()

// MARK: - System-proxy service plan (shared by Helper, GUI fallback, tests)

/// Three-way result of applying system-proxy settings. The legacy single-Bool
/// contract (`anyOK == true`) let one successful service mask silent failure on
/// every other active service, so the toggle reported "on" while half the
/// uplinks stayed direct. Both the Helper (XPC path) and the GUI fallback now
/// classify into full / partial / failed; only `.full` may be surfaced as
/// success — partial coverage must reach the user as a warning.
public enum SystemProxyApplyOutcome: Equatable {
    /// Every targeted service was configured successfully.
    case full
    /// Some services landed, others did not (ok / failed service names).
    case partial(ok: [String], failed: [String])
    /// Nothing was configured (or no target services were found).
    case failed

    /// Legacy Bool mapping: full only. This is what crosses the XPC wire and
    /// what callers may treat as "the system proxy is on".
    public var isSuccess: Bool {
        if case .full = self { return true }
        return false
    }
}

/// Single source of truth for *which* network services the system proxy should
/// be written to, and how `-get*proxy` readback parses. Compiled into the
/// Helper (ProxyManager), the GUI (EngineControl fallback + verification) and
/// the regression tests, so the three can never drift back into the
/// helper-vs-fallback inconsistency where the Helper configured the active
/// service set while the fallback wrote every enabled service.
public enum ProxyServicePlan {

    /// VPN / virtual client services we never touch: configuring them inflates
    /// the networksetup loop, often fails, and a proxy pointing into another
    /// tunnel's userspace helper is wrong anyway.
    public static let skipSubstrings = [
        "shadowrocket", "wireguard", "tailscale", "zerotier", "oray",
        "utun", "vpn", "ipsec", "l2tp", "pptp", "cisco", "openvpn",
        "clash", "surge", "quantumult", "v2ray"
    ]

    public static func isSkippableService(_ name: String) -> Bool {
        let lower = name.lowercased()
        return skipSubstrings.contains { lower.contains($0) }
    }

    /// Parse `networksetup -listnetworkserviceorder` output into
    /// (service, device) pairs.
    ///
    /// Output shape:
    /// ```
    /// (1) Wi-Fi
    /// (Hardware Port: Wi-Fi, Device: en0)
    ///
    /// (*) Bluetooth PAN          ← disabled services show (*) — no name
    /// (Hardware Port: Bluetooth PAN, Device: en3)
    /// ```
    /// The hardware-port line is itself "("-prefixed, so it must be matched
    /// BEFORE the generic "(N) name" service line. The reverse order made the
    /// hardware branch unreachable (the service branch consumed every line),
    /// `currentService` never paired with a device, and service selection
    /// silently degraded to the full enabled list — the root cause behind
    /// "proxy toggle says on, browser still direct".
    public static func serviceDevicePairs(orderOutput: String) -> [(service: String, device: String)] {
        var pairs: [(service: String, device: String)] = []
        var currentService: String? = nil
        for line in orderOutput.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            if s.hasPrefix("(Hardware Port:") {
                defer { currentService = nil }
                guard let svc = currentService, !svc.isEmpty else { continue }
                guard let devRange = s.range(of: "Device:"),
                      let endBracket = s.lastIndex(of: ")"),
                      devRange.upperBound < endBracket else { continue }
                let dev = s[devRange.upperBound..<endBracket]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !dev.isEmpty { pairs.append((service: svc, device: dev)) }
                continue
            }
            if s.hasPrefix("(") {
                if let closeIdx = s.firstIndex(of: ")") {
                    // "(*) Name" is a *disabled* service — the ordinal slot
                    // holds the asterisk instead of an index. It can never be
                    // a proxy target, so drop it before the name is captured.
                    let ordinal = s[s.index(after: s.startIndex)..<closeIdx]
                        .trimmingCharacters(in: .whitespaces)
                    if ordinal == "*" { currentService = nil }
                    else {
                        let name = s[s.index(after: closeIdx)...]
                            .trimmingCharacters(in: .whitespaces)
                        currentService = name.isEmpty ? nil : name
                    }
                }
            }
        }
        return pairs
    }

    /// Parse `networksetup -listallnetworkservices` output into enabled
    /// service names (drops the header line and `*`-disabled entries).
    public static func enabledServices(listOutput: String) -> [String] {
        listOutput.split(separator: "\n").compactMap { line -> String? in
            let s = String(line)
            if s.hasPrefix("An asterisk") { return nil }
            if s.hasPrefix("*") { return nil }
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
    }

    /// Parse `networksetup -getwebproxy`-style readback into its three fields.
    /// Shared by the GUI coverage verification so "did it really land" reads
    /// the same bytes the Helper wrote.
    public static func parseGetProxyOutput(_ output: String) -> (enabled: Bool, host: String?, port: Int?) {
        var enabled = false, host: String? = nil, port: Int? = nil
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Enabled:") { enabled = t.hasSuffix("Yes") }
            if t.hasPrefix("Server:") {
                host = t.dropFirst("Server:".count).trimmingCharacters(in: .whitespaces)
            }
            if t.hasPrefix("Port:") {
                port = Int(t.dropFirst("Port:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return (enabled, host, port)
    }

    /// The unified target list: non-virtual *active* services (device has a
    /// live IPv4), falling back to non-virtual enabled services when activity
    /// probing yields nothing, Wi-Fi/Ethernet ordered first. No count cap —
    /// capping at 2 is what left Ethernet / USB-LAN uplinks uncovered while
    /// the GUI fallback wrote all services (the two paths diverged).
    public static func targetServices(orderOutput: String?,
                                      listOutput: String?,
                                      deviceActive: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        var services = serviceDevicePairs(orderOutput: orderOutput ?? "")
            .filter { deviceActive($0.device) }
            .map { $0.service }
            .filter { !isSkippableService($0) }
            .filter { seen.insert($0).inserted }
        if services.isEmpty {
            seen.removeAll()
            services = enabledServices(listOutput: listOutput ?? "")
                .filter { !isSkippableService($0) }
                .filter { seen.insert($0).inserted }
        }
        // Prefer Wi-Fi / Ethernet first — that's what users mean by "system proxy".
        let preferred = services.filter {
            let l = $0.lowercased()
            return l.contains("wi-fi") || l.contains("wifi") || l.contains("ethernet") || l.contains("以太网")
        }
        return preferred.isEmpty ? services : preferred + services.filter { !preferred.contains($0) }
    }

    /// Fold per-service results into the shared three-way outcome.
    public static func classify(succeeded: [String], failed: [String]) -> SystemProxyApplyOutcome {
        if !succeeded.isEmpty && failed.isEmpty { return .full }
        if succeeded.isEmpty { return .failed }
        return .partial(ok: succeeded, failed: failed)
    }

    // MARK: live probes (fork networksetup / ifconfig; used by Helper *and* GUI)

    /// 5 s cap per probe: read-only, but networksetup can stall behind the
    /// configd lock and callers (XPC reply, main-actor fallback) have budgets.
    private static let probeTimeout: TimeInterval = 5.0

    private static func runProbe(_ bin: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + probeTimeout)
        timer.setEventHandler { if p.isRunning { p.terminate() } }
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

    /// True when `ifconfig <dev>` reports an active link or an IPv4 address.
    public static func deviceIsActive(_ device: String) -> Bool {
        guard !device.isEmpty else { return false }
        guard let out = runProbe("/sbin/ifconfig", [device]) else { return false }
        return out.contains("status: active") || out.contains("inet ")
    }

    /// Target services for *this* machine right now (same list the Helper and
    /// the GUI fallback configure; the GUI coverage check reuses it too).
    /// Cached ~15 s: enumeration forks networksetup twice plus ifconfig per
    /// service (~0.3–0.7 s real-world), and a single toggle off→on needs it
    /// from both the Helper write and the GUI acceptance path — service
    /// topology does not change on that timescale. `forceFresh` bypasses the
    /// cache for diagnostic reads (coverage verification after a suspicious
    /// write wants the live list, not a possibly-stale one).
    private static let targetCacheTTL: TimeInterval = 15
    private static var cacheLock = NSLock()
    private static var cachedTargets: (at: Date, services: [String]) = (.distantPast, [])

    @discardableResult
    public static func liveTargetServices(forceFresh: Bool = false) -> [String] {
        cacheLock.lock()
        if !forceFresh, Date().timeIntervalSince(cachedTargets.at) < targetCacheTTL {
            cacheLock.unlock()
            return cachedTargets.services
        }
        cacheLock.unlock()
        let services = liveTargetServicesUncached()
        cacheLock.lock()
        cachedTargets = (Date(), services)
        cacheLock.unlock()
        return services
    }

    private static func liveTargetServicesUncached() -> [String] {
        targetServices(
            orderOutput: runProbe("/usr/sbin/networksetup", ["-listnetworkserviceorder"]),
            listOutput: runProbe("/usr/sbin/networksetup", ["-listallnetworkservices"]),
            deviceActive: deviceIsActive
        )
    }
}

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
