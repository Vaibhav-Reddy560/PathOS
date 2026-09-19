import CoreLocation
import Foundation
import Testing
@testable import PathOS

/// Radar scanned the area again on every tap. These pin down when it may reuse what it found.
struct RadarCacheTests {
    private let home = CLLocation(latitude: 12.9063, longitude: 77.6008)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func place(_ id: String, north meters: Double) -> PlaceSummary {
        let coordinate = GeoMath.coordinate(home.coordinate, offsetNorthBy: meters)
        return PlaceSummary(id: id, name: id, categoryName: "Café", group: .dining, symbol: "cup.and.saucer.fill",
                            latitude: coordinate.latitude, longitude: coordinate.longitude, distanceMeters: meters)
    }

    private func moved(north meters: Double) -> CLLocation {
        let coordinate = GeoMath.coordinate(home.coordinate, offsetNorthBy: meters)
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    @Test func aScanServesYouNearbyForThreeDays() throws {
        var cache = RadarCache()
        cache.store([place("a", north: 500)], for: .food, near: home, now: now)

        // Walking 200 m doesn't scan again, and distances are measured from where you are now.
        let later = try #require(cache.places(for: .food, near: moved(north: 200), now: now.addingTimeInterval(2 * 86_400)))
        #expect(later.places.map(\.id) == ["a"])
        #expect(abs(later.places[0].distanceMeters - 300) < 5)
        #expect(later.savedAt == now)

        // After three days it's stale.
        #expect(cache.places(for: .food, near: home, now: now.addingTimeInterval(3 * 86_400 + 1)) == nil)
    }

    @Test func aNewAreaOrCategoryScans() {
        var cache = RadarCache()
        cache.store([place("a", north: 100)], for: .food, near: home, now: now)
        #expect(cache.places(for: .food, near: moved(north: 900), now: now) == nil)
        #expect(cache.places(for: .nightlife, near: home, now: now) == nil)
    }

    @Test func scanningAgainReplacesTheScanItCovers() {
        var cache = RadarCache()
        cache.store([place("old", north: 100)], for: .food, near: home, now: now)
        cache.store([place("park", north: 100)], for: .outdoors, near: home, now: now)
        cache.store([place("new", north: 100)], for: .food, near: moved(north: 150), now: now.addingTimeInterval(60))

        #expect(cache.entries.count == 2)
        #expect(cache.places(for: .food, near: home, now: now)?.places.map(\.id) == ["new"])
        #expect(cache.places(for: .outdoors, near: home, now: now)?.places.map(\.id) == ["park"])
    }

    @Test func itKeepsOnlyTheMostRecentScans() {
        var cache = RadarCache()
        for index in 0..<(RadarCache.capacity + 5) {
            cache.store([], for: .food, near: moved(north: Double(index) * 1_000), now: now.addingTimeInterval(Double(index)))
        }
        #expect(cache.entries.count == RadarCache.capacity)
        #expect(cache.entries.allSatisfy { $0.savedAt >= now.addingTimeInterval(5) })
    }

    @Test func itSurvivesBeingSaved() throws {
        var cache = RadarCache()
        cache.store([place("a", north: 50)], for: .culture, near: home, now: now)
        let data = try JSONEncoder().encode(cache)
        let restored = try JSONDecoder().decode(RadarCache.self, from: data)
        #expect(restored.places(for: .culture, near: home, now: now)?.places.first?.name == "a")
    }

    /// The ordering is made when an area is scanned and kept as long as its places, so switching
    /// category never asks Apple Intelligence again.
    @Test func theOrderingIsKeptWithTheScan() throws {
        var cache = RadarCache()
        cache.store(ranking: ["place:b", "place:a"], reasons: ["place:b": "Quiet now"], near: home, now: now)
        let kept = try #require(cache.ranking(near: moved(north: 200), now: now.addingTimeInterval(2 * 86_400)))
        #expect(kept.order == ["place:b", "place:a"])
        #expect(kept.reasons["place:b"] == "Quiet now")
        #expect(cache.ranking(near: moved(north: 900), now: now) == nil)
        #expect(cache.ranking(near: home, now: now.addingTimeInterval(3 * 86_400 + 1)) == nil)
    }

    @Test func cachesFromBeforeOrderingsStillLoad() throws {
        let old = #"{"entries":[]}"#.data(using: .utf8)!
        let cache = try JSONDecoder().decode(RadarCache.self, from: old)
        #expect(cache.rankings.isEmpty)
    }

    @Test func stopsAreToldApartByName() {
        #expect(TransitKind(name: "Indiranagar Metro Station") == .metro)
        #expect(TransitKind(name: "Silk Board Bus Stop") == .bus)
        #expect(TransitKind(name: "Kempegowda Bus Stand") == .bus)
        #expect(TransitKind(name: "KSR Bengaluru City Junction") == .rail)
        #expect(TransitKind(name: "Baiyappanahalli Railway Station") == .rail)
        #expect(TransitKind(name: "Auto Stand") == .auto)
        #expect(TransitKind(name: "Park and Ride") == .other)
        #expect(TransitKind.plainName("Indiranagar Metro Station") == TransitKind.plainName("Indiranagar"))
    }

    @Test func everythingIsEachCategoryScannedOnItsOwn() {
        #expect(RadarCategory.all.scanned == [.food, .nightlife, .culture, .outdoors])
        #expect(RadarCategory.food.scanned == [.food])
    }

    @Test func radarShowsOnlyEventsWithAPlace() {
        func event(_ source: LocalEvent.Source, latitude: Double?) -> LocalEvent {
            LocalEvent(id: "e", title: "E", subtitle: "", start: now, latitude: latitude, longitude: latitude,
                       distanceMeters: nil, source: source, symbol: "calendar")
        }
        #expect(RadarModel.isPhysical(event(.calendar, latitude: 12.9)))
        #expect(!RadarModel.isPhysical(event(.calendar, latitude: nil)))
        #expect(!RadarModel.isPhysical(event(.mail, latitude: nil)))
    }
}
