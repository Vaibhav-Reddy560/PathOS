import Foundation

/// The direction you're actually travelling, steady enough to turn a map by.
///
/// A raw GPS course jumps a few degrees on every fix and disappears the moment you stop, which
/// makes a map that swings and then snaps back. Two things fix that: averaging the last few fixes
/// around the circle, and holding the last good course through a red light rather than dropping it.
nonisolated enum TravelCourse {
    /// Below this you aren't going anywhere, and the course means nothing.
    static let movingSpeed = 1.4
    /// A stop at a light shouldn't lose the direction you were going in.
    static let hold: TimeInterval = 8
    /// How many fixes are averaged.
    static let window = 3

    nonisolated struct Reading: Equatable, Sendable {
        /// Degrees from true north, or nil when there's nothing worth believing.
        var degrees: Double?
        var at: Date
        /// The last few raw courses, newest last.
        var recent: [Double] = []
    }

    /// Takes a fix's course and speed and returns what the map should use.
    ///
    /// `course` below zero is CoreLocation's way of saying it doesn't know.
    static func update(_ reading: Reading, course: Double, accuracy: Double, speed: Double, at now: Date) -> Reading {
        guard course >= 0, accuracy >= 0, speed >= movingSpeed else {
            // Stopped or unknown: keep what we had until it goes stale, then admit we don't know.
            return now.timeIntervalSince(reading.at) <= hold
                ? reading
                : Reading(degrees: nil, at: reading.at, recent: [])
        }
        var recent = reading.recent + [course]
        if recent.count > window { recent.removeFirst(recent.count - window) }
        return Reading(degrees: mean(of: recent), at: now, recent: recent)
    }

    /// The mean of angles, taken around the circle: 350° and 10° average to 0°, not 180°.
    static func mean(of degrees: [Double]) -> Double? {
        guard !degrees.isEmpty else { return nil }
        let radians = degrees.map { $0 * .pi / 180 }
        let x = radians.reduce(0) { $0 + cos($1) } / Double(radians.count)
        let y = radians.reduce(0) { $0 + sin($1) } / Double(radians.count)
        guard x != 0 || y != 0 else { return degrees.last }
        let angle = atan2(y, x) * 180 / .pi
        return (angle + 360).truncatingRemainder(dividingBy: 360)
    }

    /// How far apart two headings are, never more than 180°.
    static func difference(_ a: Double, _ b: Double) -> Double {
        abs(((a - b) + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
}
