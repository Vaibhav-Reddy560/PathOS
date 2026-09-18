import CoreLocation
import Foundation
import MapKit
import Observation

/// A journey you're on, or about to take.
nonisolated struct Journey: Identifiable, Sendable {
    var id = UUID()
    var lineID: String
    var fromIndex: Int
    var toIndex: Int
    var startedAt: Date

    var lineName: String { MetroNetwork.line(id: lineID)?.name ?? "Metro" }

    func stationName(at index: Int) -> String {
        MetroNetwork.line(id: lineID)?.stations[safe: index] ?? ""
    }

    var origin: String { stationName(at: fromIndex) }
    var destination: String { stationName(at: toIndex) }
}

/// Metro journeys: which line, which stations, and how far along you are.
///
/// No Indian metro publishes live train positions, so this tracks *you*: your GPS position
/// snapped to the station order, with the clock carrying the estimate underground.
/// A real-time feed can be added later behind `TransitFeed` without touching the UI.
@Observable
final class TransitService {
    private(set) var journey: Journey?
    private(set) var progress: JourneyProgress?
    /// Station coordinates resolved through Apple Maps, by station name.
    private(set) var stationFixes: [String: StationFix] = [:]
    private(set) var isResolvingStations = false

    @ObservationIgnored private let places: PlacesService
    @ObservationIgnored private let notifications: NotificationService
    @ObservationIgnored private var announcedArrivalFor: UUID?

    private static let cacheKey = "pathos.stationFixes"

    init(places: PlacesService, notifications: NotificationService) {
        self.places = places
        self.notifications = notifications
        loadCachedFixes()
    }

    // MARK: Journeys

    func start(lineID: String, fromIndex: Int, toIndex: Int) {
        guard fromIndex != toIndex else { return }
        journey = Journey(lineID: lineID, fromIndex: fromIndex, toIndex: toIndex, startedAt: Date())
        announcedArrivalFor = nil
        update(location: nil)
        Task { await resolveStations(for: lineID) }
    }

    func end() {
        if let journey {
            Task { await notifications.removePending(withPrefix: "pathos.journey.\(journey.id.uuidString)") }
        }
        journey = nil
        progress = nil
    }

    /// Recomputes progress. Called on every location update and on a timer while travelling.
    func update(location: CLLocation?) {
        guard let journey, let line = MetroNetwork.line(id: journey.lineID) else { return }

        let fixes = line.stations.compactMap { stationFixes[$0] }
        var nearestIndex: Int?
        if let location, fixes.count == line.stations.count {
            nearestIndex = JourneyTracker.nearestStationIndex(to: location.coordinate, stations: fixes)
        }

        let updated = JourneyTracker.progress(
            fromIndex: journey.fromIndex,
            toIndex: journey.toIndex,
            nearestIndex: nearestIndex,
            elapsed: Date().timeIntervalSince(journey.startedAt)
        )
        progress = updated
        announceIfNeeded(updated, journey: journey)
    }

    /// One notification when your stop is next, and one when you arrive.
    private func announceIfNeeded(_ progress: JourneyProgress, journey: Journey) {
        guard announcedArrivalFor != journey.id else { return }
        if progress.isArrivingNext {
            announcedArrivalFor = journey.id
            notifications.post(
                id: "pathos.journey.\(journey.id.uuidString).next",
                title: "Get off next: \(journey.destination)",
                body: "\(journey.lineName) · about \(progress.estimatedMinutesRemaining) min",
                category: NotificationService.Category.journey,
                link: URL(string: "pathos://dashboard"),
                timeSensitive: true
            )
        }
    }

    // MARK: Station coordinates

    /// Looks each station up in Apple Maps once and caches it, so the app carries no
    /// second-hand coordinate data and stays right as the network grows.
    func resolveStations(for lineID: String) async {
        guard let line = MetroNetwork.line(id: lineID) else { return }
        let missing = line.stations.filter { stationFixes[$0] == nil }
        guard !missing.isEmpty else { return }

        isResolvingStations = true
        defer {
            isResolvingStations = false
            cacheFixes()
        }

        let bengaluru = CLLocation(latitude: 12.9716, longitude: 77.5946)
        for station in missing {
            let query = "\(station) Metro Station Bengaluru"
            guard let match = (try? await places.search(query, near: bengaluru, radius: 40_000))?.first else { continue }
            stationFixes[station] = StationFix(name: station, latitude: match.latitude, longitude: match.longitude)
        }
    }

    /// The station closest to you right now, to pre-fill "from".
    func nearestStation(to location: CLLocation, on line: MetroLine) -> Int? {
        let fixes = line.stations.compactMap { stationFixes[$0] }
        guard fixes.count == line.stations.count else { return nil }
        return JourneyTracker.nearestStationIndex(to: location.coordinate, stations: fixes)
    }

    func fix(for station: String) -> StationFix? { stationFixes[station] }

    // MARK: Cache

    private func loadCachedFixes() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let decoded = try? JSONDecoder().decode([String: CachedFix].self, from: data) else { return }
        stationFixes = decoded.mapValues { StationFix(name: $0.name, latitude: $0.latitude, longitude: $0.longitude) }
    }

    private func cacheFixes() {
        let encodable = stationFixes.mapValues { CachedFix(name: $0.name, latitude: $0.latitude, longitude: $0.longitude) }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    private struct CachedFix: Codable {
        var name: String
        var latitude: Double
        var longitude: Double
    }
}

/// Where a live feed would plug in, the day BMRCL or BMTC publish one.
protocol TransitFeed: Sendable {
    func nextDepartures(atStation station: String, lineID: String) async -> [Date]
}

extension Array {
    nonisolated subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
