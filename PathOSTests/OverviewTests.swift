import Foundation
import Testing
@testable import PathOS

/// What the days added up to.
struct OverviewTests {
    let monday = Date(timeIntervalSince1970: 1_792_000_000)

    private func item(_ id: String, _ title: String, hoursIn: Double) -> Overview.Item {
        let start = monday.addingTimeInterval(hoursIn * 3_600)
        return .init(id: id, title: title, start: start, end: start.addingTimeInterval(3_600))
    }

    @Test func itCountsWhatYouWentToAndWhatYouMissed() {
        let day = Overview.Day(
            dayStart: monday,
            planned: [item("class:1", "Physics", hoursIn: 9), item("class:2", "Maths", hoursIn: 11),
                      item("event:a", "Hackathon", hoursIn: 30)],
            missedIDs: ["class:2", "event:gone"], doneIDs: [], tasksDone: 2, distanceMeters: 4_200,
            dayOff: nil, holidayOff: nil
        )
        let summary = Overview.summary(of: [day], now: monday.addingTimeInterval(20 * 3_600))
        // Physics went; Maths was missed; the hackathon hasn't happened yet.
        #expect(summary.attended == 1)
        #expect(summary.missed.map(\.title) == ["Maths", "Something no longer on your plan"])
        #expect(summary.attendance == 1.0 / 3.0)
        #expect(summary.tasksDone == 2)
        #expect(summary.distanceMeters == 4_200)
    }

    /// A holiday you took off is a holiday; any other day off is yours.
    @Test func holidaysAndDaysOffAreToldApart() {
        func off(_ days: Double, reason: String?, holiday: String?) -> Overview.Day {
            .init(dayStart: monday.addingTimeInterval(days * 86_400), planned: [], missedIDs: [], doneIDs: [],
                  tasksDone: 0, distanceMeters: 0, dayOff: reason, holidayOff: holiday)
        }
        let summary = Overview.summary(of: [off(0, reason: "Day off", holiday: nil),
                                            off(1, reason: "Deepavali", holiday: "Deepavali"),
                                            off(2, reason: nil, holiday: nil)], now: monday)
        #expect(summary.holidaysTaken == 1)
        #expect(summary.otherDaysOff == 1)
        #expect(summary.daysOff.first?.reason == "Deepavali")
    }
}
