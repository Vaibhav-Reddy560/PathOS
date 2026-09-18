import Foundation
import Testing
@testable import PathOS

struct DayPlanTests {
    private let calendar = Calendar.current
    private let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!

    private func event(_ title: String, startingAt offsetMinutes: Int, lasting minutes: Int = 60) -> PlannedEvent {
        let start = noon.addingTimeInterval(Double(offsetMinutes) * 60)
        return PlannedEvent(
            id: UUID(),
            title: title,
            start: start,
            end: start.addingTimeInterval(Double(minutes) * 60),
            isAllDay: false,
            placeName: nil,
            latitude: nil,
            longitude: nil
        )
    }

    @Test func eventsAreGroupedByDayInOrder() {
        let today = [event("Lecture", startingAt: -120), event("Coffee", startingAt: 60)]
        let tomorrow = [event("Trip", startingAt: 24 * 60)]
        let grouped = DayPlan.events(tomorrow + today, on: noon, calendar: calendar)
        #expect(grouped.map(\.title) == ["Lecture", "Coffee"])
    }

    @Test func anEventRunningPastMidnightBelongsToBothDays() {
        let lateShow = event("Late show", startingAt: 11 * 60, lasting: 180)  // 23:00 → 02:00
        let nextDay = noon.addingTimeInterval(24 * 3_600)
        #expect(DayPlan.events([lateShow], on: noon, calendar: calendar).count == 1)
        #expect(DayPlan.events([lateShow], on: nextDay, calendar: calendar).count == 1)
    }

    @Test func nextIsTheFirstThingNotYetFinished() {
        let past = event("Done", startingAt: -180)
        let running = event("Running", startingAt: -10, lasting: 60)
        let later = event("Later", startingAt: 120)
        let next = DayPlan.next(in: [past, running, later], now: noon)
        #expect(next?.title == "Running")
        #expect(DayPlan.isUnderway(running, now: noon))
        #expect(!DayPlan.isUnderway(later, now: noon))
    }

    @Test func countdownsReadLikeSpeech() {
        #expect(DayPlan.relativeTime(to: noon.addingTimeInterval(12 * 60), now: noon) == "in 12 min")
        #expect(DayPlan.relativeTime(to: noon.addingTimeInterval(135 * 60), now: noon) == "in 2 h 15 min")
        #expect(DayPlan.relativeTime(to: noon.addingTimeInterval(120 * 60), now: noon) == "in 2 h")
        #expect(DayPlan.relativeTime(to: noon.addingTimeInterval(-180 * 60), now: noon) == "3 h ago")
        #expect(DayPlan.relativeTime(to: noon.addingTimeInterval(20), now: noon) == "Now")
    }

    @Test func remindersOnlyScheduleInTheFuture() {
        let start = noon.addingTimeInterval(3_600)
        #expect(DayPlan.reminderDate(start: start, minutesBefore: 15, now: noon) == start.addingTimeInterval(-900))
        // 90 minutes before a talk that starts in an hour is already past.
        #expect(DayPlan.reminderDate(start: start, minutesBefore: 90, now: noon) == nil)
    }

    @Test func distanceIgnoresJitterAndTeleports() {
        #expect(DayDistance.step(fromDistance: 4) == 0)
        #expect(DayDistance.step(fromDistance: 120) == 120)
        #expect(DayDistance.step(fromDistance: 50_000) == 0)
    }
}
