import Foundation

/// One finished session, kept so the real cost of a commute (battery, heat, dropouts) is visible.
struct SessionRecord: Codable, Equatable, Identifiable {
    var start: Date
    var minutes: Int
    var lid: Bool
    var batteryUsed: Int?   // percentage points; negative if it charged
    var peakThermal: Int    // ProcessInfo.ThermalState raw value: 0 nominal ... 3 critical
    var offlineSeconds: Int
    var reason: String

    var id: Date { start }

    var line: String {
        var parts = [Self.clock.string(from: start), "\(minutes)m"]
        if lid { parts.append("lid") }
        if let b = batteryUsed, b != 0 { parts.append(b > 0 ? "−\(b)%" : "+\(-b)%") }
        if peakThermal > 0 { parts.append(["", "warm", "hot", "critical heat"][min(peakThermal, 3)]) }
        if offlineSeconds > 0 { parts.append("offline " + (offlineSeconds >= 60 ? "\(offlineSeconds / 60)m" : "\(offlineSeconds)s")) }
        parts.append(reason)
        return parts.joined(separator: " · ")
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f
    }()
}

enum SessionHistory {
    static let limit = 20
    static let url = LidControl.supportDir.appendingPathComponent("history.json")

    static func load(from url: URL = url) -> [SessionRecord] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([SessionRecord].self, from: $0) } ?? []
    }

    static func save(_ records: [SessionRecord], to url: URL = url) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Array(records.prefix(limit))).write(to: url, options: .atomic)
    }
}
