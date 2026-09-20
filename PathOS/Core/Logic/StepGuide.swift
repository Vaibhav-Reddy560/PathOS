import CoreLocation
import Foundation

/// Where you are along a driving or walking route, and what to do next.
///
/// Apple Maps gives the steps; this works out which one you're on from your position and how far
/// is left of it, so the map can say "In 200 m, turn right onto Bull Temple Road" without PathOS
/// pretending to be a navigation system that knows more than it does.
nonisolated enum StepGuide {

    nonisolated struct Step: Hashable, Sendable {
        /// Apple Maps' own wording: "Turn right onto Bull Temple Road".
        var instruction: String
        /// The step's shape, in order, so how far is left of it can be measured.
        var coordinates: [CLLocationCoordinate2D]
        var distanceMeters: Double

        var end: CLLocationCoordinate2D? { coordinates.last }

        static func == (a: Step, b: Step) -> Bool {
            a.instruction == b.instruction && a.distanceMeters == b.distanceMeters
                && a.coordinates.count == b.coordinates.count
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(instruction)
            hasher.combine(distanceMeters)
        }
    }

    nonisolated struct Position: Equatable, Sendable {
        var stepIndex: Int
        /// Metres to the end of the step you're on, along the road rather than straight.
        var metresToStep: Double
        /// Metres to the end of the whole route.
        var metresRemaining: Double
        /// How far off the route you are. Far enough and the route is no longer what you're doing.
        var offRouteMetres: Double

        var isOffRoute: Bool { offRouteMetres > offRouteLimit }
    }

    /// Beyond this from the route, you're not on it: a wrong turn, or a different way entirely.
    static let offRouteLimit = 120.0
    /// Closer than this to the turn and it's happening now rather than coming up.
    static let atTheTurn = 40.0

    static func position(in steps: [Step], at location: CLLocationCoordinate2D) -> Position? {
        guard !steps.isEmpty else { return nil }

        var best: (index: Int, offset: Double, toEnd: Double)?
        for (index, step) in steps.enumerated() {
            guard step.coordinates.count > 1 else { continue }
            var walked = 0.0
            var bestForStep: (offset: Double, toEnd: Double)?
            // Along the step, segment by segment: the nearest point on it is where you are, and
            // what's left of the step is everything past that point.
            let total = length(of: step.coordinates)
            for (a, b) in zip(step.coordinates, step.coordinates.dropFirst()) {
                let segment = GeoMath.distance(from: a, to: b)
                let offset = distanceToSegment(location, a, b)
                if bestForStep == nil || offset < bestForStep!.offset {
                    // Measured to the far end of this segment, plus the rest of the step.
                    bestForStep = (offset, total - walked - segment + GeoMath.distance(from: location, to: b))
                }
                walked += segment
            }
            guard let bestForStep else { continue }
            if best == nil || bestForStep.offset < best!.offset {
                best = (index, bestForStep.offset, max(0, bestForStep.toEnd))
            }
        }
        guard let best else { return nil }

        let after = steps.dropFirst(best.index + 1).reduce(0) { $0 + $1.distanceMeters }
        return Position(
            stepIndex: best.index,
            metresToStep: best.toEnd,
            metresRemaining: best.toEnd + after,
            offRouteMetres: best.offset
        )
    }

    /// Which way the route is heading from where you are: the bearing from the nearest point on
    /// it to a point a little further along.
    ///
    /// This is what turns the map while you're stopped at a light or waiting for an auto, when
    /// there's no course to go by: the road ahead still points somewhere.
    static func heading(along route: [CLLocationCoordinate2D], at location: CLLocationCoordinate2D,
                        lookingAhead metres: Double = 80) -> Double? {
        guard route.count > 1 else { return nil }
        // The nearest point on the line, then walk forward from it.
        var nearest = 0
        var nearestDistance = Double.infinity
        for index in route.indices {
            let distance = GeoMath.distance(from: location, to: route[index])
            if distance < nearestDistance {
                nearestDistance = distance
                nearest = index
            }
        }
        var walked = 0.0
        var ahead = route.count - 1
        for index in nearest..<(route.count - 1) {
            walked += GeoMath.distance(from: route[index], to: route[index + 1])
            if walked >= metres {
                ahead = index + 1
                break
            }
        }
        guard ahead > nearest else { return nil }
        return GeoMath.bearing(from: route[nearest], to: route[ahead])
    }

    /// The turn drawn as a symbol, read from Apple Maps' own wording since it gives no code for it.
    static func symbol(for instruction: String) -> String {
        let text = instruction.lowercased()
        if text.contains("u-turn") { return "arrow.uturn.down" }
        if text.contains("arrive") || text.contains("destination") { return "mappin.and.ellipse" }
        if text.contains("roundabout") || text.contains("rotary") { return "arrow.triangle.turn.up.right.circle" }
        if text.contains("exit") { return "arrow.turn.up.right" }
        if text.contains("merge") { return "arrow.merge" }
        if text.contains("slight right") || text.contains("keep right") || text.contains("bear right") { return "arrow.up.right" }
        if text.contains("slight left") || text.contains("keep left") || text.contains("bear left") { return "arrow.up.left" }
        if text.contains("right") { return "arrow.turn.up.right" }
        if text.contains("left") { return "arrow.turn.up.left" }
        return "arrow.up"
    }

    /// "In 250 m, turn right onto Bull Temple Road", or just the instruction at the turn itself.
    static func sentence(for step: Step, metresToStep: Double) -> String {
        let instruction = step.instruction.isEmpty ? "Carry on" : step.instruction
        guard metresToStep > atTheTurn else { return instruction }
        return "In \(GeoMath.formatDistance(rounded(metresToStep))), \(instruction.prefix(1).lowercased() + instruction.dropFirst())"
    }

    /// Distances people can act on: 50 m steps close in, 100 m further out.
    static func rounded(_ metres: Double) -> Double {
        metres < 500 ? (metres / 50).rounded() * 50 : (metres / 100).rounded() * 100
    }

    static func length(of coordinates: [CLLocationCoordinate2D]) -> Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { $0 + GeoMath.distance(from: $1.0, to: $1.1) }
    }

    /// How far a point is from a segment, in metres, flat-earth over these distances.
    static func distanceToSegment(_ point: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let metresPerDegree = 111_320.0
        let scale = cos(point.latitude * .pi / 180)
        let px = (point.longitude - a.longitude) * metresPerDegree * scale
        let py = (point.latitude - a.latitude) * metresPerDegree
        let bx = (b.longitude - a.longitude) * metresPerDegree * scale
        let by = (b.latitude - a.latitude) * metresPerDegree
        let lengthSquared = bx * bx + by * by
        guard lengthSquared > 0 else { return (px * px + py * py).squareRoot() }
        let t = max(0, min(1, (px * bx + py * by) / lengthSquared))
        let dx = px - t * bx, dy = py - t * by
        return (dx * dx + dy * dy).squareRoot()
    }
}
