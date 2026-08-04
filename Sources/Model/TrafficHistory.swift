import Foundation
import Combine
import SwiftUI

@MainActor final class TrafficHistory: ObservableObject {
    struct Day: Codable {
        var direct = 0.0, proxy = 0.0, reject = 0.0
        var hourlyDown = [Double](repeating: 0, count: 24)
        var total: Double { direct + proxy + reject }
    }
    @Published var days: [String: Day] = [:]   // key "yyyy-MM-dd"

    private let path = NSHomeDirectory() + "/Library/Application Support/ClashHalo/traffic-history.json"
    private var dirty = false
    private var lastSave = Date.distantPast

    /// Shared formatter — constructing DateFormatter per call is expensive on the
    /// per-connection hot path (record is invoked once per active conn per tick).
    private static let dayDF: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// `dayDF.string(from:)` is not cheap, and the key is needed on every read
    /// and every write of the hot path. The answer only changes at midnight, so
    /// cache it and re-derive when the calendar day rolls over.
    private var cachedDayKey = ""
    private var cachedDayStart = Date.distantPast
    private var todayKey: String {
        let now = Date()
        if now < cachedDayStart || now.timeIntervalSince(cachedDayStart) >= 86_400 {
            cachedDayStart = Calendar.current.startOfDay(for: now)
            cachedDayKey = Self.dayDF.string(from: now)
        }
        return cachedDayKey
    }

    func load() {
        if let data = FileManager.default.contents(atPath: path),
           let d = try? JSONDecoder().decode([String: Day].self, from: data) {
            // keep only last 60 days
            let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: Date())!
            days = d.filter { (Self.dayDF.date(from: $0.key) ?? .distantPast) >= cutoff }
        }
    }

    /// One tick's totals in a single write.
    ///
    /// The caller used to invoke `record` once per active connection, and each
    /// call copied the whole `Day` (including its 24-element hourly array) out
    /// of the dictionary, mutated it, and wrote it back — through a `@Published`
    /// property, so every one of them also emitted an `objectWillChange`. On a
    /// busy kernel that is a couple of thousand array copies and a couple of
    /// thousand SwiftUI invalidations *per poll*, for three numbers that could
    /// just as well be summed first. Callers now accumulate locally and land
    /// here once.
    func recordBatch(direct: Double, proxy: Double, reject: Double,
                     down: Double, hour: Int) {
        guard direct > 0 || proxy > 0 || reject > 0 || down > 0 else { return }
        let key = todayKey
        var day = days[key] ?? Day()
        day.direct += direct
        day.proxy += proxy
        day.reject += reject
        if hour >= 0 && hour < 24 { day.hourlyDown[hour] += down }
        days[key] = day
        dirty = true
    }

    func flushIfNeeded() {
        guard dirty, Date().timeIntervalSince(lastSave) > 5 else { return }
        save()
    }
    func save() {
        dirty = false; lastSave = Date()
        // prune older than 60 days before saving
        let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: Date())!
        days = days.filter { (Self.dayDF.date(from: $0.key) ?? .distantPast) >= cutoff }
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: URL(fileURLWithPath: path)) }
    }

    // Aggregates for the dashboard
    var today: Day { days[todayKey] ?? Day() }

    var last7Days: Day {
        let cal = Calendar.current
        let now = Date()
        var result = Day()
        for i in 0..<7 {
            if let date = cal.date(byAdding: .day, value: -i, to: now) {
                let key = Self.dayDF.string(from: date)
                if let d = days[key] {
                    result.direct += d.direct
                    result.proxy += d.proxy
                    result.reject += d.reject
                    for j in 0..<24 { result.hourlyDown[j] += d.hourlyDown[j] }
                }
            }
        }
        return result
    }

    var last30Days: Day {
        let cal = Calendar.current
        let now = Date()
        var result = Day()
        for i in 0..<30 {
            if let date = cal.date(byAdding: .day, value: -i, to: now) {
                let key = Self.dayDF.string(from: date)
                if let d = days[key] {
                    result.direct += d.direct
                    result.proxy += d.proxy
                    result.reject += d.reject
                    for j in 0..<24 { result.hourlyDown[j] += d.hourlyDown[j] }
                }
            }
        }
        return result
    }

    var month: Day {
        let prefix = String(todayKey.prefix(7))  // yyyy-MM
        var m = Day()
        for (k, d) in days where k.hasPrefix(prefix) {
            m.direct += d.direct; m.proxy += d.proxy; m.reject += d.reject
            for i in 0..<24 { m.hourlyDown[i] += d.hourlyDown[i] }
        }
        return m
    }
    /// Daily totals for the current month, oldest→newest (for the month timeline).
    var monthDailyTotals: [Double] {
        let prefix = String(todayKey.prefix(7))
        return days.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }.map { $0.value.total }
    }

    /// Daily totals for the last 7 days
    var last7DaysTotals: [Double] {
        let cal = Calendar.current
        let now = Date()
        return (0..<7).reversed().compactMap { i in
            guard let date = cal.date(byAdding: .day, value: -i, to: now) else { return 0 }
            return days[Self.dayDF.string(from: date)]?.total ?? 0
        }
    }

    /// Daily totals for the last 30 days
    var last30DaysTotals: [Double] {
        let cal = Calendar.current
        let now = Date()
        return (0..<30).reversed().compactMap { i in
            guard let date = cal.date(byAdding: .day, value: -i, to: now) else { return 0 }
            return days[Self.dayDF.string(from: date)]?.total ?? 0
        }
    }
}
