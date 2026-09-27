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
    /// Events that touch `day`, earliest first. An event running past midnight belongs to both days;
    /// a deadline with no length belongs to the day it falls on, even at midnight.
    static func events(_ events: [PlannedEvent], on day: Date, calendar: Calendar = .current) -> [PlannedEvent] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return events
            .filter { ($0.start >= interval.start && $0.start < interval.end) || ($0.start < interval.end && $0.end > interval.start) }
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

    /// What a reminder counts back from. An all-day item starts at midnight, and a reminder
    /// before that would arrive the night before, so it counts back from 9 in the morning instead.
    static func reminderAnchor(start: Date, isAllDay: Bool, calendar: Calendar = .current) -> Date {
        guard isAllDay else { return start }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: start) ?? start
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
    /// A fix vaguer than this says little about where you went.
    static let worstAccuracy = 65.0
    /// Measuring from a point older than this, or from yesterday, says nothing about today: the
    /// journey between them went unseen, and lands on whichever day happens to ask.
    static let oldestAnchor: TimeInterval = 6 * 3_600
    /// No single step is longer than this. Past it, something has gone wrong with the fixes.
    static let longestStep = 50_000.0
    /// Faster than this between two fixes is a jump, not travel: 200 km/h.
    static let fastestTravel = 55.0

    static func step(fromDistance meters: Double) -> Double {
        (minimumStepMeters...maximumStepMeters).contains(meters) ? meters : 0
    }

    nonisolated enum Step: Equatable {
        /// Too close or too vague to count: keep measuring from the last point that counted.
        case ignore
        /// Real movement: add it, and measure on from here.
        case count(Double)
        /// A jump no one travels: measure on from here, adding nothing.
        case skip
    }

    /// What one fix adds, measured from the last one that counted — not from the one before it,
    /// which dropped every step of a slow walk as wobble: ten metres at a time, never fifteen.
    /// Gaps are fine: a ride with PathOS closed counts on its return, at any believable speed,
    /// where the old two-kilometre cap threw the whole ride away.
    /// Whether the last point that counted can still be measured from, or the gap since is too
    /// long to say anything about.
    static func canMeasure(from anchor: Date, to fix: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(anchor, inSameDayAs: fix) && fix.timeIntervalSince(anchor) <= oldestAnchor
    }

    static func step(distance: Double, seconds: TimeInterval, accuracy: Double) -> Step {
        guard accuracy >= 0, accuracy <= worstAccuracy else { return .ignore }
        guard distance >= max(minimumStepMeters, accuracy) else { return .ignore }
        if distance > longestStep { return .skip }
        if seconds > 0, distance / seconds > fastestTravel { return .skip }
        if seconds <= 0, distance > maximumStepMeters { return .skip }
        return .count(distance)
    }

    /// "3.4 km" / "620 m", for the day summary.
    static func format(_ meters: Double) -> String {
        GeoMath.formatDistance(meters)
    }
}
