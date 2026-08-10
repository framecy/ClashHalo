import Foundation

// Test harness over Sources/Model/TailscaleAPI.swift.
// Decodes fixture JSON the same way the UI will, and pins the latency
// classification that keeps peer-only tailscale nodes out of public URL tests.

var failures = 0, checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  ✗ FAIL: \(what)") } else { print("  ✓ \(what)") }
}
func section(_ s: String) { print("\n── \(s) ──") }

// MARK: - Decode

section("device list decode")
do {
    let json = """
    {
      "devices": [
        {
          "id": "nBabc",
          "hostname": "office-exit",
          "name": "office-exit.tail1234.ts.net",
          "addresses": ["100.64.1.2", "fd7a:115c:a1e0::1"],
          "online": true,
          "os": "linux",
          "keyExpiry": "2027-01-01T00:00:00Z",
          "lastSeen": "2026-08-10T12:00:00Z",
          "isEphemeral": false,
          "advertisedRoutes": ["10.20.0.0/16", "fd7a:115c::/48", "0.0.0.0/0"],
          "enabledRoutes": ["10.20.0.0/16", "192.168.50.0/24"]
        },
        {
          "id": "nCdef",
          "hostname": "phone",
          "name": "phone.tail1234.ts.net",
          "addresses": ["100.64.1.3"],
          "online": false,
          "os": "iOS",
          "isEphemeral": true
        },
        {
          "id": "nGhi",
          "hostname": "",
          "name": "bare.tail1234.ts.net",
          "addresses": ["100.64.1.4", "2001:db8::1"],
          "online": true,
          "advertisedRoutes": ["100.64.1.9/32"]
        }
      ]
    }
    """.data(using: .utf8)!

    let devices = try TailscaleAPI.decodeDevices(json)
    expect(devices.count == 3, "three devices decoded")
    // Online first.
    expect(devices[0].online && devices[1].online && !devices[2].online,
           "online devices sort before offline")
    expect(devices[0].hostname == "bare.tail1234.ts.net"
           || devices[0].hostname == "office-exit",
           "empty hostname falls back to name FQDN")
    let office = devices.first { $0.id == "nBabc" }!
    expect(office.ips == ["100.64.1.2"], "IPv6 addresses dropped from ips")
    expect(office.os == "linux", "os preserved")
    expect(!office.ephemeral, "ephemeral false by default")
    expect(office.enabledRoutes == ["10.20.0.0/16", "192.168.50.0/24"],
           "enabled IPv4 routes kept")
    expect(office.advertisedRoutes == ["10.20.0.0/16", "0.0.0.0/0"],
           "advertised IPv4 routes kept, IPv6 dropped")
    let phone = devices.first { $0.id == "nCdef" }!
    expect(phone.ephemeral, "ephemeral true preserved")
    expect(!phone.online, "offline preserved")
    expect(phone.advertisedRoutes.isEmpty && phone.enabledRoutes.isEmpty,
           "missing route arrays default to empty")
}

section("suggested subnet routes")
do {
    let json = """
    {"devices":[
      {"id":"1","hostname":"r","name":"r.tail1.ts.net",
       "addresses":["100.64.1.1"],"online":true,
       "advertisedRoutes":["10.0.0.0/8","0.0.0.0/0","100.64.1.9/32"],
       "enabledRoutes":["10.0.0.0/8","192.168.1.0/24"]},
      {"id":"2","hostname":"s","name":"s.tail1.ts.net",
       "addresses":["100.64.1.2"],"online":true,
       "advertisedRoutes":["192.168.1.0/24"]}
    ]}
    """.data(using: .utf8)!
    let devices = try TailscaleAPI.decodeDevices(json)
    let suggested = TailscaleAPI.suggestedSubnetRoutes(from: devices)
    expect(suggested.contains("10.0.0.0/8"), "enabled broad route suggested")
    expect(suggested.contains("192.168.1.0/24"), "enabled LAN route suggested")
    expect(!suggested.contains("0.0.0.0/0"), "default route excluded")
    expect(!suggested.contains("100.64.1.9/32"), "tailnet peer /32 excluded")
    expect(suggested.filter { $0 == "192.168.1.0/24" }.count == 1, "deduped across devices")
}

section("decode is tolerant of missing optional fields")
do {
    let sparse = """
    {"devices":[{"id":"x","hostname":"h","name":"h","addresses":[]}]}
    """.data(using: .utf8)!
    let d = try TailscaleAPI.decodeDevices(sparse)
    expect(d.count == 1 && d[0].hostname == "h", "sparse device decodes")
    expect(d[0].ips.isEmpty && !d[0].online && !d[0].ephemeral,
           "missing optionals default safely")
}

section("malformed payload is an error, not a crash")
do {
    var threw = false
    do { _ = try TailscaleAPI.decodeDevices(Data("nope".utf8)) }
    catch { threw = true }
    expect(threw, "garbage JSON throws")
}

// MARK: - MagicDNS suffix

section("MagicDNS suffix inference")
do {
    expect(TailscaleAPI.inferMagicDNSSuffix(fromFQDNs: [
        "office-exit.tail1234.ts.net",
        "phone.tail1234.ts.net"
    ]) == "tail1234.ts.net", "standard tailnet FQDN")
    expect(TailscaleAPI.inferMagicDNSSuffix(fromFQDNs: [
        "office-exit", "phone"
    ]) == nil, "short hostnames yield nothing")
    expect(TailscaleAPI.inferMagicDNSSuffix(fromFQDNs: [
        "box.custom.example.com"
    ]) == nil, "Headscale custom domain is left alone")
    expect(TailscaleAPI.inferMagicDNSSuffix(fromFQDNs: [
        ".tail1234.ts.net."
    ]) == "tail1234.ts.net", "already-a-suffix input is kept, not collapsed to ts.net")
    expect(TailscaleAPI.inferMagicDNSSuffix(fromFQDNs: [
        "host.tail9.ts.net"
    ]) == "tail9.ts.net", "host label stripped from FQDN")
}

section("FQDN extraction from raw payload")
do {
    let json = """
    {"devices":[
      {"id":"1","hostname":"a","name":"a.tail9.ts.net","addresses":[]},
      {"id":"2","hostname":"b","name":"b","addresses":[]}
    ]}
    """.data(using: .utf8)!
    let names = TailscaleAPI.fqdns(from: json)
    expect(names == ["a.tail9.ts.net"], "only dotted names kept")
}

// MARK: - Latency classification

section("public URL test gate")
do {
    expect(TailscaleLatency.usesPublicURLTest(nodeType: "Shadowsocks", exitNode: ""),
           "ordinary nodes always take the public URL test")
    expect(!TailscaleLatency.usesPublicURLTest(nodeType: "Tailscale", exitNode: ""),
           "peer-only tailscale skips the public URL test")
    expect(!TailscaleLatency.usesPublicURLTest(nodeType: "tailscale", exitNode: "  "),
           "whitespace-only exit node still counts as none")
    expect(TailscaleLatency.usesPublicURLTest(nodeType: "Tailscale", exitNode: "100.64.1.2"),
           "explicit exit node re-enables the public URL test")
    expect(TailscaleLatency.usesPublicURLTest(nodeType: "Tailscale", exitNode: "auto:any"),
           "auto:any re-enables the public URL test")
    expect(TailscaleLatency.peerOnlySentinel == -2,
           "sentinel is distinct from 0 (untested) and from real RTTs")
}

section("error descriptions")
do {
    expect(TailscaleAPI.describe(.noToken).contains("Token"), "noToken message")
    expect(TailscaleAPI.describe(.http(401)).contains("权限")
           || TailscaleAPI.describe(.http(401)).contains("无效"), "401 message")
    expect(TailscaleAPI.describe(.http(500)).contains("500"), "generic http code")
}

print("\n\(checks - failures)/\(checks) 通过")
if failures > 0 { print("\(failures) 处失败"); exit(1) }
