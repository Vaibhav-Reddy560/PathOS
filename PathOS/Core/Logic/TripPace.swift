import Foundation

/// How your driving compares with the pace Apple Maps times a route at.
///
/// Apple Maps times the rest of the route afresh every minute. Driven at its pace, what's left
/// shrinks by a minute every minute; driven quicker, by more. So the two, summed over the leg —
/// the time that passed, and the time Apple Maps' own estimate came down by — are your pace
/// against its, on the same roads in the same traffic, with nothing assumed about how fast any
/// road should be. It's what lets a driver who's consistently quicker see an arrival time that
/// believes them, as Google Maps and Apple Maps do.
nonisolated struct TripPace: Equatable, Sendable {
    /// Seconds that passed between readings, and seconds Apple Maps' estimate fell by over them.
    private(set) var elapsed: TimeInterval = 0
    private(set) var expected: TimeInterval = 0
    private var last: Reading?

    private struct Reading: Equatable, Sendable {
        var remaining: TimeInterval
        var at: Date
        var routeID: UUID
    }

    /// Never trusted beyond this: a fifth either way is already a very quick or very slow driver.
    static let limit = 0.2
    /// Only fully believed after this much driving, as Apple Maps reckons it.
    static let fullWeightAfter: TimeInterval = 10 * 60

    init() {}

    /// A fresh estimate of what's left, on a route. Readings across a re-route aren't compared:
    /// the two estimates are of different roads.
    mutating func record(remaining: TimeInterval, at now: Date, routeID: UUID) {
        defer { last = Reading(remaining: remaining, at: now, routeID: routeID) }
        guard let last, last.routeID == routeID else { return }
        let passed = now.timeIntervalSince(last.at)
        let cameDown = last.remaining - remaining
        // Standing still, or an estimate that jumped: traffic changed, not the driver.
        guard passed > 20, cameDown > 0, cameDown < passed * 3 else { return }
        elapsed += passed
        expected += cameDown
    }

    /// What to multiply Apple Maps' remaining time by: under 1 when you drive quicker than it
    /// expects, over 1 when slower, and 1 until there's enough to go on.
    var factor: Double {
        guard expected > 0 else { return 1 }
        let raw = min(1 + Self.limit, max(1 - Self.limit, elapsed / expected))
        let weight = min(1, expected / Self.fullWeightAfter)
        return 1 + (raw - 1) * weight
    }
}
