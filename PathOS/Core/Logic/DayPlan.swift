import Foundation

/// A plain snapshot of an event, so day logic can be tested without SwiftData.
nonisolated struct PlannedEvent: Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var placeName: String?
    var latitude: Double?
    var longitude: Double?

    var hasPlace: Bool { latitude != nil && longitude != nil }
}

nonisolated enum DayPlan {
    /// Events that touch `day`, earliest first. An event running past midnight belongs to both days.
    static func events(_ events: [PlannedEvent], on day: Date, calendar: Calendar = .current) -> [PlannedEvent] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return events
            .filter { $0.start < interval.end && $0.end > interval.start }
            .sorted { $0.start < $1.start }
    }

    /// The next event that hasn't finished yet.
    static func next(in events: [PlannedEvent], now: Date) -> PlannedEvent? {
        events.filter { $0.end > now }.min { $0.start < $1.start }
    }

    static func isUnderway(_ event: PlannedEvent, now: Date) -> Bool {
        event.start <= now && event.end > now
    }

    /// "Now", "in 12 min", "in 2 h 15 min", "3 h ago".
    static func relativeTime(to date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        let past = seconds < 0
        let minutes = Int((abs(seconds) / 60).rounded())
        if minutes < 1 { return "Now" }

        let text: String
        if minutes < 60 {
            text = "\(minutes) min"
        } else {
            let hours = minutes / 60
            let rest = minutes % 60
            text = rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
        }
        return past ? "\(text) ago" : "in \(text)"
    }

    /// When to notify, or nil when that moment has already passed.
    static func reminderDate(start: Date, minutesBefore: Int, now: Date) -> Date? {
        guard minutesBefore >= 0 else { return nil }
        let date = start.addingTimeInterval(-Double(minutesBefore) * 60)
        return date > now ? date : nil
    }
}

/// Distance travelled during a day, ignoring GPS jitter and impossible jumps.
nonisolated enum DayDistance {
    /// Below this, it's the fix wobbling rather than you moving.
    static let minimumStepMeters = 15.0
    /// Above this, the fix jumped (a tunnel, a lost signal, a simulator teleport).
    static let maximumStepMeters = 2_000.0

    static func step(fromDistance meters: Double) -> Double {
        (minimumStepMeters...maximumStepMeters).contains(meters) ? meters : 0
    }

    /// "3.4 km" / "620 m", for the day summary.
    static func format(_ meters: Double) -> String {
        GeoMath.formatDistance(meters)
    }
}
