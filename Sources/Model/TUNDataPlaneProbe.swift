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
//   2. `TUNDataPlaneHealthState` is the sliding-window failure counter: a
//      bad fd is an unreliable channel that can still answer the occasional
//      probe, so recovery fires when the failures accumulated over the last
//      `window` attempts reach `failThreshold` — never reset by an isolated
//      success the way the old consecutive run was. With the default 6-slot
//      window / 4-failure threshold and a ≈3 s per-cycle retry, a half-dead
//      fd that otherwise masquerades as healthy is caught inside ~10 s rather
//      than 20–30 minutes (the 10-minute poll cadence).

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

/// Sliding-window failure counter with a short-window, in-task retry policy.
///
/// A single `record(success:)` push enrolls one probe attempt into a ring that
/// keeps the last `window` outcomes. It returns true (recover now) exactly when
/// the failures accumulated inside that window reach `failThreshold`. A single
/// success no longer clears the window — a half-dead fd (macOS's remount leaves
/// the path open for writes but returns EBADF on every batch read) can still
/// round-trip the occasional probe, but that one good packet does not mean the
/// data plane is healthy: the flood of `bad file descriptor` continues because
/// the read goroutine is still busted. The sliding window treats the data plane
/// as an unreliable channel and lets the bad bursts accumulate across cycles
/// until the evidence is overwhelming, instead of being erased by an isolated
/// success the way the old `consecutiveFailures` counter was.
struct TUNDataPlaneHealthState {
    /// Outcomes of the last `window` probes, oldest-first. `true` = answered.
    private var window: [Bool] = []
    private let capacity: Int
    /// Recover once this many failures sit inside the window.
    private let failThreshold: Int

    /// Failures currently inside the window. Exposed for logging so the
    /// "N/threshold" message mirrors what actually drives the decision.
    private(set) var consecutiveFailures: Int = 0

    /// Historical alias kept for call-site logging; equals `failThreshold`.
    var threshold: Int { failThreshold }

    /// - Parameters:
    ///   - threshold: kept for source compatibility; mapped to `failThreshold`.
    ///   - window: ring-buffer capacity (default 6 — about two probe cycles).
    ///   - failThreshold: failures-in-window needed to trip recovery
    ///     (default 4 — tolerate up to 2 transient successes out of 6 while still
    ///     catching a half-dead fd within a few seconds of persistent bad reads).
    init(threshold: Int = 4, window: Int = 6, failThreshold: Int? = nil) {
        self.capacity = max(2, window)
        self.failThreshold = max(1, failThreshold ?? max(1, threshold))
    }

    /// Record one attempt into the ring and return whether the window's failure
    /// count just crossed `failThreshold` — `true` means recover now.
    ///
    /// A success is recorded (so it dilutes the failure ratio as the window
    /// slides) but it never clears the window by itself: a half-dead fd is
    /// exactly the case where one good packet should not cancel an ongoing bad
    /// burst. The caller clears the window with `reset()` after a completed
    /// recovery, or once a full probe cycle comes back unambiguously healthy.
    @discardableResult
    mutating func record(success: Bool) -> Bool {
        window.append(success)
        if window.count > capacity { window.removeFirst() }
        // Recompute the in-window failure count after every push so the
        // log-facing `consecutiveFailures` stays accurate; a stale failure
        // dropping off the ring must be correctly subtracted.
        consecutiveFailures = window.filter { !$0 }.count
        // Only a failure can trip recovery: a healthy probe — even one landing
        // on a window that already holds the threshold worth of failures —
        // must not re-announce the same fault. Recovery fires once, on the
        // attempt that pushes the count across the line.
        guard !success else { return false }
        // Trip only on the moment the window's failures first reach the
        // threshold; once we are *at* it, subsequent failures keep the count
        // at/around the threshold but the orchestrator has already acted, so
        // don't re-trip. (It clears the window on completed recovery.)
        return consecutiveFailures == failThreshold
    }

    /// True when the window is full and every entry is a success. The
    /// orchestrator uses this to decide the data plane is unambiguously healthy
    /// and the ring should be cleared, so an earlier bad burst cannot keep
    /// dragging the decision once the fd is genuinely restored.
    var allHealthy: Bool {
        !window.isEmpty && window.count == capacity && window.allSatisfy { $0 }
    }

    /// Reset the window to empty (e.g. after a completed recovery, on TUN being
    /// manually turned off, or after a full healthy cycle).
    mutating func reset() {
        window.removeAll(keepingCapacity: true)
        consecutiveFailures = 0
    }
}
