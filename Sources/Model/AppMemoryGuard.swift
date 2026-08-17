import Foundation

/// Decision logic for the App memory guard, isolated from `AppModel` so it can
/// be exercised without a kernel, a window, or a live connection stream.
///
/// The guard's *effect* (how far the footprint actually falls) is only
/// observable at runtime, but its *decision* — whether to act at all, how
/// aggressively, and when to stop trying — is pure arithmetic over its inputs.
/// Keeping it here is what makes the part that historically went wrong
/// testable. It has now gone wrong twice, in opposite directions:
///
///  * **v1.1.15 and earlier** shipped a guard whose threshold sat *above* the
///    footprint it was supposed to catch, so it never once ran.
///  * **v1.1.16** fixed the threshold but calibrated it against the wrong
///    metric: the doc claimed a "healthy idle footprint (~80–150 MB)", which is
///    an *RSS* figure, while `AppModel.residentMemoryBytes()` actually reported
///    `phys_footprint` — the Mach "memory footprint" that also counts
///    compressed pages. A 2-hour field capture measured a 309–317 MB idle
///    footprint against a 250 MB soft limit, so the guard tripped **463 times
///    in 2 hours** (once every 15 s, from launch to shutdown) and never once
///    brought the number down: the bulk of that footprint is not in the
///    connection caches the guard can shed. **This has now been fixed at the
///    source**: `residentMemoryBytes()` was switched from `phys_footprint` to
///    `task_basic_info.resident_size` (BSD RSS), and thresholds recalibrated
///    to RSS scale (soft=150 MB / hard=250 MB, matching the ~87–94 MB idle RSS
///    and ~130–150 MB active-use RSS measured in the field).
///
/// A guard that fires forever without effect is not a safety net — it is a
/// 15-second cache-thrash loop plus 463 lines of log noise. So the policy now
/// also decides **when to give up**, mirroring the bounded-retry shape already
/// used for gateway DNS self-heal: act a few times, and if the footprint does
/// not actually move, suspend and stay quiet until the footprint climbs enough
/// to indicate genuinely new growth worth acting on.
///
/// See `AppModel.enforceAppMemoryGuard()` for the side-effecting half.
struct AppMemoryGuardPolicy {
    /// Below this, caches are left alone.
    ///
    /// Compared against **RSS** (`mach_task_basic_info.resident_size`), the same
    /// number `ps -o rss` and Activity Monitor report.
    ///
    /// Calibrated from a 2-hour capture of 589 samples, which is what makes
    /// this number trustworthy rather than a guess: RSS started at 123 MB,
    /// climbed to a **plateau of 145.1–145.8 MB, and stayed there for the last
    /// 90 minutes** (p50 145.2, p99 145.8, max 145.8 — a flat line, no leak).
    /// A fresh launch sits near 90 MB.
    ///
    /// So ~146 MB is this app's *steady state* with no system proxy, not its
    /// peak. With system proxy on and active connections flowing, RSS
    /// legitimately reaches 220–235 MB — that is not a leak, it is the cost
    /// of rendering live connection data. The soft limit must clear that
    /// *active-use* ceiling, not just the idle plateau, or the guard trips
    /// during perfectly normal proxy operation — which is the same failure
    /// the `phys_footprint` mix-up caused, merely at a smaller amplitude.
    /// 260 MB is ~1.8× the idle plateau and ~1.1× the active-use ceiling,
    /// leaving headroom for connection spikes while still catching genuine
    /// runaway growth.
    var softLimit: UInt64 = 260 * 1_000_000
    /// At or above this, release everything regardless of what is on screen.
    ///
    /// ~2.6× the measured idle plateau: at this point something is genuinely wrong,
    /// and dropping the diffing bookkeeping (one blank tick of rates) is a
    /// cheaper price than continued growth.
    var hardLimit: UInt64 = 380 * 1_000_000
    /// Minimum spacing between two actions. The guard is called from paths that
    /// tick at 1.5 s / 3 s; without this it would thrash caches several times a
    /// second whenever the footprint settles just above `softLimit`.
    var interval: TimeInterval = 15

    /// How many of the busiest rows a soft trim keeps.
    var softKeepRows = 300

    /// How much the footprint must actually fall for an action to count as
    /// having achieved something. Anything smaller is noise — the footprint
    /// wanders by a few MB on its own between two samples.
    var effectiveDrop: UInt64 = 10 * 1_000_000

    /// Consecutive ineffective actions tolerated before the guard suspends
    /// itself. Small on purpose: if shedding every closed connection and all
    /// but 300 live rows three times in a row does not move the number, the
    /// memory is not in those caches and repeating the same work cannot help.
    var ineffectiveLimit = 3

    /// How far above the suspend-time footprint the process must climb before
    /// the guard re-arms. This is the safety net that keeps a real leak from
    /// hiding behind the backoff: growth of this size is new memory the guard
    /// has never tried to reclaim, so it deserves another attempt.
    var reArmGrowth: UInt64 = 50 * 1_000_000

    enum Action: Equatable {
        /// Under the threshold, rate-limited, or suspended. Nothing is touched.
        case skip
        /// Shed closed-connection history and truncate live rows to
        /// `keepRows`, leaving the table the user is looking at populated.
        case soft(keepRows: Int)
        /// Release the connection caches. `includingBookkeeping` additionally
        /// drops the diffing state (`prevConnBytes` / `activeConnsSet`), which
        /// is only safe when nothing on screen can go blank.
        case hard(includingBookkeeping: Bool)
    }

    /// Everything the guard must remember between calls.
    ///
    /// Kept as plain data next to the policy — like `TUNDataPlaneHealthState`
    /// — so the whole give-up/re-arm cycle can be driven in a test without a
    /// process to measure.
    struct State: Equatable {
        /// When the guard last actually acted.
        var lastRun: Date = .distantPast
        /// RSS sampled immediately before the last action, awaiting its
        /// effectiveness verdict on the next evaluation. Zero when there is no
        /// verdict outstanding.
        var rssBeforeLastAction: UInt64 = 0
        /// Consecutive actions that failed to move RSS.
        var ineffectiveStreak: Int = 0
        /// RSS at the moment the guard gave up; `nil` while armed.
        var suspendedAt: UInt64?

        /// True while the guard has stopped acting because acting did nothing.
        var isSuspended: Bool { suspendedAt != nil }

        init() {}
    }

    /// What just happened, for the caller to log on *transitions only*.
    ///
    /// The v1.1.16 guard logged one line per action, which is how a silent
    /// no-op loop turned into 463 identical log lines in a single evening.
    enum Transition: Equatable {
        /// Nothing worth saying.
        case none
        /// First action after being healthy or re-armed.
        case engaged
        /// Giving up: repeated actions did not move RSS.
        case suspended(afterActions: Int)
        /// RSS climbed far enough past the give-up point to try again.
        case reArmed
        /// RSS came back under the soft limit on its own.
        case recovered
    }

    struct Decision: Equatable {
        var action: Action
        var transition: Transition
    }

    /// Decide what the guard should do, advancing `state`.
    ///
    /// - Parameters:
    ///   - rss: current resident set size in bytes, as returned by
    ///     `AppModel.residentMemoryBytes()`. Must be RSS, not `phys_footprint`
    ///     — every threshold here is calibrated against RSS, and feeding the
    ///     footprint instead is exactly the v1.1.16 bug.
    ///   - uiVisible: main window or menu-bar popover is on screen.
    ///   - now: current time.
    ///   - state: guard bookkeeping, updated in place.
    func decide(rss: UInt64,
                uiVisible: Bool,
                now: Date,
                state: inout State) -> Decision {
        // Rate limit first: it is cheaper than anything below, and it must
        // apply to every tier equally, otherwise an RSS parked just above
        // `hardLimit` would clear caches on every single tick. Everything past
        // this point is a genuine re-evaluation, which is also what makes it
        // the right place to settle the previous action's verdict.
        guard now.timeIntervalSince(state.lastRun) >= interval else {
            return Decision(action: .skip, transition: .none)
        }

        // Did the previous action achieve anything? Settled exactly once per
        // action, here, so a rate-limited tick cannot inflate the streak.
        if state.rssBeforeLastAction > 0 {
            let before = state.rssBeforeLastAction
            // Written as a subtraction on `before` rather than `rss + drop` so
            // a pathological RSS cannot overflow the addition.
            let target = before > effectiveDrop ? before - effectiveDrop : 0
            if rss <= target {
                state.ineffectiveStreak = 0
            } else {
                state.ineffectiveStreak += 1
            }
            state.rssBeforeLastAction = 0
        }

        // Healthy again: forget the whole episode, including a suspension.
        // Dropping back under the soft limit is the one unambiguous signal
        // that whatever was holding memory is gone.
        guard rss > softLimit else {
            let wasEngaged = state.ineffectiveStreak > 0 || state.isSuspended
            state.ineffectiveStreak = 0
            state.suspendedAt = nil
            return Decision(action: .skip,
                            transition: wasEngaged ? .recovered : .none)
        }

        // Suspended: only genuinely new growth re-arms the guard.
        if let suspended = state.suspendedAt {
            // `suspended &+ reArmGrowth` would wrap on a pathological value and
            // silently re-arm forever; compare on the difference instead.
            let grewEnough = rss > suspended && rss - suspended > reArmGrowth
            guard grewEnough else {
                return Decision(action: .skip, transition: .none)
            }
            state.suspendedAt = nil
            state.ineffectiveStreak = 0
            state.lastRun = now
            state.rssBeforeLastAction = rss
            return Decision(action: tier(rss: rss, uiVisible: uiVisible),
                            transition: .reArmed)
        }

        // Repeated actions did nothing — stop, and say so once.
        if state.ineffectiveStreak >= ineffectiveLimit {
            state.suspendedAt = rss
            return Decision(action: .skip,
                            transition: .suspended(afterActions: state.ineffectiveStreak))
        }

        let engaging = state.ineffectiveStreak == 0
        state.lastRun = now
        state.rssBeforeLastAction = rss
        return Decision(action: tier(rss: rss, uiVisible: uiVisible),
                        transition: engaging ? .engaged : .none)
    }

    /// Which tier to apply once we have decided to act at all.
    private func tier(rss: UInt64, uiVisible: Bool) -> Action {
        // Nothing visible means nothing can flicker, so there is no reason to
        // be gentle — and the bookkeeping dictionaries are pure overhead until
        // the window comes back.
        if !uiVisible { return .hard(includingBookkeeping: true) }
        if rss > hardLimit { return .hard(includingBookkeeping: false) }
        return .soft(keepRows: softKeepRows)
    }
}
