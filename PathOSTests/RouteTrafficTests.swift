import CoreLocation
import Foundation
import Testing
@testable import PathOS

@Suite("Traffic on the route, from TomTom")
struct RouteTrafficTests {
    private let start = CLLocationCoordinate2D(latitude: 12.93, longitude: 77.58)

    /// Two kilometres due east: Apple's route.
    private var route: [CLLocationCoordinate2D] {
        [start, GeoMath.coordinate(start, metres: 1_000, bearing: 90), GeoMath.coordinate(start, metres: 2_000, bearing: 90)]
    }

    /// TomTom's version of the same road: its own points, every 500 m, a few metres to one side.
    private func response(sections: String) throws -> RouteTraffic.Response {
        let points = (0...4).map { i -> String in
            let c = GeoMath.coordinate(GeoMath.coordinate(start, metres: Double(i) * 500, bearing: 90), metres: 4, bearing: 0)
            return #"{"latitude": \#(c.latitude), "longitude": \#(c.longitude)}"#
        }
        let json = #"{"routes": [{"legs": [{"points": [\#(points.joined(separator: ","))]}], "sections": [\#(sections)]}]}"#
        return try JSONDecoder().decode(RouteTraffic.Response.self, from: Data(json.utf8))
    }

    @Test func aJamLandsWhereItIsOnTheRoute() throws {
        let answer = try response(sections: """
            {"startPointIndex": 0, "endPointIndex": 4, "sectionType": "TRAVEL_MODE"},
            {"startPointIndex": 1, "endPointIndex": 3, "sectionType": "TRAFFIC", "simpleCategory": "JAM", "magnitudeOfDelay": 2}
            """)
        let stretches = RouteTraffic.stretches(from: answer, on: route)
        #expect(stretches.count == 1)
        let jam = try #require(stretches.first)
        #expect(abs(jam.start - 500) < 10)
        #expect(abs(jam.end - 1_500) < 10)
        #expect(jam.level == .moderate)
    }

    /// Only traffic sections, and only ones worth a colour.
    @Test func onlyWhatsSlowIsColoured() throws {
        let answer = try response(sections: """
            {"startPointIndex": 0, "endPointIndex": 1, "sectionType": "TRAFFIC", "simpleCategory": "OTHER", "magnitudeOfDelay": 0},
            {"startPointIndex": 1, "endPointIndex": 2, "sectionType": "TOLL_ROAD"},
            {"startPointIndex": 2, "endPointIndex": 3, "sectionType": "TRAFFIC", "simpleCategory": "ROAD_CLOSURE"},
            {"startPointIndex": 3, "endPointIndex": 4, "sectionType": "TRAFFIC", "simpleCategory": "JAM"}
            """)
        let stretches = RouteTraffic.stretches(from: answer, on: route)
        #expect(stretches.map(\.level) == [.major, .minor])
    }

    /// A stretch TomTom puts on some other road isn't painted on this one.
    @Test func aStretchOffTheRouteIsLeftOff() throws {
        let far = GeoMath.coordinate(start, metres: 400, bearing: 0)
        let json = #"{"routes": [{"legs": [{"points": [{"latitude": \#(start.latitude), "longitude": \#(start.longitude)}, {"latitude": \#(far.latitude), "longitude": \#(far.longitude)}]}], "sections": [{"startPointIndex": 0, "endPointIndex": 1, "sectionType": "TRAFFIC", "simpleCategory": "JAM", "magnitudeOfDelay": 3}]}]}"#
        let answer = try JSONDecoder().decode(RouteTraffic.Response.self, from: Data(json.utf8))
        #expect(RouteTraffic.stretches(from: answer, on: route).isEmpty)
    }

    @Test func levels() {
        #expect(RouteTraffic.level(magnitude: 1, category: "JAM") == .minor)
        #expect(RouteTraffic.level(magnitude: 2, category: "JAM") == .moderate)
        #expect(RouteTraffic.level(magnitude: 3, category: "JAM") == .major)
        #expect(RouteTraffic.level(magnitude: 4, category: "OTHER") == .major)
        #expect(RouteTraffic.level(magnitude: nil, category: "ROAD_CLOSURE") == .major)
        #expect(RouteTraffic.level(magnitude: 0, category: "JAM") == .minor)
        #expect(RouteTraffic.level(magnitude: 0, category: "ROAD_WORK") == nil)
    }

    // MARK: The request

    @Test func aLongRouteIsThinnedKeepingItsEnds() {
        let long = (0..<1_000).map { GeoMath.coordinate(start, metres: Double($0) * 10, bearing: 90) }
        let thin = RouteTraffic.thinned(long)
        #expect(thin.count == RouteTraffic.mostPoints)
        #expect(thin.first?.longitude == long.first?.longitude)
        #expect(thin.last?.longitude == long.last?.longitude)
        #expect(RouteTraffic.thinned(route).count == 3)
    }

    @Test func theRequestAsksForTrafficOnThisRoute() throws {
        let request = try #require(RouteTraffic.request(for: route, key: "abc123"))
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://api.tomtom.com/routing/1/calculateRoute/12.930000,77.580000:"))
        #expect(url.contains("sectionType=traffic"))
        #expect(url.contains("traffic=true"))
        #expect(url.contains("key=abc123"))
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["supportingPoints"] as? [[String: Double]])?.count == 3)
    }

    // MARK: The colours

    @Test func slowIsAmberStoppedIsCoral() {
        #expect(PathOSPalette.traffic(level: 1) == PathOSPalette.amber)
        #expect(PathOSPalette.traffic(level: 3) == PathOSPalette.coral)
        let between = PathOSPalette.traffic(level: 2)
        #expect(between != PathOSPalette.amber && between != PathOSPalette.coral)
    }
}
