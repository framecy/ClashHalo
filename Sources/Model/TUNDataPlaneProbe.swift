import Foundation

// MARK: - TUN data-plane probe
//
// Background
// ----------
// macOS reuses the `utun100` interface name across network topology changes —
// `configd` detaches and re-attaches it — and mihomo can end up holding a file
// descriptor to a TUN that the kernel has re-mounted underneath it. The
// interface table still shows `utun100` UP, the route table still points the
// fake-ip range at it, and a plain "interface exists?" check therefore reads
// healthy. But the data plane is dead: every packet mihomo writes is silently
// dropped, and it logs `bad file descriptor / file already closed` in a flood.
//
// This file is the two pure halves of the self-heal that closes that gap — no
// UI, no process management, no MainActor — so they are unit-testable against a
// real shipping source file (see `Tests/TUNDataPlaneProbe/main.swift`):
//
//   1. `DNSProbe` builds a minimal UDP DNS query and decides whether a reply is
//      a valid reply. A valid reply is any well-formed DNS response whose
//      transaction id matches the request — NXDOMAIN/SERVFAIL count, because
//      the question "is the data plane alive" is not the question "did the name
//      resolve". Only reaching the TUN gateway and getting an answer back proves
//      the fd is not stale.
//   2. `TUNDataPlaneHealthState` is the consecutive-failure counter with a
//      short-window, in-task retry policy: 3 failures collected *within a single
//      probe run* trigger recovery, not 3 spaced poll cycles (a 10-minute cadence
//      would mean 20–30 minutes of blackout before action). One success resets it.

/// Minimal in-memory model of a DNS request/response pair used by the TUN
/// data-plane probe. The wire bytes are produced by `query(host:)` and
/// validated by `validate(response:)`. Kept self-contained so the unit test can
/// build arbitrary requests and replies without touching the network.
struct DNSProbe {
    /// A transaction id for a probe request. Two bytes, any value 0x0001…0xffff
    /// is fine — we only need it to match in the reply.
    let txID: UInt16

    /// Build a one-question UDP DNS query for `host` (type A, class IN) carrying
    /// this probe's transaction id. Returns the exact bytes to send to the TUN
    /// gateway on UDP/53, plus the host whose answer's question section we accept.
    /// `host` defaults to a label none of mihomo's rule engines short-circuit.
    func query(host: String = "probe.tun.local") -> Data {
        var d = Data()
        // Header (12 bytes). QR=0 (query), opcode=0, RD=1; QDCOUNT=1.
        d.append(UInt8(txID >> 8)); d.append(UInt8(txID & 0xff))
        d.append(0x01); d.append(0x00)   // flags: standard query, recursion desired
        d.append(0x00); d.append(0x01)   // QDCOUNT = 1
        d.append(0x00); d.append(0x00)   // ANCOUNT
        d.append(0x00); d.append(0x00)   // NSCOUNT
        d.append(0x00); d.append(0x00)   // ARCOUNT
        // Question: <labels> 0x00, type A (0x0001), class IN (0x0001).
        for label in host.split(separator: ".") {
            d.append(UInt8(label.utf8.count))
            d.append(contentsOf: label.utf8)
        }
        d.append(0x00)                   // terminator label
        d.append(0x00); d.append(0x01)   // type A
        d.append(0x00); d.append(0x01)   // class IN
        return d
    }

    /// Decide whether `response` is a valid DNS reply to *this* probe.
    ///
    /// The data-plane question is "could we round-trip a UDP datagram to the TUN
    /// gateway and back", not "did the name resolve". A server replying NXDOMAIN
    /// or SERVFAIL still proves the fd is alive — mihomo's dns-hijack answered.
    /// We therefore accept any response whose:
    ///   • length is at least the 12-byte header,
    ///   • QR bit is set (it is a response, not a stray query echo),
    ///   • transaction id matches the request.
    /// Returns `never` for empty/truncated packets so a timeout (no bytes at all)
    /// is not confused with a malformed-but-present reply.
    enum Outcome { case valid, never, malformed, mismatch }
    func validate(response: Data) -> Outcome {
        guard response.count >= 12 else { return response.isEmpty ? .never : .malformed }
        let rTx = (UInt16(response[0]) << 8) | UInt16(response[1])
        guard rTx == txID else { return .mismatch }
        // QR is the high bit of byte 2.
        let qr = (response[2] & 0x80) != 0
        guard qr else { return .malformed }
        return .valid
    }
}

/// Consecutive-failure counter with a short-window, in-task retry policy.
///
/// A single `probe(attempt:)` records one attempt's success/failure. It returns
/// true exactly when the *threshold* (default 3) failures have all been observed
/// *within a single probe cycle* — i.e. immediately after the third failure of a
/// cycle, before any intervening success. A success at any point resets the run,
/// so 2 failures + 1 success + 2 failures does NOT trigger; the data plane came
/// back. The threshold is intentionally met inside one short window (≈4–6 s),
/// not across three spaced 10-minute polls, so a genuine fd break is acted on in
/// seconds rather than tens of minutes.
struct TUNDataPlaneHealthState {
    private(set) var consecutiveFailures: Int = 0
    let threshold: Int

    init(threshold: Int = 3) { self.threshold = max(1, threshold) }

    /// Record one attempt. Returns true when recovery should fire (the threshold
    /// is met this very call), false otherwise. A success always resets the run.
    @discardableResult
    mutating func record(success: Bool) -> Bool {
        if success {
            consecutiveFailures = 0
            return false
        }
        consecutiveFailures += 1
        return consecutiveFailures >= threshold
    }

    /// Reset the counter to zero (e.g. after a completed recovery, on TUN being
    /// manually turned off, or on app exit).
    mutating func reset() { consecutiveFailures = 0 }
}
