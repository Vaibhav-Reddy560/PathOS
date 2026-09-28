import CoreLocation
import Foundation

/// Where to draw you on the map that leads you, this frame, and which way you're going.
///
/// One answer for everything on that map. The camera, your arrow and the head of the line are
/// all drawn from it, so none of them can lag the others — which is what they did when MapKit
/// moved the puck, a timer trimmed the line, and the phone's compass turned the map.
///
/// On the route, you're drawn *on* it: GPS puts you a few metres to one side as often as not,
/// and a car in the middle of the road shown beside its own line reads as lost. Between fixes,
/// you're carried forward at the speed you were doing, so the arrow glides instead of hopping
/// once a second. And the way you're going is the road's way, a few metres ahead — not the
/// compass, which in a car points wherever the phone happens to face, and not the GPS course,
/// which lags every bend of a winding road by a second or two.
nonisolated enum NavigationPose {

    /// The last fix, as the map needs it.
    nonisolated struct Fix: Sendable {
        var coordinate: CLLocationCoordinate2D
        /// The direction of travel by GPS, degrees clockwise from north; nil when it isn't known.
        var course: Double?
        /// Metres per second; 0 when it isn't known.
        var speed: Double
        var at: Date
        /// Metres along the route, and how far off it, when the fix was matched to it.
        var travelled: Double?
        var offset: Double?
    }

    nonisolated struct Pose: Sendable {
        var coordinate: CLLocationCoordinate2D
        /// The way you're going, degrees clockwise from north.
        var heading: Double
        /// Metres along the route, when you're drawn on it.
        var along: Double?
    }

    /// A route with its running distances, measured once rather than every frame.
    nonisolated struct Line: Sendable {
        let coordinates: [CLLocationCoordinate2D]
        /// Metres from the start to each point.
        let cumulative: [Double]

        init(_ coordinates: [CLLocationCoordinate2D]) {
            self.coordinates = coordinates
            var running = [0.0]
            running.reserveCapacity(coordinates.count)
            for (a, b) in zip(coordinates, coordinates.dropFirst()) {
                running.append(running[running.count - 1] + GeoMath.distance(from: a, to: b))
            }
            cumulative = coordinates.isEmpty ? [] : running
        }

        var total: Double { cumulative.last ?? 0 }

        /// The point `metres` along, and the segment it's on.
        func point(at metres: Double) -> (coordinate: CLLocationCoordinate2D, segment: Int)? {
            guard coordinates.count > 1 else { return coordinates.first.map { ($0, 0) } }
            let target = min(max(0, metres), total)
            // The last segment starting at or before the target.
            var low = 0
            var high = coordinates.count - 2
            while low < high {
                let mid = (low + high + 1) / 2
                if cumulative[mid] <= target { low = mid } else { high = mid - 1 }
            }
            let a = coordinates[low], b = coordinates[low + 1]
            let length = cumulative[low + 1] - cumulative[low]
            let t = length > 0 ? (target - cumulative[low]) / length : 0
            return (CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                           longitude: a.longitude + (b.longitude - a.longitude) * t), low)
        }

        /// Which way the road runs from `metres` along, over the next `over` metres of it.
        func bearing(at metres: Double, over: Double) -> Double? {
            guard let here = point(at: metres) else { return nil }
            let end = min(total, metres + over)
            if end - metres > 1, let ahead = point(at: end) {
                return GeoMath.bearing(from: here.coordinate, to: ahead.coordinate)
            }
            // At the very end: the way the last stretch ran into it.
            guard let before = point(at: max(0, metres - over)), metres > 1 else { return nil }
            return GeoMath.bearing(from: before.coordinate, to: here.coordinate)
        }
    }

    /// Drawn on the line when nearer it than this.
    static let snapWithin = 30.0
    /// Carried forward from a fix for no longer than this: past it, reckoning is invention.
    static let maxLead = 1.5
    /// A correction backwards smaller than this holds you still until the fixes catch up, rather
    /// than sliding you back; a bigger one is believed.
    static let snapBack = 20.0
    /// The way you're going is the road's over the next this many metres, which turns the map
    /// as a bend arrives rather than after it.
    static let roadAhead = 15.0
    /// Slower than this, you're standing still, and neither carried forward nor turned.
    static let moving = 1.0

    static func pose(_ fix: Fix, on line: Line?, lastAlong: Double?, lastHeading: Double, now: Date) -> Pose {
        let sinceFix = min(max(0, now.timeIntervalSince(fix.at)), maxLead)
        let isMoving = fix.speed >= moving

        if let line, line.total > 0, let travelled = fix.travelled, let offset = fix.offset, offset <= snapWithin {
            var along = min(line.total, travelled + (isMoving ? fix.speed * sinceFix : 0))
            if let lastAlong, along < lastAlong, lastAlong - along < snapBack {
                along = lastAlong
            }
            let point = line.point(at: along)?.coordinate ?? fix.coordinate
            let heading = line.bearing(at: along, over: roadAhead) ?? fix.course ?? lastHeading
            return Pose(coordinate: point, heading: heading, along: along)
        }

        // Off the line: where the fix says, carried on the way it was going.
        var coordinate = fix.coordinate
        if isMoving, let course = fix.course {
            coordinate = GeoMath.coordinate(coordinate, metres: fix.speed * sinceFix, bearing: course)
        }
        return Pose(coordinate: coordinate, heading: (isMoving ? fix.course : nil) ?? lastHeading, along: nil)
    }

    /// Turns from one heading towards another, the short way round, easing in over
    /// `timeConstant` seconds: quick enough to follow a zigzag, smooth enough not to jerk.
    static func turn(from current: Double, toward target: Double, dt: TimeInterval, timeConstant: TimeInterval) -> Double {
        let delta = (target - current + 540).truncatingRemainder(dividingBy: 360) - 180
        let share = timeConstant > 0 ? 1 - exp(-max(0, dt) / timeConstant) : 1
        let turned = current + delta * share
        return (turned.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }
}
