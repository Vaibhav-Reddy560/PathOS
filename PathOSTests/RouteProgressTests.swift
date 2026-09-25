import CoreLocation
import Foundation
import Testing
@testable import PathOS

/// Where you are along a route while following it: what's behind you, what's ahead, and whether
/// you've left it.
struct RouteProgressTests {
    private let start = CLLocationCoordinate2D(latitude: 12.9300, longitude: 77.5800)

    private func point(north: Double, east: Double) -> CLLocationCoordinate2D {
        GeoMath.coordinate(GeoMath.coordinate(start, metres: north, bearing: 0), metres: east, bearing: 90)
    }

    /// 600 m north, then 400 m east.
    private var route: [CLLocationCoordinate2D] {
        [start, point(north: 300, east: 0), point(north: 600, east: 0), point(north: 600, east: 400)]
    }

    @Test func halfwayUpTheFirstRoad() throws {
        let match = try #require(RouteProgress.match(route, at: point(north: 450, east: 8)))
        #expect(abs(match.travelled - 450) < 3)
        #expect(abs(match.remaining - 550) < 3)
        #expect(match.offset < 10)
        #expect(abs(match.fraction - 0.45) < 0.01)
    }

    /// What's drawn starts where you are: the part behind you is gone.
    @Test func onlyTheRouteAheadIsDrawn() throws {
        let match = try #require(RouteProgress.match(route, at: point(north: 450, east: 0)))
        let ahead = RouteProgress.ahead(of: route, from: match)
        #expect(ahead.count == 3)
        #expect(GeoMath.distance(from: ahead[0], to: point(north: 450, east: 0)) < 3)
        #expect(GeoMath.distance(from: ahead.last!, to: route.last!) < 1)
    }

    /// A road that doubles back on itself: carrying on from where you were keeps you on the leg
    /// you're driving, not the one alongside it you already drove.
    @Test func progressNeverJumpsBack() throws {
        // Up in 100 m pieces, across 30 m, and back down: the two legs 30 m apart.
        let up = (0...5).map { point(north: Double($0) * 100, east: 0) }
        let hairpin = up + [point(north: 500, east: 30), point(north: 0, east: 30)]
        // Nearer the leg already driven than the one being driven, as a wobbly fix can be.
        let onTheWayBack = point(north: 200, east: 12)
        #expect(RouteProgress.match(hairpin, at: onTheWayBack)?.segment == 1)
        let first = try #require(RouteProgress.match(hairpin, at: point(north: 500, east: 20)))
        let next = try #require(RouteProgress.match(hairpin, at: onTheWayBack, after: first))
        #expect(next.segment == 6)
        #expect(next.travelled > 500)
    }

    /// Forty metres off is a wrong turn; ten is the width of the road.
    @Test func leavingTheRouteIsSeenWithinAStreet() throws {
        let limit = RouteProgress.offRouteMetres(accuracy: 10)
        #expect(limit == 40)
        let onIt = try #require(RouteProgress.match(route, at: point(north: 200, east: 10)))
        #expect(onIt.offset < limit)
        let offIt = try #require(RouteProgress.match(route, at: point(north: 200, east: 60)))
        #expect(offIt.offset > limit)
        // A poor fix earns more room, but never the old 120 m.
        #expect(RouteProgress.offRouteMetres(accuracy: 200) == 90)
    }

    @Test func goingTheWrongWayIsNoticed() throws {
        let match = try #require(RouteProgress.match(route, at: point(north: 200, east: 0)))
        #expect(RouteProgress.isHeadingAway(course: 180, speed: 8, along: route, at: match))
        #expect(!RouteProgress.isHeadingAway(course: 5, speed: 8, along: route, at: match))
        // Standing still says nothing about direction.
        #expect(!RouteProgress.isHeadingAway(course: 180, speed: 0.5, along: route, at: match))
    }
}
