import Foundation

/// A plain copy of one leg, so trip logic can be tested without SwiftData.
nonisolated struct PlannedLeg: Identifiable, Hashable, Sendable {
    var id: UUID
    var mode: TravelMode
    var origin: String
    var destination: String
    var departure: Date
    var arrival: Date?
    var distanceMeters: Double?

    /// When you'll get there: what you entered, or an estimate from the distance.
    func arrivalEstimate(calendar: Calendar = .current) -> Date? {
        if let arrival { return arrival }
        guard let distanceMeters else { return nil }
        let hours = (distanceMeters / 1_000) / mode.averageKilometresPerHour
        return departure.addingTimeInterval(hours * 3_600)
    }
}

nonisolated enum TripPlan {
    /// Legs departing on `day`, earliest first.
    static func legs(_ legs: [PlannedLeg], on day: Date, calendar: Calendar = .current) -> [PlannedLeg] {
        legs.filter { calendar.isDate($0.departure, inSameDayAs: day) }
            .sorted { $0.departure < $1.departure }
    }

    /// The leg you're on: departed, and not yet arrived.
    static func current(in legs: [PlannedLeg], now: Date) -> PlannedLeg? {
        legs.first { leg in
            guard leg.departure <= now else { return false }
            guard let arrival = leg.arrivalEstimate() else { return false }
            return arrival > now
        }
    }

    static func next(in legs: [PlannedLeg], now: Date) -> PlannedLeg? {
        legs.filter { $0.departure > now }.min { $0.departure < $1.departure }
    }

    /// Modes used across a trip, in the order they first appear — "Metro · Train · Walk".
    static func modeSummary(_ legs: [PlannedLeg]) -> String {
        var seen: [TravelMode] = []
        for leg in legs.sorted(by: { $0.departure < $1.departure }) where !seen.contains(leg.mode) {
            seen.append(leg.mode)
        }
        return seen.map(\.label).joined(separator: " · ")
    }

    /// Planned distance across legs that have one.
    static func plannedDistance(_ legs: [PlannedLeg]) -> Double {
        legs.compactMap(\.distanceMeters).reduce(0, +)
    }
}

/// What a day added up to, for the Day log's history.
nonisolated struct DaySummary: Equatable, Sendable {
    var distanceMeters: Double
    var eventCount: Int
    var classCount: Int
    var legCount: Int
    var memoryCount: Int
    var tripName: String?
    var tripDayNumber: Int?
    var tripDayCount: Int?

    var isEmpty: Bool {
        distanceMeters < 1 && eventCount == 0 && classCount == 0 && legCount == 0 && memoryCount == 0
    }

    /// One honest sentence about the day — only what actually happened.
    var sentence: String {
        if isEmpty { return "Nothing recorded for this day." }

        var parts: [String] = []
        if distanceMeters >= 1 {
            parts.append("travelled \(GeoMath.formatDistance(distanceMeters))")
        }
        if legCount > 0 {
            parts.append(legCount == 1 ? "1 trip leg" : "\(legCount) trip legs")
        }
        if classCount > 0 {
            parts.append(classCount == 1 ? "1 class" : "\(classCount) classes")
        }
        if eventCount > 0 {
            parts.append(eventCount == 1 ? "1 event" : "\(eventCount) events")
        }
        if memoryCount > 0 {
            parts.append(memoryCount == 1 ? "saved 1 spot" : "saved \(memoryCount) spots")
        }

        let list: String
        switch parts.count {
        case 1: list = parts[0]
        case 2: list = "\(parts[0]) and \(parts[1])"
        default: list = parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        }

        let prefix: String
        if let tripName, let tripDayNumber, let tripDayCount {
            prefix = "\(tripName), day \(tripDayNumber) of \(tripDayCount): "
        } else {
            prefix = ""
        }
        return prefix + list.prefix(1).uppercased() + list.dropFirst() + "."
    }
}
