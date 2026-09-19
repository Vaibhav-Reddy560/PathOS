import CoreLocation
import Foundation
import Testing
@testable import PathOS

struct VenueClassifierTests {
    private let home = PlaceFence(kind: .home, name: "Home", latitude: 12.97, longitude: 77.59, radius: 120)
    private let elsewhere = CLLocationCoordinate2D(latitude: 13.0, longitude: 77.6)

    @Test func insideHomeFence() {
        let context = VenueClassifier.classify(
            location: CLLocationCoordinate2D(latitude: 12.9701, longitude: 77.5901),
            places: [home],
            nearby: []
        )
        #expect(context.kind == .home)
    }

    @Test func nearbyMetroStationIsTransit() {
        let context = VenueClassifier.classify(
            location: elsewhere,
            places: [home],
            nearby: [NearbyPOI(group: .transit, name: "MG Road Metro", distanceMeters: 30)]
        )
        #expect(context == VenueContext(kind: .transit, name: "MG Road Metro"))
    }

    @Test func distantPOIIsIgnored() {
        let context = VenueClassifier.classify(
            location: elsewhere,
            places: [home],
            nearby: [NearbyPOI(group: .dining, name: "Far Café", distanceMeters: 100)]
        )
        #expect(context.kind == .unknown)
    }
}

struct ExitCheckEvaluatorTests {
    private let now = Date(timeIntervalSince1970: 1_789_830_000)

    private func station(_ weather: String?, km: Double = 8) -> WeatherObservation {
        WeatherObservation(station: "Hal Airport", distanceMeters: km * 1_000, observedAt: now, temperatureC: 26,
                           presentWeather: weather, cloudCover: "BKN")
    }

    @Test func rapidDropAndRainIsHighSeverity() {
        let advice = ExitCheckEvaluator.evaluate(trend: .rapidDrop(dropHPa: 2, overHours: 2), rainChanceNext2h: 70, expectedRainMM: 1)
        #expect(advice?.severity == .high)
    }

    @Test func clearSkiesNeedNoAdvice() {
        #expect(ExitCheckEvaluator.evaluate(trend: .steady, rainChanceNext2h: 20, expectedRainMM: 0) == nil)
    }

    @Test func forecastAloneTriggersRainAdvice() {
        let advice = ExitCheckEvaluator.evaluate(trend: .steady, rainChanceNext2h: 60, expectedRainMM: 0.8)
        #expect(advice?.symbol == "cloud.rain.fill")
    }

    /// High odds of a few drops isn't a reason to carry an umbrella.
    @Test func likelyDropsAreNotRain() {
        #expect(ExitCheckEvaluator.evaluate(trend: .steady, rainChanceNext2h: 71, expectedRainMM: 0.1) == nil)
    }

    /// "Raining nearby" comes only from a station that reported rain, and says which.
    @Test func rainNearbyIsWhatAStationReported() {
        let advice = ExitCheckEvaluator.evaluate(trend: .steady, rainChanceNext2h: 10, expectedRainMM: 0, observation: station("-TSRA"))
        #expect(advice?.headline == "Raining nearby — take an umbrella")
        #expect(advice?.detail.hasPrefix("Hal Airport, 8") == true)
        #expect(ExitCheckEvaluator.evaluate(trend: .steady, rainChanceNext2h: 10, expectedRainMM: 0, observation: station(nil)) == nil)
    }
}
