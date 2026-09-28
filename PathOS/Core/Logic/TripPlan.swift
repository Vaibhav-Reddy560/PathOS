import CoreLocation
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

/// How a leg you're on is going.
nonisolated struct LegProgress: Equatable, Sendable {
    /// Straight-line metres to the destination, when both ends of that are known.
    var distanceRemaining: Double?
    /// 0…1, by distance when possible, otherwise by the clock.
    var fractionDone: Double?
    var eta: Date?
    var minutesRemaining: Int?
    var hasArrived: Bool
    /// The arrival you planned has passed and you're not there yet.
    var isLate: Bool
}

nonisolated enum TripTracker {
    /// How close counts as arrived. A station or an airport is far bigger than a street address.
    static func arrivalRadius(for mode: TravelMode) -> Double {
        switch mode {
        case .walk, .scooter, .car, .cab: 150
        case .bus, .metro: 300
        case .train, .ferry: 600
        case .flight: 3_000
        }
    }

    /// Where you are along a leg. With a location and a destination it measures you; without,
    /// it goes by the times you planned.
    static func progress(
        leg: PlannedLeg,
        origin: CLLocationCoordinate2D?,
        destination: CLLocationCoordinate2D?,
        location: CLLocationCoordinate2D?,
        now: Date
    ) -> LegProgress {
        let planned = leg.arrivalEstimate()
        var remaining: Double?
        if let destination, let location {
            remaining = GeoMath.distance(from: location, to: destination)
        }
        let hasArrived = remaining.map { $0 <= arrivalRadius(for: leg.mode) } ?? false

        var fraction: Double?
        if let remaining, let origin, let destination {
            let total = GeoMath.distance(from: origin, to: destination)
            if total > 0 { fraction = min(1, max(0, 1 - remaining / total)) }
        } else if let planned, planned > leg.departure {
            fraction = min(1, max(0, now.timeIntervalSince(leg.departure) / planned.timeIntervalSince(leg.departure)))
        }
        if hasArrived { fraction = 1 }

        // At the mode's usual speed from here; trusted over the plan only when you're clearly behind it.
        let bySpeed = remaining.map { now.addingTimeInterval(($0 / 1_000) / leg.mode.averageKilometresPerHour * 3_600) }
        var eta = planned
        var isLate = false
        if !hasArrived {
            if let planned, planned <= now {
                isLate = true
                eta = bySpeed
            } else if let planned, let bySpeed, bySpeed.timeIntervalSince(planned) > 10 * 60 {
                isLate = true
                eta = bySpeed
            } else if planned == nil {
                eta = bySpeed
            }
        }

        return LegProgress(
            distanceRemaining: remaining,
            fractionDone: fraction,
            eta: hasArrived ? now : eta,
            minutesRemaining: hasArrived ? 0 : eta.map { max(0, Int(($0.timeIntervalSince(now) / 60).rounded(.up))) },
            hasArrived: hasArrived,
            isLate: isLate
        )
    }

    /// "Arrives 5:40 PM · 38 km to go", "Running late · about 25 min to go".
    static func summary(_ progress: LegProgress) -> String {
        if progress.hasArrived { return "You've arrived" }
        var parts: [String] = []
        if progress.isLate {
            parts.append(progress.minutesRemaining.map { "Running late · about \($0) min to go" } ?? "Running late")
        } else if let eta = progress.eta {
            parts.append("Arrives \(eta.formatted(date: .omitted, time: .shortened))")
        }
        if let remaining = progress.distanceRemaining {
            parts.append("\(GeoMath.formatDistance(remaining)) to go")
        }
        return parts.isEmpty ? "On your way" : parts.joined(separator: " · ")
    }
}

/// What a day added up to, for the Day log's history.
nonisolated struct DaySummary: Equatable, Sendable {
    var distanceMeters: Double
    var eventCount: Int
    var classCount: Int
    var legCount: Int
    var memoryCount: Int
    /// Reminders ticked off that day.
    var taskCount = 0
    var tripName: String?
    var tripDayNumber: Int?
    var tripDayCount: Int?

    var isEmpty: Bool {
        distanceMeters < 1 && eventCount == 0 && classCount == 0 && legCount == 0 && memoryCount == 0 && taskCount == 0
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
            parts.append(classCount == 1 ? "1 session" : "\(classCount) sessions")
        }
        if eventCount > 0 {
            parts.append(eventCount == 1 ? "1 event" : "\(eventCount) events")
        }
        if taskCount > 0 {
            parts.append(taskCount == 1 ? "finished 1 task" : "finished \(taskCount) tasks")
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
