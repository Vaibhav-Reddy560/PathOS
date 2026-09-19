import Foundation

/// The dates a month calendar shows: whole weeks from the calendar's first weekday, so the grid
/// starts and ends with the neighbouring months' days.
nonisolated enum MonthGrid {
    static func days(around date: Date, calendar: Calendar = .current) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: month.start),
              let lastDay = calendar.date(byAdding: .day, value: -1, to: month.end),
              let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastDay) else { return [] }
        var days: [Date] = []
        var day = firstWeek.start
        while day < lastWeek.end {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// One or two letters per weekday, in the grid's column order.
    static func weekdaySymbols(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The first day of the month `months` away from the one containing `date`.
    static func month(_ months: Int, from date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? date
        return calendar.date(byAdding: .month, value: months, to: start) ?? start
    }
}
