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

    @Test func aDeadlineAtMidnightStaysOnItsDay() {
        // A task is a moment with no length; at exactly midnight it touches no time on either side.
        let midnight = calendar.startOfDay(for: noon.addingTimeInterval(24 * 3_600))
        let deadline = PlannedEvent(id: UUID(), title: "Fees due", start: midnight, end: midnight, isAllDay: false,
                                    placeName: nil, latitude: nil, longitude: nil)
        #expect(DayPlan.events([deadline], on: midnight, calendar: calendar).map(\.title) == ["Fees due"])
        #expect(DayPlan.events([deadline], on: noon, calendar: calendar).isEmpty)
    }

    @Test func allDayRemindersCountBackFromTheMorning() {
        let day = calendar.startOfDay(for: noon)
        let anchor = DayPlan.reminderAnchor(start: day, isAllDay: true, calendar: calendar)
        #expect(calendar.component(.hour, from: anchor) == 9)
        #expect(calendar.isDate(anchor, inSameDayAs: day))
        #expect(DayPlan.reminderAnchor(start: noon, isAllDay: false, calendar: calendar) == noon)
    }

    @Test func distanceIgnoresJitterAndTeleports() {
        #expect(DayDistance.step(fromDistance: 4) == 0)
        #expect(DayDistance.step(fromDistance: 120) == 120)
        #expect(DayDistance.step(fromDistance: 50_000) == 0)
    }

    /// A slow walk, fixed once a second: each step is a metre or so, and only adds up because
    /// it's measured from the last point that counted.
    @Test func aSlowWalkStillCounts() {
        var total = 0.0
        var sinceCounted = 0.0
        for _ in 0..<60 {
            sinceCounted += 1.2
            switch DayDistance.step(distance: sinceCounted, seconds: 1, accuracy: 8) {
            case .count(let metres): total += metres; sinceCounted = 0
            case .skip: sinceCounted = 0
            case .ignore: break
            }
        }
        #expect(total >= 60)
    }

    /// A ten-minute walk, fixed once a second with ordinary GPS wobble, measured the way the app
    /// measures it: from the last point that counted. Each second's step is about a metre, far
    /// under the fifteen-metre floor, so before this it added up to nothing at all.
    @Test func aTracedWalkAddsUpToRoughlyItsLength() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let pace = 1.4
        let seconds = 600
        var seed: UInt64 = 42
        // A repeatable wobble of about ±3 m, which is what a good fix in a street looks like.
        func wobble() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 40) / Double(1 << 24) * 6 - 3
        }

        var counted = 0.0
        var anchor = (position: wobble(), at: start)
        for second in 1...seconds {
            let at = start.addingTimeInterval(Double(second))
            let measured = Double(second) * pace + wobble()
            switch DayDistance.step(distance: abs(measured - anchor.position),
                                    seconds: at.timeIntervalSince(anchor.at), accuracy: 5) {
            case .count(let metres):
                counted += metres
                anchor = (measured, at)
            case .skip:
                anchor = (measured, at)
            case .ignore:
                break
            }
        }

        let walked = Double(seconds) * pace
        #expect(counted > walked * 0.85)
        #expect(counted < walked * 1.2)
    }

    /// Yesterday's last fix can't be measured from today: the journey in between went unseen and
    /// would land entirely on whichever day happened to ask.
    @Test func anAnchorFromAnotherDayIsNotMeasuredFrom() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let lastNight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 23, minute: 40))!
        let thisMorning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 8))!
        #expect(!DayDistance.canMeasure(from: lastNight, to: thisMorning, calendar: calendar))

        // Nor one from hours ago, whatever the day.
        let breakfast = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 1))!
        #expect(!DayDistance.canMeasure(from: breakfast, to: thisMorning, calendar: calendar))
        // A few minutes ago is fine.
        #expect(DayDistance.canMeasure(from: thisMorning.addingTimeInterval(-300), to: thisMorning, calendar: calendar))
    }

    /// Eight kilometres across town with PathOS closed counts when it's next open; eight
    /// kilometres in a minute doesn't.
    @Test func aRideInYourPocketCounts() {
        #expect(DayDistance.step(distance: 8_000, seconds: 25 * 60, accuracy: 10) == .count(8_000))
        #expect(DayDistance.step(distance: 8_000, seconds: 60, accuracy: 10) == .skip)
        #expect(DayDistance.step(distance: 300, seconds: 60, accuracy: 200) == .ignore)
    }
}
