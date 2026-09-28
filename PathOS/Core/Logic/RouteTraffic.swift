import CoreLocation
import Foundation

/// The slow stretches of the route you're driving, and how slow — TomTom's reading of the
/// traffic on exactly that route.
///
/// Apple gives apps no traffic figures for a street; it only paints its traffic onto the map, per
/// direction of travel, beside the route rather than on it, and on every other road too. Two
/// attempts to work traffic out from Apple Maps' travel times coloured jams green and empty roads
/// orange. TomTom will take a route as it is, point by point, and say which stretches of it are
/// slow: that's what the line is coloured by. Nowhere else on the map is.
nonisolated enum RouteTraffic {

    /// How bad a stretch is: TomTom's own three steps, closures counted with the worst.
    nonisolated enum Level: Int, Comparable, Sendable {
        case minor = 1
        case moderate = 2
        case major = 3

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// A stretch of the route, in metres along it.
    nonisolated struct Stretch: Equatable, Sendable {
        var start: Double
        var end: Double
        var level: Level
    }

    /// The parts of TomTom's answer PathOS reads.
    nonisolated struct Response: Decodable, Sendable {
        var routes: [Route]

        nonisolated struct Route: Decodable, Sendable {
            var legs: [Leg]
            var sections: [Section]?
        }

        nonisolated struct Leg: Decodable, Sendable {
            var points: [Point]
        }

        nonisolated struct Point: Decodable, Sendable {
            var latitude: Double
            var longitude: Double
        }

        nonisolated struct Section: Decodable, Sendable {
            var startPointIndex: Int
            var endPointIndex: Int
            var sectionType: String
            var simpleCategory: String?
            var magnitudeOfDelay: Int?
        }
    }

    /// No more points than this are sent: enough to pin a route to its roads, not so many that
    /// the request is mostly the route.
    static let mostPoints = 150
    /// A stretch whose ends land further than this from the route isn't on it.
    static let onRouteWithin = 50.0

    /// What a TomTom traffic section means for the line. A jam with no stated size is still a
    /// jam; roadworks or anything else with no stated size isn't worth a colour.
    static func level(magnitude: Int?, category: String?) -> Level? {
        if category == "ROAD_CLOSURE" || magnitude == 4 { return .major }
        switch magnitude {
        case 3: return .major
        case 2: return .moderate
        case 1: return .minor
        default: return category == "JAM" ? .minor : nil
        }
    }

    /// TomTom's slow stretches, laid on the route PathOS is drawing. TomTom's points don't line
    /// up with Apple's, so each stretch's ends are matched onto this route — in order, each from
    /// where the last one ended, so a route that doubles back along the other side of a road
    /// isn't matched to the wrong side.
    static func stretches(from response: Response, on route: [CLLocationCoordinate2D]) -> [Stretch] {
        guard route.count > 1, let first = response.routes.first else { return [] }
        let points = first.legs.flatMap(\.points).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        var previous: RouteProgress.Match?
        var found: [Stretch] = []
        for section in first.sections ?? [] where section.sectionType == "TRAFFIC" {
            guard let level = level(magnitude: section.magnitudeOfDelay, category: section.simpleCategory),
                  points.indices.contains(section.startPointIndex), points.indices.contains(section.endPointIndex),
                  let from = RouteProgress.match(route, at: points[section.startPointIndex], after: previous),
                  from.offset <= onRouteWithin,
                  let to = RouteProgress.match(route, at: points[section.endPointIndex], after: from),
                  to.offset <= onRouteWithin, to.travelled > from.travelled else { continue }
            found.append(Stretch(start: from.travelled, end: to.travelled, level: level))
            previous = to
        }
        return found
    }

    /// The route, thinned to at most `limit` points, keeping both ends.
    static func thinned(_ route: [CLLocationCoordinate2D], toAtMost limit: Int = mostPoints) -> [CLLocationCoordinate2D] {
        guard route.count > limit, limit >= 2 else { return route }
        let step = Double(route.count - 1) / Double(limit - 1)
        return (0..<limit).map { route[Int((Double($0) * step).rounded())] }
    }

    /// The request: this route, as it is, with the traffic on it now.
    static func request(for route: [CLLocationCoordinate2D], key: String) -> URLRequest? {
        let points = thinned(route)
        guard let first = points.first, let last = points.last,
              let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let ends = String(format: "%.6f,%.6f:%.6f,%.6f", first.latitude, first.longitude, last.latitude, last.longitude)
        let query = "traffic=true&sectionType=traffic&travelMode=car&routeType=fastest&key=\(encodedKey)"
        guard let url = URL(string: "https://api.tomtom.com/routing/1/calculateRoute/\(ends)/json?\(query)") else { return nil }
        let body: [String: Any] = [
            "supportingPoints": points.map { ["latitude": $0.latitude, "longitude": $0.longitude] },
        ]
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}
