import CoreLocation
import Foundation
import Testing
@testable import PathOS

/// Where you are along a route's turns, and what the map should be saying.
struct StepGuideTests {
    /// Three straight steps heading north, each about 200 m: up, up, then the arrival.
    private func steps() -> [StepGuide.Step] {
        func north(_ from: Double, _ to: Double) -> [CLLocationCoordinate2D] {
            stride(from: from, through: to, by: (to - from) / 4).map {
                CLLocationCoordinate2D(latitude: $0, longitude: 77.6)
            }
        }
        return [
            StepGuide.Step(instruction: "Head north on 4th Main", coordinates: north(12.9000, 12.9018), distanceMeters: 200),
            StepGuide.Step(instruction: "Turn right onto Bull Temple Road", coordinates: north(12.9018, 12.9036), distanceMeters: 200),
            StepGuide.Step(instruction: "Arrive at Jayadeva Hospital", coordinates: north(12.9036, 12.9045), distanceMeters: 100),
        ]
    }

    @Test func itKnowsWhichTurnIsNext() {
        let start = CLLocationCoordinate2D(latitude: 12.9002, longitude: 77.6)
        let position = StepGuide.position(in: steps(), at: start)
        #expect(position?.stepIndex == 0)
        #expect(!(position?.isOffRoute ?? true))
        // About 180 m of the first step left, and the rest of the route after it.
        #expect(abs((position?.metresToStep ?? 0) - 178) < 25)
        #expect(abs((position?.metresRemaining ?? 0) - 478) < 30)
    }

    @Test func movingOnPicksUpTheNextStep() {
        let later = CLLocationCoordinate2D(latitude: 12.9025, longitude: 77.6)
        let position = StepGuide.position(in: steps(), at: later)
        #expect(position?.stepIndex == 1)
        #expect((position?.metresRemaining ?? 0) < 250)
    }

    /// Far from the route, it says so rather than pretending you're on it.
    @Test func itNoticesYoureNotOnTheRoute() {
        let away = CLLocationCoordinate2D(latitude: 12.9020, longitude: 77.6060)
        let position = StepGuide.position(in: steps(), at: away)
        #expect(position?.isOffRoute == true)
        #expect((position?.offRouteMetres ?? 0) > 500)
    }

    /// The sentence carries a distance you can act on, and drops it at the turn itself.
    @Test func itReadsLikeADirection() {
        let step = steps()[1]
        #expect(StepGuide.sentence(for: step, metresToStep: 212) == "In 200 m, turn right onto Bull Temple Road")
        #expect(StepGuide.sentence(for: step, metresToStep: 20) == "Turn right onto Bull Temple Road")
        #expect(StepGuide.rounded(212) == 200)
        #expect(StepGuide.rounded(1_240) == 1_200)
    }

    @Test func aRouteWithNoStepsGivesNothing() {
        #expect(StepGuide.position(in: [], at: CLLocationCoordinate2D(latitude: 12.9, longitude: 77.6)) == nil)
    }

    /// Standing still with no compass, the road ahead still points somewhere: that's what turns
    /// the map while you wait at the kerb for an auto.
    @Test func theRoadAheadGivesAHeading() {
        let route = steps().flatMap(\.coordinates)
        let heading = StepGuide.heading(along: route, at: CLLocationCoordinate2D(latitude: 12.9005, longitude: 77.6))
        // Due north, give or take.
        #expect(abs((heading ?? -1) - 0) < 5 || abs((heading ?? -1) - 360) < 5)
        #expect(StepGuide.heading(along: [], at: CLLocationCoordinate2D(latitude: 12.9, longitude: 77.6)) == nil)
    }

    /// The turn is drawn from Apple Maps' own wording, since it gives no code for the manoeuvre.
    @Test func theTurnIsDrawnFromItsWording() {
        #expect(StepGuide.symbol(for: "Turn right onto Bull Temple Road") == "arrow.turn.up.right")
        #expect(StepGuide.symbol(for: "Turn left onto 3rd Main Road") == "arrow.turn.up.left")
        #expect(StepGuide.symbol(for: "Keep left at the fork") == "arrow.up.left")
        #expect(StepGuide.symbol(for: "Make a U-turn") == "arrow.uturn.down")
        #expect(StepGuide.symbol(for: "Arrive at BMS College") == "mappin.and.ellipse")
        #expect(StepGuide.symbol(for: "Continue on South End Road") == "arrow.up")
    }
}
