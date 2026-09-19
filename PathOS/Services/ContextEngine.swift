import CoreLocation
import Foundation
import Observation

/// Works out where you are (home, metro, mall…) and whether stepping out needs a warning.
@Observable
final class ContextEngine {
    private(set) var venue: VenueContext = .unknown
    private(set) var exitAdvice: ExitAdvice?
    private(set) var lastRefreshed: Date?

    @ObservationIgnored private let places: PlacesService
    @ObservationIgnored private let vault: SpatialVaultService
    @ObservationIgnored private let barometer: BarometerManager
    @ObservationIgnored private let weather: WeatherService
    @ObservationIgnored private var lastLocation: CLLocation?

    static let minimumMoveMeters = 100.0
    static let minimumInterval: TimeInterval = 5 * 60

    init(places: PlacesService, vault: SpatialVaultService, barometer: BarometerManager, weather: WeatherService) {
        self.places = places
        self.vault = vault
        self.barometer = barometer
        self.weather = weather
    }

    /// Re-classifies the venue and exit advice; cheap to call often (it throttles itself).
    func refresh(location: CLLocation, force: Bool = false) async {
        if !force, let lastLocation, let lastRefreshed,
           location.distance(from: lastLocation) < Self.minimumMoveMeters,
           Date().timeIntervalSince(lastRefreshed) < Self.minimumInterval {
            exitAdvice = evaluate(snapshot: weather.snapshot)
            return
        }
        lastLocation = location
        lastRefreshed = Date()

        let fences = vault.allPlaces().map {
            PlaceFence(kind: $0.kind, name: $0.name, latitude: $0.latitude, longitude: $0.longitude, radius: $0.radius)
        }
        let nearby = await places.nearbyPOIs(around: location)
        venue = VenueClassifier.classify(location: location.coordinate, places: fences, nearby: nearby)

        let snapshot = await weather.refresh(for: location)
        exitAdvice = evaluate(snapshot: snapshot)
    }

    /// Fresh check at the moment you leave a saved place.
    func evaluateExit(at location: CLLocation?) async -> ExitAdvice? {
        var snapshot = weather.snapshot
        if let location {
            snapshot = await weather.refresh(for: location)
        }
        exitAdvice = evaluate(snapshot: snapshot)
        return exitAdvice
    }

    private func evaluate(snapshot: WeatherSnapshot?) -> ExitAdvice? {
        ExitCheckEvaluator.evaluate(
            trend: barometer.trend,
            rainChanceNext2h: snapshot?.rainChanceNext2h,
            expectedRainMM: snapshot?.expectedRainMM,
            observation: snapshot?.observation
        )
    }
}
