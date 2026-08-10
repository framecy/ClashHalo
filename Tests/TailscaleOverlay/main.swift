import Foundation

// Test harness over the real shipping source
// (Sources/Model/TailscaleNode.swift), compiled in, not re-implemented.
//
// The bugs this guards are the ones that make the feature *silently* useless:
// an overlay that stacks on repeat, a sequence indentation guess that produces
// invalid YAML, a strip that does not fully undo an apply, and a login-URL
// matcher that fires on any URL-shaped log line.

var failures = 0, checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  ✗ FAIL: \(what)") } else { print("  ✓ \(what)") }
}
func section(_ s: String) { print("\n── \(s) ──") }

func settings(_ mutate: (inout TailscaleSettings) -> Void = { _ in }) -> TailscaleSettings {
    var s = TailscaleSettings()
    s.nodeName = "Tailnet"
    s.hostname = "clashhalo-mac"
    mutate(&s)
    return s
}

// Subscription YAML in the wild puts sequence items at column 0 just as often
// as column 2. YAML requires every item of one sequence to share a column.
let colZero = """
mixed-port: 7890
log-level: info
proxies:
- name: "\u{9999}\u{6E2F} 01"
  type: ss
  server: 1.2.3.4
  port: 443
proxy-groups:
- name: PROXY
  type: select
  proxies:
  - "\u{9999}\u{6E2F} 01"
dns:
  enable: true
  enhanced-mode: fake-ip
  nameserver:
  - 223.5.5.5
  nameserver-policy:
    "+.lan": 223.5.5.5
rules:
- GEOIP,CN,DIRECT
- MATCH,PROXY
"""

let colTwo = """
mixed-port: 7890
proxies:
  - name: A
    type: ss
    server: 1.2.3.4
    port: 443
dns:
  enable: true
  nameserver:
    - 223.5.5.5
rules:
  - MATCH,DIRECT
"""

// MARK: - Round trip

section("strip ∘ apply = identity")
for (label, doc) in [("column-0", colZero), ("column-2", colTwo)] {
    let r = TailscaleOverlay.apply(to: doc, settings: settings())
    expect(r.injected, "\(label): injected")
    expect(TailscaleOverlay.strip(r.yaml) == doc, "\(label): strip restores the original byte-for-byte")
}

section("apply is idempotent")
for (label, doc) in [("column-0", colZero), ("column-2", colTwo)] {
    let once = TailscaleOverlay.apply(to: doc, settings: settings()).yaml
    let twice = TailscaleOverlay.apply(to: once, settings: settings()).yaml
    expect(once == twice, "\(label): second apply changes nothing")
    let count = once.components(separatedBy: "type: tailscale").count - 1
    expect(count == 1, "\(label): exactly one node after repeat apply")
}

section("re-apply with new settings replaces, never stacks")
do {
    let first = TailscaleOverlay.apply(to: colTwo, settings: settings()).yaml
    let second = TailscaleOverlay.apply(to: first, settings: settings { $0.hostname = "other-host" }).yaml
    expect(second.contains("other-host"), "new hostname present")
    expect(!second.contains("clashhalo-mac"), "old hostname gone")
    expect(second.components(separatedBy: "type: tailscale").count - 1 == 1, "still one node")
}

// MARK: - Sequence indentation

section("sequence indentation matches the surrounding list")
do {
    let r0 = TailscaleOverlay.apply(to: colZero, settings: settings()).yaml
    let lines0 = r0.components(separatedBy: "\n")
    let node0 = lines0.first { $0.contains("type: tailscale") } ?? ""
    expect(node0.hasPrefix("- {"), "column-0 profile gets a column-0 dash")
    let rule0 = lines0.first { $0.contains("IP-CIDR,100.64.0.0/10") } ?? ""
    expect(rule0.hasPrefix("- "), "column-0 profile gets column-0 rules")

    let r2 = TailscaleOverlay.apply(to: colTwo, settings: settings()).yaml
    let lines2 = r2.components(separatedBy: "\n")
    let node2 = lines2.first { $0.contains("type: tailscale") } ?? ""
    expect(node2.hasPrefix("  - {"), "column-2 profile gets a column-2 dash")
}

section("rules go to the head of the list")
do {
    let r = TailscaleOverlay.apply(to: colZero, settings: settings()).yaml
    let lines = r.components(separatedBy: "\n")
    let ourRule = lines.firstIndex { $0.contains("IP-CIDR,100.64.0.0/10") } ?? .max
    let geoip = lines.firstIndex { $0.contains("GEOIP,CN,DIRECT") } ?? -1
    expect(ourRule < geoip, "tailnet rule precedes GEOIP/MATCH")
}

section("no-resolve on the IP rule")
do {
    let rules = TailscaleOverlay.autoRules(nodeName: "T", magicDNSSuffix: "").rules
    expect(rules.contains("IP-CIDR,100.64.0.0/10,T,no-resolve"), "CGNAT rule carries no-resolve")
    expect(rules.contains("DOMAIN-SUFFIX,ts.net,T"), "generic suffix when none discovered")
    let named = TailscaleOverlay.autoRules(nodeName: "T", magicDNSSuffix: ".tail1234.ts.net.").rules
    expect(named.contains("DOMAIN-SUFFIX,tail1234.ts.net,T"), "discovered suffix is normalized")
}

section("peer /32 and extra CIDR rules")
do {
    let r = TailscaleOverlay.autoRules(
        nodeName: "T",
        magicDNSSuffix: "tail9.ts.net",
        includeCGNAT: true,
        peerIPs: ["100.64.1.2", "100.64.1.2", "bad", "100.64.1.3",
                  "2001:db8::1"],
        extraCIDRs: ["10.20.0.0/16", "10.20.0.0/16", "0.0.0.0/0", "not-a-cidr",
                     "1.2.3.4"]
    )
    expect(r.rules.contains("IP-CIDR,100.64.1.2/32,T,no-resolve"), "peer /32 emitted")
    expect(r.rules.contains("IP-CIDR,100.64.1.3/32,T,no-resolve"), "second peer /32 emitted")
    expect(r.rules.filter { $0.contains("100.64.1.2/32") }.count == 1, "peer IPs deduped")
    expect(r.rules.contains("IP-CIDR,10.20.0.0/16,T,no-resolve"), "extra subnet emitted")
    expect(r.rules.contains("IP-CIDR,1.2.3.4/32,T,no-resolve"), "bare IP promoted to /32")
    expect(!r.rules.contains(where: { $0.contains("0.0.0.0/0") }), "default route refused")
    expect(r.warnings.contains(where: { $0.contains("默认路由") }), "default-route warning")
    expect(!r.rules.contains(where: { $0.contains(":") && $0.contains("IP-CIDR") }),
           "IPv6 peer addresses dropped")

    let noCGNAT = TailscaleOverlay.autoRules(
        nodeName: "T", magicDNSSuffix: "",
        includeCGNAT: false,
        peerIPs: ["100.64.1.2"]
    ).rules
    expect(!noCGNAT.contains(where: { $0.contains("100.64.0.0/10") }),
           "CGNAT aggregate omitted when asked")
    expect(noCGNAT.contains("IP-CIDR,100.64.1.2/32,T,no-resolve"),
           "peer /32 still present without CGNAT aggregate")
}

section("peer rule cap")
do {
    let many = (1...80).map { "100.64.1.\($0 % 250 + 1)" }
    // Force uniqueness with a second octet sweep.
    let unique = (0..<80).map { i in "100.64.\(i / 250).\(i % 250 + 1)" }
    let r = TailscaleOverlay.autoRules(nodeName: "T", magicDNSSuffix: "",
                                       peerIPs: unique)
    let peerCount = r.rules.filter { $0.contains("/32") }.count
    expect(peerCount == TailscaleSettings.maxPeerRules,
           "peer rules capped at \(TailscaleSettings.maxPeerRules), got \(peerCount)")
    expect(r.warnings.contains(where: { $0.contains("只注入前") }), "cap warning present")
    _ = many
}

section("control URL normalization")
do {
    expect(TailscaleOverlay.normalizeControlURL("") == "", "empty stays empty")
    expect(TailscaleOverlay.normalizeControlURL("  ") == "", "whitespace stays empty")
    expect(TailscaleOverlay.normalizeControlURL("https://hs.example.com") == "https://hs.example.com",
           "https accepted")
    expect(TailscaleOverlay.normalizeControlURL("http://hs.example.com:8080") == "http://hs.example.com:8080",
           "http with port accepted")
    expect(TailscaleOverlay.normalizeControlURL("hs.example.com") == nil,
           "bare host rejected — scheme required")
    expect(TailscaleOverlay.normalizeControlURL("ftp://hs.example.com") == nil,
           "non-http scheme rejected")
}

section("exit-node-allow-lan-access rendered only with exit node")
do {
    let bare = TailscaleOverlay.proxyEntry(settings())
    expect(!bare.contains("exit-node-allow-lan-access"),
           "no LAN-access flag without an exit node")
    let withExit = TailscaleOverlay.proxyEntry(settings {
        $0.exitNode = "100.64.1.2"
        $0.exitNodeAllowLANAccess = true
    })
    expect(withExit.contains("exit-node: \"100.64.1.2\""), "exit node present")
    expect(withExit.contains("exit-node-allow-lan-access: true"),
           "LAN-access flag present with exit node")
}

// MARK: - Missing / degenerate containers

section("missing containers are created")
do {
    let bare = "mixed-port: 7890\nlog-level: info"
    let r = TailscaleOverlay.apply(to: bare, settings: settings())
    expect(r.injected, "injected into a profile with no proxies/rules")
    expect(r.yaml.contains("proxies:"), "proxies key created")
    expect(r.yaml.contains("rules:"), "rules key created")
    expect(TailscaleOverlay.strip(r.yaml) == bare, "strip removes the keys it created")
}

section("empty flow sequences are converted, not corrupted")
do {
    let doc = "proxies: []\nrules: []\n"
    let r = TailscaleOverlay.apply(to: doc, settings: settings())
    expect(r.injected, "injected into `proxies: []`")
    expect(!r.yaml.contains("proxies: []"), "flow form rewritten to block form")
    expect(r.yaml.contains("- {name: \"Tailnet\""), "node written under it")
}

section("an unparsable container is refused, never half-written")
do {
    let doc = "proxies: &anchor\nrules:\n- MATCH,DIRECT"
    let r = TailscaleOverlay.apply(to: doc, settings: settings())
    expect(!r.injected, "refused")
    expect(r.yaml == doc, "input returned unchanged")
    expect(!r.warnings.isEmpty, "reported why")
}

// MARK: - DNS

section("nameserver-policy insertion")
do {
    let r = TailscaleOverlay.apply(to: colZero, settings: settings())
    expect(!r.dnsSkipped, "dns applied when an enabled dns block exists")
    let line = r.yaml.components(separatedBy: "\n").first { $0.contains("ts://Tailnet") } ?? ""
    expect(line.contains("\"+.ts.net\": \"ts://Tailnet\""), "policy entry rendered")
    expect(line.hasPrefix("    "), "entry matches the existing policy-map indent, got \"\(line)\"")

    let r2 = TailscaleOverlay.apply(to: colTwo, settings: settings())
    expect(!r2.dnsSkipped, "policy map created when absent")
    expect(r2.yaml.contains("nameserver-policy:"), "nameserver-policy key created")
}

section("DNS is left alone when it cannot be touched safely")
do {
    let noDNS = "proxies:\n  - {name: A, type: direct}\nrules:\n  - MATCH,DIRECT"
    expect(TailscaleOverlay.apply(to: noDNS, settings: settings()).dnsSkipped,
           "no dns block → skipped, not synthesized")
    let off = "dns:\n  enable: false\nrules:\n  - MATCH,DIRECT"
    expect(TailscaleOverlay.apply(to: off, settings: settings()).dnsSkipped,
           "dns disabled → skipped")
    expect(!TailscaleOverlay.apply(to: off, settings: settings()).yaml.contains("ts://"),
           "nothing written into a disabled dns block")
}

// MARK: - Conflicts

section("conflicts are reported")
do {
    let filtered = """
    dns:
      enable: true
      fake-ip-filter:
      - "+.ts.net"
      - "*.lan"
    rules:
    - MATCH,DIRECT
    """
    let w = TailscaleOverlay.apply(to: filtered, settings: settings()).warnings
    expect(w.contains { $0.contains("fake-ip-filter") }, "fake-ip-filter ts.net flagged")

    let excluded = """
    tun:
      enable: true
      route-exclude-address:
      - 100.64.0.0/10
    rules:
    - MATCH,DIRECT
    """
    let w2 = TailscaleOverlay.apply(to: excluded, settings: settings()).warnings
    expect(w2.contains { $0.contains("route-exclude-address") }, "CGNAT exclusion flagged")

    let clean = TailscaleOverlay.apply(to: colZero, settings: settings()).warnings
    expect(clean.isEmpty, "clean profile produces no warnings")
}

// MARK: - Names

section("node name validation")
do {
    expect(TailscaleName.isValid("Tailnet"), "plain name ok")
    expect(!TailscaleName.isValid("a,b"), "comma rejected — it would split the rule line")
    expect(!TailscaleName.isValid("ts://x"), "colon/slash rejected — it would break ts:// target")
    expect(!TailscaleName.isValid(""), "empty rejected")
    expect(!TailscaleName.isValid(" x"), "leading space rejected")
    expect(TailscaleName.sanitize("a,b") == "a-b", "sanitize replaces the separator")
    expect(TailscaleName.sanitize(",,,") == TailscaleSettings.defaultNodeName,
           "unsalvageable name falls back to the default")

    let r = TailscaleOverlay.apply(to: colTwo, settings: settings { $0.nodeName = "bad,name" })
    expect(!r.injected && r.yaml == colTwo, "invalid name refuses injection outright")
}

section("hostname normalization")
do {
    expect(TailscaleName.sanitizeHostname("ClashHalo Mac") == "clashhalo-mac", "lowercased, spaces to dashes")
    expect(TailscaleName.sanitizeHostname("--x--") == "x", "trimmed dashes")
    expect(TailscaleName.sanitizeHostname("") == "clashhalo-mac", "empty falls back")
    expect(TailscaleName.sanitizeHostname("陈的电脑").isEmpty == false, "non-ASCII still yields a usable label")
}

// MARK: - Rendering details

section("rendered node carries the verified-safe fields")
do {
    let entry = TailscaleOverlay.proxyEntry(settings { $0.authKey = "tskey-auth-secret" })
    expect(entry.contains("state-dir: \"tailscale\""),
           "state-dir is relative — an absolute path outside the mihomo home dir is rejected by IsSafePath")
    expect(entry.contains("udp: true"), "udp on — mihomo defaults it to false")
    expect(entry.contains("auth-key: \"tskey-auth-secret\""), "auth key rendered when present")
    expect(!TailscaleOverlay.proxyEntry(settings()).contains("auth-key"),
           "no auth-key key at all when empty (interactive login path)")
    expect(!TailscaleOverlay.proxyEntry(settings()).contains("exit-node"),
           "no exit-node key when unset")
    expect(TailscaleOverlay.proxyEntry(settings { $0.exitNode = "auto:any" })
        .contains("exit-node: \"auto:any\""), "exit-node rendered when set")
}

// MARK: - Log parsing

section("login URL is matched by node, not by shape")
do {
    let real = "[Tailscale](Tailnet) To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/1a2b3c4d"
    expect(TailscaleLog.loginURL(in: real, nodeName: "Tailnet") == "https://login.tailscale.com/a/1a2b3c4d",
           "URL extracted")
    expect(TailscaleLog.loginURL(in: real, nodeName: "Other") == nil,
           "a different node's line is ignored")
    let noise = "[Tailscale](Tailnet) control: connecting to https://controlplane.tailscale.com"
    expect(TailscaleLog.loginURL(in: noise, nodeName: "Tailnet") == nil,
           "the control URL is not a login URL")
    let unrelated = "[Provider] downloading https://example.com/a/sub.yaml"
    expect(TailscaleLog.loginURL(in: unrelated, nodeName: "Tailnet") == nil,
           "unrelated subsystem ignored")
    let headscale = "[Tailscale](Tailnet) go to: https://hs.example.com/register/abcdef"
    expect(TailscaleLog.loginURL(in: headscale, nodeName: "Tailnet") != nil,
           "headscale register URL recognized")
}

section("exit-node failure is surfaced")
do {
    let warn = "[Tailscale](Tailnet) set exit node failed: no such peer"
    expect(TailscaleLog.exitNodeFailure(in: warn, nodeName: "Tailnet") != nil,
           "warn-only kernel path is detected")
    expect(TailscaleLog.exitNodeFailure(in: "[Tailscale](Tailnet) hello", nodeName: "Tailnet") == nil,
           "ordinary chatter is not a failure")
}

// MARK: - Feature probe

section("feature probe snippet")
do {
    let y = TailscaleSupport.probeYAML()
    expect(y.contains("type: tailscale"), "probe exercises the tailscale type")
    expect(!y.contains("state-dir"),
           "probe must not set state-dir — a path error would masquerade as unsupported")
    expect(!y.contains("auth-key"), "probe carries no credential")
    expect(TailscaleSupport.isUnsupportedOutput(
        #"level=error msg="proxy 0: unsupport proxy type: tailscale""#),
        "kernel's exact phrase recognized")
}

section("auth-key redaction for display")
do {
    let flow = "  - {name: \"T\", type: tailscale, auth-key: \"tskey-auth-SECRET\", udp: true}"
    let red = TailscaleSupport.redactAuthKeys(in: flow)
    expect(red.contains("auth-key: \"***\""), "flow mapping auth-key masked")
    expect(!red.contains("SECRET"), "secret value gone")
    let block = "auth-key: tskey-auth-SECRET\nudp: true"
    let red2 = TailscaleSupport.redactAuthKeys(in: block)
    expect(red2.contains("auth-key: ***"), "block scalar auth-key masked")
    expect(!red2.contains("SECRET"), "block secret value gone")
    let clean = "proxies:\n  - {name: A, type: ss}"
    expect(TailscaleSupport.redactAuthKeys(in: clean) == clean,
           "unrelated YAML untouched")
}

print("\n\(checks - failures)/\(checks) 通过")
if failures > 0 { print("\(failures) 处失败"); exit(1) }
