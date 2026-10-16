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
//   1. `DNSProbe` builds a minimal UDP DNS query and decides whether a reply
//      proves the resolution path works: a well-formed response to *this* query
//      with RCODE=NOERROR. NXDOMAIN/SERVFAIL do NOT count — see `validate` for
//      the live measurement showing a SERVFAIL flood is what a total DNS outage
//      looks like, not what health looks like. Only a real, answered lookup
//      proves the fd and mihomo's DNS path are both working.
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
    /// Hostname used by the data-plane probe.
    ///
    /// **Do not use a `*.local` name here.** This machine's `config.yaml`
    /// fake-ip-filter contains `"+.local"` (alongside `+.lan`, `+.home`,
    /// `+.ts.net`, the Apple/MiWiFi lists), so a `.local` probe host is
    /// deliberately *excluded from fake-ip* and would be resolved against real
    /// upstream DNS. That makes the probe's outcome depend on upstream
    /// reachability and on which proxy policy the name happens to match —
    /// neither of which is the question the probe is asking. It would report
    /// "dead" for reasons unrelated to the tunnel.
    ///
    /// A name that *is* covered by fake-ip is answered by mihomo itself, from
    /// local state, with NOERROR — exactly the "resolution path works" signal
    /// the RCODE gate wants. `probe.dsh.invalid` is under the default fake-ip
    /// range (198.18.0.0/15) and is not in any filter list, so mihomo assigns
    /// it a fake IP without ever consulting upstream. `.invalid` is also
    /// RFC 2606 reserved, so it can never collide with a real domain.
    static let probeHost = "probe.dsh.invalid"

    func query(host: String = DNSProbe.probeHost) -> Data {
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
    /// **The accept-NXDOMAIN/SERVFAIL rule was wrong, and it hid a live outage.**
    /// The original reasoning — "the question is 'could we round-trip a datagram',
    /// not 'did the name resolve', so mihomo's dns-hijack answering proves the fd
    /// is alive" — rests on the hijack answering *only* when the tunnel works.
    /// Measured live on this machine with TUN up, the hijack answers from inside
    /// mihomo itself even when its `dns` section is absent and every lookup fails:
    ///
    ///     dns = null   (kernel API)
    ///     dig @198.18.0.1 www.baidu.com → status: SERVFAIL
    ///     dig @198.18.0.0 www.baidu.com → status: SERVFAIL
    ///     nslookup www.baidu.com        → ** server can't find ...: SERVFAIL
    ///
    /// so SERVFAIL means the *opposite* of alive: the query reached mihomo and
    /// mihomo could not resolve it. Treating that as healthy let the probe report
    /// green through a total system DNS blackout — the same class of false-healthy
    /// as the 1400-round incident, one layer deeper.
    ///
    /// The predicate is therefore: a reply counts only when it is a malformed-free
    /// response to *this* query **and** its RCODE shows the resolver actually
    /// answered the question. `NOERROR` is the only RCODE that means "the name
    /// resolution path worked"; `NXDOMAIN` is deliberately *not* accepted either,
    /// because mihomo returns SERVFAIL — not NXDOMAIN — for a name it cannot
    /// resolve, and accepting NXDOMAIN would re-open the same hole for a probe
    /// host that a rule engine blackholes. The probe host is chosen to exist for
    /// exactly this reason (`DNSProbe.probeHost` is covered by mihomo's fake-ip
    /// filter, so NOERROR is expected whenever the path is healthy).
    ///
    /// Accepts only responses whose:
    ///   • length is at least the 12-byte header,
    ///   • QR bit is set (it is a response, not a stray query echo),
    ///   • transaction id matches the request,
    ///   • RCODE is NOERROR (0).
    /// Returns `never` for empty/truncated packets so a timeout (no bytes at all)
    /// is not confused with a malformed-but-present reply.
    enum Outcome { case valid, never, malformed, mismatch, refused }
    func validate(response: Data) -> Outcome {
        guard response.count >= 12 else { return response.isEmpty ? .never : .malformed }
        let rTx = (UInt16(response[0]) << 8) | UInt16(response[1])
        guard rTx == txID else { return .mismatch }
        // QR is the high bit of byte 2.
        let qr = (response[2] & 0x80) != 0
        guard qr else { return .malformed }
        // RCODE is the low nibble of byte 3. Only NOERROR proves the resolver
        // path worked; SERVFAIL (2) is the live-outage signature.
        let rcode = response[3] & 0x0f
        guard rcode == 0 else { return .refused }
        return .valid
    }
}

/// Decides whether a probe reply is admissible as evidence that **our** tunnel
/// is alive — as opposed to *any* resolver on the machine answering.
///
/// The probe used to send to the fake-ip gateway over the default route and
/// accept any well-formed reply with a matching transaction id. That made the
/// check unfalsifiable on exactly the failure it exists to catch, and the log
/// proves it: 1400 consecutive rounds of
///
///     TUN 数据面探测 1/1: DNS gateway 198.18.0.0 应答
///
/// while the address being probed was `198.18.0.0/30`'s **network address** —
/// a value no host owns, which the kernel drops. Nothing in the tunnel had to
/// work for that line to be printed: mihomo's `dns-hijack` (`any:53`) answers
/// whatever lands on it, and a probe that only checks "did bytes come back from
/// somewhere" cannot tell the hijacked path from a dead fd. The probe then
/// short-circuits (`firstOK == true`) and the data-plane health window never
/// sees a failure — so the 30 s / 10 min health passes all reported green while
/// the interface was unusable.
///
/// Identity, not liveness, is therefore the missing predicate. A reply only
/// counts when it can be attributed to the interface we believe is carrying the
/// tunnel.
///
/// **Why attribution is by address and not by interface index.** The obvious
/// mechanism — `IP_RECVIF`, "tell me which device this datagram arrived on" — is
/// broken on macOS for UDP: measured on this machine through the documented C
/// macros (`CMSG_FIRSTHDR` / `CMSG_DATA`), a reply that demonstrably arrived on
/// `en0` (index 7) is reported as index `463380`, which is not a device at all,
/// and it returns the same garbage regardless of interface. Comparing it would
/// therefore reject every genuine reply and the probe would fail closed forever.
/// `IP_RECVDSTADDR` does work: on the same socket it correctly reported the local
/// address the datagram landed on (`172.16.10.57`, `en0`'s own address), and that
/// is the signal this gate is built on.
///
/// So the probe pins egress with `IP_BOUND_IF`, reads the reply's destination
/// address with `IP_RECVDSTADDR`, and admits the reply only when that address is
/// the bound interface's own address — the caller resolves the address from the
/// device, and the kernel's own report must match it. A packet that took the
/// physical link lands on a physical address and is rejected even though it is a
/// perfectly well-formed DNS answer.
///
/// Verdicts:
///   * **address matches the bound device** → admissible. The datagram landed on
///     an address owned by the interface we pinned, so it traversed that device.
///   * **address known but owned by another interface** → rejected. This is the
///     case that used to be silently accepted: a hijack answer arriving on the
///     physical NIC, or a peer tunnel's resolver.
///   * **address unreported** → rejected, because the datagram could not be
///     attributed at all. Rejecting is the safe direction: a false "dead" costs
///     one wasted self-heal cycle, a false "alive" hides the blackhole the whole
///     mechanism exists to find.
///
/// Kept pure (no sockets) so the rule is unit-testable and cannot drift from
/// what the shipping probe enforces.
enum TUNProbeReplyGate {

    /// - Parameters:
    ///   - boundAddress: the local address of the interface the probe socket was
    ///     pinned to with `IP_BOUND_IF`; `nil` when the caller could not resolve
    ///     one (then nothing can be attributed and the probe must not run).
    ///   - replyDestination: the address the kernel reports the reply landed on
    ///     (`IP_RECVDSTADDR`). `nil` means the reply carried no such report.
    enum Verdict: Equatable {
        case admissible
        /// Reply landed on an address the pinned interface does not own.
        case wrongAddress(expected: String, actual: String)
        /// Reply carried no destination report — never counts.
        case unattributed
        /// The probe was not pinned to an interface address, so every reply is
        /// inadmissible: the caller must resolve the address before probing.
        case notPinned
    }

    static func verdict(boundAddress: String?,
                        replyDestination: String?) -> Verdict {
        guard let bound = boundAddress, !bound.isEmpty else { return .notPinned }
        guard let actual = replyDestination, !actual.isEmpty else { return .unattributed }
        // Compared exactly: two different local addresses are two different
        // devices, and "close enough" has no meaning for an identity check.
        return actual == bound ? .admissible : .wrongAddress(expected: bound, actual: actual)
    }

    static func admits(boundAddress: String?, replyDestination: String?) -> Bool {
        verdict(boundAddress: boundAddress, replyDestination: replyDestination) == .admissible
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

    /// 交替形态闩锁：threshold-1 补触发对当前窗口只生效一次，reset() 解除
    /// （见 record() 的交替触发注释）。
    private var alternateTripLatch = false

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
        if consecutiveFailures == failThreshold { return true }
        // 交替形态触发（2026-10-14 审查中-10 修复）：半死 fd 的另一种形态是
        // 严格 F/S 交替——窗口失败数永远在 failThreshold-1 上震荡（6 窗 3 失），
        // 主条件永不满足、allHealthy 也永不成立，状态机卡死在「不触发也不
        // 清零」，这正是 v1.1.13 滑动窗口设计时漏掉的实测盲区。补判据：
        // 满窗 + 失败数达 threshold-1 + 本条是失败。闩锁保证同一窗口只触发
        // 一次（交替形态下否则每隔一条失败就重复触发、反复拉起 recovery），
        // reset() 时解除——与主条件「触发后由编排方清窗」的契约一致。
        // 健康形态零误报：满窗最多 1~2 次偶发失败到不了 threshold-1。
        if !alternateTripLatch, window.count == capacity,
           consecutiveFailures == failThreshold - 1 {
            alternateTripLatch = true
            return true
        }
        return false
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
        alternateTripLatch = false
    }
}
