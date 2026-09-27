import Foundation

/// How the traffic runs along the road ahead, in stretches of the route.
///
/// Apple Maps publishes no per-street traffic, but it will time any stretch of road in the traffic
/// on it now. So PathOS asks twice: once for the next kilometre and once for the whole of what's
/// left, and takes the difference. That gives two stretches — what's immediately ahead, and what
/// comes after it — each judged by the plainest measure there is, how fast the road is moving.
///
/// Taking the difference is the whole point. A clear kilometre in front of a jam averages out to
/// "slow" over the whole remaining route, which is exactly the answer that would send you into it.
nonisolated enum RouteTraffic {

    nonisolated enum Flow: String, Equatable, Sendable {
        case clear
        case slow
        case heavy

        /// Aurora, amber, coral — the palette's own meanings: yours, worth a glance, urgent.
        var role: SignalRole {
            switch self {
            case .clear: .you
            case .slow: .attention
            case .heavy: .critical
            }
        }

        var label: String {
            switch self {
            case .clear: "Clear"
            case .slow: "Slow"
            case .heavy: "Heavy traffic"
            }
        }
    }

    /// A stretch of the route, as fractions of the whole of it, so it composes with the part
    /// already behind you without being worked out again.
    nonisolated struct Band: Equatable, Sendable {
        var start: Double
        var end: Double
        var flow: Flow
    }

    /// How far ahead the road's speed is asked about.
    static let probeMetres = 1_000.0
    /// City speeds, in metres per second: 30 km/h and 15 km/h.
    static let clearSpeed = 30.0 / 3.6
    static let heavySpeed = 15.0 / 3.6
    /// Shorter than this isn't worth a colour of its own.
    static let shortestBand = 200.0

    /// What a stretch's speed makes of it. Unknown never alarms.
    static func flow(metres: Double, seconds: TimeInterval) -> Flow {
        guard metres > 0, seconds > 0 else { return .clear }
        let speed = metres / seconds
        if speed >= clearSpeed { return .clear }
        return speed >= heavySpeed ? .slow : .heavy
    }

    /// The route ahead split into stretches. Without a probe, or with too little left after it,
    /// the whole of what remains is one stretch.
    static func bands(routeMetres: Double, travelledMetres: Double,
                      probeMetres: Double?, probeSeconds: TimeInterval?,
                      remainingMetres: Double, remainingSeconds: TimeInterval) -> [Band] {
        guard routeMetres > 0 else { return [] }
        let head = min(1, max(0, travelledMetres / routeMetres))
        let whole = Band(start: head, end: 1, flow: flow(metres: remainingMetres, seconds: remainingSeconds))
        guard let probeMetres, let probeSeconds, probeMetres > 0, probeSeconds > 0 else { return [whole] }

        // What's left after the stretch just measured — not the whole of it again.
        let restMetres = remainingMetres - probeMetres
        let restSeconds = remainingSeconds - probeSeconds
        guard restMetres >= shortestBand, restSeconds > 0 else { return [whole] }

        let boundary = min(1, head + probeMetres / routeMetres)
        guard boundary > head else { return [whole] }
        let near = Band(start: head, end: boundary, flow: flow(metres: probeMetres, seconds: probeSeconds))
        let far = Band(start: boundary, end: 1, flow: flow(metres: restMetres, seconds: restSeconds))
        // A clear kilometre in front of a clear rest is one line, not two.
        return near.flow == far.flow ? [Band(start: head, end: 1, flow: near.flow)] : [near, far]
    }
}
