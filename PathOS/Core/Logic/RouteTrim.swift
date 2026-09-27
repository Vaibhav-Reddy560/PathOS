import Foundation

/// Where the head of the route line is drawn between one fix and the next.
///
/// MapKit moves its puck smoothly towards each new position, while PathOS only learns where you are
/// about once a second. Setting the line's head to the last known position leaves it trailing behind
/// a puck that has already moved on, and then snapping forward — which is what "the line takes time
/// to catch up" looks like. So between fixes the head is reckoned forward at the speed you were
/// doing, and put right the moment the truth arrives.
///
/// Two rules keep the reckoning honest. It never runs more than `maxLead` seconds ahead of the last
/// fix, so a lost signal can't draw a long stretch of fiction. And it never goes backwards for a
/// small correction — it waits for the truth to catch up instead, because a head that retreats
/// under the puck reads as a fault. Only a jump big enough to be a new route snaps it back.
nonisolated enum RouteTrim {

    /// The last thing actually known: where you were on the route, when, and how fast.
    nonisolated struct Anchor: Equatable, Sendable {
        /// How much of the route was behind you, 0 to 1.
        var fraction: Double
        var at: Date
        /// 0 when stopped, or when the fix doesn't say.
        var metresPerSecond: Double
        var routeMetres: Double
    }

    /// Past this long without a fix, the head simply waits.
    static let maxLead: TimeInterval = 1.5
    /// A drop bigger than this is a new route, not a correction.
    static let snapBack = 0.02
    /// Slower than this and there is nowhere for the head to go.
    static let stopped = 0.5

    /// Where to draw the head now, given the last fix and where it was drawn a frame ago.
    static func shown(_ anchor: Anchor, lastShown: Double, sinceFix: TimeInterval) -> Double {
        guard anchor.routeMetres > 0 else { return 0 }
        // Far enough back to be a different route: follow it down.
        if anchor.fraction < lastShown - snapBack { return anchor.fraction }
        let lead = min(max(0, sinceFix), maxLead) * max(0, anchor.metresPerSecond)
        return min(0.999, max(lastShown, anchor.fraction + lead / anchor.routeMetres))
    }
}
