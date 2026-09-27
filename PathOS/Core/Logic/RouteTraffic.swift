import Foundation

/// How the traffic runs along the road ahead, in stretches of the route.
///
/// Apple Maps publishes no per-street traffic, but it will time any stretch of road for any
/// departure. So PathOS asks twice: once for the next kilometre and once for the whole of what's
/// left, and takes the difference. That gives two stretches — what's immediately ahead, and what
/// comes after it.
///
/// Taking the difference is the whole point. A clear kilometre in front of a jam averages out to
/// "slow" over the whole remaining route, which is exactly the answer that would send you into it.
///
/// Each stretch is then judged against *itself*, not against a speed. Asking how fast a road is
/// moving sounds like the plainest measure there is, and it is wrong: the lanes around Jayanagar
/// run at 18 km/h at four in the morning with nothing on them, because of the speed humps and a
/// junction every hundred metres. Judged by speed alone the whole of a city's side streets is a
/// permanent jam. So every stretch is asked about a second time for a quiet hour, and what's
/// reported is how much longer it is taking than the same road takes when nothing is in the way.
nonisolated enum RouteTraffic {

    /// What one stretch of road measured.
    nonisolated struct Measure: Equatable, Sendable {
        var metres: Double
        /// How long it takes in the traffic on it now.
        var seconds: TimeInterval
        /// How long the same stretch takes when nothing is in the way. Nil when Apple Maps
        /// wouldn't say, and then the stretch is reported as flowing rather than guessed at.
        var freeFlowSeconds: TimeInterval?

        /// What's left of this stretch once a shorter one inside it has been accounted for.
        /// Free flow subtracts only when both halves know it: the rest of a road can't be timed
        /// against a baseline that was never measured for the part being taken off it.
        func less(_ part: Measure) -> Measure {
            var freeFlow: TimeInterval?
            if let whole = freeFlowSeconds, let inside = part.freeFlowSeconds {
                freeFlow = whole - inside
            }
            return Measure(metres: metres - part.metres, seconds: seconds - part.seconds,
                           freeFlowSeconds: freeFlow)
        }
    }

    nonisolated enum Flow: String, Equatable, Sendable {
        case clear
        case slow
        case heavy

        /// The words for a degree. The colour is a ramp, not these three — `PathOSPalette.traffic`
        /// draws it — but speech and labels have to pick one of a few things to say.
        init(severity: Double) {
            self = severity <= 0 ? .clear : severity < Flow.heavyAbove ? .slow : .heavy
        }

        static let heavyAbove = 0.5

        /// Aurora, amber, coral — the palette's own meanings: moving, worth a glance, urgent.
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
        /// 0 while the road runs as it always does, up to 1 when it's as held up as PathOS shows.
        var severity: Double

        var flow: Flow { Flow(severity: severity) }
    }

    /// How far ahead the road's speed is asked about.
    static let probeMetres = 1_000.0
    /// Shorter than this isn't worth a colour of its own.
    static let shortestBand = 200.0
    /// Two stretches this close in degree are one stretch.
    static let sameEnough = 0.12

    /// Slower than free flow by less than this is the road being the road, not traffic.
    /// Apple Maps' own times drift by a few per cent between identical requests, and a junction
    /// or a light that happens to be red costs more than that on a short stretch.
    static let freeFlowing = 1.15
    /// Taking well over twice as long as it should is as bad as the colour goes. Past this the
    /// road is stopped and there is nothing more to say about it.
    static let jammed = 2.2

    /// How badly a stretch is held up, 0…1.
    ///
    /// Zero means "running as it always does", which is not the same as fast: a lane that never
    /// exceeds 18 km/h scores zero when it is doing 18 km/h, and a motorway that normally does
    /// 80 scores badly at 40. That is the whole difference between this and measuring speed.
    static func severity(seconds: TimeInterval, freeFlow: TimeInterval?) -> Double {
        guard let freeFlow, seconds > 0, freeFlow > 0 else { return 0 }
        let ratio = seconds / freeFlow
        guard ratio > freeFlowing else { return 0 }
        return min(1, (ratio - freeFlowing) / (jammed - freeFlowing))
    }

    static func severity(of measure: Measure) -> Double {
        severity(seconds: measure.seconds, freeFlow: measure.freeFlowSeconds)
    }

    /// The route ahead split into stretches. Without a probe, or with too little left after it,
    /// the whole of what remains is one stretch.
    static func bands(routeMetres: Double, travelledMetres: Double,
                      probe: Measure?, remaining: Measure) -> [Band] {
        guard routeMetres > 0 else { return [] }
        let head = min(1, max(0, travelledMetres / routeMetres))
        let whole = Band(start: head, end: 1, severity: severity(of: remaining))
        guard let probe, probe.metres > 0, probe.seconds > 0 else { return [whole] }

        // What's left after the stretch just measured — not the whole of it again.
        let rest = remaining.less(probe)
        guard rest.metres >= shortestBand, rest.seconds > 0 else { return [whole] }

        let boundary = min(1, head + probe.metres / routeMetres)
        guard boundary > head else { return [whole] }
        let near = severity(of: probe)
        let far = severity(of: rest)
        // A clear kilometre in front of a clear rest is one line, not two.
        guard abs(near - far) > sameEnough else {
            return [Band(start: head, end: 1, severity: max(near, far))]
        }
        return [Band(start: head, end: boundary, severity: near),
                Band(start: boundary, end: 1, severity: far)]
    }

    /// A time the roads are empty, for asking Apple Maps what a stretch takes without traffic.
    ///
    /// Half three in the morning: after the last of the night out and before the first of the
    /// markets. Always the next one, because Apple Maps predicts departures and won't be asked
    /// about the past.
    static func quietHour(after now: Date, calendar: Calendar = .current) -> Date {
        var wanted = DateComponents()
        wanted.hour = 3
        wanted.minute = 30
        // A minute's grace: asking for the very instant it is now can land behind the request.
        return calendar.nextDate(after: now.addingTimeInterval(60), matching: wanted,
                                 matchingPolicy: .nextTime) ?? now.addingTimeInterval(3_600)
    }
}
