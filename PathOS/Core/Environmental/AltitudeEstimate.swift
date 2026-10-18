import Foundation

/// How high you are, from the readings the phone gives and how sure it is of each.
///
/// The barometer's absolute altitude and GPS's both come with an accuracy, and both wander: a
/// reading 30 m out was shown as plainly as a good one. This keeps the last minute of each,
/// takes the middle of the ones known to within `usable`, and says how sure that is — so the
/// number on screen either deserves its precision or says it's settling.
nonisolated enum AltitudeEstimate {
    nonisolated struct Sample: Equatable, Sendable {
        var metres: Double
        /// To within this many metres, either way.
        var accuracy: Double
        var at: Date
    }

    nonisolated struct Reading: Equatable, Sendable {
        var metres: Double
        var accuracy: Double

        /// Known well enough to stand as a number on its own.
        var isSettled: Bool { accuracy <= AltitudeEstimate.settled }
    }

    /// Readings older than this are let go.
    static let window: TimeInterval = 60
    /// Worse than this, a reading isn't shown at all.
    static let usable = 40.0
    /// Better than this, it's shown without a caveat.
    static let settled = 20.0

    /// Keeps the last minute, newest last.
    static func adding(_ sample: Sample, to samples: [Sample]) -> [Sample] {
        (samples + [sample]).filter { sample.at.timeIntervalSince($0.at) <= window }
    }

    /// The best altitude to show now: the median of the usable readings in the last minute, as
    /// sure as the best of them. Nil when nothing is good enough.
    static func best(_ samples: [Sample], now: Date) -> Reading? {
        let usableNow = samples.filter { $0.accuracy > 0 && $0.accuracy <= usable && now.timeIntervalSince($0.at) <= window }
        guard !usableNow.isEmpty else { return nil }
        // Only the most accurate source's readings, when one is clearly better: GPS 30 m out
        // shouldn't pull a barometer reading good to 5 m.
        let sharpest = usableNow.map(\.accuracy).min()!
        let kept = usableNow.filter { $0.accuracy <= max(sharpest * 2, settled) }
        let sorted = kept.map(\.metres).sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return Reading(metres: median, accuracy: sharpest)
    }
}
