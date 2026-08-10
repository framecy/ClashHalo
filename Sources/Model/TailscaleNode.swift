import Foundation

// Tailscale as a mihomo outbound (`type: tailscale`, tsnet/gVisor userspace).
//
// This file is the *pure* half of the feature: everything that can be decided
// without touching the filesystem, the kernel, the network, or the UI. It is
// compiled into `Scripts/run-tests.sh` as production source, so nothing here
// may reach for Foundation's process/network APIs or MainActor state.
//
// Why an overlay at all: `config.yaml` is regenerated from the active
// subscription profile on every switch/update, and `PATCH /configs` cannot add
// proxies or rules. So the node has to be re-injected into the produced YAML on
// every commit, idempotently, and be removable without a trace.
//
// Verified kernel behaviour this file encodes (mihomo v1.19.29, see
// Docs/TailscaleIntegration.md):
//   * duplicate top-level keys are a hard YAML error, so the overlay must merge
//     into the existing `proxies:` / `rules:` sequences, not append its own.
//   * `state-dir` is resolved against the mihomo home dir and then checked by
//     `IsSafePath`, so only a *relative* value is safe here.
//   * `ts://<name>` in `nameserver-policy` is resolved at runtime by name and
//     is NOT validated at config-parse time — a typo fails silently at query
//     time, which is why the name is rendered from one place, never typed twice.

// MARK: - Settings

/// User intent for the built-in tailnet node. Persisted by `AppModel` in
/// `UserDefaults` (except `authKey`, which lives in the Keychain and is only
/// merged in at render time).
struct TailscaleSettings: Equatable {
    /// Proxy name in `proxies:`, rule target, and `ts://` target — one source.
    var nodeName: String = TailscaleSettings.defaultNodeName
    /// Node name shown in the tailnet admin console.
    var hostname: String = "clashhalo-mac"
    /// Empty = official control plane. Set for Headscale.
    var controlURL: String = ""
    /// Empty = no exit node. `auto:any` or a peer IP / DNS name.
    var exitNode: String = ""
    /// Accept subnet routes advertised in the tailnet.
    var acceptRoutes: Bool = true
    /// mihomo defaults this to false; tailnet UDP is dead without it.
    var udp: Bool = true
    /// Generate the MagicDNS suffix + CGNAT rules (Surge's
    /// `auto-add-magic-dns-rule` equivalent).
    var autoRules: Bool = true
    /// MagicDNS suffix discovered from the tailnet, e.g. `tail1234.ts.net`.
    /// Empty falls back to the generic `ts.net` suffix, which is correct for
    /// every tailnet and only slightly broader.
    var magicDNSSuffix: String = ""
    /// Emit the broad `100.64.0.0/10` rule. Off when the user wants only the
    /// precise peer /32 and hand-written subnet rules (Headscale with a
    /// non-CGNAT allocation, or a tailnet that must not swallow carrier NAT).
    var includeCGNATRule: Bool = true
    /// Online peer IPv4 addresses from the device panel. Rendered as `/32`
    /// rules when `autoRules` is on. Capped at render time.
    var peerIPs: [String] = []
    /// Hand-written subnet routes (CIDR) the user wants through this node —
    /// the L2 half of Surge's model: advertised routes still need an explicit
    /// rule even with `accept-routes: true`.
    var extraCIDRs: [String] = []
    /// mihomo `exit-node-allow-lan-access`. Default on so Gateway-mode LAN
    /// clients keep reaching the LAN when an exit node is selected.
    var exitNodeAllowLANAccess: Bool = true
    /// Auth key, injected at render time only. Never persisted in this struct.
    var authKey: String = ""

    static let defaultNodeName = "Tailnet"
    /// Hard cap on auto-generated peer /32 rules. A large tailnet must not
    /// blow up the rule table on every device refresh.
    static let maxPeerRules = 64

    /// tsnet state directory. Relative on purpose: mihomo resolves it against
    /// its home dir (`mihomo -d <appSupport>`) and rejects anything outside it
    /// (`path is not subpath of home directory or SAFE_PATHS`). Writing an
    /// absolute path buys nothing and breaks the moment `-d` changes.
    static let stateDir = "tailscale"
}

// MARK: - Name validation

enum TailscaleName {

    /// A node name is a rule target and a `ts://` authority at the same time.
    /// A comma would split the rule line; quotes and `#` would break the scalar.
    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 40 else { return false }
        if name.trimmingCharacters(in: .whitespaces) != name { return false }
        let banned = CharacterSet(charactersIn: ",\"'#:/\\\n\t")
        return name.rangeOfCharacter(from: banned) == nil
    }

    /// Best-effort repair for a user-supplied name; falls back to the default.
    static func sanitize(_ raw: String) -> String {
        let banned = CharacterSet(charactersIn: ",\"'#:/\\\n\t")
        var cleaned = raw.components(separatedBy: banned)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        // A name made entirely of separators survives the character filter but
        // is not a name; collapse and trim the filler before judging it.
        while cleaned.contains("--") {
            cleaned = cleaned.replacingOccurrences(of: "--", with: "-")
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        guard isValid(cleaned) else { return TailscaleSettings.defaultNodeName }
        return cleaned
    }

    /// mihomo normalizes the hostname to lowercase; DNS labels only.
    static func sanitizeHostname(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let lowered = raw.lowercased()
        var out = ""
        for ch in lowered.unicodeScalars {
            out.append(allowed.contains(ch) ? Character(ch) : "-")
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "clashhalo-mac" : String(out.prefix(63))
    }
}

// MARK: - Overlay

enum TailscaleOverlay {

    static let fenceBegin = "# >>> clashhalo:tailscale >>>"
    static let fenceEnd = "# <<< clashhalo:tailscale <<<"

    struct Result: Equatable {
        var yaml: String
        /// Non-fatal findings the caller should surface (log/toast), e.g. a
        /// `fake-ip-filter` entry that would keep MagicDNS names off fake-ip.
        var warnings: [String] = []
        /// False when the profile shape defeated injection; `yaml` is then the
        /// input unchanged. Never half-write.
        var injected: Bool = false
        /// True when the DNS half could not be applied (no usable `dns:` block).
        var dnsSkipped: Bool = false
    }

    // MARK: Strip

    /// Remove every fenced region. Runs before each injection so the operation
    /// is idempotent, and on disable so nothing of ours survives.
    static func strip(_ yaml: String) -> String {
        var out: [String] = []
        var inside = false
        var removedAnything = false
        for line in yaml.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == fenceBegin { inside = true; removedAnything = true; continue }
            if t == fenceEnd { inside = false; continue }
            if inside { continue }
            out.append(line)
        }
        guard removedAnything else { return yaml }
        return out.joined(separator: "\n")
    }

    // MARK: Apply

    /// Inject the node, its rules, and the MagicDNS resolver policy.
    ///
    /// Always strips first, so calling this repeatedly with the same settings is
    /// a no-op and calling it with new settings never stacks.
    static func apply(to yaml: String, settings: TailscaleSettings) -> Result {
        var lines = strip(yaml).components(separatedBy: "\n")
        var warnings: [String] = []

        guard TailscaleName.isValid(settings.nodeName) else {
            return Result(yaml: yaml,
                          warnings: ["节点名 \"\(settings.nodeName)\" 含非法字符，未注入"],
                          injected: false)
        }

        // 1. proxies
        guard let afterProxies = insertIntoSequence(
            &lines, key: "proxies", entries: [proxyEntry(settings)]
        ) else {
            return Result(yaml: yaml,
                          warnings: ["配置中的 proxies 段落无法安全解析，未注入"],
                          injected: false)
        }
        _ = afterProxies

        // 2. rules — tailnet destinations must win over GEOIP/MATCH, so they go
        //    at the head of the list, not the tail.
        if settings.autoRules {
            let built = autoRules(settings)
            if !built.rules.isEmpty {
                guard insertIntoSequence(&lines, key: "rules", entries: built.rules) != nil else {
                    return Result(yaml: yaml,
                                  warnings: ["配置中的 rules 段落无法安全解析，未注入"],
                                  injected: false)
                }
            }
            warnings.append(contentsOf: built.warnings)
        }

        // 3. dns.nameserver-policy → MagicDNS through this very node.
        let dnsOK = insertNameserverPolicy(&lines, settings: settings)

        warnings.append(contentsOf: conflictWarnings(in: lines, settings: settings))

        return Result(yaml: lines.joined(separator: "\n"),
                      warnings: warnings,
                      injected: true,
                      dnsSkipped: !dnsOK)
    }

    // MARK: Rendering

    /// Rendered as a *flow mapping on one line* on purpose. Subscription YAML
    /// writes sequence items at column 0 as often as at column 2, and a block
    /// mapping would have to match the surrounding item's inner indentation
    /// exactly or produce invalid YAML. One line only has to match the dash
    /// column, which `insertIntoSequence` measures.
    static func proxyEntry(_ s: TailscaleSettings) -> String {
        var kv: [String] = []
        kv.append("name: \(quoted(s.nodeName))")
        kv.append("type: tailscale")
        let host = TailscaleName.sanitizeHostname(s.hostname)
        kv.append("hostname: \(quoted(host))")
        kv.append("state-dir: \(quoted(TailscaleSettings.stateDir))")
        if !s.authKey.isEmpty { kv.append("auth-key: \(quoted(s.authKey))") }
        if !s.controlURL.isEmpty { kv.append("control-url: \(quoted(s.controlURL))") }
        kv.append("udp: \(s.udp)")
        kv.append("accept-routes: \(s.acceptRoutes)")
        if !s.exitNode.isEmpty {
            kv.append("exit-node: \(quoted(s.exitNode))")
            // Only meaningful with an exit node; omit otherwise so the kernel
            // does not carry a dead preference.
            kv.append("exit-node-allow-lan-access: \(s.exitNodeAllowLANAccess)")
        }
        return "{" + kv.joined(separator: ", ") + "}"
    }

    struct AutoRulesResult: Equatable {
        var rules: [String]
        var warnings: [String] = []
    }

    /// Surge's `auto-add-magic-dns-rule` equivalent, plus optional peer /32 and
    /// hand-written subnet CIDRs.
    ///
    /// `no-resolve` is mandatory on every IP rule — without it every unmatched
    /// domain would be resolved just to test the rule.
    static func autoRules(_ s: TailscaleSettings) -> AutoRulesResult {
        autoRules(nodeName: s.nodeName,
                  magicDNSSuffix: s.magicDNSSuffix,
                  includeCGNAT: s.includeCGNATRule,
                  peerIPs: s.peerIPs,
                  extraCIDRs: s.extraCIDRs)
    }

    static func autoRules(nodeName: String,
                          magicDNSSuffix: String,
                          includeCGNAT: Bool = true,
                          peerIPs: [String] = [],
                          extraCIDRs: [String] = []) -> AutoRulesResult {
        var rules: [String] = []
        var warnings: [String] = []
        let suffix = magicDNSSuffix.isEmpty
            ? "ts.net"
            : magicDNSSuffix.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        rules.append("DOMAIN-SUFFIX,\(suffix),\(nodeName)")

        if includeCGNAT {
            rules.append("IP-CIDR,100.64.0.0/10,\(nodeName),no-resolve")
        }

        // Peer /32 first (more specific), then hand-written subnets. Dedup
        // against each other and against the CGNAT aggregate when present.
        var seen = Set<String>()
        if includeCGNAT { seen.insert("100.64.0.0/10") }

        let peers = normalizePeerIPs(peerIPs)
        if peers.count > TailscaleSettings.maxPeerRules {
            warnings.append("peer 地址 \(peers.count) 个，只注入前 \(TailscaleSettings.maxPeerRules) 条 /32 规则")
        }
        for ip in peers.prefix(TailscaleSettings.maxPeerRules) {
            let cidr = "\(ip)/32"
            guard seen.insert(cidr).inserted else { continue }
            rules.append("IP-CIDR,\(cidr),\(nodeName),no-resolve")
        }

        let extras = normalizeCIDRs(extraCIDRs)
        for cidr in extras {
            guard seen.insert(cidr).inserted else { continue }
            // Refuse to install a default route as a "subnet" rule — that is
            // exit-node territory and would black-hole everything without one.
            if cidr == "0.0.0.0/0" || cidr == "::/0" {
                warnings.append("已忽略默认路由 \(cidr)（请用出口节点，而不是子网规则）")
                continue
            }
            rules.append("IP-CIDR,\(cidr),\(nodeName),no-resolve")
        }

        return AutoRulesResult(rules: rules, warnings: warnings)
    }

    /// Keep only dotted IPv4 addresses. No hostnames — those belong in DNS.
    static func normalizePeerIPs(_ raw: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for r in raw {
            let ip = r.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isIPv4(ip), seen.insert(ip).inserted else { continue }
            out.append(ip)
        }
        return out
    }

    /// Accept `a.b.c.d` or `a.b.c.d/n`. Returns canonical CIDR strings.
    static func normalizeCIDRs(_ raw: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for r in raw {
            let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let cidr: String
            if let slash = t.firstIndex(of: "/") {
                let ip = String(t[..<slash])
                let pref = String(t[t.index(after: slash)...])
                guard isIPv4(ip), let n = Int(pref), (0...32).contains(n) else { continue }
                cidr = "\(ip)/\(n)"
            } else if isIPv4(t) {
                cidr = "\(t)/32"
            } else {
                continue
            }
            if seen.insert(cidr).inserted { out.append(cidr) }
        }
        return out
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            // Reject empty labels and non-decimal noise; allow mild leading zeros
            // so a pasted `01.02.03.04` still works.
            guard !p.isEmpty, p.allSatisfy(\Character.isNumber),
                  let n = Int(p), (0...255).contains(n) else { return false }
            return true
        }
    }

    /// Control URL for Headscale / custom coordination. Empty = official.
    /// Rejects non-http(s) schemes and bare hosts without a scheme so a typo
    /// does not become a mysterious tsnet dial failure.
    static func normalizeControlURL(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else { return nil }
        return t
    }

    static func nameserverPolicyEntry(nodeName: String, magicDNSSuffix: String) -> String {
        let suffix = magicDNSSuffix.isEmpty
            ? "ts.net"
            : magicDNSSuffix.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return "\"+.\(suffix)\": \"ts://\(nodeName)\""
    }

    private static func quoted(_ v: String) -> String {
        "\"" + v.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Sequence insertion

    /// Insert `entries` at the head of the top-level block sequence under `key`,
    /// creating the key when absent. Returns the index just past the inserted
    /// block, or nil when the existing shape is something we refuse to touch.
    @discardableResult
    private static func insertIntoSequence(_ lines: inout [String],
                                           key: String,
                                           entries: [String]) -> Int? {
        let keyIdx = lines.firstIndex { topLevelKey($0) == key }

        guard let idx = keyIdx else {
            // No such key: append the key *inside* the fence, so removal takes
            // the container with it and leaves the document byte-identical.
            var block = [fenceBegin, "\(key):"]
            block.append(contentsOf: entries.map { "  - " + $0 })
            block.append(fenceEnd)
            lines.append(contentsOf: block)
            return lines.count
        }

        // `proxies: []` / `rules: []` — an explicit empty flow sequence. Rewrite
        // the key to block form; anything else after the colon we do not touch.
        // Removal later leaves a bare `key:` (null), which parses identically —
        // the alternative is reconstructing a form the user may not have wanted.
        let after = valueAfterColon(lines[idx])
        if !after.isEmpty {
            guard after == "[]" else { return nil }
            lines[idx] = "\(key):"
        }

        let indent = sequenceIndent(lines, after: idx)
        var block = [indent + fenceBegin]
        block.append(contentsOf: entries.map { indent + "- " + $0 })
        block.append(indent + fenceEnd)
        lines.insert(contentsOf: block, at: idx + 1)
        return idx + 1 + block.count
    }

    /// Indentation of the existing sequence under a key. Subscription YAML uses
    /// column 0 dashes at least as often as column 2, and YAML requires every
    /// item of one sequence to share a column — guessing wrong is a parse error.
    private static func sequenceIndent(_ lines: [String], after idx: Int) -> String {
        var i = idx + 1
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { i += 1; continue }
            if t.hasPrefix("- ") || t == "-" {
                return String(line.prefix(while: { $0 == " " }))
            }
            break   // next top-level key: the sequence is empty
        }
        return "  "
    }

    // MARK: DNS

    /// Point `+.<suffix>` at this node's MagicDNS resolver.
    ///
    /// Deliberately conservative: when there is no `dns:` block, or DNS is off,
    /// we do nothing and report it. Synthesizing a whole DNS block for a
    /// profile that never had one changes resolution for *all* traffic — that
    /// is not a side effect this feature is allowed to have.
    private static func insertNameserverPolicy(_ lines: inout [String],
                                               settings: TailscaleSettings) -> Bool {
        guard let dnsIdx = lines.firstIndex(where: { topLevelKey($0) == "dns" }) else {
            return false
        }
        let block = topLevelBlockRange(lines, startingAt: dnsIdx)
        guard dnsEnabled(lines, in: block) else { return false }

        let entry = nameserverPolicyEntry(nodeName: settings.nodeName,
                                          magicDNSSuffix: settings.magicDNSSuffix)

        // Existing `nameserver-policy:` → insert one fenced entry under it.
        if let polIdx = lines[block].indices.first(where: {
            childKey(lines[$0]) == "nameserver-policy"
        }) {
            guard valueAfterColon(lines[polIdx]).isEmpty else { return false }
            let indent = mappingChildIndent(lines, after: polIdx,
                                            fallback: indentOf(lines[polIdx]) + "  ")
            lines.insert(contentsOf: [indent + fenceBegin,
                                      indent + entry,
                                      indent + fenceEnd],
                         at: polIdx + 1)
            return true
        }

        // No policy map yet — create the whole key inside the dns block.
        let childIndent = mappingChildIndent(lines, after: dnsIdx, fallback: "  ")
        let entryIndent = childIndent + "  "
        lines.insert(contentsOf: [childIndent + fenceBegin,
                                  childIndent + "nameserver-policy:",
                                  entryIndent + entry,
                                  childIndent + fenceEnd],
                     at: dnsIdx + 1)
        return true
    }

    private static func dnsEnabled(_ lines: [String], in range: Range<Int>) -> Bool {
        for i in range where childKey(lines[i]) == "enable" {
            return YamlScalar.parse(valueAfterColon(lines[i])) as? Bool ?? false
        }
        return false
    }

    // MARK: Conflicts

    /// Findings that make the feature silently useless. Reported, never
    /// auto-corrected: `fake-ip-filter` and `route-exclude-address` are also
    /// written by the coexistence layer and by the user.
    static func conflictWarnings(in lines: [String],
                                 settings: TailscaleSettings) -> [String] {
        var out: [String] = []
        if listUnderKey(lines, parent: "dns", key: "fake-ip-filter")
            .contains(where: { $0.contains("ts.net") }) {
            out.append("dns.fake-ip-filter 含 ts.net —— MagicDNS 名字不会走 fake-ip，"
                       + "DOMAIN-SUFFIX 规则在 TUN 场景下不会命中")
        }
        if listUnderKey(lines, parent: "tun", key: "route-exclude-address")
            .contains(where: { $0.hasPrefix("100.64.") || $0.hasPrefix("100.100.") }) {
            out.append("tun.route-exclude-address 排除了 100.64/10 —— tailnet 流量"
                       + "不会进入 TUN，内置节点收不到任何流量")
        }
        return out
    }

    // MARK: Line helpers

    /// Top-level (column 0) mapping key on this line, if any.
    private static func topLevelKey(_ line: String) -> String? {
        guard let first = line.first, first != " ", first != "\t", first != "#" else {
            return nil
        }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[line.startIndex..<colon])
        return key.isEmpty ? nil : key
    }

    /// Indented mapping key (any depth), used inside a known block.
    private static func childKey(_ line: String) -> String? {
        guard let first = line.first, first == " " else { return nil }
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), !t.hasPrefix("-"), let colon = t.firstIndex(of: ":") else {
            return nil
        }
        return String(t[t.startIndex..<colon])
    }

    private static func valueAfterColon(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        let raw = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        return YamlScalar.stripInlineComment(raw)
    }

    private static func indentOf(_ line: String) -> String {
        String(line.prefix(while: { $0 == " " }))
    }

    /// Indentation used by the children of a mapping key.
    private static func mappingChildIndent(_ lines: [String],
                                           after idx: Int,
                                           fallback: String) -> String {
        let parentIndent = indentOf(lines[idx]).count
        var i = idx + 1
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { i += 1; continue }
            let ind = indentOf(line).count
            if ind > parentIndent { return indentOf(line) }
            break
        }
        return fallback
    }

    /// Half-open range of the lines belonging to a top-level block.
    private static func topLevelBlockRange(_ lines: [String],
                                           startingAt idx: Int) -> Range<Int> {
        var end = idx + 1
        while end < lines.count {
            let line = lines[end]
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && topLevelKey(line) != nil { break }
            end += 1
        }
        return (idx + 1)..<end
    }

    /// Scalar list items under `parent: → key:`, comments and quotes removed.
    private static func listUnderKey(_ lines: [String],
                                     parent: String,
                                     key: String) -> [String] {
        guard let pIdx = lines.firstIndex(where: { topLevelKey($0) == parent }) else {
            return []
        }
        let block = topLevelBlockRange(lines, startingAt: pIdx)
        guard let kIdx = block.first(where: { childKey(lines[$0]) == key }) else {
            return []
        }
        let inline = valueAfterColon(lines[kIdx])
        if !inline.isEmpty {
            return (YamlScalar.parse(inline) as? [String]) ?? []
        }
        var out: [String] = []
        var i = kIdx + 1
        while i < block.upperBound {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { i += 1; continue }
            guard t.hasPrefix("- ") else { break }
            let raw = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            let v = YamlScalar.parse(raw)
            out.append((v as? String) ?? String(describing: v))
            i += 1
        }
        return out
    }
}

// MARK: - Session state

/// What the UI shows. Derived from log lines plus a liveness probe — mihomo
/// exposes no tailnet status API, so this is the whole observable surface.
enum TailscaleSessionState: Equatable {
    case disabled
    /// Injected but tsnet has not been asked to do anything yet. This is the
    /// normal resting state: `ensureStarted` is a `sync.Once` driven by the
    /// first dial, so a node nobody routed to is *not* running and will never
    /// print a login URL on its own.
    case idle
    case starting
    case needsLogin(url: String)
    case running
    case failed(reason: String)

    var isTerminalFailure: Bool { if case .failed = self { return true }; return false }
}

// MARK: - Log parsing

enum TailscaleLog {

    /// mihomo wires tsnet's `UserLogf` to `log.Infoln("[Tailscale](%s) …")`, so
    /// the prefix carries the node name and the interactive login URL arrives
    /// on that channel. `Logf` (debug) is noise and is not parsed.
    ///
    /// Filtering by node name matters: a URL-shaped string from any other
    /// subsystem must not be presented to the user as a tailnet login.
    static func loginURL(in payload: String, nodeName: String) -> String? {
        guard payload.contains(prefix(nodeName)) else { return nil }
        guard let r = payload.range(of: #"https?://[^\s"'\\]+"#,
                                    options: .regularExpression) else { return nil }
        let url = String(payload[r]).trimmingCharacters(
            in: CharacterSet(charactersIn: ".,)]}"))
        // The control URL itself shows up in unrelated chatter; a login URL is
        // an authorization path, not a bare host.
        guard url.contains("/a/") || url.contains("/login") || url.contains("/register")
        else { return nil }
        return url
    }

    /// `applyExitNodePrefs` only warns on failure, so a bad selector degrades to
    /// "no exit node" — and "no exit node" means non-tailnet targets fail
    /// outright rather than falling back to direct. Surface it.
    static func exitNodeFailure(in payload: String, nodeName: String) -> String? {
        guard payload.contains(prefix(nodeName)),
              payload.contains("set exit node failed") else { return nil }
        return payload
    }

    static func isFromNode(_ payload: String, nodeName: String) -> Bool {
        payload.contains(prefix(nodeName))
    }

    private static func prefix(_ nodeName: String) -> String { "[Tailscale](\(nodeName))" }
}

// MARK: - Feature detection

enum TailscaleSupport {

    /// Mask `auth-key:` scalars in a YAML string for display / export.
    ///
    /// The live `config.yaml` must keep the real key for the kernel; this is
    /// only for surfaces that show the file to the user (or to logs). Matching
    /// is line-oriented and deliberately narrow — only our well-known key — so
    /// it cannot eat unrelated `key:` fields.
    static func redactAuthKeys(in yaml: String) -> String {
        yaml.components(separatedBy: "\n").map { line in
            // Flow mapping: `{…, auth-key: "tskey-…", …}`
            if line.contains("auth-key:") {
                if let range = line.range(of: #"auth-key:\s*"[^"]*""#,
                                          options: .regularExpression) {
                    return line.replacingCharacters(in: range, with: "auth-key: \"***\"")
                }
                if let range = line.range(of: #"auth-key:\s*\S+"#,
                                          options: .regularExpression) {
                    return line.replacingCharacters(in: range, with: "auth-key: ***")
                }
            }
            return line
        }.joined(separator: "\n")
    }

    /// Smallest config that only parses when the kernel was built with
    /// `with_gvisor && !no_tailscale`. Fed to `mihomo -t`, which exits 1 with
    /// `unsupport proxy type: tailscale` on a kernel without it.
    ///
    /// No auth key, and no `state-dir` override — an out-of-sandbox path would
    /// fail the path check first and misreport "unsupported" as "bad path".
    static func probeYAML(mixedPort: Int = 17890) -> String {
        """
        mixed-port: \(mixedPort)
        log-level: silent
        proxies:
          - {name: "__clashhalo_probe__", type: tailscale, hostname: probe}
        rules:
          - MATCH,DIRECT
        """
    }

    /// `-t` prints this exact phrase for an unknown/absent proxy type.
    static func isUnsupportedOutput(_ output: String) -> Bool {
        output.contains("unsupport proxy type")
    }
}
