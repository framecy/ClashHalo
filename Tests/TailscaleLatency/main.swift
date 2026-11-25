import Foundation

// Regression harness for TailscaleLatency（迁自已删除的 Tests/TailscaleAPI）。
// 对等节点（无 exit-node）不得参与公网 URL 测速，否则会被永久标红。

var failures = 0, checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  ✗ FAIL: \(what)") } else { print("  ✓ \(what)") }
}
func section(_ s: String) { print("\n── \(s) ──") }

section("public URL test gate")
do {
    expect(TailscaleLatency.usesPublicURLTest(nodeType: "Shadowsocks", exitNode: ""),
           "普通节点总是参与公网 URLTest")
    expect(!TailscaleLatency.usesPublicURLTest(nodeType: "Tailscale", exitNode: ""),
           "对等 tailscale 节点跳过公网 URLTest")
    expect(!TailscaleLatency.usesPublicURLTest(nodeType: "tailscale", exitNode: "  "),
           "仅空白的 exit-node 仍算没有")
    expect(TailscaleLatency.usesPublicURLTest(nodeType: "Tailscale", exitNode: "100.64.1.2"),
           "显式 exit-node 重新启用公网 URLTest")
    expect(TailscaleLatency.usesPublicURLTest(nodeType: "Tailscale", exitNode: "auto:any"),
           "auto:any 重新启用公网 URLTest")
    expect(TailscaleLatency.peerOnlySentinel == -2,
           "哨兵 -2 与 0（未测）和真实 RTT 区分")
}

print("\n\(checks - failures)/\(checks) 通过")
if failures > 0 { print("\(failures) 处失败"); exit(1) }
