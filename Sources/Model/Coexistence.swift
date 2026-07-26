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
//  * Harvesting is filtered, because every prefix credited to a peer becomes a
//    real unscoped static route on the system. A peer's *interface-scoped* routes
//    carry nothing globally and must be left as they are; link-only ranges
//    (multicast, broadcast, link-local) and subnets the machine is physically
//    attached to must never point at a tunnel at all. See `routesByInterface`
//    and `PeerRouteGuard`.
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
        // Subnets the machine is physically attached to. A peer may not claim
        // these, whatever its route table says — see `routesByInterface`.
        // Read through the same shared helper the privileged side enforces with:
        // this list decides what gets *asked* for and that one decides what gets
        // *installed*, and the two disagreeing is how a prefix slips through.
        let localSubnets = PeerRouteGuard.localAttachedSubnets()
        let ownedRoutes = await routesByInterface(Set(foreign.map { $0.id }),
                                                  localSubnets: localSubnets)

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

            // The two outputs are not interchangeable and must not share a filter.
            //
            //  * `routeExcludes` feeds mihomo's `tun.route-exclude-address`, i.e.
            //    "do not pull this into the proxy TUN". Multicast, broadcast and
            //    the local LAN are exactly the prefixes that belong there — the
            //    user's own config.yaml lists them for that reason.
            //  * `routeOwners` becomes a real `route add -interface utunN`, i.e.
            //    "send this into the peer's tunnel". Those same prefixes must
            //    never appear here.
            //
            // Filtering both (the first shape of this fix) withdrew the user's
            // hand-written `224.0.0.0/4` exclusion and let mihomo's own auto-route
            // swallow multicast instead — the identical fault one tunnel to the
            // left. Guard the routing half only.
            func claim(_ cidr: String) {
                peer.routeExcludes.append(cidr)
                guard !PeerRouteGuard.isForbidden(cidr, localSubnets: localSubnets) else { return }
                peer.routeOwners[cidr] = iface.id
            }

            // The interface's own addresses always bypass TUN.
            for ip in iface.ipv4 { claim("\(ip)/32") }
            // Whatever the route table says this interface carries.
            for cidr in ownedRoutes[iface.id] ?? [] { claim(cidr) }

            if let v = vendor {
                // A fixed vendor allocation belongs to the interface we just
                // matched the vendor on.
                for cidr in v.routeExcludes { claim(cidr) }
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
    ///
    /// Four classes are refused, because every entry surviving this filter is
    /// eventually installed by the privileged helper as a **real, unscoped static
    /// route** pointing at the peer's interface:
    ///
    ///  * **`default`** — a peer claiming the default route is a conflict to
    ///    report, never something to hand it by excluding 0.0.0.0/0 from TUN.
    ///  * **Interface-scoped routes** (`RTF_IFSCOPE`, the `I` flag). These apply
    ///    only to traffic already bound to that interface, so they carry nothing
    ///    globally and cost nothing to leave alone. Re-installing one *unscoped*
    ///    — which is what the helper does — converts a deliberate no-op into a
    ///    real hijack. This is exactly how `10.1.1.0/24` (the machine's own LAN,
    ///    published by Tailscale as a scoped `UCSI` route) became an unscoped
    ///    `USc` route into utun8: LAN hosts, LAN broadcast and every gateway-mode
    ///    client reply left via the tunnel instead of the Ethernet. The same rule
    ///    already governs `NetScanner.isNonShadowing` and
    ///    `foreignDefaultRouteHolder`; it belongs here too.
    ///  * **Link-only prefixes and directly-attached subnets** — both refused by
    ///    `PeerRouteGuard.isForbidden`, the rule the privileged helper enforces
    ///    again at install time.
    private static func routesByInterface(_ ifaceNames: Set<String>,
                                          localSubnets: [String]) async -> [String: [String]] {
        var out: [String: [String]] = [:]
        for route in await NetScanner.allRoutes() where ifaceNames.contains(route.iface) {
            guard route.dest != "default", !route.dest.contains("0.0.0.0/0") else { continue }
            guard !route.flags.contains("I") else { continue }
            guard let cidr = NetScanner.normalizedCIDR(route.dest) else { continue }
            guard !PeerRouteGuard.isForbidden(cidr, localSubnets: localSubnets) else { continue }
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

    // MARK: Route-table drift

    /// One prefix whose actual carrier disagrees with the coexistence plan.
    ///
    /// This class of fault is invisible to `fingerprint(plan)`, which is why
    /// auditing the table itself is necessary rather than merely thorough.
    /// mihomo re-runs `auto-route` every time its TUN is rebuilt — a kernel
    /// restart, a config reload, a default-interface change — and the
    /// split-default it installs swallows peer prefixes again. The set of peers
    /// is unchanged throughout, so the fingerprint is unchanged, so
    /// `reconcileCoexistenceIfChanged` correctly concludes there is nothing to
    /// do. The hijack then persists until something unrelated happens to move
    /// the topology. Reading the route table is the only thing that sees it.
    /// Display wrapper over `RouteTable.Drift`. The comparison itself lives in
    /// `HelperProtocol.swift` beside the guard the Helper enforces with, so the
    /// asking side and the installing side cannot drift apart; only the Chinese
    /// rendering belongs up here.
    struct RouteDrift: Equatable, Identifiable {
        let inner: RouteTable.Drift
        var id: String { inner.cidr }
        var cidr: String { inner.cidr }
        var expected: String { inner.expected }

        var describe: String {
            switch inner.kind {
            case .hijackedByOurTun:
                return "\(inner.cidr) 被本机 TUN（\(inner.actual ?? "?")）抢占，应由 \(inner.expected) 承载"
            case .missing:
                return "\(inner.cidr) 无任何路由承载，应由 \(inner.expected) 承载"
            }
        }
    }

    /// Compare the plan's route ownership against the live table.
    ///
    /// Privilege-free — one `netstat -rn` fork, the same read the Helper makes
    /// before it changes anything — so this is cheap enough to run on a timer
    /// without opening an XPC connection to find out there was nothing to do.
    static func auditRoutes(expected: [String: String]) -> [RouteDrift] {
        RouteTable.drift(expected: expected, in: RouteTable.current())
            .map(RouteDrift.init)
    }

    // MARK: Advertised-but-absent peer subnets

    /// A subnet a peer tunnel says it carries, paired with what the local route
    /// table actually does about it.
    ///
    /// Route-table harvesting alone cannot see this class of fault. A subnet
    /// route that is missing contributes nothing to scan, so a peer network that
    /// has silently become unreachable looks identical to a peer that never
    /// advertised anything — the SD-WAN page reported "拓扑正常" while
    /// `ping 10.1.1.1` was going out the physical NIC. Asking the vendor what it
    /// *believes* it carries turns that silence into a finding.
    struct PeerSubnetGap: Equatable, Identifiable {
        /// Advertised prefix, e.g. `10.1.1.0/24`.
        let cidr: String
        /// Peer advertising it, e.g. `GL-MT3000`.
        let peer: String
        /// Interface the local table sends this prefix to, nil when there is no
        /// matching route at all.
        let routedVia: String?
        /// Interface the vendor's own tunnel is on.
        let expected: String
        var id: String { cidr }
        var isMissing: Bool { routedVia == nil }
    }

    /// Subnets the tailnet advertises whose local route is missing or points
    /// somewhere other than Tailscale's own interface.
    ///
    /// Diagnostic only — deliberately not fed into `routeExcludes`, and never
    /// auto-installed. Excluding a prefix from mihomo's TUN that Tailscale is
    /// *not* actually carrying would send it out the physical NIC instead of the
    /// proxy, which is a second wrong answer; and installing the route ourselves
    /// would duplicate management of something tailscaled owns. Reporting is the
    /// honest action: the fix belongs to whoever owns the tunnel.
    static func tailscaleSubnetGaps(interfaces: [NetIface],
                                    routes: [RouteEntry]) async -> [PeerSubnetGap] {
        guard let tsIface = interfaces.first(where: { $0.kind == .tailscale })?.id,
              let advertised = await tailscaleAdvertisedRoutes(), !advertised.isEmpty
        else { return [] }

        return advertised.compactMap { (cidr, peer) -> PeerSubnetGap? in
            let carrier = routes.first { r in
                NetScanner.normalizedCIDR(r.dest) == cidr && r.iface == tsIface
            }
            guard carrier == nil else { return nil }
            // No Tailscale-borne route for it — record where it does go, if
            // anywhere specific.
            let other = routes.first { NetScanner.normalizedCIDR($0.dest) == cidr }
            return PeerSubnetGap(cidr: cidr, peer: peer,
                                 routedVia: other?.iface, expected: tsIface)
        }
        .sorted { $0.cidr < $1.cidr }
    }

    /// `(prefix, peer hostname)` for every subnet route the tailnet says is
    /// reachable, read from `tailscale status --json`.
    ///
    /// Returns nil — distinct from empty — when the CLI is absent or unusable,
    /// so callers can tell "Tailscale advertises nothing" from "cannot ask".
    /// The pkg/App Store builds ship the binary inside the app bundle, Homebrew
    /// puts it on PATH; a Tailscale that is installed but not running answers
    /// with an error, which lands in the same nil.
    static func tailscaleAdvertisedRoutes() async -> [(cidr: String, peer: String)]? {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale"
        ]
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }

        let out: Data? = await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["status", "--json"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? d : nil
        }.value

        guard let out,
              let root = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
              let peers = root["Peer"] as? [String: Any] else { return nil }

        var result: [(String, String)] = []
        for value in peers.values {
            guard let peer = value as? [String: Any],
                  // PrimaryRoutes = subnet routes this peer is the elected
                  // carrier for. Non-primary advertisements are not routable
                  // here and would be false alarms.
                  let primary = peer["PrimaryRoutes"] as? [String] else { continue }
            let name = (peer["HostName"] as? String) ?? "未知节点"
            for cidr in primary where !cidr.contains(":") {   // IPv4 only for now
                result.append((cidr, name))
            }
        }
        return result
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
        // Anything present that we did not inject last time is the user's — and
        // a protective exclusion is never ours to drop whatever the record says.
        let userOwned = existing.filter {
            !previouslyInjected.contains($0) || isProtectiveExclusion($0)
        }
        return Array(Set(userOwned + desired)).sorted()
    }

    /// A `route-exclude-address` entry that must survive every withdrawal pass.
    ///
    /// Provenance is only as trustworthy as the version that wrote it. A build
    /// that wrongly claimed `224.0.0.0/4` — as the pre-guard coexistence code did
    /// — leaves a record asserting the user's own multicast exclusion belongs to
    /// this app, and the next withdrawal then deletes it. Observed exactly that:
    /// the entry vanished from the running config and mihomo's auto-route
    /// promptly swallowed multicast into its own TUN.
    ///
    /// The asymmetry justifies the special case. Keeping a protective exclusion
    /// that is no longer needed costs nothing — it only tells mihomo to leave
    /// alone a range it should never have taken. Dropping one breaks the local
    /// segment. When the record and the rule disagree about these, the rule wins.
    static func isProtectiveExclusion(_ cidr: String) -> Bool {
        PeerRouteGuard.linkOnlyPrefixes.contains { RouteTable.overlaps(cidr, $0) }
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
        return existing
            .filter { !injected.contains($0) || isProtectiveExclusion($0) }
            .sorted()
    }
}
