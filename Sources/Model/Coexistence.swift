import Foundation

// MARK: - TUN coexistence
//
// mihomo's TUN takes over routing and DNS wholesale: `auto-route` installs a
// split-default that shadows other tunnels' prefixes, and fake-ip rewrites every
// name it is not told to leave alone. Any other utun on the machine — Tailscale,
// ZeroTier, WireGuard, WARP, a corporate VPN — therefore needs two things carved
// out of mihomo, not one:
//
//   route layer  → its prefixes in `tun.route-exclude-address`
//   DNS layer    → its domains in `dns.fake-ip-filter`, pointed at its own
//                  resolver via `dns.nameserver-policy`
//
// Only the route layer existed before, which is why hostname access to a peer
// network failed while raw-IP access worked: the address was excluded but the
// name still resolved to a fake 198.18.x.
//
// Design notes:
//
//  * The generic path must carry unknown VPNs. Detection falls back to "any utun
//    that is not ours" and harvests whatever the route table says it owns, so a
//    vendor absent from `knownVendors` still gets correct route exclusion. The
//    registry only adds knowledge a scan cannot produce — chiefly which *domains*
//    belong to the peer and which resolver answers for them.
//
//  * Only the route layer is applied automatically. mihomo accepts a runtime DNS
//    PATCH with 204 and then ignores it, and `GET /configs` reports an empty
//    `dns` object, so neither writing nor merging DNS is possible over the API.
//    The DNS half is therefore computed and reported (`CoexistencePlan.dnsAdvice`)
//    for the user to apply, rather than pushed silently through a config.yaml
//    rewrite + reload.
//
//  * Injected entries are tracked so they can be withdrawn. Merging blindly into
//    the user's config (the previous behaviour) meant a disconnected VPN left its
//    prefixes excluded forever, with nothing to distinguish app-injected entries
//    from hand-written ones. Provenance lives in UserDefaults keyed per config
//    field; see `mergePreservingUserEntries` / `commitProvenance` / `withdraw`.
//
//  * `fingerprint` exists so callers can skip a no-op PATCH. mihomo ACKs
//    `PATCH /configs` before deciding whether it can apply it, so a PATCH landing
//    on a settling kernel is silently dropped — re-pushing an unchanged plan on
//    every poll is both wasteful and a way to lose a real change in the noise.

/// A non-mihomo virtual network sharing the machine, and what mihomo must yield
/// to it.
struct CoexistencePeer: Equatable {
    /// Stable identifier (`tailscale`, `zerotier`, or `utun<N>` when generic).
    let id: String
    let displayName: String
    /// Interfaces this peer was detected on.
    var interfaces: [String] = []
    /// CIDRs that must bypass TUN auto-route.
    var routeExcludes: [String] = []
    /// CIDR → owning interface. The privileged helper installs real static routes
    /// and needs the exact interface per prefix, which a flat CIDR list cannot
    /// express once a peer spans more than one utun.
    var routeOwners: [String: String] = [:]
    /// Domain patterns that must not be fake-ip'd. Always `+.`-prefixed for
    /// suffix matching — see `suffixPattern`.
    var dnsDomains: [String] = []
    /// Resolver(s) authoritative for `dnsDomains`.
    var dnsResolvers: [String] = []
}

/// The concrete config deltas a set of peers requires.
struct CoexistencePlan: Equatable {
    var routeExcludes: [String] = []
    var fakeIPFilters: [String] = []
    /// domain pattern → resolver list
    var nameserverPolicy: [String: [String]] = [:]
    /// Display names of the peers this plan came from, for logs and the UI.
    var peerNames: [String] = []

    var isEmpty: Bool {
        routeExcludes.isEmpty && fakeIPFilters.isEmpty && nameserverPolicy.isEmpty
    }

    var peerSummary: String {
        peerNames.isEmpty ? "无" : peerNames.joined(separator: "、")
    }

    /// Human-readable description of the DNS changes this plan wants, for the log
    /// and the SD-WAN page.
    ///
    /// The DNS half is reported rather than applied. Three reasons, all verified
    /// against a live kernel rather than assumed:
    ///
    ///  * `PATCH /configs` answers 204 for a `dns` body and then ignores it —
    ///    resolution is unchanged afterwards. Runtime DNS injection is a no-op.
    ///  * `GET /configs` returns an empty `dns` object, so there is no way to read
    ///    the current filter list back; any "merge" would in fact be a blind
    ///    overwrite of the user's own entries.
    ///  * The only channel that works is rewriting config.yaml and reloading,
    ///    which restarts DNS and drops in-flight connections — too destructive to
    ///    trigger implicitly, and it would silently rewrite resolver choices the
    ///    user deliberately made.
    var dnsAdvice: [String] {
        guard !fakeIPFilters.isEmpty || !nameserverPolicy.isEmpty else { return [] }
        var lines: [String] = []
        if !fakeIPFilters.isEmpty {
            lines.append("dns.fake-ip-filter 建议包含：\(fakeIPFilters.joined(separator: "、"))")
        }
        for (domain, resolvers) in nameserverPolicy.sorted(by: { $0.key < $1.key }) {
            lines.append("dns.nameserver-policy[\(domain)] 建议指向：\(resolvers.joined(separator: "、"))")
        }
        return lines
    }
}

enum Coexistence {

    // MARK: Vendor registry

    /// Knowledge a scan cannot recover: domain suffixes and resolvers.
    /// Route prefixes are listed only where the vendor uses a fixed allocation
    /// that may not yet be in the route table when we look.
    struct Vendor {
        let id: String
        let displayName: String
        /// Daemon process names that prove this vendor is actually installed and
        /// running. Presence of a matching IP range alone is not proof — 100.64/10
        /// is carrier-grade NAT and a real ISP can hand it out.
        let processNames: [String]
        /// Interface IP predicate.
        let matchesIP: (String) -> Bool
        let routeExcludes: [String]
        let dnsDomains: [String]
        let dnsResolvers: [String]
    }

    static let knownVendors: [Vendor] = [
        Vendor(
            id: "tailscale",
            displayName: "Tailscale",
            processNames: ["tailscaled", "Tailscale"],
            matchesIP: isCGNAT,
            // 100.64/10 is the tailnet; 100.100.100.100 is MagicDNS.
            routeExcludes: ["100.64.0.0/10", "100.100.100.100/32"],
            // Tailscale names are `<host>.<tailnet>.ts.net` — two labels before
            // the suffix, so a single-label `*.ts.net` never matches them. This
            // is the whole reason hostname access broke while IP access worked.
            dnsDomains: ["+.ts.net"],
            dnsResolvers: ["100.100.100.100"]
        ),
        Vendor(
            id: "zerotier",
            displayName: "ZeroTier",
            processNames: ["zerotier-one", "ZeroTier"],
            matchesIP: { $0.hasPrefix("10.147.") },
            routeExcludes: ["10.147.0.0/16"],
            dnsDomains: [],
            dnsResolvers: []
        ),
        Vendor(
            id: "warp",
            displayName: "Cloudflare WARP",
            processNames: ["warp-svc", "CloudflareWARP"],
            matchesIP: { $0.hasPrefix("172.16.0.") },
            routeExcludes: [],
            dnsDomains: [],
            dnsResolvers: []
        ),
        Vendor(
            id: "wireguard",
            displayName: "WireGuard",
            processNames: ["wireguard-go", "wg-quick", "WireGuard"],
            // No fixed allocation — relies purely on the route-table harvest.
            matchesIP: { _ in false },
            routeExcludes: [],
            dnsDomains: [],
            dnsResolvers: []
        )
    ]

    /// 100.64.0.0/10 carrier-grade NAT.
    static func isCGNAT(_ ip: String) -> Bool {
        let p = ip.split(separator: ".")
        guard p.count == 4, p[0] == "100", let o2 = Int(p[1]) else { return false }
        return o2 >= 64 && o2 <= 127
    }

    // MARK: Detection

    /// Identify every non-mihomo tunnel currently on the machine.
    ///
    /// Evidence is layered so a vendor is only *named* when there is real proof
    /// it runs here, while an unnamed tunnel still gets full route treatment:
    ///   1. running daemon + matching interface IP  → named vendor, full plan
    ///   2. route-table footprint                   → generic peer, routes only
    static func detect() async -> [CoexistencePeer] {
        let ifaces = NetScanner.interfaces()
        // Everything tunnel-shaped that is not mihomo's own TUN.
        let foreign = ifaces.filter { $0.id.hasPrefix("utun") && $0.kind != .proxyTun }
        guard !foreign.isEmpty else { return [] }

        let running = await runningProcessNames()
        let ownedRoutes = await routesByInterface(Set(foreign.map { $0.id }))

        var peers: [String: CoexistencePeer] = [:]

        for iface in foreign {
            // macOS runs a fleet of its own utuns — iCloud Private Relay, Wi-Fi
            // Calling, Handoff — that carry no IPv4 address and no IPv4 route
            // (only a link-local fe80:: and a scoped IPv6 default). They can never
            // contribute an exclusion, and they are created and destroyed
            // constantly, so admitting them only fills the peer list and the log
            // with phantom "虚拟接口 utunN" entries. Nothing here is IPv6-aware
            // yet; when it becomes so, this gate is what has to widen.
            let ownsRoutes = !(ownedRoutes[iface.id] ?? []).isEmpty
            guard !iface.ipv4.isEmpty || ownsRoutes else { continue }

            // Which known vendor, if any, owns this interface?
            let vendor = knownVendors.first { v in
                v.processNames.contains(where: running.contains)
                    && iface.ipv4.contains(where: v.matchesIP)
            }

            let key = vendor?.id ?? iface.id
            var peer = peers[key] ?? CoexistencePeer(
                id: key,
                displayName: vendor?.displayName ?? "虚拟接口 \(iface.id)"
            )
            peer.interfaces.append(iface.id)

            // The interface's own addresses always bypass TUN.
            for ip in iface.ipv4 {
                peer.routeExcludes.append("\(ip)/32")
                peer.routeOwners["\(ip)/32"] = iface.id
            }
            // Whatever the route table says this interface carries.
            for cidr in ownedRoutes[iface.id] ?? [] {
                peer.routeExcludes.append(cidr)
                peer.routeOwners[cidr] = iface.id
            }

            if let v = vendor {
                for cidr in v.routeExcludes {
                    peer.routeExcludes.append(cidr)
                    // A fixed vendor allocation belongs to the interface we just
                    // matched the vendor on.
                    peer.routeOwners[cidr] = iface.id
                }
                peer.dnsDomains.append(contentsOf: v.dnsDomains)
                // Bind each resolver to the peer's own interface. TUN enable pins
                // mihomo's egress to the physical NIC via `interface-name`, so an
                // unqualified `100.100.100.100` is dialled from en0 and times out
                // ("i/o timeout" against the peer's resolver) even though the
                // address is reachable over the peer's utun. mihomo's
                // `<server>#<interface>` form dials it on the right link.
                peer.dnsResolvers.append(contentsOf: v.dnsResolvers.map { "\($0)#\(iface.id)" })
            }
            peers[key] = peer
        }

        return peers.values
            .map { p in
                var p = p
                p.routeExcludes = Array(Set(p.routeExcludes)).sorted()
                p.dnsDomains = Array(Set(p.dnsDomains)).sorted()
                p.dnsResolvers = Array(Set(p.dnsResolvers)).sorted()
                return p
            }
            .sorted { $0.id < $1.id }
    }

    /// Route-table destinations owned by each of `ifaceNames`, normalized to CIDR.
    /// `default` is skipped: a peer claiming the default route is a conflict to
    /// report, never something to hand it by excluding 0.0.0.0/0 from TUN.
    private static func routesByInterface(_ ifaceNames: Set<String>) async -> [String: [String]] {
        var out: [String: [String]] = [:]
        for route in await NetScanner.allRoutes() where ifaceNames.contains(route.iface) {
            guard route.dest != "default", !route.dest.contains("0.0.0.0/0") else { continue }
            guard let cidr = NetScanner.normalizedCIDR(route.dest) else { continue }
            out[route.iface, default: []].append(cidr)
        }
        return out
    }

    /// Names of currently running processes, for vendor proof-of-presence.
    private static func runningProcessNames() async -> Set<String> {
        await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-axco", "command"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            do { try p.run() } catch { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let out = String(data: data, encoding: .utf8) else { return [] }
            return Set(out.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            })
        }.value
    }

    // MARK: Planning

    /// Fold detected peers into the config deltas to apply. Pure — unit-testable
    /// without touching the network.
    static func plan(_ peers: [CoexistencePeer]) -> CoexistencePlan {
        var plan = CoexistencePlan()
        var policy: [String: Set<String>] = [:]

        for peer in peers {
            plan.routeExcludes.append(contentsOf: peer.routeExcludes)
            plan.fakeIPFilters.append(contentsOf: peer.dnsDomains)
            guard !peer.dnsResolvers.isEmpty else { continue }
            for domain in peer.dnsDomains {
                policy[domain, default: []].formUnion(peer.dnsResolvers)
            }
        }

        plan.routeExcludes = Array(Set(plan.routeExcludes)).sorted()
        plan.fakeIPFilters = Array(Set(plan.fakeIPFilters)).sorted()
        plan.nameserverPolicy = policy.mapValues { $0.sorted() }
        plan.peerNames = peers.map(\.displayName).sorted()
        return plan
    }

    /// Flatten detected peers into the `CIDR → interface` map the privileged
    /// helper needs for real static routes. Same detection pass as the config
    /// planner, so the routes installed on the system and the prefixes excluded
    /// inside mihomo can never describe different topologies.
    static func excludeRouteMap(_ peers: [CoexistencePeer]) -> [String: String] {
        peers.reduce(into: [String: String]()) { acc, peer in
            acc.merge(peer.routeOwners) { current, _ in current }
        }
    }

    // MARK: DNS resolver interface pinning

    /// A resolver whose `#interface` suffix in config.yaml no longer names the
    /// interface its peer is actually on.
    ///
    /// This is the one piece of coexistence that cannot be expressed as a runtime
    /// PATCH (mihomo ignores those for `dns`), so it lives in the user's file as a
    /// hand-written `100.100.100.100#utun0` — and BSD hands out utun indices in
    /// creation order, so the moment the tunnels around it churn the pin names an
    /// interface the resolver isn't on and every lookup for that peer times out.
    /// Detected here, repaired only on an explicit user action: the repair rewrites
    /// config.yaml and reloads, which drops in-flight connections.
    struct ResolverDrift: Equatable, Identifiable {
        /// Resolver address, e.g. `100.100.100.100`.
        let resolver: String
        /// Interface written in config.yaml.
        let from: String
        /// Interface the peer is on right now.
        let to: String
        var id: String { resolver }
    }

    /// resolver address → interface it must be dialled on, read back out of the
    /// plan so file repair and runtime planning can never disagree.
    static func resolverInterfaces(_ plan: CoexistencePlan) -> [String: String] {
        var out: [String: String] = [:]
        for entry in plan.nameserverPolicy.values.flatMap({ $0 }) {
            let parts = entry.split(separator: "#", maxSplits: 1)
            guard parts.count == 2 else { continue }
            out[String(parts[0])] = String(parts[1])
        }
        return out
    }

    /// Bindings present on disk that point at the wrong interface. Resolvers with
    /// no detected peer are left alone — an absent peer means "cannot tell", not
    /// "wrong", and rewriting a pin for a VPN that is merely disconnected would
    /// destroy the correct value.
    static func resolverDrift(configured: [(resolver: String, iface: String)],
                              desired: [String: String]) -> [ResolverDrift] {
        var seen = Set<String>()
        return configured.compactMap { binding in
            guard let want = desired[binding.resolver], want != binding.iface,
                  seen.insert(binding.resolver).inserted else { return nil }
            return ResolverDrift(resolver: binding.resolver, from: binding.iface, to: want)
        }
    }

    /// Stable digest of a plan. Callers compare against the last applied value to
    /// decide whether a PATCH is warranted at all.
    static func fingerprint(_ plan: CoexistencePlan) -> String {
        let policy = plan.nameserverPolicy
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.joined(separator: ","))" }
            .joined(separator: ";")
        return [
            plan.routeExcludes.joined(separator: ","),
            plan.fakeIPFilters.joined(separator: ","),
            policy
        ].joined(separator: "|")
    }

    // MARK: Provenance-tracked merge

    private static let provenanceKeyPrefix = "coexistence.injected."

    /// Merge `desired` into `existing` for `field`, dropping entries this app
    /// injected on a previous pass that are no longer wanted, while never
    /// touching entries the user wrote themselves.
    ///
    /// Without the withdrawal half, a VPN that disconnects leaves its prefixes
    /// excluded from TUN forever — traffic silently keeps bypassing the proxy for
    /// a network that is gone, and the config accretes junk no one can attribute.
    ///
    /// Pure with respect to the provenance record: computing a merge must not
    /// claim the entries were applied. Call `commitProvenance` once the kernel
    /// has actually accepted them.
    static func mergePreservingUserEntries(field: String,
                                           desired: [String],
                                           in existing: [String]) -> [String] {
        let previouslyInjected = Set(injectedRecord(field))
        // Anything present that we did not inject last time is the user's.
        let userOwned = existing.filter { !previouslyInjected.contains($0) }
        return Array(Set(userOwned + desired)).sorted()
    }

    /// What we recorded as injected for `field` on the last accepted change.
    static func injectedRecord(_ field: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: provenanceKeyPrefix + field) ?? []
    }

    /// Record what the kernel accepted, so the next pass can withdraw whatever
    /// is no longer wanted. Call only after a confirmed apply.
    static func commitProvenance(field: String, injected: [String]) {
        UserDefaults.standard.set(injected.sorted(), forKey: provenanceKeyPrefix + field)
    }

    /// Entries to strip when coexistence is torn down (TUN off): whatever we
    /// injected last, minus anything the user has since written by hand.
    ///
    /// Note this *computes* the withdrawal — it does not forget the record.
    /// Clearing provenance without removing the entries would silently promote
    /// them to user-owned, and they would then survive every later withdrawal
    /// pass: exactly the accretion this mechanism exists to prevent.
    static func withdraw(field: String, from existing: [String]) -> [String] {
        let injected = Set(injectedRecord(field))
        return existing.filter { !injected.contains($0) }.sorted()
    }
}
