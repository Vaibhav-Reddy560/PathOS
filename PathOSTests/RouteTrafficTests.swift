import Foundation
import Testing
@testable import PathOS

@Suite("Traffic along the route")
struct RouteTrafficTests {

    /// Helper: a stretch measured now and at a quiet hour.
    private func measure(_ metres: Double, _ seconds: TimeInterval, freeFlow: TimeInterval?) -> RouteTraffic.Measure {
        RouteTraffic.Measure(metres: metres, seconds: seconds, freeFlowSeconds: freeFlow)
    }

    // MARK: What counts as traffic

    /// The fault this whole measure exists to fix. These are Apple Maps' real numbers for a
    /// kilometre of the residential grid around Jayanagar: 229 s now, 210 s at half three in the
    /// morning with nothing on the road at all. That is 16.5 km/h, which any speed threshold
    /// calls a jam — and it is an empty street with speed humps.
    @Test func anEmptyButSlowStreetIsNotTraffic() {
        #expect(RouteTraffic.severity(seconds: 229, freeFlow: 210) == 0)
        #expect(RouteTraffic.Flow(severity: RouteTraffic.severity(seconds: 229, freeFlow: 210)) == .clear)
    }

    /// And the same road's real numbers when it is held up: a main road that runs 3.7 km in
    /// 468 s on an empty night and takes 576 s now. Worth a colour, nowhere near the worst.
    @Test func aRealDelayShows() {
        let severity = RouteTraffic.severity(seconds: 576, freeFlow: 468)
        #expect(severity > 0)
        #expect(severity < RouteTraffic.Flow.heavyAbove)
        #expect(RouteTraffic.Flow(severity: severity) == .slow)
    }

    /// A motorway at half its usual speed is heavy even though 40 km/h beats the side street.
    @Test func halfSpeedOnAFastRoadIsHeavy() {
        let severity = RouteTraffic.severity(seconds: 1_200, freeFlow: 480)
        #expect(severity == 1)
        #expect(RouteTraffic.Flow(severity: severity) == .heavy)
    }

    @Test func nothingToCompareAgainstNeverAlarms() {
        #expect(RouteTraffic.severity(seconds: 600, freeFlow: nil) == 0)
        #expect(RouteTraffic.severity(seconds: 0, freeFlow: 100) == 0)
        #expect(RouteTraffic.severity(seconds: 100, freeFlow: 0) == 0)
    }

    @Test func fasterThanFreeFlowIsClear() {
        #expect(RouteTraffic.severity(seconds: 400, freeFlow: 468) == 0)
    }

    // MARK: Two stretches from one probe

    /// The headline case. A clear kilometre in front of a jam: over the whole of what's left the
    /// average says "slow", which is the answer that would send you into it. The residual says
    /// clear now, heavy after.
    @Test func aClearKilometreInFrontOfAJamReadsAsBoth() {
        // 10 km left in 40 min; free flow 20 min. The next km is clear: 90 s against 85 s.
        // So the rest is 9 km in 2_310 s against 1_115 s — stopped.
        let bands = RouteTraffic.bands(
            routeMetres: 10_000, travelledMetres: 0,
            probe: measure(1_000, 90, freeFlow: 85),
            remaining: measure(10_000, 2_400, freeFlow: 1_200)
        )
        #expect(bands.count == 2)
        #expect(bands[0].severity == 0)
        #expect(bands[0].flow == .clear)
        #expect(bands[1].flow == .heavy)
        // Whereas judging the whole remaining route at once would have called all of it one thing.
        #expect(RouteTraffic.Flow(severity: RouteTraffic.severity(seconds: 2_400, freeFlow: 1_200)) == .heavy)
    }

    /// And the other way round: the jam is the bit you're in, and it clears after.
    @Test func aJamInFrontOfAClearRoadReadsAsBoth() {
        let bands = RouteTraffic.bands(
            routeMetres: 8_000, travelledMetres: 0,
            probe: measure(1_000, 400, freeFlow: 120),
            remaining: measure(8_000, 1_060, freeFlow: 780)
        )
        #expect(bands.count == 2)
        #expect(bands[0].flow == .heavy)
        #expect(bands[1].severity == 0)
    }

    @Test func oneDegreeAllTheWayIsOneStretch() {
        let bands = RouteTraffic.bands(
            routeMetres: 5_000, travelledMetres: 500,
            probe: measure(1_000, 100, freeFlow: 95),
            remaining: measure(4_500, 450, freeFlow: 430)
        )
        #expect(bands.count == 1)
        #expect(bands[0].start == 0.1)
        #expect(bands[0].end == 1)
        #expect(bands[0].severity == 0)
    }

    @Test func theHeadIsWhereYouAre() {
        let bands = RouteTraffic.bands(
            routeMetres: 10_000, travelledMetres: 2_500,
            probe: measure(1_000, 300, freeFlow: 100),
            remaining: measure(7_500, 900, freeFlow: 700)
        )
        #expect(bands[0].start == 0.25)
        #expect(bands[0].end == 0.35)
        #expect(bands.last?.end == 1)
    }

    // MARK: When there's only one thing to say

    @Test func noProbeMeansOneStretch() {
        let bands = RouteTraffic.bands(routeMetres: 5_000, travelledMetres: 1_000,
                                       probe: nil, remaining: measure(4_000, 900, freeFlow: 500))
        #expect(bands.count == 1)
        #expect(bands[0].flow == .heavy)
    }

    @Test func tooLittleLeftAfterTheProbeMeansOneStretch() {
        let almostThere = RouteTraffic.bands(
            routeMetres: 5_000, travelledMetres: 3_900,
            probe: measure(1_000, 120, freeFlow: 100),
            remaining: measure(1_100, 140, freeFlow: 110)
        )
        #expect(almostThere.count == 1)
    }

    @Test func nonsenseIsSurvived() {
        let past = RouteTraffic.bands(routeMetres: 4_000, travelledMetres: 9_000,
                                      probe: nil, remaining: measure(0, 0, freeFlow: nil))
        #expect(past.allSatisfy { $0.start <= 1 && $0.end <= 1 })
        #expect(RouteTraffic.bands(routeMetres: 0, travelledMetres: 0, probe: nil,
                                   remaining: measure(0, 0, freeFlow: nil)).isEmpty)
    }

    // MARK: The quiet hour

    @Test func theQuietHourIsAlwaysTheNextOne() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: hour, minute: minute))!
        }
        // Asked at ten at night, it's tomorrow morning.
        let evening = RouteTraffic.quietHour(after: at(22, 0), calendar: calendar)
        #expect(calendar.component(.hour, from: evening) == 3)
        #expect(calendar.component(.minute, from: evening) == 30)
        #expect(calendar.component(.day, from: evening) == 28)
        // Asked at two in the morning, it's in ninety minutes.
        let night = RouteTraffic.quietHour(after: at(2, 0), calendar: calendar)
        #expect(calendar.component(.day, from: night) == 27)
        #expect(calendar.component(.hour, from: night) == 3)
    }

    @Test func theQuietHourIsNeverNowOrBehindUs() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let onIt = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 3, minute: 30))!
        #expect(RouteTraffic.quietHour(after: onIt, calendar: calendar) > onIt)
    }

    // MARK: The colours it turns into

    @Test func clearIsAuroraAndTheRestRunsAmberToCoral() {
        #expect(PathOSPalette.traffic(severity: 0) == PathOSPalette.aurora)
        #expect(PathOSPalette.traffic(severity: 0.001) == PathOSPalette.amber)
        #expect(PathOSPalette.traffic(severity: 1) == PathOSPalette.coral)
        // And in between, something that is neither but lies between the two on every channel.
        let middle = PathOSPalette.traffic(severity: 0.5)
        #expect(middle != PathOSPalette.amber)
        #expect(middle != PathOSPalette.coral)
        for shift in [UInt32(16), 8, 0] {
            let value = (middle >> shift) & 0xFF
            let low = min((PathOSPalette.amber >> shift) & 0xFF, (PathOSPalette.coral >> shift) & 0xFF)
            let high = max((PathOSPalette.amber >> shift) & 0xFF, (PathOSPalette.coral >> shift) & 0xFF)
            #expect(value >= low && value <= high)
        }
    }

    @Test func theWordsStillFollowThePalettesMeanings() {
        #expect(RouteTraffic.Flow.clear.role == .you)
        #expect(RouteTraffic.Flow.slow.role == .attention)
        #expect(RouteTraffic.Flow.heavy.role == .critical)
    }
}
