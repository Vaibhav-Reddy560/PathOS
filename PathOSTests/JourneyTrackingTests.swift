import CoreLocation
import Foundation
import Testing
@testable import PathOS

struct JourneyTrackingTests {
    // Indiranagar (15) → Majestic (22) on the Purple Line.
    private let fromIndex = 15
    private let toIndex = 22

    @Test func theNetworkMatchesWhatBMRCLRuns() {
        #expect(MetroNetwork.purple.stations.count == 37)
        #expect(MetroNetwork.green.stations.count == 32)
        #expect(MetroNetwork.yellow.stations.count == 16)
        #expect(MetroNetwork.purple.stations.first == "Whitefield (Kadugodi)")
        #expect(MetroNetwork.yellow.stations.last == "Delta Electronics Bommasandra")
    }

    @Test func majesticAndRVRoadAreInterchanges() {
        #expect(MetroNetwork.interchangeLines(for: "Nadaprabhu Kempegowda Station, Majestic").map(\.id) == ["purple", "green"])
        #expect(MetroNetwork.interchangeLines(for: "Rashtreeya Vidyalaya Road").map(\.id) == ["green", "yellow"])
        #expect(MetroNetwork.interchangeLines(for: "Indiranagar").map(\.id) == ["purple"])
    }

    @Test func aJustStartedJourneyCountsEveryStop() {
        let progress = JourneyTracker.progress(fromIndex: fromIndex, toIndex: toIndex, nearestIndex: fromIndex, elapsed: 0)
        #expect(progress.stopsRemaining == 7)
        #expect(progress.nextStationIndex == 16)
        #expect(!progress.isArrivingNext)
        #expect(!progress.hasArrived)
    }

    @Test func gpsMovesYouAlongTheLine() {
        let progress = JourneyTracker.progress(fromIndex: fromIndex, toIndex: toIndex, nearestIndex: 21, elapsed: 8 * 60)
        #expect(progress.currentIndex == 21)
        #expect(progress.stopsRemaining == 1)
        #expect(progress.isArrivingNext)
        #expect(progress.isTrackingByLocation)
    }

    @Test func undergroundTheClockKeepsTheEstimateGoing() {
        // No usable fix: 9 minutes at ~2.2 min per stop is about 4 stops.
        let progress = JourneyTracker.progress(fromIndex: fromIndex, toIndex: toIndex, nearestIndex: nil, elapsed: 9 * 60)
        #expect(progress.currentIndex == 19)
        #expect(progress.stopsRemaining == 3)
        #expect(!progress.isTrackingByLocation)
    }

    @Test func aStrayFixBehindYouIsIgnored() {
        // A fix snapping back to the start after 8 minutes shouldn't rewind the journey.
        let progress = JourneyTracker.progress(fromIndex: fromIndex, toIndex: toIndex, nearestIndex: fromIndex, elapsed: 8 * 60)
        #expect(progress.currentIndex >= 18)
    }

    @Test func journeysRunBackwardsToo() {
        // Majestic → Indiranagar is the same line the other way.
        let progress = JourneyTracker.progress(fromIndex: toIndex, toIndex: fromIndex, nearestIndex: 17, elapsed: 10 * 60)
        #expect(progress.currentIndex == 17)
        #expect(progress.nextStationIndex == 16)
        #expect(progress.stopsRemaining == 2)
    }

    @Test func arrivalEndsTheJourney() {
        let progress = JourneyTracker.progress(fromIndex: fromIndex, toIndex: toIndex, nearestIndex: toIndex, elapsed: 16 * 60)
        #expect(progress.hasArrived)
        #expect(progress.nextStationIndex == nil)
        #expect(JourneyTracker.summary(progress) == "You've arrived")
    }

    @Test func nearestStationNeedsYouToBeNearIt() {
        let stations = [
            StationFix(name: "Indiranagar", latitude: 12.9784, longitude: 77.6408),
            StationFix(name: "Halasuru", latitude: 12.9761, longitude: 77.6266),
        ]
        let atIndiranagar = CLLocationCoordinate2D(latitude: 12.9785, longitude: 77.6410)
        #expect(JourneyTracker.nearestStationIndex(to: atIndiranagar, stations: stations) == 0)

        let farAway = CLLocationCoordinate2D(latitude: 12.90, longitude: 77.50)
        #expect(JourneyTracker.nearestStationIndex(to: farAway, stations: stations) == nil)
    }

    @Test func summaryAlwaysReadsAsAnEstimate() {
        let progress = JourneyTracker.progress(fromIndex: fromIndex, toIndex: toIndex, nearestIndex: 18, elapsed: 6 * 60)
        #expect(JourneyTracker.summary(progress) == "4 stops · about 9 min")
    }
}
