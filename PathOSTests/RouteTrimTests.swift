import Foundation
import Testing
@testable import PathOS

/// Drawing the head of the route line between fixes, so it keeps up with a puck MapKit is moving
/// smoothly rather than trailing behind it and snapping.
struct RouteTrimTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A 7 km leg, a third of the way along, at 50 km/h.
    private func anchor(fraction: Double = 1.0 / 3, speed: Double = 14, metres: Double = 7_000) -> RouteTrim.Anchor {
        RouteTrim.Anchor(fraction: fraction, at: now, metresPerSecond: speed, routeMetres: metres)
    }

    /// Stopped at a light: the head stays exactly where the last fix put it.
    @Test func stoppedItStaysPut() {
        let still = anchor(speed: 0)
        #expect(RouteTrim.shown(still, lastShown: still.fraction, sinceFix: 1) == still.fraction)
    }

    /// Moving, it runs on at the speed you were doing: 14 m of a 7 km route in a second.
    @Test func movingItRunsOn() {
        let shown = RouteTrim.shown(anchor(), lastShown: 1.0 / 3, sinceFix: 1)
        #expect(abs(shown - (1.0 / 3 + 14.0 / 7_000)) < 1e-9)
    }

    /// A fix that never comes can't draw more than a second and a half of guesswork.
    @Test func aLostFixIsNotGuessedPast() {
        let capped = RouteTrim.shown(anchor(), lastShown: 1.0 / 3, sinceFix: 30)
        let limit = RouteTrim.shown(anchor(), lastShown: 1.0 / 3, sinceFix: RouteTrim.maxLead)
        #expect(capped == limit)
        // 1.5 s at 14 m/s is 21 m, and no more.
        #expect(abs(capped - (1.0 / 3 + 21.0 / 7_000)) < 1e-9)
    }

    /// The next fix says you're a few metres short of where the head was drawn. It waits there
    /// rather than sliding backwards under the puck.
    @Test func aSmallCorrectionHoldsRatherThanRetreating() {
        let drawn = 1.0 / 3 + 20.0 / 7_000
        let behind = anchor(fraction: 1.0 / 3 + 5.0 / 7_000)
        #expect(RouteTrim.shown(behind, lastShown: drawn, sinceFix: 0) == drawn)
    }

    /// A new route starts you near its beginning: that is a jump, not a correction, so it follows.
    @Test func aNewRouteSnapsBack() {
        let fresh = anchor(fraction: 0.01)
        #expect(RouteTrim.shown(fresh, lastShown: 0.62, sinceFix: 0) == 0.01)
    }

    @Test func itNeverReachesTheVeryEnd() {
        let nearlyThere = anchor(fraction: 0.999, speed: 30)
        #expect(RouteTrim.shown(nearlyThere, lastShown: 0.999, sinceFix: 1) == 0.999)
    }

    @Test func aRouteOfNoLengthDrawsNothing() {
        #expect(RouteTrim.shown(anchor(metres: 0), lastShown: 0.5, sinceFix: 1) == 0)
    }
}
