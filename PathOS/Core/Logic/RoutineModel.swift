import Foundation

nonisolated struct DepartureSample: Hashable, Sendable {
    var date: Date
    /// 1 = Sunday … 7 = Saturday.
    var weekday: Int
    var minutesSinceMidnight: Int
}

/// Learns typical commute departure times from logged departures.
nonisolated struct RoutineModel: Sendable {
    static let minimumSamples = 3
    static let lookbackDays = 56
    /// Departures this far from the median are treated as one-offs.
    static let outlierToleranceMinutes = 90

    let samples: [DepartureSample]

    /// Typical departure for `weekday`, in minutes since midnight. Falls back to the
    /// weekday/weekend group when that specific day has too little history.
    func typicalDeparture(weekday: Int, now: Date = Date()) -> Int? {
        let cutoff = now.addingTimeInterval(-Double(Self.lookbackDays) * 86_400)
        let recent = samples.filter { $0.date >= cutoff }

        let sameDay = recent.filter { $0.weekday == weekday }.map(\.minutesSinceMidnight)
        if let minutes = Self.robustMedian(sameDay) { return minutes }

        let wantsWeekend = Self.isWeekend(weekday)
        let sameGroup = recent.filter { Self.isWeekend($0.weekday) == wantsWeekend }.map(\.minutesSinceMidnight)
        return Self.robustMedian(sameGroup)
    }

    /// Reminder time `leadMinutes` before the typical departure.
    func reminderTime(weekday: Int, leadMinutes: Int = 15, now: Date = Date()) -> (hour: Int, minute: Int)? {
        guard let departure = typicalDeparture(weekday: weekday, now: now) else { return nil }
        let reminder = max(0, departure - leadMinutes)
        return (reminder / 60, reminder % 60)
    }

    /// Only the first departure of each day counts as a commute (not lunch runs).
    static func firstPerDay(_ samples: [DepartureSample], calendar: Calendar = .current) -> [DepartureSample] {
        let byDay = Dictionary(grouping: samples) { calendar.startOfDay(for: $0.date) }
        return byDay.values
            .compactMap { $0.min { $0.date < $1.date } }
            .sorted { $0.date < $1.date }
    }

    static func isWeekend(_ weekday: Int) -> Bool { weekday == 1 || weekday == 7 }

    static func robustMedian(_ values: [Int]) -> Int? {
        guard values.count >= minimumSamples else { return nil }
        let center = median(values)
        let kept = values.filter { abs($0 - center) <= outlierToleranceMinutes }
        guard kept.count >= minimumSamples else { return nil }
        return median(kept)
    }

    static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
