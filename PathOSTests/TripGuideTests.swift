import CoreLocation
import Foundation
import Testing
@testable import PathOS

/// Following a planned journey: which leg you're on, and how far behind the plan you've fallen.
struct TripGuideTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let station = CLLocationCoordinate2D(latitude: 12.9168, longitude: 77.6004)
    let office = CLLocationCoordinate2D(latitude: 12.9757, longitude: 77.6068)
    let home = CLLocationCoordinate2D(latitude: 12.9265, longitude: 77.5935)

    private func trip() -> DoorToDoor.Option {
        let auto = DoorToDoor.Leg(mode: .auto, title: "Auto to Jayadeva Hospital", detail: "2.4 km", minutes: 10,
                                  distanceMeters: 2_400, endName: "Jayadeva Hospital",
                                  endLatitude: station.latitude, endLongitude: station.longitude)
        let ride = DoorToDoor.Leg(mode: .metro, title: "Yellow Line to Mahatma Gandhi Road", detail: "8 stops", minutes: 20,
                                  distanceMeters: 9_000, endName: "Mahatma Gandhi Road",
                                  endLatitude: office.latitude, endLongitude: office.longitude)
        let walk = DoorToDoor.Leg(mode: .walk, title: "Walk to the office", detail: "400 m", minutes: 6,
                                  distanceMeters: 400, endName: "Office",
                                  endLatitude: office.latitude + 0.004, endLongitude: office.longitude)
        return DoorToDoor.Option(headline: "Metro, with an auto to the station", legs: [auto, ride, walk],
                                 minutes: 40, fareLow: 100, fareHigh: 140)
    }

    /// Getting into the station is counted before the ride, where that time actually goes.
    @Test func theScheduleCountsGettingIntoTheStation() {
        let plan = TripGuide.schedule(trip())
        #expect(plan == [10, 34, 40])
    }

    @Test func itSaysWhatToDoOnTheLegYoureOn() {
        let guide = TripGuide.status(for: trip(), startedAt: start, now: start.addingTimeInterval(120), location: home)
        #expect(guide?.legIndex == 0)
        #expect(guide?.headline == "Take an auto to Jayadeva Hospital")
        #expect(guide?.isBehind == false)
        // Two minutes gone of the forty.
        #expect(guide?.minutesRemaining == 38)
    }

    /// On the road, the time left is Apple Maps' for the rest of the route in today's traffic,
    /// and a jam makes you behind before any leg is missed.
    @Test func trafficOnTheRoadMovesTheArrival() throws {
        let now = start.addingTimeInterval(4 * 60)
        let planned = try #require(TripGuide.status(for: trip(), startedAt: start, now: now, location: home))
        #expect(planned.minutesRemaining == 36)

        // Six minutes of road left, as planned: nothing changes.
        let onTime = TripGuide.adjusting(planned, in: trip(), startedAt: start, now: now, legMinutesLeft: 6)
        #expect(onTime.minutesRemaining == 36)
        #expect(onTime.minutesBehind == 0)

        // Fourteen, in a jam: eight minutes later than planned, said as behind.
        let jammed = TripGuide.adjusting(planned, in: trip(), startedAt: start, now: now, legMinutesLeft: 14)
        #expect(jammed.minutesRemaining == 44)
        #expect(jammed.minutesBehind == 8)
        #expect(jammed.isBehind)
    }

    /// At the station, the ride is next, and nothing is late.
    @Test func reachingAPlaceMovesYouOn() {
        let guide = TripGuide.status(for: trip(), startedAt: start, now: start.addingTimeInterval(11 * 60), location: station)
        #expect(guide?.legIndex == 1)
        #expect(guide?.headline == "Ride to Mahatma Gandhi Road")
        #expect(guide?.minutesBehind == 0)
    }

    /// Still not at the station long after you should have been: behind, and it says where you
    /// were supposed to be.
    @Test func stillAtHomeMeansBehind() {
        let guide = TripGuide.status(for: trip(), startedAt: start, now: start.addingTimeInterval(22 * 60), location: home)
        #expect(guide?.legIndex == 0)
        #expect(guide?.minutesBehind == 12)
        #expect(guide?.isBehind == true)
        #expect(guide?.detail.contains("you should be at Jayadeva Hospital by now") == true)
    }

    /// A leg taking a little longer than planned is traffic, not lateness.
    @Test func aFewMinutesOverIsNotLate() {
        let guide = TripGuide.status(for: trip(), startedAt: start, now: start.addingTimeInterval(13 * 60), location: home)
        #expect(guide?.minutesBehind == 3)
        #expect(guide?.isBehind == false)
    }

    /// Underground, with no fix, the clock carries the plan — but it can never say you've arrived.
    @Test func theClockCarriesItWithoutAFix() {
        let mid = TripGuide.status(for: trip(), startedAt: start, now: start.addingTimeInterval(20 * 60), location: nil)
        #expect(mid?.legIndex == 1)
        let late = TripGuide.status(for: trip(), startedAt: start, now: start.addingTimeInterval(90 * 60), location: nil)
        #expect(late?.hasArrived == false)
        #expect(late?.legIndex == 2)
    }

    /// Arriving is something the map has to see.
    @Test func arrivingIsAPlaceNotATime() {
        let there = CLLocationCoordinate2D(latitude: office.latitude + 0.004, longitude: office.longitude)
        let guide = TripGuide.status(for: trip(), startedAt: start, now: start.addingTimeInterval(38 * 60), location: there)
        #expect(guide?.hasArrived == true)
        #expect(guide?.headline == "You've arrived")
    }
}
