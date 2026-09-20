import Foundation

/// What to say out loud while you're being led somewhere, and when to say it.
///
/// Spoken directions are only useful if they come once, early enough to act on, and again at the
/// turn itself. Anything more is noise in a car. This decides; `SpeechOutput` says it.
nonisolated enum NavigationVoice {
    /// The warning that gives you time to move across.
    static let warnAhead = 300.0
    /// The one at the turn itself.
    static let atTurn = 60.0

    nonisolated enum Moment: Hashable, Sendable {
        /// The turn, a long way off: "In 300 metres, turn right onto…".
        case approaching(step: Int)
        /// The turn, now.
        case turning(step: Int)
        /// This leg is done and another starts: "You've reached X. Take…".
        case handover(leg: Int)
        /// Said once, when the plan first slips.
        case behind(leg: Int)
    }

    nonisolated struct Announcement: Equatable, Sendable {
        var moment: Moment
        var text: String
    }

    /// The next thing worth saying, or nothing. `said` is every moment already spoken on this trip.
    static func announcement(step: StepGuide.Step?, stepIndex: Int, metresToStep: Double,
                             legIndex: Int, legInstruction: String, isBehind: Bool, minutesBehind: Int,
                             hasSaidLeg: Bool, said: Set<Moment>) -> Announcement? {
        // A leg that has just begun is announced before anything about its turns.
        if !hasSaidLeg, !said.contains(.handover(leg: legIndex)), legIndex > 0 {
            return Announcement(moment: .handover(leg: legIndex), text: legInstruction)
        }
        if let step {
            let instruction = spoken(step.instruction)
            if metresToStep <= atTurn, !said.contains(.turning(step: stepIndex)) {
                return Announcement(moment: .turning(step: stepIndex), text: instruction)
            }
            if metresToStep <= warnAhead, !said.contains(.approaching(step: stepIndex)),
               !said.contains(.turning(step: stepIndex)) {
                let distance = Int((metresToStep / 50).rounded() * 50)
                return Announcement(moment: .approaching(step: stepIndex),
                                    text: "In \(distance) metres, \(instruction.prefix(1).lowercased() + instruction.dropFirst())")
            }
        }
        if isBehind, !said.contains(.behind(leg: legIndex)) {
            return Announcement(moment: .behind(leg: legIndex),
                                text: "You're about \(minutesBehind) minutes behind.")
        }
        return nil
    }

    /// Apple Maps writes for the eye; a few of its shorthands need saying differently.
    static func spoken(_ instruction: String) -> String {
        guard !instruction.isEmpty else { return "Carry on" }
        return instruction
            .replacingOccurrences(of: " m ", with: " metres ")
            .replacingOccurrences(of: " km", with: " kilometres")
            .replacingOccurrences(of: "Rd", with: "Road")
            .replacingOccurrences(of: "St ", with: "Street ")
    }
}
