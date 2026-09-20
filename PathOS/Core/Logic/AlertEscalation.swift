import Foundation

/// How hard an alert should try to reach you.
///
/// PathOS can only hear the world while it's open, so at the moment an alert fires — phone locked,
/// in a pocket, on a noisy road — it doesn't know what it's competing with. What it does know is
/// what it heard last, and how much the alert matters. Something urgent, in a place that was loud
/// the last time PathOS listened, is said twice: one buzz in traffic is easily missed, and the
/// second is cancelled the moment you pick the phone up.
nonisolated enum AlertEscalation {
    /// After this long, what PathOS last heard says nothing about where you are now.
    static let sceneGoesStale: TimeInterval = 2 * 3_600
    /// Long enough to have missed the first, short enough to still matter.
    static let repeatAfter: TimeInterval = 45
    static let repeatAfterQuiet: TimeInterval = 90

    nonisolated struct Plan: Equatable, Sendable {
        /// Breaks through a Focus, and shows while the phone is on a table.
        var isTimeSensitive: Bool
        /// Nil means it's said once.
        var repeatAfter: TimeInterval?
        /// Said aloud, where PathOS is already talking to you.
        var speaks: Bool
    }

    /// `heardNoise` is what the microphone last reported, and when.
    static func plan(role: SignalRole, heardNoise: (scene: SoundScene, at: Date)?, now: Date = Date(),
                     repeatsUrgent: Bool = true, isSpeaking: Bool = false) -> Plan {
        let scene = heardNoise.flatMap { now.timeIntervalSince($0.at) <= sceneGoesStale ? $0.scene : nil }
        let isLoud = scene == .noisy
        let isHushed = scene == .quiet

        switch role {
        case .critical:
            return Plan(isTimeSensitive: true,
                        repeatAfter: repeatsUrgent ? (isHushed ? repeatAfterQuiet : repeatAfter) : nil,
                        speaks: isSpeaking)
        case .attention:
            // Worth acting on: leaving now, running late, rain before you walk out. It breaks
            // through a Focus, and in somewhere loud it says itself twice.
            return Plan(isTimeSensitive: true,
                        repeatAfter: repeatsUrgent && isLoud ? repeatAfter : nil,
                        speaks: isSpeaking && isLoud)
        case .you, .world:
            return Plan(isTimeSensitive: false, repeatAfter: nil, speaks: false)
        }
    }

    /// The second one says the same thing, so it reads as a nudge rather than news.
    static func repeatID(of id: String) -> String { "\(id).again" }
}
