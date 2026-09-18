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
    @Test func rapidDropAndRainIsHighSeverity() {
        let advice = ExitCheckEvaluator.evaluate(trend: .rapidDrop(dropHPa: 2, overHours: 2), rainChanceNext2h: 70, precipitationNowMM: 0)
        #expect(advice?.severity == .high)
    }

    @Test func clearSkiesNeedNoAdvice() {
        #expect(ExitCheckEvaluator.evaluate(trend: .steady, rainChanceNext2h: 20, precipitationNowMM: 0) == nil)
    }

    @Test func forecastAloneTriggersRainAdvice() {
        let advice = ExitCheckEvaluator.evaluate(trend: .steady, rainChanceNext2h: 60, precipitationNowMM: nil)
        #expect(advice?.symbol == "cloud.rain.fill")
    }
}
