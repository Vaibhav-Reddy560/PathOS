import Foundation

/// What your days added up to, over a week, a month or everything: what you went to and what you
/// missed, the days off and holidays you took, what you got done and how far you went.
nonisolated enum Overview {
    nonisolated enum Span: String, CaseIterable, Identifiable, Sendable {
        case week
        case month
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .week: "This week"
            case .month: "This month"
            case .all: "Everything"
            }
        }

        /// Where the span starts: the week's or the month's first day, or nil for everything.
        func start(now: Date, calendar: Calendar = .current) -> Date? {
            switch self {
            case .week: calendar.dateInterval(of: .weekOfYear, for: now)?.start
            case .month: calendar.dateInterval(of: .month, for: now)?.start
            case .all: nil
            }
        }
    }

    /// Something on a day's plan: a session, an event, a calendar entry.
    nonisolated struct Item: Hashable, Sendable {
        var id: String
        var title: String
        var start: Date
        var end: Date
    }

    /// One day as the overview reads it.
    nonisolated struct Day: Sendable {
        var dayStart: Date
        var planned: [Item]
        var missedIDs: Set<String>
        var doneIDs: Set<String>
        var tasksDone: Int
        var distanceMeters: Double
        /// Why the day was taken off, when it was.
        var dayOff: String?
        /// A holiday on the day you said was a day off for you.
        var holidayOff: String?
    }

    /// Something you were seen to miss.
    nonisolated struct Missed: Identifiable, Hashable, Sendable {
        var id: String
        var title: String
        var start: Date
        var dayStart: Date
    }

    /// A day off, and why.
    nonisolated struct DayOff: Identifiable, Hashable, Sendable {
        var dayStart: Date
        var reason: String
        var isHoliday: Bool

        var id: Date { dayStart }
    }

    nonisolated struct Summary: Equatable, Sendable {
        var attended = 0
        var missed: [Missed] = []
        var tasksDone = 0
        var distanceMeters = 0.0
        var daysOff: [DayOff] = []

        /// The share of what was on that you went to, when anything was.
        var attendance: Double? {
            let total = attended + missed.count
            return total == 0 ? nil : Double(attended) / Double(total)
        }

        var holidaysTaken: Int { daysOff.filter(\.isHoliday).count }
        var otherDaysOff: Int { daysOff.count - holidaysTaken }
    }

    /// Adds the days up. Things still to come aren't counted either way; something missed that's
    /// since been deleted from your plan is still a miss, under the name it can no longer be
    /// looked up by.
    static func summary(of days: [Day], now: Date) -> Summary {
        var summary = Summary()
        for day in days {
            let byID = Dictionary(day.planned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            summary.attended += Attendance.finished(day.planned.map { (id: $0.id, end: $0.end) },
                                                    done: day.doneIDs, missed: day.missedIDs, now: now)
            for id in day.missedIDs where !day.doneIDs.contains(id) {
                let item = byID[id]
                summary.missed.append(Missed(id: id, title: item?.title ?? "Something no longer on your plan",
                                             start: item?.start ?? day.dayStart, dayStart: day.dayStart))
            }
            summary.tasksDone += day.tasksDone
            summary.distanceMeters += day.distanceMeters
            if let holiday = day.holidayOff {
                summary.daysOff.append(DayOff(dayStart: day.dayStart, reason: holiday, isHoliday: true))
            } else if let reason = day.dayOff {
                summary.daysOff.append(DayOff(dayStart: day.dayStart, reason: reason, isHoliday: false))
            }
        }
        summary.missed.sort { $0.start > $1.start }
        summary.daysOff.sort { $0.dayStart > $1.dayStart }
        return summary
    }
}
