import CoreLocation
import Foundation
import Testing
@testable import PathOS

/// Whole ways of getting somewhere: an auto to the station, the ride, and something at the far end.
struct DoorToDoorTests {
    /// Jayadeva Hospital metro, and a home a couple of kilometres from it.
    let home = CLLocationCoordinate2D(latitude: 12.9265, longitude: 77.5935)
    /// Near Mahatma Gandhi Road station, across the city.
    let office = CLLocationCoordinate2D(latitude: 12.9757, longitude: 77.6068)
    let noon = Date(timeIntervalSince1970: 1_790_000_000)

    /// Apple Maps stands in: road at 20 km/h, walking at 4.5, straight-line distances.
    private func roads(multiplier: Double = 1) -> DoorToDoor.RoadTimes {
        { from, to, byRoad in
            let metres = GeoMath.distance(from: from, to: to) * (byRoad ? 1.35 : 1.15)
            let speed = byRoad ? 20_000.0 : 4_500.0
            return DoorToDoor.RoadHop(minutes: max(1, Int((metres / speed * 60 * multiplier).rounded())), distanceMeters: metres)
        }
    }

    @Test func aCrossCityJourneyOffersRoadAndMetro() async {
        // Seven hundred metres from Mahatma Gandhi Road station: a walk at the far end.
        let offices = CLLocationCoordinate2D(latitude: 12.9810, longitude: 77.6100)
        let options = await DoorToDoor.options(from: home, to: offices, destinationName: "Office", now: noon, road: roads())
        #expect(options.contains { $0.legs.allSatisfy { $0.mode == .auto } })

        let metro = try! #require(options.first { $0.legs.contains { $0.mode == .metro } })
        // Something to the station, the ride, something at the far end.
        #expect(metro.legs.count == 3)
        #expect(metro.legs.first?.mode != .metro && metro.legs.last?.mode != .metro)
        // Every leg is timed and the total is at least their sum.
        #expect(metro.legs.allSatisfy { $0.minutes > 0 })
        #expect(metro.minutes >= metro.legs.reduce(0) { $0 + $1.minutes })
        // The ride can be followed stop by stop.
        #expect(metro.legs.first { $0.mode == .metro }?.metro != nil)
    }

    /// The two stations anyone would name: the one nearest you, and the one nearest where you're
    /// going — not the one a stop along the line that happens to save a change. Boarding at
    /// Ragigudda to ride one stop to RV Road, then taking an auto the rest of the way, is what
    /// this stops: the ride has to be most of the journey.
    @Test func itBoardsAndAlightsAtTheStationsYoudExpect() async {
        // Beside Jayadeva Hospital station, going to BMS College of Engineering, whose nearest
        // station is National College.
        let here = CLLocationCoordinate2D(latitude: 12.9200, longitude: 77.5990)
        let college = CLLocationCoordinate2D(latitude: 12.9412, longitude: 77.5656)
        let options = await DoorToDoor.options(from: here, to: college, destinationName: "BMS College", now: noon, road: roads())
        let metro = try! #require(options.first { $0.legs.contains { $0.mode == .metro } })
        let ride = try! #require(metro.legs.first { $0.mode == .metro })

        #expect(ride.metro?.origin == "Jayadeva Hospital")
        #expect(ride.endName == "National College")
        #expect((ride.metro?.stationsTravelled ?? 0) >= 3)
        // And the journey says which stations, so it can be checked at a glance.
        #expect(metro.headline.contains("Jayadeva Hospital") && metro.headline.contains("National College"))
    }

    /// Both ends, from anywhere: the nearest station wins even where another would be quicker.
    @Test func itAlwaysUsesTheNearestStations() async {
        for (from, to) in [(home, office), (office, home)] {
            let options = await DoorToDoor.options(from: from, to: to, destinationName: "There", now: noon, road: roads())
            guard let ride = options.compactMap({ $0.legs.first { $0.mode == .metro } }).first else { continue }
            #expect(ride.metro?.origin == MetroNetwork.nearbyStations(to: from, atLeast: 1).first?.station.name)
            #expect(ride.endName == MetroNetwork.nearbyStations(to: to, atLeast: 1).first?.station.name)
        }
    }

    /// The walk is only offered when it's a walk anyone would take.
    @Test func onlyShortJourneysAreOfferedOnFoot() async {
        let nearby = CLLocationCoordinate2D(latitude: home.latitude + 0.008, longitude: home.longitude)
        let short = await DoorToDoor.options(from: home, to: nearby, destinationName: "The shop", now: noon, road: roads())
        #expect(short.contains { $0.legs.allSatisfy { $0.mode == .walk } })

        let far = await DoorToDoor.options(from: home, to: office, destinationName: "Office", now: noon, road: roads())
        #expect(!far.contains { $0.legs.allSatisfy { $0.mode == .walk } })
    }

    /// Each road leg carries what an auto, a bike taxi and a cab would cost, and the journey's
    /// total is a range, never a price.
    @Test func everyRoadLegIsPricedThreeWays() async {
        let options = await DoorToDoor.options(from: home, to: office, destinationName: "Office", now: noon, road: roads())
        let byRoad = try! #require(options.first { $0.legs.allSatisfy { $0.mode == .auto } })
        let leg = try! #require(byRoad.legs.first)
        #expect(Set(leg.fares.map(\.mode)) == [.auto, .bikeTaxi, .cab])
        #expect(leg.fares.allSatisfy { $0.estimate.low > 0 && $0.estimate.high >= $0.estimate.low })
        // The auto's fare is what the journey is costed at: the city sets it, and a total that
        // mixed a bike taxi's floor with a cab's ceiling would mean nothing.
        #expect(byRoad.fareLow == leg.fares.first { $0.mode == .auto }?.estimate.low)
    }

    /// The metro leg says what it costs on a token and on a card, from BMRCL's own slabs.
    @Test func theRideIsPricedFromTheFareTable() async {
        let options = await DoorToDoor.options(from: home, to: office, destinationName: "Office", now: noon, road: roads())
        let ride = try! #require(options.compactMap { $0.legs.first { $0.mode == .metro } }.first)
        let fare = try! #require(ride.fares.first)
        #expect(fare.estimate.low <= fare.estimate.high)
        #expect(fare.estimate.high == MetroRouter.fare(stationsTravelled: ride.metro!.stationsTravelled, at: noon).token)
    }

    /// Quickest first, and anything that isn't running is last however quick it claims to be.
    @Test func whatIsRunningComesFirst() async {
        let night = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: noon)!
        let options = await DoorToDoor.options(from: home, to: office, destinationName: "Office", now: night, road: roads())
        #expect(options.first?.isAvailableNow == true)
        if let metro = options.first(where: { $0.legs.contains { $0.mode == .metro } }) {
            #expect(!metro.isAvailableNow)
            #expect(metro.notes.contains { $0.contains("isn't running") })
            #expect(options.last?.id == metro.id)
        }
    }

    /// Somewhere you're already standing isn't a journey.
    @Test func thereIsNothingToPlanNextDoor() async {
        let options = await DoorToDoor.options(from: home, to: home, destinationName: "Home", now: noon, road: roads())
        #expect(options.isEmpty)
    }

    /// Anywhere PathOS doesn't call "Here" is somewhere a way can be planned to, however close:
    /// near and far are led the same way.
    @Test func anywhereBeyondHereIsPlanned() async {
        let justPast = GeoMath.coordinate(home, metres: 150, bearing: 90)
        let options = await DoorToDoor.options(from: home, to: justPast, destinationName: "The shop",
                                               now: noon, road: roads())
        #expect(!options.isEmpty)
    }

    /// The fault behind "by road to BTM Layout, then the Yellow Line back to Jayadeva": going to
    /// the station by Jayadeva Hospital, the nearest station was the destination itself, so the
    /// next one along was tried as somewhere to board. Getting on has to be on your way.
    @Test func itNeverBoardsAwayFromWhereYoureGoing() async {
        // Where Jayadeva Hospital is the nearest station, then BTM Layout, then Ragigudda.
        let here = CLLocationCoordinate2D(latitude: 12.9105, longitude: 77.6004)
        let jayadeva = CLLocationCoordinate2D(latitude: 12.916764, longitude: 77.600442)
        let options = await DoorToDoor.options(from: here, to: jayadeva, destinationName: "Jayadeva Hospital",
                                               now: noon, road: roads())
        #expect(!options.isEmpty)
        #expect(!options.contains { $0.legs.contains { $0.mode == .metro } })
    }

    /// Your own three stations — Jayadeva Hospital nearest, then BTM Layout, then Ragigudda.
    /// Going to either of the other two, the metro from the nearest is offered: a stop each way.
    /// Apple Maps, as here, can't route the zero metres from a station to itself; that used to
    /// lose the metro journey altogether.
    @Test(arguments: [
        // Seven hundred metres south of Jayadeva Hospital.
        CLLocationCoordinate2D(latitude: 12.9105, longitude: 77.6004),
        // A couple of kilometres south: the station is an auto ride away, and the one stop to
        // BTM Layout is short beside that. It used to be ruled out for it.
        CLLocationCoordinate2D(latitude: 12.895, longitude: 77.6004),
        // Almost as near BTM Layout as Jayadeva Hospital.
        CLLocationCoordinate2D(latitude: 12.9125, longitude: 77.6040),
    ])
    func theNearestStationTakesYouToTheOthers(here: CLLocationCoordinate2D) async {
        let nearest = MetroNetwork.nearbyStations(to: here, atLeast: 3).prefix(3).map(\.station.name)
        #expect(nearest == ["Jayadeva Hospital", "BTM Layout", "Ragigudda"])
        let timed = roads()
        let appleMaps: DoorToDoor.RoadTimes = { from, to, byRoad in
            guard GeoMath.distance(from: from, to: to) > 1 else { return nil }
            return await timed(from, to, byRoad)
        }
        for (name, station) in [("BTM Layout", CLLocationCoordinate2D(latitude: 12.916598, longitude: 77.608622)),
                                ("Ragigudda", CLLocationCoordinate2D(latitude: 12.917089, longitude: 77.588698))] {
            let options = await DoorToDoor.options(from: here, to: station, destinationName: name, now: noon, road: appleMaps)
            let metro = options.first { $0.legs.contains { $0.mode == .metro } }
            #expect(metro != nil, "\(name)")
            let ride = metro?.legs.first { $0.mode == .metro }
            #expect(ride?.metro?.origin == "Jayadeva Hospital", "\(name)")
            #expect(ride?.endName == name)
            // Off the train is there: no walk from the station to itself.
            #expect(metro?.legs.last?.mode == .metro, "\(name)")
        }
    }

    /// Without Apple Maps, the legs still get times rather than disappearing.
    /// A place right outside a station is reached by the ride itself: no walk of a few metres
    /// from the station to it.
    @Test func noWalkFromAStationToItsOwnDoor() async {
        let options = await DoorToDoor.options(from: home, to: office, destinationName: "Office", now: noon, road: roads())
        let metro = try! #require(options.first { $0.legs.contains { $0.mode == .metro } })
        #expect(metro.legs.last?.mode == .metro)
    }

    @Test func itStillPlansWithoutAppleMaps() async {
        let options = await DoorToDoor.options(from: home, to: office, destinationName: "Office", now: noon, road: { _, _, _ in nil })
        #expect(!options.isEmpty)
        #expect(options.allSatisfy { $0.legs.allSatisfy { $0.minutes > 0 } })
    }
}

/// Auto fares are the city's and can be worked out; app fares move, so they're ranges.
struct RoadFareTests {
    let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!

    @Test func theAutoFollowsTheMeter() throws {
        let auto = try #require(RoadFares.rate("auto"))
        // 2 km is the minimum; 6 km is the minimum plus four more kilometres.
        #expect(RoadFares.estimate(auto, distanceMeters: 1_500, at: noon).low == 30)
        let six = RoadFares.estimate(auto, distanceMeters: 6_000, at: noon)
        #expect(six.low <= 90 && six.high >= 90)
        #expect(six.isRegulated)
    }

    @Test func theNightRateApplies() throws {
        let auto = try #require(RoadFares.rate("auto"))
        let night = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: Date())!
        #expect(RoadFares.estimate(auto, distanceMeters: 6_000, at: night).low > RoadFares.estimate(auto, distanceMeters: 6_000, at: noon).low)
        #expect(RoadFares.isNight(night, rate: auto))
        #expect(!RoadFares.isNight(noon, rate: auto))
    }

    /// A cab's fare is never stated as a price: it comes as a range, and a wide one.
    @Test func appFaresAreRanges() throws {
        let cab = try #require(RoadFares.rate("cab"))
        let fare = RoadFares.estimate(cab, distanceMeters: 8_000, at: noon)
        #expect(fare.high > fare.low)
        #expect(!fare.isRegulated)
        #expect(fare.text.contains("–"))
    }
}
