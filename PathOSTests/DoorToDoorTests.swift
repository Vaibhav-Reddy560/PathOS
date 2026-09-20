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
        let options = await DoorToDoor.options(from: home, to: office, destinationName: "Office", now: noon, road: roads())
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

    /// Without Apple Maps, the legs still get times rather than disappearing.
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
