import CoreLocation
import Foundation

/// A station with the coordinate PathOS resolved for it through Apple Maps.
nonisolated struct StationFix: Hashable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Where you are along a journey. Times are estimates: no Indian metro publishes live
/// train positions, so PathOS measures *you* and estimates the rest.
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
}

nonisolated enum JourneyTracker {
    /// Rough time between adjacent metro stations, including the stop.
    static let minutesPerStop = 2.2
    /// A fix further than this from every station means you're between stations.
    static let stationRadiusMeters = 700.0

    /// The station you're closest to, if you're close enough to call it.
    static func nearestStationIndex(to coordinate: CLLocationCoordinate2D, stations: [StationFix]) -> Int? {
        let ranked = stations.enumerated()
            .map { ($0.offset, GeoMath.distance(from: coordinate, to: $0.element.coordinate)) }
            .min { $0.1 < $1.1 }
        guard let ranked, ranked.1 <= stationRadiusMeters else { return nil }
        return ranked.0
    }

    /// Progress along the line between two station indexes.
    /// `nearestIndex` comes from GPS when available; otherwise the clock carries the estimate,
    /// which is what happens in the underground stretches.
    static func progress(
        fromIndex: Int,
        toIndex: Int,
        nearestIndex: Int?,
        elapsed: TimeInterval
    ) -> JourneyProgress {
        let direction = toIndex >= fromIndex ? 1 : -1
        let travelled = Int((elapsed / 60 / minutesPerStop).rounded(.down))
        let estimatedIndex = fromIndex + direction * travelled

        // Trust GPS only when it agrees you're between the endpoints and haven't gone backwards.
        var currentIndex = clamp(estimatedIndex, fromIndex: fromIndex, toIndex: toIndex)
        var byLocation = false
        if let nearestIndex {
            let clamped = clamp(nearestIndex, fromIndex: fromIndex, toIndex: toIndex)
            let isAhead = direction == 1 ? clamped >= currentIndex : clamped <= currentIndex
            if isAhead || abs(clamped - currentIndex) <= 1 {
                currentIndex = clamped
                byLocation = true
            }
        }

        let stopsRemaining = abs(toIndex - currentIndex)
        let hasArrived = stopsRemaining == 0
        let nextIndex = hasArrived ? nil : currentIndex + direction

        return JourneyProgress(
            currentIndex: currentIndex,
            nextStationIndex: nextIndex,
            stopsRemaining: stopsRemaining,
            estimatedMinutesRemaining: max(0, Int((Double(stopsRemaining) * minutesPerStop).rounded())),
            isArrivingNext: stopsRemaining == 1,
            hasArrived: hasArrived,
            isTrackingByLocation: byLocation
        )
    }

    private static func clamp(_ index: Int, fromIndex: Int, toIndex: Int) -> Int {
        let lower = min(fromIndex, toIndex)
        let upper = max(fromIndex, toIndex)
        return min(max(index, lower), upper)
    }

    /// "4 stops · about 9 min" — always phrased as an estimate.
    static func summary(_ progress: JourneyProgress) -> String {
        if progress.hasArrived { return "You've arrived" }
        let stops = progress.stopsRemaining == 1 ? "1 stop" : "\(progress.stopsRemaining) stops"
        return "\(stops) · about \(progress.estimatedMinutesRemaining) min"
    }
}
