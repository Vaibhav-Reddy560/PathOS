import CoreLocation
import Foundation
import Testing
@testable import PathOS

@Suite("Traffic along the route")
struct RouteTrafficTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func reading(_ seconds: TimeInterval, freeFlow: TimeInterval) -> RouteTraffic.Reading {
        RouteTraffic.Reading(seconds: seconds, measuredAt: now, freeFlowSeconds: freeFlow)
    }

    // MARK: What counts as traffic

    /// Apple Maps' real numbers for a kilometre of the residential grid around Jayanagar: 229 s
    /// now, 210 s at half three in the morning with nothing on the road at all. That is 16.5 km/h,
    /// which any speed threshold calls a jam — and it is an empty street with speed humps.
    @Test func anEmptyButSlowStreetIsNotTraffic() {
        #expect(RouteTraffic.severity(seconds: 229, freeFlow: 210) == 0)
    }

    /// A main road that runs 3.7 km in 468 s on an empty night and takes 576 s at a quarter to
    /// eleven. Four-fifths of its empty speed: moving, as every map would draw it.
    @Test func aRoadAtFourFifthsOfItsSpeedIsStillMoving() {
        #expect(RouteTraffic.severity(seconds: 576, freeFlow: 468) == 0)
    }

    @Test func realDelaysRunUpTheScale() {
        let slowish = RouteTraffic.severity(seconds: 700, freeFlow: 468)
        let bad = RouteTraffic.severity(seconds: 850, freeFlow: 468)
        #expect(slowish > 0)
        #expect(bad > slowish)
        #expect(RouteTraffic.Flow(severity: slowish) == .slow)
    }

    /// Half its usual speed is as bad as the colour goes, however fast the road usually is.
    @Test func halfSpeedIsTheTopOfTheScale() {
        #expect(RouteTraffic.severity(seconds: 960, freeFlow: 480) == 1)
        #expect(RouteTraffic.severity(seconds: 3_000, freeFlow: 480) == 1)
        #expect(RouteTraffic.Flow(severity: 1) == .heavy)
    }

    @Test func nothingToCompareAgainstNeverAlarms() {
        #expect(RouteTraffic.severity(seconds: 600, freeFlow: nil) == 0)
        #expect(RouteTraffic.severity(seconds: 0, freeFlow: 100) == 0)
        #expect(RouteTraffic.severity(seconds: 100, freeFlow: 0) == 0)
        #expect(RouteTraffic.severity(seconds: 400, freeFlow: 468) == 0)
    }

    // MARK: Cutting the route

    @Test func aRouteIsCutIntoEqualPiecesThatCoverIt() {
        let pieces = RouteTraffic.pieces(routeMetres: 8_100)
        #expect(pieces.count == RouteTraffic.pieceLimit)
        #expect(pieces.first?.startMetres == 0)
        #expect(abs((pieces.last?.endMetres ?? 0) - 8_100) < 0.001)
        for (a, b) in zip(pieces, pieces.dropFirst()) {
            #expect(a.endMetres == b.startMetres)
        }
    }

    @Test func piecesAreNeverTooShortNorTooMany() {
        #expect(RouteTraffic.pieces(routeMetres: 490).count == 1)
        #expect(RouteTraffic.pieces(routeMetres: 2_000).count == 4)
        #expect(RouteTraffic.pieces(routeMetres: 40_000).count == RouteTraffic.pieceLimit)
        #expect(RouteTraffic.pieces(routeMetres: 2_000).allSatisfy { $0.metres >= RouteTraffic.shortestPiece })
        #expect(RouteTraffic.pieces(routeMetres: 0).isEmpty)
    }

    // MARK: The fault that started this

    /// A long route through a jam and a short one down the same lanes, at the same moment. Before,
    /// the long one averaged the jam over its whole length and drew every piece orange — the empty
    /// lanes included — while the short one drew green. Measured piece by piece, the lanes are the
    /// same colour on both, and only the jammed piece is anything else.
    @Test func theSameLaneIsTheSameColourOnEveryRoute() {
        let lane = reading(229, freeFlow: 210)
        let jam = reading(1_100, freeFlow: 480)
        let long = RouteTraffic.severities([0: lane, 1: lane, 2: jam, 3: lane], count: 4)
        let short = RouteTraffic.severities([0: lane], count: 1)
        #expect(long[0] == short[0])
        #expect(long[0] == 0)
        #expect(long[1] == 0)
        #expect(long[2] == 1)
        #expect(long[3] == 0)
    }

    // MARK: Pieces not yet known

    @Test func aGapTakesTheMilderOfItsNeighbours() {
        let heavy = reading(1_000, freeFlow: 480)
        let slow = reading(700, freeFlow: 480)
        let severities = RouteTraffic.severities([0: heavy, 2: slow], count: 3)
        #expect(severities[1] == severities[2])
        #expect(severities[1] < severities[0])
    }

    /// Before anything is measured, and past the last thing measured, the line is aurora — what
    /// it was before PathOS knew anything.
    @Test func whatIsntKnownYetIsDrawnAsFlowing() {
        #expect(RouteTraffic.severities([:], count: 4) == [0, 0, 0, 0])
        let severities = RouteTraffic.severities([0: reading(1_000, freeFlow: 480)], count: 3)
        #expect(severities == [1, 0, 0])
    }

    @Test func anUnmeasurablePieceIsAGap() {
        var odd = reading(2_000, freeFlow: 100)
        odd.isUnmeasurable = true
        #expect(odd.severity == nil)
        let lane = reading(229, freeFlow: 210)
        #expect(RouteTraffic.severities([0: lane, 1: odd, 2: lane], count: 3) == [0, 0, 0])
    }

    // MARK: What to ask next

    @Test func theNearestPieceIsAskedFirstAndBothWays() {
        let pieces = RouteTraffic.pieces(routeMetres: 6_000)
        let asks = RouteTraffic.due(pieces, readings: [:], travelledMetres: 0, now: now)
        #expect(asks.count == RouteTraffic.batchSize)
        #expect(asks.first == .init(piece: 0, ask: .freeFlow))
        #expect(asks.contains(.init(piece: 0, ask: .now)))
        #expect(asks.allSatisfy { $0.piece <= 1 })
    }

    @Test func piecesBehindYouAreLeftAlone() {
        let pieces = RouteTraffic.pieces(routeMetres: 6_000)
        let asks = RouteTraffic.due(pieces, readings: [:], travelledMetres: 2_100, now: now)
        #expect(asks.allSatisfy { pieces[$0.piece].endMetres > 2_100 })
    }

    @Test func freeFlowIsAskedOnceAndLiveTimesWhenStale() {
        let pieces = RouteTraffic.pieces(routeMetres: 900)
        #expect(pieces.count == 1)
        let fresh = [0: reading(100, freeFlow: 90)]
        #expect(RouteTraffic.due(pieces, readings: fresh, travelledMetres: 0, now: now).isEmpty)
        let later = now.addingTimeInterval(RouteTraffic.freshNear + 1)
        #expect(RouteTraffic.due(pieces, readings: fresh, travelledMetres: 0, now: later) == [.init(piece: 0, ask: .now)])
    }

    @Test func farPiecesAreKeptFreshLessOften() {
        let pieces = RouteTraffic.pieces(routeMetres: 12_000)
        var readings: [Int: RouteTraffic.Reading] = [:]
        for index in pieces.indices { readings[index] = reading(100, freeFlow: 90) }
        let asks = RouteTraffic.due(pieces, readings: readings, travelledMetres: 0,
                                    now: now.addingTimeInterval(RouteTraffic.freshNear + 1), limit: 99)
        #expect(!asks.isEmpty)
        #expect(asks.allSatisfy { pieces[$0.piece].startMetres < RouteTraffic.nearMetres })
    }

    // MARK: Folding in answers

    @Test func anAnswerForADifferentRoadIsNeverUsed() {
        let piece = RouteTraffic.Piece(startMetres: 0, endMetres: 700)
        let detour = RouteTraffic.record((seconds: 300, metres: 1_600), for: .now, on: piece, into: .init(), at: now)
        #expect(detour.isUnmeasurable)
        #expect(detour.seconds == nil)
        let right = RouteTraffic.record((seconds: 120, metres: 720), for: .now, on: piece, into: .init(), at: now)
        #expect(!right.isUnmeasurable)
        #expect(right.seconds == 120)
    }

    @Test func noAnswerIsWaitedOut() {
        let piece = RouteTraffic.Piece(startMetres: 0, endMetres: 700)
        let live = RouteTraffic.record(nil, for: .now, on: piece, into: .init(), at: now)
        #expect(live.measuredAt == now)
        #expect(!live.isUnmeasurable)
        var free = RouteTraffic.record(nil, for: .freeFlow, on: piece, into: .init(), at: now)
        #expect(!free.isUnmeasurable)
        free = RouteTraffic.record(nil, for: .freeFlow, on: piece, into: free, at: now)
        #expect(free.isUnmeasurable)
    }

    // MARK: The quiet hour

    @Test func theQuietHourIsAlwaysTheNextOne() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: hour, minute: minute))!
        }
        let evening = RouteTraffic.quietHour(after: at(22, 0), calendar: calendar)
        #expect(calendar.component(.hour, from: evening) == 3)
        #expect(calendar.component(.minute, from: evening) == 30)
        #expect(calendar.component(.day, from: evening) == 28)
        let night = RouteTraffic.quietHour(after: at(2, 0), calendar: calendar)
        #expect(calendar.component(.day, from: night) == 27)
        #expect(RouteTraffic.quietHour(after: at(3, 30), calendar: calendar) > at(3, 30))
    }

    // MARK: The colours it turns into

    @Test func clearIsAuroraAndTheRestRunsAmberToCoral() {
        #expect(PathOSPalette.traffic(severity: 0) == PathOSPalette.aurora)
        #expect(PathOSPalette.traffic(severity: 0.001) == PathOSPalette.amber)
        #expect(PathOSPalette.traffic(severity: 1) == PathOSPalette.coral)
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

@Suite("Cutting a route into pieces")
struct RouteSliceTests {
    /// Three points a kilometre apart, due east along the equator-ish latitude of Bengaluru.
    private let route: [CLLocationCoordinate2D] = {
        let start = CLLocationCoordinate2D(latitude: 12.93, longitude: 77.58)
        return [start, GeoMath.coordinate(start, metres: 1_000, bearing: 90),
                GeoMath.coordinate(start, metres: 2_000, bearing: 90)]
    }()

    @Test func lengthIsTheSumOfTheSegments() {
        // The fixture is laid out by a flat step and measured on the sphere: a tenth of a per cent.
        #expect(abs(RouteProgress.length(route) - 2_000) < 10)
        #expect(RouteProgress.length([]) == 0)
    }

    @Test func aSliceIsCutExactlyAtItsEnds() {
        let slice = RouteProgress.slice(route, from: 500, to: 1_500)
        #expect(slice.count == 3)
        #expect(abs(RouteProgress.length(slice) - 1_000) < 2)
        #expect(abs(GeoMath.distance(from: route[0], to: slice[0]) - 500) < 2)
        // The corner it passes through is kept.
        #expect(GeoMath.distance(from: slice[1], to: route[1]) < 0.01)
    }

    @Test func piecesPutBackTogetherAreTheRoute() {
        let total = RouteProgress.length(route)
        let pieces = RouteTraffic.pieces(routeMetres: total)
        let lengths = pieces.map { RouteProgress.length(RouteProgress.slice(route, from: $0.startMetres, to: $0.endMetres)) }
        #expect(abs(lengths.reduce(0, +) - total) < 1)
    }

    @Test func aSliceWithinOneSegmentHasTwoPoints() {
        let slice = RouteProgress.slice(route, from: 100, to: 400)
        #expect(slice.count == 2)
        #expect(abs(RouteProgress.length(slice) - 300) < 1)
    }

    @Test func nonsenseGivesNothing() {
        #expect(RouteProgress.slice(route, from: 800, to: 800).isEmpty)
        #expect(RouteProgress.slice(route, from: 900, to: 100).isEmpty)
        #expect(RouteProgress.slice([route[0]], from: 0, to: 100).isEmpty)
    }
}
