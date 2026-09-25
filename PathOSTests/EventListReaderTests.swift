import Foundation
import Testing
@testable import PathOS

/// Reading a programme of several events at once: a festival's days, a conference agenda.
struct EventListReaderTests {
    /// Monday 22 September 2026, in the morning.
    private let now = Date(timeIntervalSince1970: 1_790_050_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    private func describe(_ items: [EventListReader.Item]) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMM HH:mm"
        let time = DateFormatter()
        time.timeZone = calendar.timeZone
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        return items.map { "\(formatter.string(from: $0.start))-\(time.string(from: $0.end)) \($0.title)" + ($0.place.map { " @\($0)" } ?? "") }
    }

    @Test func aFestivalOverSeveralDays() {
        let text = """
        TechFest 2026 — Schedule
        Day 1 · Wed 24 Sep
        10:00 AM – 11:00 AM  Inauguration | Main stage
        11:00 Tea break
        11:30 AM - 1:00 PM Tutorial 1 | The Chancery Pavilion
        Thursday, 25 September
        2 PM - 4 PM | Hackathon finals | Seminar hall 2
        Friday 26th September
        6:30 PM Pro show @ Open air theatre
        """
        #expect(describe(EventListReader.items(in: text, now: now, calendar: calendar)) == [
            "24 Sep 10:00-11:00 Inauguration @Main stage",
            "24 Sep 11:00-11:30 Tea break",
            "24 Sep 11:30-13:00 Tutorial 1 @The Chancery Pavilion",
            "25 Sep 14:00-16:00 Hackathon finals @Seminar hall 2",
            "26 Sep 18:30-19:30 Pro show @Open air theatre",
        ])
    }

    /// Agendas often put the time on a line of its own, with the session under it.
    @Test func aTimeOverItsTitle() {
        let text = """
        24/09/2026
        09:30 - 10:15
        Registration
        10:15 - 11:00
        Keynote: On-device AI
        """
        #expect(describe(EventListReader.items(in: text, now: now, calendar: calendar)) == [
            "24 Sep 09:30-10:15 Registration",
            "24 Sep 10:15-11:00 Keynote: On-device AI",
        ])
    }

    /// With no date at all, everything is on the day it's being added to.
    @Test func withoutADateItsTheDayYoureOn() {
        let text = "9:00 - 10:00 Maths\n10-11 am Physics"
        let items = EventListReader.items(in: text, now: now, calendar: calendar)
        #expect(items.count == 2)
        #expect(items.allSatisfy { calendar.isDate($0.start, inSameDayAs: now) })
    }

    @Test func datesReadEveryWay() {
        func day(_ text: String) -> String? {
            EventListReader.date(in: text, now: now, calendar: calendar).map {
                let parts = calendar.dateComponents([.year, .month, .day], from: $0.date)
                return "\(parts.year!)-\(parts.month!)-\(parts.day!)"
            }
        }
        #expect(day("Wed 24 Sep") == "2026-9-24")
        #expect(day("September 25, 2026") == "2026-9-25")
        #expect(day("26th Sept") == "2026-9-26")
        #expect(day("27/09/2026") == "2026-9-27")
        #expect(day("10-11 Workshop") == nil)
        // A date already past this year is next year's.
        #expect(day("3 Jan") == "2027-1-3")
    }
}
