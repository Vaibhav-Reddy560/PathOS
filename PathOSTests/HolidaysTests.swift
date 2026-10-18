import Foundation
import Testing
@testable import PathOS

/// Holidays: the bundled lists, what's asked about, and reading a college's calendar.
struct HolidaysTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// The state's own list for 2026: twenty general holidays, three of them national.
    @Test func theBundledListIsTheStatesOwn() {
        let file = Holidays.bundled
        #expect(file.holidays.count == 20)
        #expect(file.holidays.filter { $0.kind == .national }.map(\.name) == ["Republic Day", "Independence Day", "Gandhi Jayanthi"])
        #expect(file.holidays.contains { $0.date == "2026-11-10" && $0.name.contains("Deepavali") })
        #expect(file.sources.first?.notification.contains("DPAR 16 HHL 2025") == true)
        #expect(file.holidays.allSatisfy { Holidays.day($0.date, calendar: calendar) != nil })
    }

    /// Only unanswered ones in the month ahead are asked about, soonest first.
    @Test func itAsksAboutWhatsCloseAndUnanswered() {
        func entry(_ name: String, _ date: Date, _ isOff: Bool? = nil) -> Holidays.Entry {
            .init(id: UUID(), day: date, name: name, kind: .karnataka, isOff: isOff)
        }
        let today = day(2026, 10, 18)
        let asked = Holidays.toAsk([
            entry("Deepavali", day(2026, 11, 10)),
            entry("Gandhi Jayanthi", day(2026, 10, 2)),
            entry("Vijayadashami", day(2026, 10, 21), true),
            entry("Mahanavami", day(2026, 10, 20)),
            entry("Christmas", day(2026, 12, 25)),
        ], today: today, calendar: calendar)
        #expect(asked.map(\.name) == ["Mahanavami", "Deepavali"])
    }

    /// A college calendar, however it's typed out.
    @Test func aCollegeCalendarReadsByRule() {
        let text = """
        BMS COLLEGE OF ENGINEERING — ACADEMIC CALENDAR (ODD SEMESTER 2026)
        Sl. No | Date | Day | Holiday
        1 | 20.10.2026 | Tuesday | Mahanavami / Ayudha Pooja
        2 | 21/10/2026 | Wednesday | Vijayadashami
        3. 1 Nov 2026 – Kannada Rajyotsava
        Nov 10, Tue: Deepavali
        2026-12-25 Christmas
        Commencement of classes
        """
        let rows = HolidayListReader.rows(in: text, today: day(2026, 10, 18), calendar: calendar)
        #expect(rows.map(\.name) == ["Mahanavami / Ayudha Pooja", "Vijayadashami", "Kannada Rajyotsava", "Deepavali", "Christmas"])
        #expect(rows.first.map { calendar.isDate($0.day, inSameDayAs: day(2026, 10, 20)) } == true)
        #expect(rows.last.map { calendar.isDate($0.day, inSameDayAs: day(2026, 12, 25)) } == true)
    }

    /// A word that only starts like a month isn't one.
    @Test func janmashtamiIsNotJanuary() {
        let rows = HolidayListReader.rows(in: "Sep 4 Krishna Janmashtami", today: day(2026, 8, 1), calendar: calendar)
        #expect(rows.first.map { calendar.isDate($0.day, inSameDayAs: day(2026, 9, 4)) } == true)
        #expect(rows.first?.name == "Krishna Janmashtami")
    }

    /// Without a year, a date is the next time it comes round.
    @Test func aDateWithoutAYearIsTheNextOne() {
        let rows = HolidayListReader.rows(in: "Jan 15 Sankranti\n2nd October Gandhi Jayanthi", today: day(2026, 10, 18),
                                          calendar: calendar)
        // Both have already been this year: Sankranti next January, Gandhi Jayanthi next October.
        #expect(rows.map(\.name) == ["Sankranti", "Gandhi Jayanthi"])
        #expect(rows.map { calendar.component(.year, from: $0.day) } == [2027, 2027])
    }
}
