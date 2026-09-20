import Foundation
import Testing
@testable import PathOS

/// The direction you're travelling, steady enough to turn a map by.
struct TravelCourseTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// Angles average around the circle: north-by-a-hair either side is still north.
    @Test func headingsAverageAroundTheCircle() {
        #expect(abs((TravelCourse.mean(of: [350, 10]) ?? -1) - 0) < 0.001)
        #expect(abs((TravelCourse.mean(of: [80, 100]) ?? -1) - 90) < 0.001)
        #expect(TravelCourse.mean(of: []) == nil)
    }

    /// Driving: each fix is taken, averaged with the last few.
    @Test func drivingGivesACourse() {
        var reading = TravelCourse.Reading(degrees: nil, at: .distantPast)
        for (index, course) in [88.0, 92.0, 90.0].enumerated() {
            reading = TravelCourse.update(reading, course: course, accuracy: 5, speed: 8,
                                          at: start.addingTimeInterval(Double(index)))
        }
        #expect(abs((reading.degrees ?? -1) - 90) < 1)
    }

    /// A red light must not throw the map back to north: the last course is held for a few
    /// seconds, and only then admitted to be unknown.
    @Test func aStopHoldsTheLastCourse() {
        var reading = TravelCourse.update(TravelCourse.Reading(degrees: nil, at: .distantPast),
                                          course: 270, accuracy: 5, speed: 9, at: start)
        #expect(reading.degrees == 270)

        // Stopped at the light, four seconds later.
        reading = TravelCourse.update(reading, course: 13, accuracy: 5, speed: 0.2, at: start.addingTimeInterval(4))
        #expect(reading.degrees == 270)

        // Still stopped a good while later: no longer worth claiming.
        reading = TravelCourse.update(reading, course: 13, accuracy: 5, speed: 0.2, at: start.addingTimeInterval(30))
        #expect(reading.degrees == nil)
    }

    /// CoreLocation says "I don't know" with a negative course or accuracy.
    @Test func anUnknownCourseIsNotUsed() {
        let reading = TravelCourse.update(TravelCourse.Reading(degrees: nil, at: .distantPast),
                                          course: -1, accuracy: -1, speed: 12, at: start)
        #expect(reading.degrees == nil)
    }

    @Test func differencesNeverExceedHalfATurn() {
        #expect(abs(TravelCourse.difference(350, 10) - 20) < 0.001)
        #expect(abs(TravelCourse.difference(10, 350) - 20) < 0.001)
        #expect(abs(TravelCourse.difference(0, 180) - 180) < 0.001)
    }
}
