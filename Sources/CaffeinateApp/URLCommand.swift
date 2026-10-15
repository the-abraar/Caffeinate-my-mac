import Foundation

/// `caffeinate-my-mac://` commands, used by the CLI, Shortcuts and agents. Any local app can
/// open these URLs, so every value is range-checked here; lid mode still needs the one-time setup.
enum URLCommand: Equatable {
    case start(seconds: Int, lid: Bool)   // start?minutes=45 or start?until=09:30, optional &lid=1
    case commute                          // commute
    case untilIdle(lid: Bool)             // idle
    case whilePID(Int32, lid: Bool)       // while?pid=123
    case extend(seconds: Int)             // extend, extend?minutes=30
    case stop                             // stop

    static func parse(_ url: URL, now: Date = Date()) -> URLCommand? {
        guard url.scheme == "caffeinate-my-mac", let action = url.host else { return nil }
        var q: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            q[item.name] = item.value
        }
        let lid = q["lid"] == "1"
        let seconds = q["minutes"].flatMap(Int.init).flatMap { (1...1440).contains($0) ? $0 * 60 : nil }
        switch action {
        case "start":
            if let until = q["until"] {
                let parts = until.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { return nil }
                return secondsUntil(hour: parts[0], minute: parts[1], from: now).map { .start(seconds: $0, lid: lid) }
            }
            return seconds.map { .start(seconds: $0, lid: lid) }
        case "commute":
            return .commute
        case "idle":
            return .untilIdle(lid: lid)
        case "while":
            guard let pid = q["pid"].flatMap(Int32.init), pid > 1 else { return nil }
            return .whilePID(pid, lid: lid)
        case "extend":
            return q["minutes"] == nil ? .extend(seconds: 15 * 60) : seconds.map { .extend(seconds: $0) }
        case "stop":
            return .stop
        default:
            return nil
        }
    }
}

/// Seconds from `now` to the next HH:MM, tomorrow if that time already passed today.
func secondsUntil(hour: Int, minute: Int, from now: Date, calendar: Calendar = .current) -> Int? {
    guard (0...23).contains(hour), (0...59).contains(minute),
          let next = calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                       matchingPolicy: .nextTime) else { return nil }
    return Int(next.timeIntervalSince(now).rounded())
}
