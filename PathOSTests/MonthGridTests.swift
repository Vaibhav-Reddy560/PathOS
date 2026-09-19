import Foundation
import Testing
@testable import PathOS

struct MonthGridTests {
    private func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test func aMonthIsWholeWeeksFromTheFirstWeekday() {
        let monday = calendar(firstWeekday: 2)
        // September 2026 starts on a Tuesday and ends on a Wednesday.
        let days = MonthGrid.days(around: date(2026, 9, 19, monday), calendar: monday)
        #expect(days.count == 35)
        #expect(days.first == date(2026, 8, 31, monday))
        #expect(days.last == date(2026, 10, 4, monday))

        let sunday = calendar(firstWeekday: 1)
        let sundayDays = MonthGrid.days(around: date(2026, 9, 19, sunday), calendar: sunday)
        #expect(sundayDays.first == date(2026, 8, 30, sunday))
        #expect(sundayDays.count % 7 == 0)
    }

    @Test func weekdayLettersFollowTheColumns() {
        #expect(MonthGrid.weekdaySymbols(calendar: calendar(firstWeekday: 2)).first == "M")
        #expect(MonthGrid.weekdaySymbols(calendar: calendar(firstWeekday: 1)).first == "S")
        #expect(MonthGrid.weekdaySymbols(calendar: calendar(firstWeekday: 2)).count == 7)
    }

    @Test func monthsStepFromTheFirst() {
        let cal = calendar(firstWeekday: 2)
        #expect(MonthGrid.month(1, from: date(2026, 1, 31, cal), calendar: cal) == date(2026, 2, 1, cal))
        #expect(MonthGrid.month(-1, from: date(2026, 3, 15, cal), calendar: cal) == date(2026, 2, 1, cal))
    }
}
