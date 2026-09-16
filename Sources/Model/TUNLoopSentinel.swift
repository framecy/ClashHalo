import Foundation

// MARK: - TUN self-loop sentinel
//
// 2026-09-16 field capture: the kernel showed ONE UDP connection
// (`dataaccessd → p119-caldav.icloud.com`, chains ["DIRECT","苹果服务"])
// whose `download` counter had grown past 10.8 TB while `upload` sat at
// exactly zero, the physical NIC counters stood still, and a *disabled*
// TUN (`tun.enable: false`) was still UP with 211 auto-route splits in the
// table. The tunnel kept re-injecting its own DIRECT output as "server
// downlink", and every lap added the same bytes to the same connection —
// ~104 MB/s of traffic that never touched a wire.
//
// The fingerprint (all four must hold, per connection, per snapshot tick):
//
//   1. the chain resolves to DIRECT — a proxied flow talks to its node and
//      the kernel's own accounting would show the upstream leg;
//   2. total upload is near-zero — real traffic, even push-heavy QUIC,
//      acknowledges; 10 TB in with 0 out is physically impossible;
//   3. download advances by a big chunk every tick (default ≥ 25 MB/tick);
//   4. that persists for consecutive ticks — a single fat tick is a burst,
//      six of them with a frozen upload is a loop.
//
// The sentinel only *proposes* recovery: `handleTUNLoopTrip` confirms by
// resolving the destination through `route -n get` — the loop is proven
// when the destination of a supposedly-direct connection re-enters our
// tunnel. Like `TUNDataPlaneProbe`: no UI, no process management, no
// MainActor — `recordHistoryOnly` drives it from the per-connection diff
// loop it already runs.

struct TUNLoopTrip: Equatable {
    let connID: String
    let host: String
    let destinationIP: String
    /// Phantom bytes attributed to this connection while watching.
    let phantomBytes: Int64
    let ticks: Int
}

struct TUNLoopSentinel {
    /// Bytes of download growth that count as a "fat" tick.
    var minTickDownBytes: Int64 = 25_000_000
    /// Ceiling for the connection's TOTAL upload — the client side of a
    /// looping connection is silent by definition.
    var maxSilentUploadBytes: Int64 = 2_000_000
    /// Consecutive qualifying ticks before a trip is emitted.
    var requiredTicks: Int = 6

    private struct Watch {
        var ticks: Int = 0
        var host: String = ""
        var dstIP: String = ""
        var phantom: Int64 = 0
    }
    private var watched: [String: Watch] = [:]

    /// Feed one connection of one snapshot. Emits a trip at most once per
    /// connection — the watch entry is dropped when the trip fires and the
    /// recovery path resets the whole sentinel anyway.
    ///
    /// A watch that goes stale (connection vanished from the snapshot) is
    /// reclaimed by `reap(excluding:)`, which the driver calls once per tick
    /// — the sentinel must not accumulate a row for every connection that
    /// ever existed.
    mutating func observe(id: String, chains: [String], host: String, destinationIP: String,
                          tickDownBytes: Int64, totalUploadBytes: Int64) -> TUNLoopTrip? {
        guard chains.contains("DIRECT"),
              tickDownBytes >= minTickDownBytes,
              totalUploadBytes <= maxSilentUploadBytes else {
            watched.removeValue(forKey: id)   // a non-qualifying tick breaks the streak
            return nil
        }
        var w = watched[id] ?? Watch()
        w.ticks += 1
        if !host.isEmpty { w.host = host }
        if !destinationIP.isEmpty { w.dstIP = destinationIP }
        w.phantom += tickDownBytes
        if w.ticks >= requiredTicks {
            watched.removeValue(forKey: id)
            return TUNLoopTrip(connID: id, host: w.host.isEmpty ? "?" : w.host,
                               destinationIP: w.dstIP, phantomBytes: w.phantom, ticks: w.ticks)
        }
        watched[id] = w
        // Bounded memory: a candidate storm keeps the biggest offenders.
        if watched.count > 64 {
            watched = Dictionary(watched.sorted { $0.value.phantom > $1.value.phantom }.prefix(32).map { ($0.key, $0.value) },
                                 uniquingKeysWith: { a, _ in a })
        }
        return nil
    }

    /// Drop watches whose connection disappeared from the latest snapshot.
    /// Short-lived loops that die between ticks simply vanish; we only care
    /// about loops that are alive long enough to be seen repeatedly.
    mutating func reap(excluding liveIDs: Set<String>) {
        guard !watched.isEmpty else { return }
        watched = watched.filter { liveIDs.contains($0.key) }
    }

    mutating func reset() { watched.removeAll(keepingCapacity: true) }

    var watchedCount: Int { watched.count }
}
