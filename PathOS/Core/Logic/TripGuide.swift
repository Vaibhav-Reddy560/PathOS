import CoreLocation
import Foundation

/// Following a planned journey while you make it: which leg you're on, what to do next, and
/// whether you're running behind.
///
/// It measures *you*, never the train or the auto: where you are against where the plan said
/// you'd be by now. Being behind is reported as the plain difference, so it can be trusted.
nonisolated enum TripGuide {

    nonisolated struct Status: Equatable, Sendable {
        /// The leg you're on now.
        var legIndex: Int
        var hasArrived: Bool
        /// Minutes later than the plan, 0 when on time or ahead.
        var minutesBehind: Int
        /// Minutes still to go, the delay included.
        var minutesRemaining: Int
        /// "By road to Jayadeva Hospital".
        var headline: String
        /// "About 9 min · you should be on the train by now".
        var detail: String
        var symbol: String

        var isBehind: Bool { minutesBehind >= lateAfterMinutes }
    }

    /// Being a few minutes out is traffic, not lateness.
    static let lateAfterMinutes = 5
    /// Metro stations are big and GPS is poor around them.
    static let stationRadius = 700.0
    static let placeRadius = 250.0

    /// Arriving never needs you nearer than this: about as well as GPS knows a street.
    static let nearestArrival = 30.0

    static func radius(for leg: DoorToDoor.Leg) -> Double {
        leg.mode == .metro || leg.mode == .bus ? stationRadius : placeRadius
    }

    /// How close to a place counts as being at it, at the end of a road or a walk.
    static let doorRadius = 60.0
    /// And how close to where the road route ends — which, for a campus whose pin is a couple of
    /// hundred metres inside its gate, is the gate.
    static let roadEndRadius = 40.0

    /// How close counts as having reached the end of a leg that set off from `start`.
    ///
    /// For a road or a walk: at the place, or at the end of the road to it (`RoadEnd`) — never a
    /// couple of hundred metres short. A generous 250 m ended the driving view before you'd
    /// arrived, and a fixed one made every trip shorter than that arrive on its first fix. Never
    /// more than a third of the leg either, so a short trip doesn't arrive as it sets off. A
    /// station keeps its wide circle: GPS underground can't be asked for more.
    static func radius(for leg: DoorToDoor.Leg, from start: CLLocationCoordinate2D?) -> Double {
        guard leg.mode != .metro, leg.mode != .bus else { return radius(for: leg) }
        guard let start else { return doorRadius }
        let span = GeoMath.distance(from: start, to: leg.endCoordinate)
        return min(doorRadius, max(nearestArrival, span / 3))
    }

    /// Where the road route for the leg you're on ends, and whether you've stopped near it.
    nonisolated struct RoadEnd: Sendable {
        var leg: Int
        var point: CLLocationCoordinate2D
        /// Stopped within a short walk of it for a while: parked just short, which is arriving.
        var hasStoppedNear = false
    }

    /// Which side of you the place is, once you're there.
    nonisolated enum Side: String, Equatable, Sendable {
        case left
        case right
        case ahead
        case here
    }

    /// The side of the road the place is on, arriving along `bearing` at the end of the route.
    static func side(of place: CLLocationCoordinate2D, from roadEnd: CLLocationCoordinate2D,
                     arrivingAlong bearing: Double) -> Side {
        guard GeoMath.distance(from: roadEnd, to: place) > 20 else { return .here }
        let turn = (GeoMath.bearing(from: roadEnd, to: place) - bearing + 540)
            .truncatingRemainder(dividingBy: 360) - 180
        if abs(turn) < 30 { return .ahead }
        return turn > 0 ? .right : .left
    }

    /// When each leg should be finished, in minutes from setting off. Getting into a station is
    /// counted before the ride, which is where that time actually goes.
    static func schedule(_ option: DoorToDoor.Option) -> [Double] {
        var clock = 0.0
        return option.legs.map { leg in
            if leg.mode == .metro || leg.mode == .bus {
                clock += Double(DoorToDoor.stationEntryMinutes)
            }
            clock += Double(leg.minutes)
            return clock
        }
    }

    /// How many legs you've finished, from where you are. A leg counts as finished when you're at
    /// the place it ends; the furthest one wins, so passing a station you'd already left behind
    /// doesn't send the plan backwards.
    static func legsDone(_ option: DoorToDoor.Option, at location: CLLocationCoordinate2D?,
                         origin: CLLocationCoordinate2D? = nil, roadEnd: RoadEnd? = nil) -> Int? {
        guard let location else { return nil }
        let reached = option.legs.indices.filter { index in
            // Each leg sets off from where the one before it ended; the first from where you were.
            let start = index == 0 ? origin : option.legs[index - 1].endCoordinate
            let leg = option.legs[index]
            if GeoMath.distance(from: location, to: leg.endCoordinate) <= radius(for: leg, from: start) {
                return true
            }
            guard let roadEnd, roadEnd.leg == index else { return false }
            return roadEnd.hasStoppedNear || GeoMath.distance(from: location, to: roadEnd.point) <= roadEndRadius
        }
        // Knowing you're nowhere along it yet is knowing something: nil is only for having no
        // fix at all, which is when the clock has to carry the plan instead.
        return (reached.max().map { $0 + 1 }) ?? 0
    }

    static func status(for option: DoorToDoor.Option, startedAt: Date, now: Date,
                       location: CLLocationCoordinate2D?, origin: CLLocationCoordinate2D? = nil,
                       roadEnd: RoadEnd? = nil) -> Status? {
        guard !option.legs.isEmpty else { return nil }
        let plan = schedule(option)
        let elapsed = max(0, now.timeIntervalSince(startedAt) / 60)

        // Without a fix, the clock carries the plan, which is what happens underground. It can
        // move you along the legs but never past the end: arriving is something the map has to see.
        let byClock = min(plan.filter { $0 <= elapsed }.count, option.legs.count - 1)
        let done = min(legsDone(option, at: location, origin: origin, roadEnd: roadEnd) ?? byClock, option.legs.count)

        if done >= option.legs.count {
            return Status(legIndex: option.legs.count - 1, hasArrived: true, minutesBehind: 0, minutesRemaining: 0,
                          headline: "You've arrived", detail: option.legs.last?.endName ?? "", symbol: "checkmark.circle.fill")
        }

        // Behind by the plainest measure there is: how long past the time this leg should have
        // ended. Inside the leg's own window that's nothing, however slow the leg felt.
        let leg = option.legs[done]
        let dueBy = plan[done]
        let behind = max(0, Int((elapsed - dueBy).rounded()))
        // What's left after this leg, plus whatever this one still needs. Once you're past due,
        // the rest of this leg is unknowable, so it's taken as a couple of minutes at least.
        let afterThisLeg = plan.last! - dueBy
        let thisLeg = behind > 0 ? 2.0 : max(0, dueBy - elapsed)

        return Status(
            legIndex: done,
            hasArrived: false,
            minutesBehind: behind,
            minutesRemaining: Int((afterThisLeg + thisLeg).rounded()),
            headline: instruction(for: leg),
            detail: detail(leg: leg, behind: behind, remaining: Int((afterThisLeg + thisLeg).rounded())),
            symbol: leg.mode.symbol
        )
    }

    /// The same status, timed by what's actually left of the leg you're on — Apple Maps' time for
    /// the rest of the route, in the traffic now — instead of by the plan's clock. Behind is then
    /// how much later than planned you'll arrive, which traffic can make true before you've
    /// missed a single leg.
    static func adjusting(_ status: Status, in option: DoorToDoor.Option, startedAt: Date, now: Date,
                          legMinutesLeft: Double) -> Status {
        guard !status.hasArrived, option.legs.indices.contains(status.legIndex) else { return status }
        let plan = schedule(option)
        let afterThisLeg = plan.last! - plan[status.legIndex]
        let remaining = Int((afterThisLeg + max(0, legMinutesLeft)).rounded())
        let plannedArrival = startedAt.addingTimeInterval(plan.last! * 60)
        let projected = now.addingTimeInterval(Double(remaining) * 60)
        let behind = max(0, Int((projected.timeIntervalSince(plannedArrival) / 60).rounded()))
        var adjusted = status
        adjusted.minutesRemaining = remaining
        adjusted.minutesBehind = behind
        adjusted.detail = detail(leg: option.legs[status.legIndex], behind: behind, remaining: remaining)
        return adjusted
    }

    /// What to do on this leg, as an instruction rather than a label.
    static func instruction(for leg: DoorToDoor.Leg) -> String {
        switch leg.mode {
        case .walk: leg.title
        // However you're going by road — driving, an auto, a cab — it's the road that's said.
        case .auto, .bikeTaxi, .cab: "By road to \(leg.endName)"
        case .metro: "Ride to \(leg.endName)"
        case .bus: "Take the bus to \(leg.endName)"
        }
    }

    private static func detail(leg: DoorToDoor.Leg, behind: Int, remaining: Int) -> String {
        var parts: [String] = []
        if behind >= lateAfterMinutes {
            parts.append("\(behind) min behind · you should be at \(leg.endName) by now")
        } else if let detail = leg.detail {
            parts.append(detail)
        }
        parts.append("about \(remaining) min to go")
        return parts.joined(separator: " · ")
    }
}
