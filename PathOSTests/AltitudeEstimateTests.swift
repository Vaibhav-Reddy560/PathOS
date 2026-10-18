import Foundation
import Testing
@testable import PathOS

/// How high you are: the steady middle of what the phone is sure of, and how sure that is.
struct AltitudeEstimateTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func sample(_ metres: Double, _ accuracy: Double, secondsAgo: Double = 0) -> AltitudeEstimate.Sample {
        .init(metres: metres, accuracy: accuracy, at: now.addingTimeInterval(-secondsAgo))
    }

    /// A barometer good to 6 m isn't pulled about by GPS 30 m out, or by one wild reading.
    @Test func theSharpestReadingsLead() throws {
        let samples = [sample(905, 6, secondsAgo: 20), sample(907, 6, secondsAgo: 10), sample(960, 30), sample(906, 6)]
        let best = try #require(AltitudeEstimate.best(samples, now: now))
        #expect(best.metres == 906)
        #expect(best.accuracy == 6)
        #expect(best.isSettled)
    }

    /// Unsure readings are said to be settling; hopeless ones aren't shown at all.
    @Test func itSaysHowSureItIs() {
        #expect(AltitudeEstimate.best([sample(912, 28)], now: now)?.isSettled == false)
        #expect(AltitudeEstimate.best([sample(912, 55)], now: now) == nil)
    }

    /// Only the last minute counts.
    @Test func oldReadingsAreLetGo() {
        let kept = AltitudeEstimate.adding(sample(900, 5), to: [sample(880, 5, secondsAgo: 90), sample(901, 5, secondsAgo: 30)])
        #expect(kept.map(\.metres) == [901, 900])
    }
}
