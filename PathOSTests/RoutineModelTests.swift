import Foundation
import Testing
@testable import PathOS

struct RoutineModelTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func monday(_ hour: Int, _ minute: Int, week: Int) -> DepartureSample {
        DepartureSample(
            date: start.addingTimeInterval(Double(week) * 7 * 86_400),
            weekday: 2,
            minutesSinceMidnight: hour * 60 + minute
        )
    }

    private var model: RoutineModel {
        RoutineModel(samples: [monday(9, 0, week: 0), monday(9, 10, week: 1), monday(8, 50, week: 2), monday(13, 0, week: 3)])
    }

    private var now: Date { start.addingTimeInterval(4 * 7 * 86_400) }

    @Test func medianIgnoresOutliers() {
        #expect(model.typicalDeparture(weekday: 2, now: now) == 9 * 60)
    }

    @Test func fallsBackToWeekdayGroup() {
        #expect(model.typicalDeparture(weekday: 3, now: now) == 9 * 60)
        #expect(model.typicalDeparture(weekday: 7, now: now) == nil)
    }

    @Test func reminderIs15MinutesEarly() {
        let reminder = model.reminderTime(weekday: 2, now: now)
        #expect(reminder?.hour == 8)
        #expect(reminder?.minute == 45)
    }

    @Test func onlyFirstDepartureOfDayCounts() {
        // `monday` gives every sample in a week the same timestamp, so build these by hand:
        // firstPerDay picks by real timestamp, and the UTC calendar keeps both on one day in any time zone.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let morning = DepartureSample(date: start, weekday: 2, minutesSinceMidnight: 9 * 60)
        let lunch = DepartureSample(date: start.addingTimeInterval(3 * 3600), weekday: 2, minutesSinceMidnight: 12 * 60)
        let samples = RoutineModel.firstPerDay([lunch, morning], calendar: utc)
        #expect(samples.count == 1)
        #expect(samples.first?.minutesSinceMidnight == 9 * 60)
    }

    @Test func oldHistoryIsIgnored() {
        let muchLater = now.addingTimeInterval(Double(RoutineModel.lookbackDays + 30) * 86_400)
        #expect(model.typicalDeparture(weekday: 2, now: muchLater) == nil)
    }
}
