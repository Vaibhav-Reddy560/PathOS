import CoreLocation
import Foundation

nonisolated struct BusStop: Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    /// Which side of the road: BMTC names the direction a stop serves, e.g. "Towards Majestic".
    var towards: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

nonisolated struct BusRoute: Hashable, Sendable {
    /// "500D", "KBS-3C".
    var number: String
    /// "Hebbal ⇔ Central Silk Board".
    var name: String
}

/// One route in one direction: the stops it calls at and how often it runs.
nonisolated struct BusPattern: Identifiable, Hashable, Sendable {
    var id: Int
    var route: BusRoute
    var headsign: String
    var stops: [Int]
    /// Scheduled minutes from each stop to the next.
    var gaps: [Int]
    var tripsPerDay: Int
    /// Minutes after midnight that the first and last buses leave the first stop.
    var firstDeparture: Int
    var lastDeparture: Int
    var headwayPeak: Int?
    var headwayOffPeak: Int?

    /// Scheduled minutes from the first stop to the stop at `position`.
    func minutes(to position: Int) -> Int {
        gaps.prefix(position).reduce(0, +)
    }
}

/// How a pattern serves one stop right now.
nonisolated struct BusService: Identifiable, Hashable, Sendable {
    var pattern: BusPattern
    var position: Int
    /// Roughly how often at this hour, when the timetable has enough buses to say.
    var everyMinutes: Int?
    /// When the first and last buses reach this stop.
    var firstAtStop: Int
    var lastAtStop: Int
    var isRunningNow: Bool

    var id: Int { pattern.id }
}

/// A direct bus from one stop to another.
nonisolated struct BusOption: Hashable, Sendable {
    var service: BusService
    var fromStop: BusStop
    var toStop: BusStop
    var toPosition: Int

    var stopsCount: Int { toPosition - service.position }
    var rideMinutes: Int { service.pattern.minutes(to: toPosition) - service.pattern.minutes(to: service.position) }
}

/// BMTC's stops and routes, bundled from the community GTFS feed (see `source`).
///
/// Timings come from the Namma BMTC app, whose timetables are known to be rough, so everything
/// derived from them is shown as approximate. There are no live bus positions.
nonisolated final class BusNetwork: Sendable {
    nonisolated struct Source: Sendable, Decodable {
        var what: String
        var url: String
        var licence: String
        var caveat: String
    }

    let stops: [BusStop]
    let patterns: [BusPattern]
    let source: Source
    let generated: String
    /// Patterns and the position they reach each stop at, by stop id.
    private let services: [[(pattern: Int, position: Int)]]
    /// Stop ids by grid cell, for nearby queries without scanning ten thousand stops.
    private let grid: [GridCell: [Int]]
    private let names: [String]

    private nonisolated struct GridCell: Hashable {
        var latitude: Int
        var longitude: Int
    }

    /// About 550 m of latitude.
    private static let cellDegrees = 0.005

    init(json: Data) throws {
        struct File: Decodable {
            struct Pattern: Decodable {
                var r: Int
                var h: String
                var s: [Int]
                var d: [Int]
                var n: Int
                var f: Int
                var l: Int
                var hp: Int?
                var ho: Int?
            }

            var generated: String
            var source: Source
            var stops: [[JSONValue]]
            var routes: [[String]]
            var patterns: [Pattern]
        }

        let file = try JSONDecoder().decode(File.self, from: json)
        stops = file.stops.enumerated().map { index, row in
            BusStop(id: index, name: row[safe: 0]?.string ?? "", towards: row[safe: 1]?.string ?? "",
                    latitude: row[safe: 2]?.number ?? 0, longitude: row[safe: 3]?.number ?? 0)
        }
        let routes = file.routes.map { BusRoute(number: $0[safe: 0] ?? "", name: $0[safe: 1] ?? "") }
        patterns = file.patterns.enumerated().map { index, row in
            BusPattern(id: index, route: routes[row.r], headsign: row.h, stops: row.s, gaps: row.d,
                       tripsPerDay: row.n, firstDeparture: row.f, lastDeparture: row.l,
                       headwayPeak: row.hp, headwayOffPeak: row.ho)
        }
        source = file.source
        generated = file.generated

        var services = Array(repeating: [(pattern: Int, position: Int)](), count: stops.count)
        for pattern in patterns {
            for (position, stop) in pattern.stops.enumerated() where services.indices.contains(stop) {
                services[stop].append((pattern.id, position))
            }
        }
        self.services = services

        var grid: [GridCell: [Int]] = [:]
        for stop in stops {
            grid[Self.cell(for: stop.coordinate), default: []].append(stop.id)
        }
        self.grid = grid
        names = Array(Set(stops.map(\.name))).sorted()
    }

    private static func cell(for coordinate: CLLocationCoordinate2D) -> GridCell {
        GridCell(latitude: Int((coordinate.latitude / cellDegrees).rounded(.down)),
                 longitude: Int((coordinate.longitude / cellDegrees).rounded(.down)))
    }

    // MARK: Loading

    private static let bundled: BusNetwork? = {
        guard let url = Bundle.main.url(forResource: "bus", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? BusNetwork(json: data)
    }()

    /// The bundled network, decoded off the main thread the first time it's needed.
    static func load() async -> BusNetwork? {
        await Task.detached(priority: .utility) { bundled }.value
    }

    // MARK: Queries

    /// Stops within `radius`, nearest first.
    func nearbyStops(to coordinate: CLLocationCoordinate2D, within radius: Double) -> [(stop: BusStop, distance: Double)] {
        let center = Self.cell(for: coordinate)
        let reach = Int((radius / 550).rounded(.up))
        var found: [(BusStop, Double)] = []
        for latitude in (center.latitude - reach)...(center.latitude + reach) {
            for longitude in (center.longitude - reach)...(center.longitude + reach) {
                for id in grid[GridCell(latitude: latitude, longitude: longitude)] ?? [] {
                    let distance = GeoMath.distance(from: coordinate, to: stops[id].coordinate)
                    if distance <= radius { found.append((stops[id], distance)) }
                }
            }
        }
        return found.sorted { $0.1 < $1.1 }.map { (stop: $0.0, distance: $0.1) }
    }

    /// Every pattern that stops here and goes somewhere afterwards.
    func services(at stopID: Int, at date: Date = Date(), calendar: Calendar = .current) -> [BusService] {
        guard services.indices.contains(stopID) else { return [] }
        let minute = Self.minuteOfDay(date, calendar: calendar)
        return services[stopID]
            .filter { $0.position < patterns[$0.pattern].stops.count - 1 }
            .map { entry in
                let pattern = patterns[entry.pattern]
                let offset = pattern.minutes(to: entry.position)
                let first = pattern.firstDeparture + offset
                let last = pattern.lastDeparture + offset
                return BusService(
                    pattern: pattern,
                    position: entry.position,
                    everyMinutes: Self.isPeak(minute) ? (pattern.headwayPeak ?? pattern.headwayOffPeak) : (pattern.headwayOffPeak ?? pattern.headwayPeak),
                    firstAtStop: first,
                    lastAtStop: last,
                    isRunningNow: minute >= first - 5 && minute <= last + 5
                )
            }
            .sorted { ($0.isRunningNow ? 0 : 1, $0.pattern.route.number) < ($1.isRunningNow ? 0 : 1, $1.pattern.route.number) }
    }

    /// Stops with this name — usually one on each side of the road.
    func stops(named name: String) -> [BusStop] {
        stops.filter { $0.name == name }
    }

    /// Stop names matching a search, for the journey planner.
    func stopNames(matching query: String, limit: Int = 60) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let matches = names.filter { $0.localizedCaseInsensitiveContains(trimmed) }
        // Names that start with the search come first.
        let (leading, rest) = (matches.filter { $0.lowercased().hasPrefix(trimmed.lowercased()) }, matches.filter { !$0.lowercased().hasPrefix(trimmed.lowercased()) })
        return Array((leading + rest).prefix(limit))
    }

    /// Buses that go from a stop with one name to a stop with the other without changing,
    /// quickest first, counting roughly half a wait.
    func directOptions(from origin: String, to destination: String, at date: Date = Date(), calendar: Calendar = .current) -> [BusOption] {
        let destinationIDs = Set(stops(named: destination).map(\.id))
        guard !destinationIDs.isEmpty, origin != destination else { return [] }
        var best: [Int: BusOption] = [:]
        for fromStop in stops(named: origin) {
            for service in services(at: fromStop.id, at: date, calendar: calendar) {
                let pattern = service.pattern
                guard let toPosition = pattern.stops.indices.first(where: { $0 > service.position && destinationIDs.contains(pattern.stops[$0]) }) else { continue }
                let option = BusOption(service: service, fromStop: fromStop, toStop: stops[pattern.stops[toPosition]], toPosition: toPosition)
                if let existing = best[pattern.id], existing.rideMinutes <= option.rideMinutes { continue }
                best[pattern.id] = option
            }
        }
        return best.values.sorted { Self.score($0) < Self.score($1) }
    }

    private static func score(_ option: BusOption) -> Double {
        let wait = Double(option.service.everyMinutes ?? 30) / 2
        return Double(option.rideMinutes) + wait + (option.service.isRunningNow ? 0 : 1_000)
    }

    // MARK: Time

    static func isPeak(_ minute: Int) -> Bool {
        (8 * 60..<11 * 60).contains(minute) || (17 * 60..<20 * 60).contains(minute)
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// "6:10 AM" for minutes after midnight; timetables run past midnight, so it wraps.
    static func clockText(_ minutes: Int, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: Date())
        return day.addingTimeInterval(Double(minutes % (24 * 60)) * 60).formatted(date: .omitted, time: .shortened)
    }

    /// "About every 12 min", "3 buses a day", "Not running now · first at 6:10 AM". Always approximate.
    static func describe(_ service: BusService, calendar: Calendar = .current) -> String {
        if !service.isRunningNow {
            return "Not running now · first around \(clockText(service.firstAtStop, calendar: calendar))"
        }
        if let every = service.everyMinutes {
            return "About every \(every) min"
        }
        return service.pattern.tripsPerDay == 1 ? "1 bus a day" : "\(service.pattern.tripsPerDay) buses a day"
    }
}

extension Journey {
    /// A direct bus ride, stop by stop, with BMTC's scheduled minutes between stops.
    static func bus(_ option: BusOption, network: BusNetwork, startedAt: Date = Date()) -> Journey {
        let pattern = option.service.pattern
        let wait = Double(option.service.everyMinutes ?? 10) / 2
        let base = pattern.minutes(to: option.service.position)
        let stops = (option.service.position...option.toPosition).map { position -> JourneyStop in
            let stop = network.stops[pattern.stops[position]]
            let ride = Double(pattern.minutes(to: position) - base)
            return JourneyStop(name: stop.name, latitude: stop.latitude, longitude: stop.longitude,
                               minutesFromStart: position == option.service.position ? 0 : ride + wait)
        }
        return Journey(kind: .bus, lineName: "Bus \(pattern.route.number)", stops: stops, startedAt: startedAt)
    }
}

/// A JSON value that's either a string or a number, for the bus file's compact rows.
nonisolated enum JSONValue: Decodable, Sendable {
    case string(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}
