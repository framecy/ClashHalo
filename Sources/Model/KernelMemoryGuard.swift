import Foundation

// MARK: - Stale connection watch
//
// 2026-09-28 field capture, after six days of uptime behind a closed lid:
// the kernel held 1412 connections. 1039 of them were TCP, older than twelve
// hours, and between them had moved **1.2 MB** in total — 897 belonged to a
// single Electron process. Real RSS 426 MB against the 145 MB the same kernel
// sits at with ~100 connections. Those sockets are corpses: the lid closed,
// the peer and every NAT state along the path expired, no FIN or RST ever
// arrived, and `disable-keep-alive: true` — the 设置页「禁用 Keep-Alive」开关,
// written into config.yaml by `patchPersistent`, not a subscription default —
// means nothing probes them. mihomo has no idle timeout for proxied TCP — a
// connection leaves the table only when a side closes it — so each corpse
// pins its copy buffers for the rest of the kernel's life.
//
// Closing everything on wake (`DELETE /connections`) would fix the number and
// break the user: an idle-but-live SSH session, an IM push socket, a download
// resuming after the lid opens are all silent by nature and all alive. So the
// rule is deliberately two-track, and both tracks require the socket to have
// stopped *moving*, not merely to be quiet:
//
//   1. **Armed** — a real interruption happened (wake, or offline → online),
//      and this connection predates it and has stayed frozen for
//      `armedSilent` since. A socket that is merely idle still breathes:
//      keepalives, HPACK pings and push heartbeats all move bytes well inside
//      two hours, so anything that survived the interruption by staying silent
//      was already dead when the network broke.
//   2. **Ungated** — `alwaysSilent` (default twelve hours) with no
//      interruption at all. No long-lived protocol that is actually alive
//      goes twelve hours without a single byte in either direction; this
//      track exists for a machine that never sleeps and leaks anyway.
//
// TCP only: mihomo ages UDP associations out on its own, and a silent UDP
// "corpse" is a normal QUIC idle, not a stuck socket.
//
// Pure arithmetic over timestamps and byte counters — no UI, no process
// management, no MainActor — so the whole decision is exercisable without a
// kernel (see `Tests/KernelMemoryGuard`).

struct StaleConnectionWatch {
    struct Row: Equatable {
        var firstSeen: Date
        var lastGrowth: Date
        var bytes: Int64
        var tcp: Bool
    }

    /// Silence that condemns a connection when an interruption armed the watch.
    ///
    /// Two hours, not thirty minutes: an armed-track verdict has to clear the
    /// slowest application-layer keepalive that a *live* socket may legally run.
    /// HTTP/2 pings are seconds to minutes, SSH keepalive ≤ 5 min, IMAP IDLE is
    /// re-sent at ~29 min, APNs and mobile TCP keepalive at ~20–30 min, MQTT
    /// above an hour is already non-conformant. Two hours with not one byte in
    /// either direction, across a network that has since broken and come back,
    /// is not an idle socket — it is a corpse. Calibrating this tighter is what
    /// would turn a memory reclaim into a dropped push channel.
    var armedSilent: TimeInterval = 2 * 3600
    /// How long after the arming event the armed track may act. Sockets that
    /// are alive but were mid-flight when the network broke reconnect inside
    /// this window; condemning them at t=0 would race the apps' own retry.
    var armedGrace: TimeInterval = 5 * 60
    /// Silence that condemns a connection with no interruption at all.
    var alwaysSilent: TimeInterval = 12 * 3600

    // No separate minimum-age floor: `lastGrowth` starts at first sight, so
    // silence is always ≤ age and both tracks above already demand far more
    // silence than any plausible age threshold would.

    private(set) var rows: [String: Row] = [:]

    /// Instant of the most recent interruption, or nil while the armed track
    /// is disarmed.
    private(set) var armedAt: Date?

    /// Feed one connection from one snapshot. `bytes` is the connection's
    /// monotonic upload+download total.
    mutating func observe(id: String, bytes: Int64, tcp: Bool, now: Date) {
        guard let row = rows[id] else {
            rows[id] = Row(firstSeen: now, lastGrowth: now, bytes: bytes, tcp: tcp)
            return
        }
        if bytes != row.bytes {
            rows[id] = Row(firstSeen: row.firstSeen, lastGrowth: now,
                           bytes: bytes, tcp: tcp)
        } else if tcp != row.tcp {
            // Same id with a different protocol is a decoder surprise, not a
            // real transition; trust the newer reading and keep the clock.
            rows[id] = Row(firstSeen: row.firstSeen, lastGrowth: row.lastGrowth,
                           bytes: bytes, tcp: tcp)
        }
    }

    /// Drop connections that left the table. Bounds `rows` to the live set,
    /// which is why there is no size cap here: pruning by size would reset a
    /// corpse's silence clock and make exactly the connections this exists for
    /// immortal.
    mutating func reap(excluding liveIDs: Set<String>) {
        guard !rows.isEmpty else { return }
        rows = rows.filter { liveIDs.contains($0.key) }
    }

    /// Record that the network was interrupted. Called from wake and from the
    /// offline → online transition. Stays armed for the rest of the session:
    /// the last interruption is the one that can have killed these sockets.
    mutating func arm(now: Date) { armedAt = now }

    /// Connections condemned by the rules above, longest-silent first so a
    /// bounded batch closes the worst offenders rather than an arbitrary slice.
    func candidates(now: Date) -> [String] {
        guard !rows.isEmpty else { return [] }
        let armed = armedAt
        var doomed: [(id: String, lastGrowth: Date)] = []
        for (id, row) in rows {
            guard row.tcp else { continue }
            let silent = now.timeIntervalSince(row.lastGrowth)
            let ungated = silent >= alwaysSilent
            let byArm: Bool
            if let a = armed {
                byArm = silent >= armedSilent
                    && now >= a.addingTimeInterval(armedGrace)
                    && row.firstSeen <= a
            } else {
                byArm = false
            }
            if ungated || byArm { doomed.append((id, row.lastGrowth)) }
        }
        return doomed.sorted { $0.lastGrowth < $1.lastGrowth }.map(\.id)
    }

    /// Forget rows about to be closed, so a snapshot that still lists them
    /// cannot propose them twice.
    mutating func forget(_ ids: some Sequence<String>) {
        for id in ids { rows[id] = nil }
    }

    var trackedCount: Int { rows.count }
}

// MARK: - Kernel memory guard policy
//
// The guard that preceded this one compared mihomo's **connection memory
// accounting** against 512 MB and, when it finally tripped, flushed the DNS
// and fake-ip caches. Both halves were wrong. The number is not memory:
// `/memory`'s `inuse` and `/connections`' `memory` field are byte-identical
// to each other (446,267,392 on both, 2026-09-28) and were frozen at exactly
// 363,905,024 across all 1415 samples of a two-hour capture while `ps`
// measured the kernel at 148 MB — a high-water counter, not a footprint. And
// the caches it flushed are not where the bytes were: the memory sat in the
// 1039 dead sockets that no cache flush touches. So it never once fired on the
// way to 426 MB, and had it fired it would have freed nothing.
//
// This policy reads **real RSS** (`KernelRSS`) and acts on connections first.
// Tiering, rate limiting and the give-up/re-arm cycle follow
// `AppMemoryGuardPolicy`, which earned that shape by firing 463 times in two
// hours against a metric it could not move.
//
// Deliberately absent: an automatic kernel restart. It is the one action that
// reliably frees the memory and the one the user would feel — a full profile
// reload, TUN teardown, every connection dropped. When reaping and flushing
// both fail to move RSS the guard suspends and says so, and the restart stays
// a human decision.
struct KernelMemoryGuardPolicy {
    /// Reap stale connections at or above this RSS.
    ///
    /// Calibrated against the two kernel measurements on record: 145 MB with
    /// ~100 connections (2026-09-16) and 426 MB with 1412 (2026-09-28). 320 MB
    /// is ~2.2× the healthy working set, and the action is cheap and selective
    /// — it can only close sockets the watch already condemned.
    var reapLimit: UInt64 = 320_000_000
    /// Additionally flush DNS + fake-ip caches.
    var flushLimit: UInt64 = 448_000_000
    /// Minimum spacing between actions. Reaping is driven by a snapshot loop
    /// that runs every 1.5 s in the foreground.
    var interval: TimeInterval = 300
    /// RSS fall required for an action to count as having achieved something.
    var effectiveDrop: UInt64 = 20_000_000
    /// Consecutive ineffective actions before suspending.
    var ineffectiveLimit = 3
    /// Growth past the suspension point that re-arms the guard.
    var reArmGrowth: UInt64 = 64_000_000

    struct State: Equatable {
        var lastRun: Date = .distantPast
        var rssBeforeLastAction: UInt64 = 0
        var ineffectiveStreak: Int = 0
        var suspendedAt: UInt64?

        var isSuspended: Bool { suspendedAt != nil }
        init() {}
    }

    enum Action: Equatable {
        case skip
        /// Close stale connections only.
        case reap
        /// Close stale connections, then flush the resolver caches.
        case reapAndFlush
    }

    enum Transition: Equatable {
        case none
        case engaged
        case suspended(afterActions: Int)
        case reArmed
        case recovered
    }

    struct Decision: Equatable {
        var action: Action
        var transition: Transition
    }

    func decide(rss: UInt64, now: Date, state: inout State) -> Decision {
        guard now.timeIntervalSince(state.lastRun) >= interval else {
            return Decision(action: .skip, transition: .none)
        }

        // Settle the previous action's verdict here, so a rate-limited tick
        // cannot inflate the streak. Subtraction on `before`, not `rss + drop`,
        // so a pathological RSS cannot overflow.
        if state.rssBeforeLastAction > 0 {
            let before = state.rssBeforeLastAction
            let target = before > effectiveDrop ? before - effectiveDrop : 0
            if rss <= target {
                state.ineffectiveStreak = 0
            } else {
                state.ineffectiveStreak += 1
            }
            state.rssBeforeLastAction = 0
        }

        guard rss > reapLimit else {
            let wasEngaged = state.ineffectiveStreak > 0 || state.isSuspended
            state.ineffectiveStreak = 0
            state.suspendedAt = nil
            return Decision(action: .skip, transition: wasEngaged ? .recovered : .none)
        }

        if let suspended = state.suspendedAt {
            let grewEnough = rss > suspended && rss - suspended > reArmGrowth
            guard grewEnough else {
                return Decision(action: .skip, transition: .none)
            }
            state.suspendedAt = nil
            state.ineffectiveStreak = 0
            state.lastRun = now
            state.rssBeforeLastAction = rss
            return Decision(action: tier(rss: rss), transition: .reArmed)
        }

        if state.ineffectiveStreak >= ineffectiveLimit {
            state.suspendedAt = rss
            return Decision(action: .skip,
                            transition: .suspended(afterActions: state.ineffectiveStreak))
        }

        let engaging = state.ineffectiveStreak == 0
        state.lastRun = now
        state.rssBeforeLastAction = rss
        return Decision(action: tier(rss: rss), transition: engaging ? .engaged : .none)
    }

    private func tier(rss: UInt64) -> Action {
        rss >= flushLimit ? .reapAndFlush : .reap
    }
}
