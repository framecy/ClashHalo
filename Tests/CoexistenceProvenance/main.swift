import Foundation

// Test harness over the real shipping source
// (Sources/Model/CoexistenceProvenance.swift), compiled in, not re-implemented.
//
// The regression this pins down, in the shape it actually occurred:
//
//   A Tailscale user hand-writes `100.64.0.0/10` into their own
//   `tun.route-exclude-address`. The Tailscale vendor entry in Coexistence emits
//   the *same string*. Provenance was committed as the whole desired plan, so
//   one TUN enable relabelled the user's entry as app-injected — and the next
//   teardown withdrew it. CGNAT then fell into mihomo's auto-route and Tailscale
//   traffic went into the wrong tunnel, with a config file that still listed the
//   exclusion.
//
// `isProtectiveExclusion` had already been added to paper over one instance of
// this (multicast). The rule under test here fixes the class: record what was
// actually added, never what was merely wanted.

var failures = 0, checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  ✗ FAIL: \(what)") } else { print("  ✓ \(what)") }
}
func section(_ s: String) { print("\n── \(s) ──") }

// Isolate the UserDefaults-backed record so the suite never touches a real app
// domain, and so each case starts from a known provenance.
let field = "test.route-exclude-address"
func setRecord(_ v: [String]) { CoexistenceProvenance.commitProvenance(field: field, injected: v) }

// The user's own list, taken verbatim from a real deployed config.
let userWritten = [
    "127.0.0.0/8", "100.64.0.0/10", "192.168.0.0/16", "10.0.0.0/8",
    "172.16.0.0/12", "224.0.0.0/4", "239.0.0.0/8", "169.254.0.0/16",
    "fd7a:115c:a1e0::/48", "fe80::/10", "ff00::/8",
    "219.146.1.66/32", "219.147.1.66/32", "223.5.5.5/32",
]
// What the Tailscale vendor entry emits.
let tailscalePlan = ["100.64.0.0/10", "100.100.100.100/32"]

// MARK: - newlyInjected

section("provenance 只记录真正新增的条目")
let added = CoexistenceProvenance.newlyInjected(desired: tailscalePlan,
                                                existingBefore: userWritten)
expect(added == ["100.100.100.100/32"],
       "与用户已有条目重合的 100.64.0.0/10 不计入 provenance")
expect(!added.contains("100.64.0.0/10"), "用户手写的 CGNAT 不被认领")
expect(CoexistenceProvenance.newlyInjected(desired: tailscalePlan, existingBefore: [])
       == ["100.100.100.100/32", "100.64.0.0/10"].sorted(),
       "空配置时整份计划都是新增")
expect(CoexistenceProvenance.newlyInjected(desired: [], existingBefore: userWritten).isEmpty,
       "空计划不新增任何条目")

// MARK: - The end-to-end cycle that used to lose the entry

section("开关 TUN 一轮后用户条目仍在（回归本体）")
setRecord([])
let merged = CoexistenceProvenance.mergePreservingUserEntries(
    field: field, desired: tailscalePlan, in: userWritten)
expect(merged.contains("100.64.0.0/10") && merged.contains("100.100.100.100/32"),
       "合并结果同时包含用户条目与计划条目")
// Commit only what was added — the fix.
setRecord(CoexistenceProvenance.newlyInjected(desired: tailscalePlan,
                                              existingBefore: userWritten))
let afterOff = CoexistenceProvenance.withdraw(field: field, from: merged)
expect(afterOff.contains("100.64.0.0/10"), "关 TUN 后用户手写的 100.64.0.0/10 仍在")
expect(!afterOff.contains("100.100.100.100/32"), "关 TUN 后本应用注入的 MagicDNS 条目被撤回")
for cidr in userWritten {
    expect(afterOff.contains(cidr), "用户条目保留：\(cidr)")
}

section("旧行为会丢失条目（证明这条测试确实有效）")
setRecord(tailscalePlan)   // 旧代码：整份计划都记为自己的
let afterOffOld = CoexistenceProvenance.withdraw(field: field, from: merged)
expect(!afterOffOld.contains("100.64.0.0/10"),
       "把整份计划记为 provenance 时，用户条目确实会被删除")

// MARK: - Protective prefixes still hold as a second line of defence

section("保护性前缀仍不可撤回")
setRecord(["224.0.0.0/4", "fe80::/10", "127.0.0.0/8"])
let afterProt = CoexistenceProvenance.withdraw(field: field, from: userWritten)
expect(afterProt.contains("224.0.0.0/4"), "组播即便被错误认领也不撤回")
expect(afterProt.contains("fe80::/10"), "IPv6 链路本地不撤回")
expect(afterProt.contains("127.0.0.0/8"), "回环不撤回")

section("PingMonitor 探测目标不被任何计划牵连")
setRecord(tailscalePlan)
let afterPing = CoexistenceProvenance.withdraw(field: field, from: userWritten)
for t in ["219.146.1.66/32", "219.147.1.66/32", "223.5.5.5/32"] {
    expect(afterPing.contains(t), "ICMP 排除目标保留：\(t)")
}

// Leave no residue behind.
UserDefaults.standard.removeObject(forKey: "coexistence.injected." + field)

print("\n\(checks - failures)/\(checks) 通过")
if failures > 0 {
    print("\(failures) 项失败")
    exit(1)
}
