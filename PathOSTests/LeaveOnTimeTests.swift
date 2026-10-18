import CoreLocation
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

    // MARK: On your way

    private var home: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 12.9265, longitude: 77.5935) }
    private var college: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 12.9412, longitude: 77.5656) }

    private func watch(_ previous: LeaveOnTime.Watch?, at here: CLLocationCoordinate2D,
                       speed: Double? = nil, course: Double? = nil) -> LeaveOnTime.Watch {
        LeaveOnTime.watch(previous, id: "class:1", here: here, distance: GeoMath.distance(from: here, to: college),
                          speed: speed, course: course, bearingToPlace: GeoMath.bearing(from: here, to: college))
    }

    /// Opening PathOS in an auto, halfway there: the first check already knows you've set off.
    @Test func movingTowardsItIsOnYourWayAtOnce() {
        let halfway = GeoMath.coordinate(home, metres: 1_700, bearing: GeoMath.bearing(from: home, to: college))
        let bearing = GeoMath.bearing(from: halfway, to: college)
        #expect(watch(nil, at: halfway, speed: 6, course: bearing).isOnTheWay)
        // Sitting still, or walking about, says nothing yet.
        #expect(!watch(nil, at: halfway, speed: 0.4, course: bearing).isOnTheWay)
        // Driving the other way isn't heading there.
        #expect(!watch(nil, at: halfway, speed: 6, course: bearing + 180).isOnTheWay)
    }

    /// Gone from where you were first seen, and closer: set off, whatever the last check said.
    @Test func leavingWhereYouWereIsOnYourWay() {
        let first = watch(nil, at: home)
        #expect(!first.isOnTheWay)
        let down = GeoMath.coordinate(home, metres: 400, bearing: GeoMath.bearing(from: home, to: college))
        #expect(watch(first, at: down).isOnTheWay)
        // A stroll round the block that comes back no closer isn't.
        let around = GeoMath.coordinate(home, metres: 350, bearing: GeoMath.bearing(from: home, to: college) + 180)
        #expect(!watch(first, at: around).isOnTheWay)
    }

    /// Only the reminders for what's next survive: something cancelled, skipped or dropped loses
    /// its own.
    @Test func remindersForAnythingButWhatsNextAreStale() {
        #expect(LeaveOnTime.isStaleReminder("pathos.leave.event:A.now", keeping: "class:1"))
        #expect(!LeaveOnTime.isStaleReminder("pathos.leave.class:1.soon", keeping: "class:1"))
        #expect(LeaveOnTime.isStaleReminder("pathos.leave.class:12.soon", keeping: "class:1"))
        #expect(LeaveOnTime.isStaleReminder("pathos.leave.class:1.now", keeping: nil))
        #expect(!LeaveOnTime.isStaleReminder("pathos.event.A", keeping: nil))
    }
}
