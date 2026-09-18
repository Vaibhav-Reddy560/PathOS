import CoreLocation
import Foundation

/// One stop along a journey, in riding order.
nonisolated struct JourneyStop: Hashable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
    /// Estimated minutes from setting off to reaching this stop.
    var minutesFromStart: Double
    /// Set where you change: "Change to the Green Line towards Silk Institute".
    var changeInstruction: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A metro or bus journey you're on.
nonisolated struct Journey: Identifiable, Sendable {
    nonisolated enum Kind: String, Sendable {
        case metro
        case bus
    }

    var id = UUID()
    var kind: Kind
    /// "Purple Line", "Purple → Green Line", "Bus 500D".
    var lineName: String
    var stops: [JourneyStop]
    var startedAt: Date

    var origin: String { stops.first?.name ?? "" }
    var destination: String { stops.last?.name ?? "" }
    var symbol: String { kind == .metro ? "tram.fill" : "bus.fill" }
    /// How close to a stop counts as being at it. Metro stations are big and GPS is poor near them.
    var stopRadius: Double { kind == .metro ? 700 : 200 }

    func stationName(at index: Int) -> String {
        stops[safe: index]?.name ?? ""
    }

    static func metro(_ route: MetroRoute, startedAt: Date = Date()) -> Journey {
        let changes = Dictionary(uniqueKeysWithValues: route.rides.dropFirst().map {
            ($0.boardAt, "Change to the \($0.lineName) towards \($0.towards)")
        })
        let stops = zip(route.path, route.arrivalMinutes).map { station, minutes in
            JourneyStop(name: station.name, latitude: station.lat, longitude: station.lon,
                        minutesFromStart: minutes, changeInstruction: changes[station.name])
        }
        return Journey(kind: .metro, lineName: route.lineSummary, stops: stops, startedAt: startedAt)
    }
}

/// Where you are along a journey. Times are estimates: no Indian metro or bus service publishes
/// live vehicle positions, so PathOS measures *you* and estimates the rest.
nonisolated struct JourneyProgress: Equatable, Sendable {
    var currentIndex: Int
    var nextStationIndex: Int?
    var stopsRemaining: Int
    var estimatedMinutesRemaining: Int
    /// The next stop is where you get off.
    var isArrivingNext: Bool
    var hasArrived: Bool
    /// True when the position came from GPS rather than the clock.
    var isTrackingByLocation: Bool
    /// The next stop is where you change lines.
    var isChangingNext = false
    /// The next change still ahead, if any.
    var nextChangeIndex: Int?
}

nonisolated enum JourneyTracker {
    /// The stop you're closest to, if you're close enough to call it.
    static func nearestStopIndex(to coordinate: CLLocationCoordinate2D, stops: [JourneyStop], radius: Double) -> Int? {
        let ranked = stops.enumerated()
            .map { ($0.offset, GeoMath.distance(from: coordinate, to: $0.element.coordinate)) }
            .min { $0.1 < $1.1 }
        guard let ranked, ranked.1 <= radius else { return nil }
        return ranked.0
    }

    /// Progress along the journey's stops. `nearestIndex` comes from GPS when available; otherwise
    /// the clock carries the estimate, which is what happens in the underground stretches.
    static func progress(stops: [JourneyStop], nearestIndex: Int?, elapsed: TimeInterval) -> JourneyProgress {
        let last = max(0, stops.count - 1)
        let elapsedMinutes = elapsed / 60
        let estimatedIndex = stops.lastIndex { $0.minutesFromStart <= elapsedMinutes } ?? 0

        // Trust GPS only when it agrees you haven't gone backwards.
        var currentIndex = min(estimatedIndex, last)
        var byLocation = false
        if let nearestIndex {
            let clamped = min(max(nearestIndex, 0), last)
            if clamped >= currentIndex || abs(clamped - currentIndex) <= 1 {
                currentIndex = clamped
                byLocation = true
            }
        }

        let stopsRemaining = last - currentIndex
        let hasArrived = stopsRemaining == 0
        let nextIndex = hasArrived ? nil : currentIndex + 1
        let remaining = (stops.last?.minutesFromStart ?? 0) - (stops[safe: currentIndex]?.minutesFromStart ?? 0)
        let nextChange = stops.indices.first { $0 > currentIndex && stops[$0].changeInstruction != nil }

        return JourneyProgress(
            currentIndex: currentIndex,
            nextStationIndex: nextIndex,
            stopsRemaining: stopsRemaining,
            estimatedMinutesRemaining: max(0, Int(remaining.rounded())),
            isArrivingNext: stopsRemaining == 1,
            hasArrived: hasArrived,
            isTrackingByLocation: byLocation,
            isChangingNext: nextChange != nil && nextChange == nextIndex,
            nextChangeIndex: nextChange
        )
    }

    /// "4 stops · about 9 min" — always phrased as an estimate.
    static func summary(_ progress: JourneyProgress) -> String {
        if progress.hasArrived { return "You've arrived" }
        let stops = progress.stopsRemaining == 1 ? "1 stop" : "\(progress.stopsRemaining) stops"
        return "\(stops) · about \(progress.estimatedMinutesRemaining) min"
    }
}
