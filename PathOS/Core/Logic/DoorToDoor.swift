import CoreLocation
import Foundation

/// Whole ways to get somewhere, door to door.
///
/// A metro ride is rarely the journey: it's an auto to the station, the ride, and something at the
/// other end. This builds those whole journeys — every leg, how long each takes, and what each
/// costs — so a way to get there can be compared against going by road the entire way.
///
/// Times for the road legs come from Apple Maps, passed in rather than fetched here, so the
/// planning itself stays pure and testable. Everything is an estimate and is labelled as one:
/// no Indian operator publishes live positions, and app fares move with demand.
nonisolated enum DoorToDoor {

    nonisolated enum Mode: String, Hashable, Sendable {
        case walk
        case auto
        case bikeTaxi
        case cab
        case metro
        case bus

        var symbol: String {
            switch self {
            case .walk: "figure.walk"
            case .auto: "car.rear.fill"
            case .bikeTaxi: "scooter"
            case .cab: "car.fill"
            case .metro: "tram.fill"
            case .bus: "bus.fill"
            }
        }

        var name: String {
            switch self {
            case .walk: "Walk"
            case .auto: "Auto"
            case .bikeTaxi: "Bike taxi"
            case .cab: "Cab"
            case .metro: "Metro"
            case .bus: "Bus"
            }
        }
    }

    /// One fare for one way of covering a leg. A road leg has one of these for the auto, the bike
    /// taxi and the cab, because they're the same leg at different prices.
    nonisolated struct LegFare: Hashable, Sendable {
        var mode: Mode
        var estimate: FareEstimate
        var note: String
    }

    nonisolated struct Leg: Hashable, Sendable, Identifiable {
        var id = UUID()
        var mode: Mode
        /// "Auto to Jayadeva Hospital", "Yellow Line to BTM Layout".
        var title: String
        /// "6 stops · towards Bommasandra", "1.4 km".
        var detail: String?
        var minutes: Int
        var distanceMeters: Double
        /// Where the leg ends, for tracking how far along you are.
        var endName: String
        var endLatitude: Double
        var endLongitude: Double
        /// The ways to pay for a road leg, or the metro's token and smart-card fares.
        var fares: [LegFare] = []
        /// Set on a metro leg, so the ride can be followed stop by stop.
        var metro: MetroRoute?

        var endCoordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: endLatitude, longitude: endLongitude)
        }

        /// What the leg costs the usual way: in an auto on a road leg, since that's the fare the
        /// city sets and the one most people pay. The others are shown beside it, but a journey's
        /// total can't mix a bike taxi's floor with a cab's ceiling and mean anything.
        var headlineFare: LegFare? {
            fares.first { $0.mode == .auto } ?? fares.first
        }
    }

    nonisolated struct Option: Hashable, Sendable, Identifiable {
        var id = UUID()
        /// What the journey is, in a few words: "Metro, with an auto to the station".
        var headline: String
        var legs: [Leg]
        var minutes: Int
        /// The range across the whole journey, taking each leg's cheapest way.
        var fareLow: Int
        var fareHigh: Int
        /// True where the fare can't be known, as on a BMTC bus: free and unknown are not the same.
        var fareIsUnknown = false
        /// "Trains start at 5:00 AM", "Fares are paid to the conductor".
        var notes: [String] = []
        /// False when the metro or the bus isn't running at that hour.
        var isAvailableNow = true

        var kind: Mode { legs.first { $0.mode == .metro || $0.mode == .bus }?.mode ?? legs.first?.mode ?? .walk
        }

        var fareText: String {
            if fareIsUnknown { return "fare on board" }
            return fareLow == 0 && fareHigh == 0 ? "free" : FareEstimate(low: fareLow, high: fareHigh, isRegulated: false).text
        }

        /// The place each leg hands over at, for following the journey.
        var checkpoints: [Leg] { legs }
    }

    /// A road hop as Apple Maps times it.
    nonisolated struct RoadHop: Hashable, Sendable {
        var minutes: Int
        var distanceMeters: Double
    }

    /// Asked for each road or walking leg. Returning nil falls back to a rough estimate.
    typealias RoadTimes = @Sendable (CLLocationCoordinate2D, CLLocationCoordinate2D, Bool) async -> RoadHop?

    /// Far enough that you'd take something to the station rather than walk.
    /// Nearer than this and there is no journey to plan: you can see it from where you stand, and
    /// what helps is a pointer, not a route.
    static let tooCloseToRoute = 120.0
    static let walkToStation = 1_100.0
    /// Getting in, buying a token and reaching the platform.
    static let stationEntryMinutes = 4
    /// Under this, the whole way on foot is worth offering.
    static let walkableJourney = 2_000.0
    /// Stations tried at each end.
    static let stationsTried = 3
    /// Longer than this between buses and it isn't a service you'd plan around.
    static let longestWait = 30
    /// The share of the journey the ride itself has to cover to be worth taking.
    static let rideShare = 0.45

    // MARK: Planning

    static func options(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        destinationName: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        bus: BusNetwork? = nil,
        road: RoadTimes
    ) async -> [Option] {
        let straight = GeoMath.distance(from: origin, to: destination)
        guard straight > tooCloseToRoute else { return [] }

        var options: [Option] = []
        if let byRoad = await roadOption(from: origin, to: destination, name: destinationName, now: now, calendar: calendar, road: road) {
            options.append(byRoad)
        }
        if straight <= walkableJourney, let walk = await walkOption(from: origin, to: destination, name: destinationName, road: road) {
            options.append(walk)
        }
        if let metro = await metroOption(from: origin, to: destination, name: destinationName, now: now, calendar: calendar, road: road) {
            options.append(metro)
        }
        if let bus, let ride = await busOption(from: origin, to: destination, name: destinationName, now: now, calendar: calendar, network: bus, road: road) {
            options.append(ride)
        }
        // Quickest first, but anything that isn't running yet goes last however quick it would be.
        return options.sorted {
            $0.isAvailableNow == $1.isAvailableNow ? $0.minutes < $1.minutes : $0.isAvailableNow
        }
    }

    // MARK: The ways

    private static func roadOption(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
                                   name: String, now: Date, calendar: Calendar, road: RoadTimes) async -> Option? {
        guard let hop = await hop(from: origin, to: destination, byRoad: true, road: road) else { return nil }
        let leg = roadLeg(hop, to: destination, name: name, now: now, calendar: calendar, title: "By road to \(name)")
        let fare = leg.headlineFare?.estimate
        return Option(
            headline: "Straight there by road",
            legs: [leg],
            minutes: hop.minutes,
            fareLow: fare?.low ?? 0,
            fareHigh: fare?.high ?? 0
        )
    }

    private static func walkOption(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
                                   name: String, road: RoadTimes) async -> Option? {
        guard let hop = await hop(from: origin, to: destination, byRoad: false, road: road) else { return nil }
        let leg = Leg(
            mode: .walk,
            title: "Walk to \(name)",
            detail: GeoMath.formatDistance(hop.distanceMeters),
            minutes: hop.minutes,
            distanceMeters: hop.distanceMeters,
            endName: name,
            endLatitude: destination.latitude,
            endLongitude: destination.longitude
        )
        return Option(headline: "On foot", legs: [leg], minutes: hop.minutes, fareLow: 0, fareHigh: 0)
    }

    /// The metro journey: on at the station nearest you, off at the station nearest where you're
    /// going.
    ///
    /// Those two stations, and no others, unless the pair can't actually be used — no route
    /// between them, or a ride so short it leaves the travelling to an auto. Weighing minutes
    /// instead used to board a station or two along the line to save a change, which is a fair
    /// trade on paper and reads as PathOS picking stations at random: the answer has to be the
    /// one you can check against what you already know about the city.
    private static func metroOption(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
                                    name: String, now: Date, calendar: Calendar, road: RoadTimes) async -> Option? {
        let boarding = Array(MetroNetwork.nearbyStations(to: origin, atLeast: stationsTried).prefix(stationsTried))
        let alighting = Array(MetroNetwork.nearbyStations(to: destination, atLeast: stationsTried).prefix(stationsTried))
        let journey = GeoMath.distance(from: origin, to: destination)

        // Nearest first at both ends, and the first pair that works is the answer. The rest are
        // only there for when the nearest station is no use: a line that doesn't reach, or a ride
        // that would cover nothing.
        for start in boarding {
            for end in alighting where end.station.name != start.station.name {
                // Getting off has to leave you meaningfully closer than getting on did. Comparing
                // the two stations' own distance instead would throw out good journeys, since a
                // metro line bends and its stations can be further apart than the places they serve.
                guard GeoMath.distance(from: end.station.coordinate, to: destination)
                        < GeoMath.distance(from: start.station.coordinate, to: destination) - 500 else { continue }
                // And the ride has to be most of the journey. A stop or two between stations that
                // are both miles from where you're going is a metro ride in name only: it looked
                // quick on the clock while leaving an auto to do the real travelling.
                guard GeoMath.distance(from: start.station.coordinate, to: end.station.coordinate) >= journey * rideShare else { continue }
                if let built = await metroJourney(from: origin, boardingAt: start.station, alightingAt: end.station,
                                                  to: destination, name: name, now: now, calendar: calendar, road: road) {
                    return built.option
                }
            }
        }
        return nil
    }

    /// One metro journey between two named stations, with its access and egress legs.
    private static func metroJourney(from origin: CLLocationCoordinate2D, boardingAt board: MetroStation,
                                     alightingAt alight: MetroStation, to destination: CLLocationCoordinate2D,
                                     name: String, now: Date, calendar: Calendar,
                                     road: RoadTimes) async -> (option: Option, minutes: Int)? {
        guard let route = MetroRouter.route(from: board.name, to: alight.name, at: now, calendar: calendar) else { return nil }
        guard let access = await accessLeg(from: origin, to: board, now: now, calendar: calendar, road: road),
              let egress = await egressLeg(from: alight, to: destination, name: name, now: now, calendar: calendar, road: road)
        else { return nil }

        let fare = MetroRouter.fare(stationsTravelled: route.stationsTravelled, at: now, calendar: calendar)
        let ride = Leg(
            mode: .metro,
            title: "\(route.lineSummary) to \(alight.name)",
            detail: rideDetail(route),
            minutes: route.minutes,
            distanceMeters: route.distanceMeters,
            endName: alight.name,
            endLatitude: alight.lat,
            endLongitude: alight.lon,
            fares: [LegFare(
                mode: .metro,
                estimate: FareEstimate(low: Int(fare.smartCard.rounded()), high: fare.token, isRegulated: true),
                note: "₹\(fare.token) token, ₹\(Int(fare.smartCard.rounded())) with a smart card"
            )],
            metro: route
        )
        let legs = [access, ride, egress]
        let minutes = legs.reduce(0) { $0 + $1.minutes } + stationEntryMinutes

        var notes = ["Times include about \(stationEntryMinutes) min to get in and onto the platform, and half a wait for a train."]
        var available = true
        for ride in route.rides {
            guard let line = ride.line else { continue }
            switch MetroSchedule.status(for: line, at: now, calendar: calendar) {
            case .running: break
            case .closingSoon(let last):
                notes.append("Last trains on the \(line.name) around \(last.formatted(date: .omitted, time: .shortened)).")
            case .closed(let first):
                notes.append("The \(line.name) isn't running: first train \(first.formatted(date: .omitted, time: .shortened)).")
                available = false
            }
        }
        let option = Option(
            headline: "\(route.lineSummary) from \(board.name) to \(alight.name)",
            legs: legs,
            minutes: minutes,
            fareLow: legs.compactMap { $0.headlineFare?.estimate.low }.reduce(0, +),
            fareHigh: legs.compactMap { $0.headlineFare?.estimate.high }.reduce(0, +),
            notes: notes,
            isAvailableNow: available
        )
        return (option, minutes)
    }

    private static func busOption(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
                                  name: String, now: Date, calendar: Calendar, network: BusNetwork, road: RoadTimes) async -> Option? {
        let from = network.nearbyStops(to: origin, within: 700)
        let to = network.nearbyStops(to: destination, within: 700)
        guard let start = from.first, let end = to.first, start.stop.name != end.stop.name else { return nil }
        guard let ride = network.directOptions(from: start.stop.name, to: end.stop.name, at: now, calendar: calendar).first else { return nil }

        guard let walkTo = await hop(from: origin, to: start.stop.coordinate, byRoad: false, road: road),
              let walkFrom = await hop(from: end.stop.coordinate, to: destination, byRoad: false, road: road) else { return nil }
        let wait = ride.service.everyMinutes.map { $0 / 2 } ?? 10
        // A bus every three hours is not a way of getting somewhere. Where the data says the
        // wait is this long, it's either a rare service or wrong, and neither is worth offering.
        guard wait <= longestWait else { return nil }
        let legs = [
            Leg(mode: .walk, title: "Walk to \(start.stop.name)", detail: GeoMath.formatDistance(walkTo.distanceMeters),
                minutes: walkTo.minutes, distanceMeters: walkTo.distanceMeters,
                endName: start.stop.name, endLatitude: start.stop.latitude, endLongitude: start.stop.longitude),
            Leg(mode: .bus, title: "Bus \(ride.service.pattern.route.number) to \(end.stop.name)",
                detail: "\(ride.stopsCount) stops · about \(wait) min waiting",
                minutes: ride.rideMinutes + wait, distanceMeters: 0,
                endName: end.stop.name, endLatitude: end.stop.latitude, endLongitude: end.stop.longitude),
            Leg(mode: .walk, title: "Walk to \(name)", detail: GeoMath.formatDistance(walkFrom.distanceMeters),
                minutes: walkFrom.minutes, distanceMeters: walkFrom.distanceMeters,
                endName: name, endLatitude: destination.latitude, endLongitude: destination.longitude),
        ]
        return Option(
            headline: "Bus \(ride.service.pattern.route.number)",
            legs: legs,
            minutes: legs.reduce(0) { $0 + $1.minutes },
            fareLow: 0,
            fareHigh: 0,
            fareIsUnknown: true,
            notes: ["The fare is paid on board: BMTC publishes no fare table PathOS can read.",
                    "Bus timings in this data are rough, and there are no live positions."],
            isAvailableNow: ride.service.isRunningNow
        )
    }

    // MARK: Legs

    private static func accessLeg(from origin: CLLocationCoordinate2D, to station: MetroStation,
                                  now: Date, calendar: Calendar, road: RoadTimes) async -> Leg? {
        let straight = GeoMath.distance(from: origin, to: station.coordinate)
        if straight <= walkToStation {
            guard let hop = await hop(from: origin, to: station.coordinate, byRoad: false, road: road) else { return nil }
            return Leg(mode: .walk, title: "Walk to \(station.name)", detail: GeoMath.formatDistance(hop.distanceMeters),
                       minutes: hop.minutes, distanceMeters: hop.distanceMeters,
                       endName: station.name, endLatitude: station.lat, endLongitude: station.lon)
        }
        guard let hop = await hop(from: origin, to: station.coordinate, byRoad: true, road: road) else { return nil }
        return roadLeg(hop, to: station.coordinate, name: station.name, now: now, calendar: calendar,
                       title: "Auto to \(station.name)")
    }

    private static func egressLeg(from station: MetroStation, to destination: CLLocationCoordinate2D, name: String,
                                  now: Date, calendar: Calendar, road: RoadTimes) async -> Leg? {
        let straight = GeoMath.distance(from: station.coordinate, to: destination)
        if straight <= walkToStation {
            guard let hop = await hop(from: station.coordinate, to: destination, byRoad: false, road: road) else { return nil }
            return Leg(mode: .walk, title: "Walk to \(name)", detail: GeoMath.formatDistance(hop.distanceMeters),
                       minutes: hop.minutes, distanceMeters: hop.distanceMeters,
                       endName: name, endLatitude: destination.latitude, endLongitude: destination.longitude)
        }
        guard let hop = await hop(from: station.coordinate, to: destination, byRoad: true, road: road) else { return nil }
        return roadLeg(hop, to: destination, name: name, now: now, calendar: calendar, title: "Auto to \(name)")
    }

    /// A leg you'd take an auto for, priced for an auto, a bike taxi and a cab, since it's the
    /// same leg whichever pulls up.
    static func roadLeg(_ hop: RoadHop, to end: CLLocationCoordinate2D, name: String,
                        now: Date, calendar: Calendar = .current, title: String) -> Leg {
        let fares = RoadFares.data.modes.compactMap { rate -> LegFare? in
            guard let mode = Mode(rawValue: rate.id) else { return nil }
            return LegFare(mode: mode,
                           estimate: RoadFares.estimate(rate, distanceMeters: hop.distanceMeters, at: now, calendar: calendar),
                           note: rate.note)
        }
        return Leg(
            mode: .auto,
            title: title,
            detail: GeoMath.formatDistance(hop.distanceMeters),
            minutes: hop.minutes,
            distanceMeters: hop.distanceMeters,
            endName: name,
            endLatitude: end.latitude,
            endLongitude: end.longitude,
            fares: fares
        )
    }

    private static func hop(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, byRoad: Bool, road: RoadTimes) async -> RoadHop? {
        if let hop = await road(from, to, byRoad) { return hop }
        // Apple Maps couldn't route it: fall back to the same rough speeds used for leaving on time.
        let straight = GeoMath.distance(from: from, to: to)
        guard straight > 0 else { return nil }
        return RoadHop(
            minutes: byRoad ? LeaveOnTime.roughTravelMinutes(distance: max(straight, LeaveOnTime.walkingDistance + 1))
                            : GeoMath.walkingMinutes(forDistance: straight),
            distanceMeters: straight * (byRoad ? 1.4 : 1.2)
        )
    }

    // MARK: Words

    private static func rideDetail(_ route: MetroRoute) -> String {
        var parts = ["\(route.stationsTravelled) stops"]
        if let first = route.rides.first {
            parts.append("towards \(first.towards)")
        }
        if !route.changes.isEmpty {
            parts.append("change at \(route.changes.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }

}
