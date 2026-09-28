import CoreLocation
import Foundation
import Testing
@testable import PathOS

/// Counting the things you actually went to, without punishing you for the app being closed.
struct AttendanceTests {
    private let college = CLLocationCoordinate2D(latitude: 12.9412, longitude: 77.5652)

    private func away(_ metres: Double) -> CLLocationCoordinate2D {
        GeoMath.coordinate(college, metres: metres, bearing: 90)
    }

    @Test func oneLookSaysThereAwayOrNothing() {
        #expect(Attendance.sighting(at: away(50), of: college) == .there)
        #expect(Attendance.sighting(at: away(4_000), of: college) == .away)
        // On the edge of a big site, nothing is concluded either way.
        #expect(Attendance.sighting(at: away(500), of: college) == .unknown)
        // No fix, or nowhere to be: nothing is concluded either.
        #expect(Attendance.sighting(at: nil, of: college) == .unknown)
        #expect(Attendance.sighting(at: away(50), of: nil) == .unknown)
    }

    /// The rule the whole thing rests on: never seen either way means you went.
    @Test func silenceMeansYouWent() {
        #expect(Attendance.verdict(sawThere: false, sawAway: false, wasDropped: false) == .unknown)
        #expect(Attendance.count(["a", "b", "c"], missed: []) == 3)
    }

    @Test func seenElsewhereWhileItWasOnIsMissed() {
        #expect(Attendance.verdict(sawThere: false, sawAway: true, wasDropped: false) == .missed)
        #expect(Attendance.count(["a", "b", "c"], missed: ["b"]) == 2)
    }

    /// Having been there once outweighs having been seen away later: you went, then you left.
    @Test func havingBeenThereWins() {
        #expect(Attendance.verdict(sawThere: true, sawAway: true, wasDropped: false) == .attended)
        #expect(Attendance.verdict(sawThere: true, sawAway: false, wasDropped: true) == .attended)
    }

    /// Saying "Drop it" is evidence, even with no location at all.
    @Test func droppingItCounts() {
        #expect(Attendance.verdict(sawThere: false, sawAway: false, wasDropped: true) == .missed)
    }

    /// What's behind you counts; what's still to come doesn't yet. Marking something done while
    /// it's on counts it at once — before, the whole day counted from the morning, so marking one
    /// done changed nothing.
    @Test func finishedIsDoneOrOver() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let items: [(id: String, end: Date)] = [
            ("class:past", now.addingTimeInterval(-600)),
            ("class:now", now.addingTimeInterval(1_800)),
            ("class:later", now.addingTimeInterval(7_200)),
            ("event:missed", now.addingTimeInterval(-60)),
        ]
        #expect(Attendance.finished(items, done: [], missed: ["event:missed"], now: now) == 1)
        #expect(Attendance.finished(items, done: ["class:now"], missed: ["event:missed"], now: now) == 2)
        // A day that's over counts everything but what was missed.
        #expect(Attendance.finished(items, done: [], missed: ["event:missed"], now: now.addingTimeInterval(86_400)) == 3)
    }
}
