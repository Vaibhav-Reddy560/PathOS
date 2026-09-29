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
        #expect(guide?.headline == "By road to Jayadeva Hospital")
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

    // MARK: Short trips

    private func shortTrip(to end: CLLocationCoordinate2D, mode: DoorToDoor.Mode = .walk) -> DoorToDoor.Option {
        let leg = DoorToDoor.Leg(mode: mode, title: "To the shop", detail: "", minutes: 3, distanceMeters: 200,
                                 endName: "The shop", endLatitude: end.latitude, endLongitude: end.longitude)
        return DoorToDoor.Option(headline: "Straight there", legs: [leg], minutes: 3, fareLow: 0, fareHigh: 0)
    }

    /// The fault behind Follow this way doing nothing for anywhere close: a fixed 250 m circle
    /// made a trip to somewhere 150 m off arrive before it started. Near is now led like far.
    @Test func aShortTripDoesntArriveAsItSetsOff() {
        let shop = GeoMath.coordinate(home, metres: 150, bearing: 90)
        for mode in [DoorToDoor.Mode.walk, .auto] {
            let setOff = TripGuide.status(for: shortTrip(to: shop, mode: mode), startedAt: start, now: start,
                                          location: home, origin: home)
            #expect(setOff?.hasArrived == false)
        }
        let nearly = GeoMath.coordinate(home, metres: 130, bearing: 90)
        let there = TripGuide.status(for: shortTrip(to: shop), startedAt: start, now: start.addingTimeInterval(120),
                                     location: nearly, origin: home)
        #expect(there?.hasArrived == true)
    }

    /// The same for anything PathOS will plan: past "Here", setting off is never arriving.
    @Test func nothingPlannableArrivesOnItsFirstFix() {
        for metres in [DoorToDoor.tooCloseToRoute + 1, 60, 120, 240, 400, 900] {
            let end = GeoMath.coordinate(home, metres: metres, bearing: 45)
            let leg = shortTrip(to: end).legs[0]
            #expect(TripGuide.radius(for: leg, from: home) < GeoMath.distance(from: home, to: end))
        }
    }

    /// A long leg arrives at the place, not a couple of hundred metres short of it — that ended
    /// the driving view early. A station keeps its wide circle: GPS underground can't be asked
    /// for more.
    @Test func aLongLegArrivesAtTheDoorNotAStreetShort() {
        let leg = trip().legs[0]
        #expect(TripGuide.radius(for: leg, from: home) == TripGuide.doorRadius)
        #expect(TripGuide.radius(for: trip().legs[1], from: station) == TripGuide.stationRadius)
        let short = GeoMath.coordinate(station, metres: 200, bearing: 0)
        let stillGoing = TripGuide.status(for: trip(), startedAt: start, now: start.addingTimeInterval(9 * 60),
                                          location: short, origin: home)
        #expect(stillGoing?.legIndex == 0)
    }

    // MARK: The end of the road

    /// A campus whose pin is 200 m inside its gate: the road ends at the gate, and reaching the
    /// gate is arriving. Before it — 150 m down the road — isn't.
    @Test func theEndOfTheRoadIsArriving() {
        let college = GeoMath.coordinate(home, metres: 3_000, bearing: 0)
        let gate = GeoMath.coordinate(college, metres: 200, bearing: 180)
        let drive = shortTrip(to: college, mode: .auto)
        let end = TripGuide.RoadEnd(leg: 0, point: gate)
        let atGate = TripGuide.status(for: drive, startedAt: start, now: start.addingTimeInterval(600),
                                      location: GeoMath.coordinate(gate, metres: 15, bearing: 90), origin: home, roadEnd: end)
        #expect(atGate?.hasArrived == true)
        let short = TripGuide.status(for: drive, startedAt: start, now: start.addingTimeInterval(600),
                                     location: GeoMath.coordinate(gate, metres: 150, bearing: 180), origin: home, roadEnd: end)
        #expect(short?.hasArrived == false)
    }

    /// Parked just short of the end and stopped there: arrived.
    @Test func parkingJustShortIsArriving() {
        let college = GeoMath.coordinate(home, metres: 3_000, bearing: 0)
        let parked = TripGuide.RoadEnd(leg: 0, point: college, hasStoppedNear: true)
        let status = TripGuide.status(for: shortTrip(to: college, mode: .auto), startedAt: start,
                                      now: start.addingTimeInterval(600),
                                      location: GeoMath.coordinate(college, metres: 120, bearing: 180),
                                      origin: home, roadEnd: parked)
        #expect(status?.hasArrived == true)
    }

    /// Which side of the road the place is, arriving northwards.
    @Test func whichSideItsOn() {
        let end = GeoMath.coordinate(home, metres: 1_000, bearing: 0)
        #expect(TripGuide.side(of: GeoMath.coordinate(end, metres: 60, bearing: 270), from: end, arrivingAlong: 0) == .left)
        #expect(TripGuide.side(of: GeoMath.coordinate(end, metres: 60, bearing: 90), from: end, arrivingAlong: 0) == .right)
        #expect(TripGuide.side(of: GeoMath.coordinate(end, metres: 60, bearing: 5), from: end, arrivingAlong: 0) == .ahead)
        #expect(TripGuide.side(of: GeoMath.coordinate(end, metres: 10, bearing: 90), from: end, arrivingAlong: 0) == .here)
    }

    @Test func theSentenceSaysWhere() {
        func arrival(_ side: TripGuide.Side) -> TripArrival {
            TripArrival(destinationName: "BMS College of Engineering", latitude: 0, longitude: 0, side: side,
                        at: start, minutesDoorToDoor: 22)
        }
        #expect(arrival(.left).sentence == "BMS College of Engineering is on your left")
        #expect(arrival(.here).sentence == "You're at BMS College of Engineering")
    }
}
