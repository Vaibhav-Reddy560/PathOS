import Testing
@testable import PathOS

/// Getting across the city: by car or two-wheeler first, on foot only when it's a walk.
struct TravelTimesTests {
    /// 71 min by metro and a 120 min walk to college: nobody walks that, so it isn't offered.
    @Test func aLongWalkIsLeftOut() {
        let options = TravelTimes.options(car: 34, transit: 71, walk: 120)
        #expect(options.map(\.mode) == [.car, .twoWheeler, .transit])
        #expect(options.map(\.minutes) == [34, 27, 71])
    }

    @Test func aShortWalkIsKept() {
        let options = TravelTimes.options(car: 6, transit: nil, walk: 18)
        #expect(options.map(\.mode) == [.car, .twoWheeler, .walk])
    }

    /// If the roads couldn't be timed, the walk is all there is, however long.
    @Test func withoutRoadsTheWalkStays() {
        #expect(TravelTimes.options(car: nil, transit: nil, walk: 90).map(\.mode) == [.walk])
        #expect(TravelTimes.options(car: nil, transit: nil, walk: nil).isEmpty)
    }

    /// Worked out from the car's time, and marked as such.
    @Test func theTwoWheelerIsAnEstimate() {
        let twoWheeler = TravelTimes.options(car: 40, transit: nil, walk: nil).first { $0.mode == .twoWheeler }
        #expect(twoWheeler?.minutes == 32)
        #expect(twoWheeler?.isEstimate == true)
        #expect(TravelTimes.twoWheelerMinutes(car: 1) == 1)
    }

    /// The Lock Screen gets one line: the car, unless it's a short walk.
    @Test func theLockScreenShowsTheCarUnlessItsAStroll() {
        #expect(TravelTimes.headline(car: 34, transit: 71, walk: 120)?.mode == .car)
        #expect(TravelTimes.headline(car: 4, transit: nil, walk: 9)?.mode == .walk)
        #expect(TravelTimes.headline(car: nil, transit: 50, walk: nil)?.mode == .transit)
    }
}
