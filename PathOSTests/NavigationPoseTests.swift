import CoreLocation
import Foundation
import Testing
@testable import PathOS

@Suite("Where you're drawn while being led")
struct NavigationPoseTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let start = CLLocationCoordinate2D(latitude: 12.93, longitude: 77.58)

    /// 500 m east, then 500 m north: a right angle, like any city corner.
    private var corner: NavigationPose.Line {
        let turn = GeoMath.coordinate(start, metres: 500, bearing: 90)
        return NavigationPose.Line([start, turn, GeoMath.coordinate(turn, metres: 500, bearing: 0)])
    }

    private func fix(travelled: Double?, offset: Double?, speed: Double = 10, course: Double? = 90,
                     at: Date? = nil, coordinate: CLLocationCoordinate2D? = nil) -> NavigationPose.Fix {
        NavigationPose.Fix(coordinate: coordinate ?? start, course: course, speed: speed, at: at ?? now,
                           travelled: travelled, offset: offset)
    }

    private func angle(_ a: Double, _ b: Double) -> Double {
        abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    // MARK: On the line

    /// GPS put you 8 m to the side; you're drawn on the route, where you are along it.
    @Test func onTheRouteYoureDrawnOnIt() throws {
        let line = corner
        let pose = NavigationPose.pose(fix(travelled: 200, offset: 8, speed: 0), on: line,
                                       lastAlong: nil, lastHeading: 0, now: now)
        #expect(pose.along == 200)
        let onLine = try #require(line.point(at: 200)).coordinate
        #expect(GeoMath.distance(from: pose.coordinate, to: onLine) < 0.01)
    }

    /// Between fixes you're carried on at the speed you were doing — never more than a second
    /// and a half's worth.
    @Test func betweenFixesYouKeepMoving() {
        let line = corner
        let half = NavigationPose.pose(fix(travelled: 200, offset: 2), on: line, lastAlong: nil, lastHeading: 0,
                                       now: now.addingTimeInterval(0.5))
        #expect(abs((half.along ?? 0) - 205) < 0.001)
        let stale = NavigationPose.pose(fix(travelled: 200, offset: 2), on: line, lastAlong: nil, lastHeading: 0,
                                        now: now.addingTimeInterval(20))
        #expect(abs((stale.along ?? 0) - (200 + 10 * NavigationPose.maxLead)) < 0.001)
    }

    /// Carried a little too far, the next fix says you're behind that: you hold still until it
    /// catches up rather than sliding backwards. A big correction is believed.
    @Test func smallCorrectionsHoldBigOnesJump() {
        let line = corner
        let held = NavigationPose.pose(fix(travelled: 210, offset: 2, speed: 0), on: line, lastAlong: 214,
                                       lastHeading: 90, now: now)
        #expect(held.along == 214)
        let jumped = NavigationPose.pose(fix(travelled: 150, offset: 2, speed: 0), on: line, lastAlong: 214,
                                         lastHeading: 90, now: now)
        #expect(jumped.along == 150)
    }

    /// The way you're going is the road's, a few metres ahead: east along the first street, and
    /// already turning north as the corner arrives.
    @Test func theHeadingIsTheRoads() {
        let line = corner
        let street = NavigationPose.pose(fix(travelled: 200, offset: 2, speed: 0, course: 120), on: line,
                                         lastAlong: nil, lastHeading: 0, now: now)
        #expect(angle(street.heading, 90) < 1)
        let atCorner = NavigationPose.pose(fix(travelled: 495, offset: 2, speed: 0), on: line,
                                           lastAlong: nil, lastHeading: 0, now: now)
        #expect(angle(atCorner.heading, 90) > 10)
        let round = NavigationPose.pose(fix(travelled: 600, offset: 2, speed: 0), on: line,
                                        lastAlong: nil, lastHeading: 0, now: now)
        #expect(angle(round.heading, 0) < 1)
    }

    // MARK: Off the line

    /// Too far off to be on it: where GPS says, carried the way it's going.
    @Test func offTheRouteItsWhereGPSSays() {
        let off = GeoMath.coordinate(start, metres: 100, bearing: 180)
        let pose = NavigationPose.pose(fix(travelled: 0, offset: 100, speed: 10, course: 180, coordinate: off),
                                       on: corner, lastAlong: 40, lastHeading: 90, now: now.addingTimeInterval(1))
        #expect(pose.along == nil)
        #expect(abs(GeoMath.distance(from: pose.coordinate, to: off) - 10) < 0.5)
        #expect(angle(pose.heading, 180) < 0.001)
    }

    /// Standing still, the way you were facing is kept — GPS has no course when you're not moving.
    @Test func standingStillKeepsTheHeading() {
        let pose = NavigationPose.pose(fix(travelled: nil, offset: nil, speed: 0, course: nil),
                                       on: nil, lastAlong: nil, lastHeading: 37, now: now)
        #expect(pose.heading == 37)
    }

    // MARK: Turning

    @Test func turningTakesTheShortWayRound() {
        // From 350° to 10° is twenty degrees clockwise, not three hundred and forty back.
        let turned = NavigationPose.turn(from: 350, toward: 10, dt: 10, timeConstant: 0.35)
        #expect(angle(turned, 10) < 0.01)
        let partway = NavigationPose.turn(from: 350, toward: 10, dt: 0.1, timeConstant: 0.35)
        #expect(angle(partway, 350) < 20)
        #expect(angle(partway, 10) < 20)
        #expect(partway > 350 || partway < 10)
    }

    @Test func aLineKnowsItsLength() {
        #expect(abs(corner.total - 1_000) < 5)
        #expect(NavigationPose.Line([]).total == 0)
        #expect(corner.point(at: -10)?.coordinate.latitude == start.latitude)
    }
}

@Suite("Your pace against Apple Maps'")
struct TripPaceTests {
    private let route = UUID()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// Driven at Apple Maps' pace, what's left comes down a minute a minute: nothing changes.
    @Test func atItsPaceNothingChanges() {
        var pace = TripPace()
        for minute in 0...12 {
            pace.record(remaining: Double(1_800 - minute * 60), at: start.addingTimeInterval(Double(minute) * 60), routeID: route)
        }
        #expect(abs(pace.factor - 1) < 0.001)
    }

    /// A quicker driver: what's left comes down 72 s every minute. After ten minutes of it, the
    /// time left is believed to be a sixth shorter.
    @Test func aQuickerDriverArrivesSooner() {
        var pace = TripPace()
        for minute in 0...12 {
            pace.record(remaining: Double(2_400 - minute * 72), at: start.addingTimeInterval(Double(minute) * 60), routeID: route)
        }
        #expect(pace.factor < 0.86)
        #expect(pace.factor >= 1 - TripPace.limit)
    }

    /// Two minutes in, it's only partly believed.
    @Test func earlyOnItsOnlyPartlyBelieved() {
        var pace = TripPace()
        for minute in 0...2 {
            pace.record(remaining: Double(2_400 - minute * 72), at: start.addingTimeInterval(Double(minute) * 60), routeID: route)
        }
        #expect(pace.factor < 1)
        #expect(pace.factor > 0.95)
    }

    /// A re-route is a different road: its first estimate isn't compared with the old one's.
    @Test func aReRouteStartsAfresh() {
        var pace = TripPace()
        pace.record(remaining: 1_800, at: start, routeID: route)
        pace.record(remaining: 600, at: start.addingTimeInterval(60), routeID: UUID())
        #expect(pace.factor == 1)
    }

    /// Stuck at a light, or traffic ahead clearing: not the driver's doing, and not counted.
    @Test func jumpsAndStandstillsArentPace() {
        var pace = TripPace()
        pace.record(remaining: 1_800, at: start, routeID: route)
        pace.record(remaining: 1_810, at: start.addingTimeInterval(60), routeID: route)
        pace.record(remaining: 900, at: start.addingTimeInterval(120), routeID: route)
        #expect(pace.factor == 1)
    }

    @Test func neverBeyondTheLimit() {
        var pace = TripPace()
        for minute in 0...30 {
            pace.record(remaining: Double(9_000 - minute * 170), at: start.addingTimeInterval(Double(minute) * 60), routeID: route)
        }
        #expect(abs(pace.factor - (1 - TripPace.limit)) < 0.001)
    }
}
