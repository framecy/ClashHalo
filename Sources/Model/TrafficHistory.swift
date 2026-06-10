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

    private let path = NSHomeDirectory() + "/Library/Application Support/ClashPow/traffic-history.json"
    private var dirty = false
    private var lastSave = Date.distantPast

    private var todayKey: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    func load() {
        if let data = FileManager.default.contents(atPath: path),
           let d = try? JSONDecoder().decode([String: Day].self, from: data) {
            // keep only last 60 days
            let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: Date())!
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            days = d.filter { (f.date(from: $0.key) ?? .distantPast) >= cutoff }
        }
    }

    func record(category: String, down: Int64, up: Int64, hour: Int) {
        let bytes = Double(down + up)
        guard bytes > 0 else { return }
        var day = days[todayKey] ?? Day()
        switch category {
        case "direct": day.direct += bytes
        case "reject": day.reject += bytes
        default: day.proxy += bytes
        }
        if hour >= 0 && hour < 24 { day.hourlyDown[hour] += Double(down) }
        days[todayKey] = day
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
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        days = days.filter { (f.date(from: $0.key) ?? .distantPast) >= cutoff }
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: URL(fileURLWithPath: path)) }
    }

    // Aggregates for the dashboard
    var today: Day { days[todayKey] ?? Day() }
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
}
