import Foundation

// Test harness over the real shipping source
// (Sources/Model/TUNDataPlaneProbe.swift), compiled in, not re-implemented.
// Re-implementing the rule in the test is how a test passes while the product
// is broken.

var failures = 0, checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  ✗ FAIL: \(what)") } else { print("  ✓ \(what)") }
}
func section(_ s: String) { print("\n── \(s) ──") }

// MARK: - DNS wire helpers used only by the test

/// Build a minimal DNS response for a given request. Flags/QR/RCODE are
/// controllable so the validator's acceptance surface can be exercised without
/// a live resolver.
func makeResponse(for request: Data,
                  qr: Bool = true,
                  rcode: UInt8 = 0,
                  flipTxID: Bool = false,
                  truncateTo: Int? = nil) -> Data {
    precondition(request.count >= 12)
    var resp = Data(request.prefix(12))
    // QR bit of byte 2; RCODE in low nibble of byte 3.
    if qr { resp[2] = resp[2] | 0x80 } else { resp[2] = resp[2] & 0x7f }
    resp[3] = (resp[3] & 0xf0) | (rcode & 0x0f)
    // Zero answer counts — empty answer section is still a valid response.
    resp[4] = 0; resp[5] = 1   // QDCOUNT = 1 (echo question)
    resp[6] = 0; resp[7] = 0
    resp[8] = 0; resp[9] = 0
    resp[10] = 0; resp[11] = 0
    // Echo the question section of the request so the packet is well-formed.
    if request.count > 12 { resp.append(request.dropFirst(12)) }
    if flipTxID {
        resp[0] = resp[0] &+ 1
    }
    if let n = truncateTo {
        return Data(resp.prefix(n))
    }
    return resp
}

// MARK: - DNSProbe.validate

section("DNSProbe — 构造与校验")
let probe = DNSProbe(txID: 0xA5C3)
let req = probe.query(host: "probe.tun.local")
expect(req.count >= 12, "请求长度 ≥ 12 字节（实得 \(req.count)）")
expect(req[0] == 0xA5 && req[1] == 0xC3, "请求 transaction ID 正确写入")
expect((req[2] & 0x80) == 0, "请求 QR 位为 0（query）")
// QDCOUNT = 1
expect(req[4] == 0 && req[5] == 1, "QDCOUNT = 1")

let ok = makeResponse(for: req)
expect(probe.validate(response: ok) == .valid, "正常响应 → valid")

let nx = makeResponse(for: req, rcode: 3)   // NXDOMAIN
expect(probe.validate(response: nx) == .valid,
       "NXDOMAIN 仍视为数据面存活（valid）")

let servfail = makeResponse(for: req, rcode: 2)
expect(probe.validate(response: servfail) == .valid,
       "SERVFAIL 仍视为数据面存活（valid）")

let mismatch = makeResponse(for: req, flipTxID: true)
expect(probe.validate(response: mismatch) == .mismatch,
       "transaction ID 不匹配 → mismatch")

let truncated = makeResponse(for: req, truncateTo: 8)
expect(probe.validate(response: truncated) == .malformed,
       "截断包（<12 字节且非空）→ malformed")

let empty = Data()
expect(probe.validate(response: empty) == .never,
       "空包 / 超时（无字节）→ never")

let noQR = makeResponse(for: req, qr: false)
expect(probe.validate(response: noQR) == .malformed,
       "QR 位未置位（不是响应）→ malformed")

// MARK: - TUNDataPlaneHealthState

section("TUNDataPlaneHealthState — 连续失败 / 成功清零 / 阈值触发")
var state = TUNDataPlaneHealthState(threshold: 3)
expect(state.record(success: false) == false, "第 1 次失败不触发")
expect(state.consecutiveFailures == 1, "连续失败计数 = 1")
expect(state.record(success: false) == false, "第 2 次失败不触发")
expect(state.consecutiveFailures == 2, "连续失败计数 = 2")
expect(state.record(success: false) == true,  "第 3 次失败触发一次修复")
expect(state.consecutiveFailures == 3, "连续失败计数 = 3")

// 成功后清零
expect(state.record(success: true) == false, "成功不触发修复")
expect(state.consecutiveFailures == 0, "成功后失败计数清零")

// 2 次失败 + 1 次成功 + 2 次失败 不应触发（数据面曾恢复）
_ = state.record(success: false)
_ = state.record(success: false)
_ = state.record(success: true)
expect(state.consecutiveFailures == 0, "中途成功打断连续失败")
expect(state.record(success: false) == false, "重新计数后第 1 次失败不触发")
expect(state.record(success: false) == false, "重新计数后第 2 次失败不触发")
expect(state.record(success: false) == true,  "重新计数后第 3 次失败才触发")

// reset()
state.reset()
expect(state.consecutiveFailures == 0, "reset() 将计数清零")
expect(state.record(success: false) == false, "reset 后第 1 次失败不触发")

// threshold=1：单次失败即触发（用于“一个 cycle 确认即恢复”的配置）
var once = TUNDataPlaneHealthState(threshold: 1)
expect(once.record(success: false) == true, "threshold=1 时首次失败即触发")
_ = once.record(success: true)
expect(once.record(success: true) == false, "成功永不触发")

// MARK: - Summary

print("\n════════════════════════════════")
if failures == 0 {
    print("全部通过：\(checks) 项")
    exit(0)
} else {
    print("失败 \(failures)/\(checks) 项")
    exit(1)
}
