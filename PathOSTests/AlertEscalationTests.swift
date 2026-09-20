import Foundation
import Testing
@testable import PathOS

/// How hard an alert tries to reach you, given what PathOS last heard.
struct AlertEscalationTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func heard(_ scene: SoundScene, minutesAgo: Double) -> (scene: SoundScene, at: Date) {
        (scene, now.addingTimeInterval(-minutesAgo * 60))
    }

    /// In traffic, one buzz is easily missed, so an urgent alert says itself twice.
    @Test func urgentAlertsRepeatWhereItWasLoud() {
        let plan = AlertEscalation.plan(role: .attention, heardNoise: heard(.noisy, minutesAgo: 5), now: now)
        #expect(plan.isTimeSensitive)
        #expect(plan.repeatAfter == AlertEscalation.repeatAfter)
    }

    /// Somewhere quiet, once is enough — it still breaks through a Focus.
    @Test func quietPlacesAreToldOnce() {
        let plan = AlertEscalation.plan(role: .attention, heardNoise: heard(.quiet, minutesAgo: 5), now: now)
        #expect(plan.isTimeSensitive)
        #expect(plan.repeatAfter == nil)
        #expect(!plan.speaks)
    }

    /// Something PathOS heard hours ago says nothing about where you are now.
    @Test func whatItHeardLongAgoIsIgnored() {
        let stale = AlertEscalation.plan(role: .attention, heardNoise: heard(.noisy, minutesAgo: 180), now: now)
        #expect(stale.repeatAfter == nil)
        let never = AlertEscalation.plan(role: .attention, heardNoise: nil, now: now)
        #expect(never.repeatAfter == nil)
        #expect(never.isTimeSensitive)
    }

    /// Something critical repeats wherever you are, and waits longer where it was quiet.
    @Test func criticalAlwaysRepeats() {
        #expect(AlertEscalation.plan(role: .critical, heardNoise: nil, now: now).repeatAfter == AlertEscalation.repeatAfter)
        #expect(AlertEscalation.plan(role: .critical, heardNoise: heard(.quiet, minutesAgo: 1), now: now).repeatAfter
                == AlertEscalation.repeatAfterQuiet)
    }

    /// Turned off, nothing is said twice.
    @Test func repeatsCanBeTurnedOff() {
        let plan = AlertEscalation.plan(role: .critical, heardNoise: heard(.noisy, minutesAgo: 1), now: now, repeatsUrgent: false)
        #expect(plan.repeatAfter == nil)
        #expect(plan.isTimeSensitive)
    }

    /// The everyday ones stay quiet: a journey's progress isn't an interruption.
    @Test func ordinaryAlertsDontInterrupt() {
        for role in [SignalRole.you, .world] {
            let plan = AlertEscalation.plan(role: role, heardNoise: heard(.noisy, minutesAgo: 1), now: now)
            #expect(!plan.isTimeSensitive)
            #expect(plan.repeatAfter == nil)
            #expect(!plan.speaks)
        }
    }

    /// While a way is being followed with voice on, a loud place gets it spoken as well.
    @Test func itSpeaksWhileLeadingYouSomewhereLoud() {
        let loud = AlertEscalation.plan(role: .attention, heardNoise: heard(.noisy, minutesAgo: 2), now: now, isSpeaking: true)
        #expect(loud.speaks)
        let calm = AlertEscalation.plan(role: .attention, heardNoise: heard(.moderate, minutesAgo: 2), now: now, isSpeaking: true)
        #expect(!calm.speaks)
    }

    @Test func theNudgeHasItsOwnIdentifier() {
        #expect(AlertEscalation.repeatID(of: "pathos.alert.leave.now") == "pathos.alert.leave.now.again")
    }
}
