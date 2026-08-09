import Foundation

/// Decision logic for the App memory guard, isolated from `AppModel` so it can
/// be exercised without a kernel, a window, or a live connection stream.
///
/// The guard's *effect* (how far RSS actually falls) is only observable at
/// runtime, but its *decision* — whether to act at all, and how aggressively —
/// is pure arithmetic over four inputs. Keeping it here is what makes the part
/// that historically went wrong testable: v1.1.15 and earlier shipped a guard
/// whose threshold sat above the footprint it was supposed to catch, so it
/// never once ran, and nothing in the build could have noticed.
///
/// See `AppModel.enforceAppMemoryGuard()` for the side-effecting half.
struct AppMemoryGuardPolicy {
    /// Below this, caches are left alone.
    ///
    /// Deliberately under the ~350 MB plateau reported from the field and above
    /// a healthy idle footprint (~80–150 MB): a guard that only trips past the
    /// plateau is indistinguishable from no guard.
    var softLimit: UInt64 = 250 * 1_000_000
    /// At or above this, release everything regardless of what is on screen.
    var hardLimit: UInt64 = 400 * 1_000_000
    /// Minimum spacing between two actions. The guard is called from paths that
    /// tick at 1.5 s / 3 s; without this it would thrash caches several times a
    /// second whenever RSS settles just above `softLimit`.
    var interval: TimeInterval = 15

    enum Action: Equatable {
        /// Under the threshold, or rate-limited. Nothing is touched.
        case skip
        /// Shed closed-connection history and truncate live rows to
        /// `keepRows`, leaving the table the user is looking at populated.
        case soft(keepRows: Int)
        /// Release the connection caches. `includingBookkeeping` additionally
        /// drops the diffing state (`prevConnBytes` / `activeConnsSet`), which
        /// is only safe when nothing on screen can go blank.
        case hard(includingBookkeeping: Bool)
    }

    /// How many of the busiest rows a soft trim keeps.
    var softKeepRows = 300

    /// Decide what the guard should do.
    ///
    /// - Parameters:
    ///   - rss: current resident footprint in bytes.
    ///   - uiVisible: main window or menu-bar popover is on screen.
    ///   - now: current time.
    ///   - lastRun: when the guard last *acted*; `.distantPast` if never.
    func decide(rss: UInt64, uiVisible: Bool, now: Date, lastRun: Date) -> Action {
        // Rate limit first: it is cheaper than reading RSS is worth re-checking,
        // and it must apply to every tier equally, otherwise a footprint parked
        // just above `hardLimit` would clear caches on every single tick.
        guard now.timeIntervalSince(lastRun) >= interval else { return .skip }
        guard rss > softLimit else { return .skip }

        // Nothing visible means nothing can flicker, so there is no reason to be
        // gentle — and the bookkeeping dictionaries are pure overhead until the
        // window comes back.
        if !uiVisible { return .hard(includingBookkeeping: true) }
        if rss > hardLimit { return .hard(includingBookkeeping: false) }
        return .soft(keepRows: softKeepRows)
    }
}
