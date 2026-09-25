import Foundation
import Testing
@testable import PathOS

/// When to set off for the next place you need to be, and when to say so.
struct LeaveOnTimeTests {
    private let nine = Date(timeIntervalSince1970: 1_789_875_000) // a morning session at 9:00
    private func minutes(_ value: Double) -> TimeInterval { value * 60 }

    @Test func farAheadThereIsNothingToSay() {
        // 25 minutes away, starting in three hours: leave by 8:30, with hours to spare.
        let status = LeaveOnTime.status(start: nine, travel: minutes(25), distance: 9_000, now: nine.addingTimeInterval(-minutes(180)))
        #expect(status == .inGoodTime(leaveBy: nine.addingTimeInterval(-minutes(30))))
    }

    @Test func withinTheHourItSaysWhenToLeave() {
        let status = LeaveOnTime.status(start: nine, travel: minutes(25), distance: 9_000, now: nine.addingTimeInterval(-minutes(75)))
        #expect(status == .leaveSoon(leaveBy: nine.addingTimeInterval(-minutes(30))))
    }

    @Test func thenItSaysToGo() {
        let status = LeaveOnTime.status(start: nine, travel: minutes(25), distance: 9_000, now: nine.addingTimeInterval(-minutes(28)))
        #expect(status == .leaveNow(leaveBy: nine.addingTimeInterval(-minutes(30))))
    }

    @Test func andThenHowLateYoullBe() {
        let status = LeaveOnTime.status(start: nine, travel: minutes(25), distance: 9_000, now: nine.addingTimeInterval(-minutes(13)))
        #expect(status == .late(arrival: nine.addingTimeInterval(minutes(12)), minutes: 12))
    }

    /// Half an hour late and still at home: reminding again won't help, so it asks once whether
    /// you're still going. Already on your way, it doesn't ask.
    @Test func farTooLateAndNotMovingItAsks() {
        let status = LeaveOnTime.status(start: nine, travel: minutes(25), distance: 9_000, now: nine.addingTimeInterval(minutes(8)))
        #expect(status == .late(arrival: nine.addingTimeInterval(minutes(33)), minutes: 33))
        #expect(LeaveOnTime.asksToDrop(status, isOnTheWay: false))
        #expect(!LeaveOnTime.asksToDrop(status, isOnTheWay: true))

        let slightly = LeaveOnTime.status(start: nine, travel: minutes(25), distance: 9_000, now: nine.addingTimeInterval(-minutes(13)))
        #expect(!LeaveOnTime.asksToDrop(slightly, isOnTheWay: false))
    }

    @Test func onceYoureThereItsQuiet() {
        #expect(LeaveOnTime.status(start: nine, travel: 0, distance: 120, now: nine.addingTimeInterval(-minutes(10))) == .there)
    }

    @Test func theNextPlaceIsTheSoonestStillToCome() {
        func place(_ id: String, _ start: Double, _ length: Double = 55) -> LeaveOnTime.Destination {
            .init(id: id, title: id, placeName: "Work", start: nine.addingTimeInterval(minutes(start)),
                  end: nine.addingTimeInterval(minutes(start + length)), latitude: 12.94, longitude: 77.56)
        }
        let day = [place("maths", 60), place("physics", 0), place("evening", 600)]
        #expect(LeaveOnTime.next(in: day, now: nine.addingTimeInterval(-minutes(90)))?.id == "physics")
        // Started ten minutes ago and you're not there: still the one that matters.
        #expect(LeaveOnTime.next(in: day, now: nine.addingTimeInterval(minutes(10)))?.id == "physics")
        // Well under way: the next one.
        #expect(LeaveOnTime.next(in: day, now: nine.addingTimeInterval(minutes(40)))?.id == "maths")
        // Nothing within four hours.
        #expect(LeaveOnTime.next(in: [place("evening", 600)], now: nine)?.id == nil)
    }

    @Test func withoutARouteItEstimates() {
        #expect(LeaveOnTime.roughTravelMinutes(distance: 800) == GeoMath.walkingMinutes(forDistance: 800))
        // 9 km across a city: about 42 minutes by road.
        #expect(LeaveOnTime.roughTravelMinutes(distance: 9_000) == 42)
    }
}
