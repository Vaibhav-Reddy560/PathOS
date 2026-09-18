import CoreLocation
import Foundation

/// One ride on one line, from where you board to where you get off.
nonisolated struct MetroRide: Hashable, Sendable {
    var lineID: String
    var fromIndex: Int
    var toIndex: Int

    var line: MetroLine? { MetroNetwork.line(id: lineID) }
    var lineName: String { line?.name ?? "Metro" }
    var stops: Int { abs(toIndex - fromIndex) }
    var boardAt: String { line?.stations[safe: fromIndex] ?? "" }
    var getOffAt: String { line?.stations[safe: toIndex] ?? "" }
    /// How the platform is signed: trains towards this terminus.
    var towards: String { line?.terminus(from: fromIndex, to: toIndex) ?? "" }

    /// Stations in riding order, boarding station first.
    var path: [MetroStation] {
        guard let line else { return [] }
        let indices = fromIndex <= toIndex ? Array(fromIndex...toIndex) : Array((toIndex...fromIndex).reversed())
        return indices.map { line.stops[$0] }
    }
}

nonisolated struct MetroFare: Equatable, Sendable {
    var token: Int
    var smartCard: Double
    var isPeak: Bool
}

/// A way from one station to another: the rides, where you change, and roughly how long and
/// how much. Times and fares are estimates and are labelled as such wherever they're shown.
nonisolated struct MetroRoute: Hashable, Sendable {
    var rides: [MetroRide]
    /// Stations passed through, not counting the one you board at. BMRCL prices by this.
    var stationsTravelled: Int
    var distanceMeters: Double
    var minutes: Int
    /// Minutes from setting off to reaching each station on `path`, for tracking.
    var arrivalMinutes: [Double]

    var origin: String { rides.first?.boardAt ?? "" }
    var destination: String { rides.last?.getOffAt ?? "" }
    var changes: [String] { rides.dropFirst().map(\.boardAt) }

    /// Every station in riding order, each once — a change station isn't listed twice.
    var path: [MetroStation] {
        rides.enumerated().flatMap { index, ride in index == 0 ? ride.path : Array(ride.path.dropFirst()) }
    }

    /// "Purple Line", "Purple → Green Line".
    var lineSummary: String {
        let names = rides.map { $0.lineName.replacingOccurrences(of: " Line", with: "") }
        return names.count == 1 ? rides[0].lineName : names.joined(separator: " → ") + " Line"
    }
}

nonisolated enum MetroRouter {
    /// Average speed including stops, from BMRCL's end-to-end running times (the Purple Line's
    /// 43 km takes about 80 minutes). Straight lines between stations undercount the track a little.
    static let averageSpeedKmh = 33.0
    static let trackFactor = 1.08
    /// A change costs a walk plus half a wait — enough that a route with fewer changes wins when close.
    static let changePenaltyMinutes = 4.0

    /// The quickest route between two stations, changing lines where it helps.
    static func route(from origin: String, to destination: String, at now: Date = Date(), calendar: Calendar = .current) -> MetroRoute? {
        guard origin != destination else { return nil }

        // Nodes are (line, station index); edges run between neighbours and across interchanges.
        struct Node: Hashable { var line: String; var index: Int }
        var best: [Node: Double] = [:]
        var previous: [Node: Node] = [:]
        var queue: [(Node, Double)] = []

        for line in MetroNetwork.lines {
            if let index = line.stations.firstIndex(of: origin) {
                let start = Node(line: line.id, index: index)
                best[start] = 0
                queue.append((start, 0))
            }
        }

        var reached: Node?
        while !queue.isEmpty {
            queue.sort { $0.1 < $1.1 }
            let (node, cost) = queue.removeFirst()
            guard cost <= best[node] ?? .infinity, let line = MetroNetwork.line(id: node.line) else { continue }
            let name = line.stations[node.index]
            if name == destination {
                reached = node
                break
            }

            var neighbours: [(Node, Double)] = []
            for step in [-1, 1] {
                let next = node.index + step
                guard line.stops.indices.contains(next) else { continue }
                neighbours.append((Node(line: line.id, index: next), rideMinutes(line.stops[node.index], line.stops[next])))
            }
            for other in MetroNetwork.interchangeLines(for: name) where other.id != line.id {
                if let index = other.stations.firstIndex(of: name) {
                    neighbours.append((Node(line: other.id, index: index), Double(MetroNetwork.interchangeWalkMinutes(at: name)) + changePenaltyMinutes))
                }
            }
            for (neighbour, extra) in neighbours where cost + extra < best[neighbour] ?? .infinity {
                best[neighbour] = cost + extra
                previous[neighbour] = node
                queue.append((neighbour, cost + extra))
            }
        }

        guard var node = reached else { return nil }
        var trail = [node]
        while let before = previous[node] {
            trail.append(before)
            node = before
        }
        trail.reverse()

        // Consecutive nodes on the same line form one ride.
        var rides: [MetroRide] = []
        var rideStart = trail[0]
        for (current, next) in zip(trail, trail.dropFirst()) where next.line != current.line {
            if current.index != rideStart.index {
                rides.append(MetroRide(lineID: current.line, fromIndex: rideStart.index, toIndex: current.index))
            }
            rideStart = next
        }
        if let last = trail.last, last.index != rideStart.index {
            rides.append(MetroRide(lineID: last.line, fromIndex: rideStart.index, toIndex: last.index))
        }
        guard !rides.isEmpty else { return nil }
        return describe(rides, at: now, calendar: calendar)
    }

    /// Distance, time, and the running clock along the route.
    static func describe(_ rides: [MetroRide], at now: Date, calendar: Calendar = .current) -> MetroRoute {
        var distance = 0.0
        var clock = 0.0
        var arrivals: [Double] = [0]
        for (number, ride) in rides.enumerated() {
            let wait = Double(ride.line.map { MetroSchedule.headway(for: $0, at: now, calendar: calendar) } ?? 10) / 2
            if number > 0 {
                clock += Double(MetroNetwork.interchangeWalkMinutes(at: ride.boardAt))
            }
            // The wait for a train counts towards reaching the next station, not the one you're at.
            clock += wait
            for (a, b) in zip(ride.path, ride.path.dropFirst()) {
                distance += GeoMath.distance(from: a.coordinate, to: b.coordinate) * trackFactor
                clock += rideMinutes(a, b)
                arrivals.append(clock)
            }
        }
        let stations = rides.reduce(0) { $0 + $1.stops }
        return MetroRoute(
            rides: rides,
            stationsTravelled: stations,
            distanceMeters: distance,
            minutes: Int(clock.rounded()),
            arrivalMinutes: arrivals
        )
    }

    static func rideMinutes(_ a: MetroStation, _ b: MetroStation) -> Double {
        GeoMath.distance(from: a.coordinate, to: b.coordinate) * trackFactor / 1_000 / averageSpeedKmh * 60
    }

    /// BMRCL's fare for a number of stations, with the smart card discount for the hour.
    static func fare(stationsTravelled: Int, at date: Date, calendar: Calendar = .current) -> MetroFare {
        let fares = MetroNetwork.data.fares
        let token = stationsTravelled == 0
            ? fares.sameStation
            : fares.slabs.first { stationsTravelled <= $0.upToStations }?.fare ?? fares.slabs.last?.fare ?? 0
        let isPeak = MetroSchedule.isPeak(date, calendar: calendar)
        let discount = isPeak ? fares.smartCardDiscountPeak : fares.smartCardDiscountOffPeak
        return MetroFare(token: token, smartCard: (Double(token) * (1 - discount) * 100).rounded() / 100, isPeak: isPeak)
    }
}
