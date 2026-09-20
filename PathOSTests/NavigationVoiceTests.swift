import CoreLocation
import Foundation
import Testing
@testable import PathOS

/// What's said aloud while you drive: each turn once, early enough to act on, and again at it.
struct NavigationVoiceTests {
    private let step = StepGuide.Step(
        instruction: "Turn right onto Bull Temple Road",
        coordinates: [CLLocationCoordinate2D(latitude: 12.9, longitude: 77.6),
                      CLLocationCoordinate2D(latitude: 12.902, longitude: 77.6)],
        distanceMeters: 220
    )

    private func announcement(metres: Double, said: Set<NavigationVoice.Moment> = [],
                              isBehind: Bool = false, legIndex: Int = 0) -> NavigationVoice.Announcement? {
        NavigationVoice.announcement(
            step: step, stepIndex: 2, metresToStep: metres,
            legIndex: legIndex, legInstruction: "Take an auto to Jayadeva Hospital",
            isBehind: isBehind, minutesBehind: 9,
            hasSaidLeg: said.contains(.handover(leg: legIndex)), said: said
        )
    }

    /// Far out, nothing. Coming up, the warning. At the turn, the turn.
    @Test func eachTurnIsSaidTwiceAtMost() {
        #expect(announcement(metres: 800) == nil)

        let warning = announcement(metres: 280)
        #expect(warning?.moment == .approaching(step: 2))
        #expect(warning?.text == "In 300 metres, turn right onto Bull Temple Road")

        let atTurn = announcement(metres: 30, said: [.approaching(step: 2)])
        #expect(atTurn?.moment == .turning(step: 2))
        #expect(atTurn?.text == "Turn right onto Bull Temple Road")
    }

    /// Nothing is ever said twice.
    @Test func nothingRepeats() {
        #expect(announcement(metres: 280, said: [.approaching(step: 2)]) == nil)
        #expect(announcement(metres: 30, said: [.approaching(step: 2), .turning(step: 2)]) == nil)
    }

    /// Past the turn's warning distance, the warning is skipped rather than said late.
    @Test func aTurnReachedQuicklySkipsTheWarning() {
        let atTurn = announcement(metres: 20)
        #expect(atTurn?.moment == .turning(step: 2))
        #expect(announcement(metres: 280, said: [.turning(step: 2)]) == nil)
    }

    /// Reaching the station is said before anything about the next leg's turns.
    @Test func theHandoverComesFirst() {
        let handover = announcement(metres: 100, legIndex: 1)
        #expect(handover?.moment == .handover(leg: 1))
        #expect(handover?.text == "Take an auto to Jayadeva Hospital")
    }

    /// Running behind is mentioned once per leg, and only when there's no turn to call.
    @Test func lateIsSaidOncePerLeg() {
        let late = announcement(metres: 900, isBehind: true)
        #expect(late?.moment == .behind(leg: 0))
        #expect(late?.text == "You're about 9 minutes behind.")
        #expect(announcement(metres: 900, said: [.behind(leg: 0)], isBehind: true) == nil)
    }

    /// Written for the eye, said for the ear.
    @Test func abbreviationsAreSpokenOut() {
        #expect(NavigationVoice.spoken("Turn left onto Old Airport Rd") == "Turn left onto Old Airport Road")
        #expect(NavigationVoice.spoken("") == "Carry on")
    }
}
