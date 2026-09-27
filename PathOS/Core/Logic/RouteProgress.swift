import CoreLocation
import Foundation

/// Where you are along the route you're driving or walking, measured the way a navigation app
/// does: the nearest point on the line *ahead of where you were*, so a road that doubles back
/// can't snap you to a stretch you've already driven.
///
/// It gives the three things the map needs every second: how much of the line is behind you (so
/// that part stops being drawn), how far is left, and whether you've left the route at all.
nonisolated enum RouteProgress {

    nonisolated struct Match: Equatable, Sendable {
        /// The segment you're on: from `route[segment]` to `route[segment + 1]`.
        var segment: Int
        /// Your position on the line.
        var point: CLLocationCoordinate2D
        /// Metres of the route behind you, and in all.
        var travelled: Double
        var total: Double
        /// How far you are from the line.
        var offset: Double

        var remaining: Double { max(0, total - travelled) }
        /// Share of the route behind you, 0 to 1.
        var fraction: Double { total > 0 ? min(1, travelled / total) : 0 }

        static func == (a: Match, b: Match) -> Bool {
            a.segment == b.segment && a.travelled == b.travelled && a.offset == b.offset
        }
    }

    /// Past this many segments ahead, a nearer point is a different road, not progress.
    static let lookAhead = 60

    /// Where you are on `route`, carrying on from `previous` when there is one.
    static func match(_ route: [CLLocationCoordinate2D], at location: CLLocationCoordinate2D,
                      after previous: Match? = nil) -> Match? {
        guard route.count > 1 else { return nil }
        let lengths = zip(route, route.dropFirst()).map { GeoMath.distance(from: $0, to: $1) }
        let total = lengths.reduce(0, +)

        func nearest(in range: ClosedRange<Int>) -> (segment: Int, t: Double, offset: Double)? {
            var best: (segment: Int, t: Double, offset: Double)?
            for index in range {
                let (t, offset) = project(location, route[index], route[index + 1])
                if best == nil || offset < best!.offset {
                    best = (index, t, offset)
                }
            }
            return best
        }

        let last = route.count - 2
        var found: (segment: Int, t: Double, offset: Double)?
        if let previous, previous.segment <= last {
            // Onward from where you were, allowing a segment back for the fix's wobble.
            let from = max(0, previous.segment - 1)
            found = nearest(in: from...min(last, previous.segment + lookAhead))
            // Nowhere near the road ahead: look along the whole route, in case you rejoined it.
            if let onward = found, onward.offset > offRouteMetres(accuracy: 0) * 2,
               let anywhere = nearest(in: 0...last), anywhere.offset < onward.offset / 2 {
                found = anywhere
            }
        } else {
            found = nearest(in: 0...last)
        }
        guard let found else { return nil }

        let before = lengths[..<found.segment].reduce(0, +)
        let travelled = before + lengths[found.segment] * found.t
        let a = route[found.segment], b = route[found.segment + 1]
        let point = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * found.t,
                                           longitude: a.longitude + (b.longitude - a.longitude) * found.t)
        return Match(segment: found.segment, point: point, travelled: travelled, total: total, offset: found.offset)
    }

    /// The point `metres` further along the route, and how far that turned out to be — shorter
    /// when the route ends first. Where the speed of the road ahead is asked about.
    static func point(_ route: [CLLocationCoordinate2D], from match: Match,
                      after metres: Double) -> (coordinate: CLLocationCoordinate2D, metres: Double)? {
        guard route.count > 1, metres > 0, match.segment + 1 < route.count else { return nil }

        func between(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                   longitude: a.longitude + (b.longitude - a.longitude) * t)
        }

        // The rest of the segment you're on, then segment by segment.
        var walked = GeoMath.distance(from: match.point, to: route[match.segment + 1])
        if walked >= metres {
            return (between(match.point, route[match.segment + 1], metres / max(walked, 0.001)), metres)
        }
        var index = match.segment + 1
        while index + 1 < route.count {
            let step = GeoMath.distance(from: route[index], to: route[index + 1])
            if walked + step >= metres {
                return (between(route[index], route[index + 1], (metres - walked) / max(step, 0.001)), metres)
            }
            walked += step
            index += 1
        }
        // The route ends first: its end, and how far that is.
        return (route[route.count - 1], walked)
    }

    /// The line still ahead of you, starting where you are on it — which is all the map draws.
    static func ahead(of route: [CLLocationCoordinate2D], from match: Match) -> [CLLocationCoordinate2D] {
        guard match.segment + 1 < route.count else { return [] }
        return [match.point] + route[(match.segment + 1)...]
    }

    /// Off the route: further from it than the fix's own uncertainty explains. A street's width
    /// and some GPS error, not the two hundred metres of a parallel road, which is how far the
    /// old fixed 120 m let you go before anything happened.
    static func offRouteMetres(accuracy: Double) -> Double {
        min(90, max(40, accuracy * 1.5))
    }

    /// Going the wrong way along the route: moving, and heading well away from the way the line
    /// runs where you are.
    static func isHeadingAway(course: Double?, speed: Double, along route: [CLLocationCoordinate2D], at match: Match) -> Bool {
        guard let course, speed >= 3, match.segment + 1 < route.count else { return false }
        let bearing = GeoMath.bearing(from: route[match.segment], to: route[match.segment + 1])
        return TravelCourse.difference(course, bearing) > 110
    }

    /// How far along the segment a point lies (0 to 1), and how far from it, in metres.
    static func project(_ point: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> (t: Double, offset: Double) {
        let metresPerDegree = 111_320.0
        let scale = cos(point.latitude * .pi / 180)
        let px = (point.longitude - a.longitude) * metresPerDegree * scale
        let py = (point.latitude - a.latitude) * metresPerDegree
        let bx = (b.longitude - a.longitude) * metresPerDegree * scale
        let by = (b.latitude - a.latitude) * metresPerDegree
        let lengthSquared = bx * bx + by * by
        guard lengthSquared > 0 else { return (0, (px * px + py * py).squareRoot()) }
        let t = max(0, min(1, (px * bx + py * by) / lengthSquared))
        let dx = px - t * bx, dy = py - t * by
        return (t, (dx * dx + dy * dy).squareRoot())
    }
}
