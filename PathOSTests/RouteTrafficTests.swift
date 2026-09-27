import Foundation
import Testing
@testable import PathOS

/// Splitting the road ahead into stretches by how fast it's actually moving.
struct RouteTrafficTests {

    @Test func speedDecidesTheColour() {
        // 1 km in 100 s is 36 km/h; in 180 s, 20 km/h; in 300 s, 12 km/h.
        #expect(RouteTraffic.flow(metres: 1_000, seconds: 100) == .clear)
        #expect(RouteTraffic.flow(metres: 1_000, seconds: 180) == .slow)
        #expect(RouteTraffic.flow(metres: 1_000, seconds: 300) == .heavy)
        // Exactly on the thresholds, and the kinder side wins.
        #expect(RouteTraffic.flow(metres: 30_000, seconds: 3_600) == .clear)
        #expect(RouteTraffic.flow(metres: 15_000, seconds: 3_600) == .slow)
        // Nothing known says nothing alarming.
        #expect(RouteTraffic.flow(metres: 0, seconds: 0) == .clear)
    }

    /// The case the whole thing exists for: a clear kilometre, then a jam. Averaged over what's
    /// left it reads "slow", which is the answer that would drive you into it.
    @Test func aClearKilometreInFrontOfAJam() throws {
        // 3 km left in 600 s: the first km in 60 s (60 km/h), so the other 2 km take 540 s (13 km/h).
        let bands = RouteTraffic.bands(routeMetres: 10_000, travelledMetres: 7_000,
                                       probeMetres: 1_000, probeSeconds: 60,
                                       remainingMetres: 3_000, remainingSeconds: 600)
        #expect(bands.map(\.flow) == [.clear, .heavy])
        #expect(abs(bands[0].start - 0.7) < 1e-9)
        #expect(abs(bands[0].end - 0.8) < 1e-9)
        #expect(bands[1].end == 1)
        // Taking the whole remaining route instead would have said "slow" — 18 km/h.
        #expect(RouteTraffic.flow(metres: 3_000, seconds: 600) == .slow)
    }

    /// A jam right in front of a clear run: the other way round.
    @Test func aJamInFrontOfAClearRun() {
        let bands = RouteTraffic.bands(routeMetres: 8_000, travelledMetres: 0,
                                       probeMetres: 1_000, probeSeconds: 400,
                                       remainingMetres: 8_000, remainingSeconds: 1_000)
        #expect(bands.map(\.flow) == [.heavy, .clear])
    }

    /// Both stretches moving the same way is one line, not two.
    @Test func oneFlowIsOneBand() {
        let bands = RouteTraffic.bands(routeMetres: 5_000, travelledMetres: 500,
                                       probeMetres: 1_000, probeSeconds: 60,
                                       remainingMetres: 4_500, remainingSeconds: 270)
        #expect(bands.count == 1)
        #expect(bands[0].flow == .clear)
        #expect(abs(bands[0].start - 0.1) < 1e-9)
        #expect(bands[0].end == 1)
    }

    /// No probe, or nothing much left after it: the whole of what remains is one stretch.
    @Test func withoutAProbeThereIsOneStretch() {
        let none = RouteTraffic.bands(routeMetres: 5_000, travelledMetres: 1_000,
                                      probeMetres: nil, probeSeconds: nil,
                                      remainingMetres: 4_000, remainingSeconds: 800)
        #expect(none.count == 1)
        #expect(none[0].flow == .slow)

        // The probe covers all but 100 m of what's left.
        let almostThere = RouteTraffic.bands(routeMetres: 5_000, travelledMetres: 3_900,
                                             probeMetres: 1_000, probeSeconds: 60,
                                             remainingMetres: 1_100, remainingSeconds: 70)
        #expect(almostThere.count == 1)
    }

    @Test func bandsStayInOrderAndInRange() {
        let bands = RouteTraffic.bands(routeMetres: 4_000, travelledMetres: 9_000,
                                       probeMetres: 1_000, probeSeconds: 300,
                                       remainingMetres: 3_000, remainingSeconds: 400)
        #expect(bands.allSatisfy { $0.start >= 0 && $0.end <= 1 && $0.start <= $0.end })
        #expect(RouteTraffic.bands(routeMetres: 0, travelledMetres: 0, probeMetres: nil, probeSeconds: nil,
                                   remainingMetres: 0, remainingSeconds: 0).isEmpty)
    }

    /// Each flow carries a role, so the line is never given a raw colour.
    @Test func eachFlowHasItsRole() {
        #expect(RouteTraffic.Flow.clear.role == .you)
        #expect(RouteTraffic.Flow.slow.role == .attention)
        #expect(RouteTraffic.Flow.heavy.role == .critical)
    }
}
