import CoreLocation
import Foundation
import Testing
@testable import PathOS

struct JourneyTrackingTests {
    private let indiranagar = "Indiranagar"
    private let majestic = "Nadaprabhu Kempegowda Station, Majestic"
    /// A Tuesday at 14:00, off-peak.
    private var afternoon: Date {
        var parts = DateComponents(year: 2026, month: 9, day: 15, hour: 14)
        parts.timeZone = TimeZone(identifier: "Asia/Kolkata")
        return Calendar.current.date(from: parts)!
    }

    private var purpleRide: Journey {
        Journey.metro(MetroRouter.route(from: indiranagar, to: majestic, at: afternoon)!, startedAt: afternoon)
    }

    // MARK: The bundled network

    @Test func theNetworkMatchesWhatBMRCLRuns() {
        let lines = MetroNetwork.lines.map(\.id)
        #expect(lines == ["purple", "green", "yellow"])
        #expect(MetroNetwork.line(id: "purple")?.stations.count == 37)
        #expect(MetroNetwork.line(id: "green")?.stations.count == 32)
        #expect(MetroNetwork.line(id: "yellow")?.stations.count == 16)
        #expect(MetroNetwork.line(id: "purple")?.stations.first == "Whitefield (Kadugodi)")
        #expect(MetroNetwork.line(id: "yellow")?.stations.last == "Delta Electronics Bommasandra")
    }

    @Test func everyStationHasARealPlaceInBengaluru() {
        for line in MetroNetwork.lines {
            for station in line.stops {
                #expect((12.7...13.3).contains(station.lat) && (77.3...77.9).contains(station.lon), "\(station.name)")
            }
            for (a, b) in zip(line.stops, line.stops.dropFirst()) {
                let gap = GeoMath.distance(from: a.coordinate, to: b.coordinate)
                #expect(gap > 300 && gap < 3_500, "\(a.name) → \(b.name) is \(Int(gap)) m")
            }
        }
    }

    @Test func majesticAndRVRoadAreInterchanges() {
        #expect(MetroNetwork.interchangeLines(for: majestic).map(\.id) == ["purple", "green"])
        #expect(MetroNetwork.interchangeLines(for: "Rashtreeya Vidyalaya Road").map(\.id) == ["green", "yellow"])
        #expect(MetroNetwork.interchangeLines(for: indiranagar).map(\.id) == ["purple"])
    }

    @Test func typedNamesFindTheirStation() {
        #expect(MetroNetwork.station(matching: "MG Road") == "Mahatma Gandhi Road")
        #expect(MetroNetwork.station(matching: "Majestic metro station") == majestic)
        #expect(MetroNetwork.station(matching: "whitefield") == "Whitefield (Kadugodi)")
        #expect(MetroNetwork.station(matching: "Silk Board") == "Central Silk Board")
        // "Peenya" is inside "Peenya Industry" too, but an exact name wins.
        #expect(MetroNetwork.station(matching: "Peenya") == "Peenya")
        #expect(MetroNetwork.station(matching: "Koramangala") == nil)
    }

    // MARK: Following a journey

    @Test func aJustStartedJourneyCountsEveryStop() {
        let journey = purpleRide
        let progress = JourneyTracker.progress(stops: journey.stops, nearestIndex: 0, elapsed: 0)
        #expect(journey.stops.count == 8)
        #expect(progress.stopsRemaining == 7)
        #expect(progress.nextStationIndex == 1)
        #expect(!progress.isArrivingNext)
        #expect(!progress.hasArrived)
        #expect(progress.nextChangeIndex == nil)
    }

    @Test func gpsMovesYouAlongTheLine() {
        let progress = JourneyTracker.progress(stops: purpleRide.stops, nearestIndex: 6, elapsed: 8 * 60)
        #expect(progress.currentIndex == 6)
        #expect(progress.isArrivingNext)
        #expect(progress.isTrackingByLocation)
    }

    @Test func undergroundTheClockKeepsTheEstimateGoing() {
        let stops = purpleRide.stops
        // No usable fix: the clock says you've just passed the fifth stop.
        let progress = JourneyTracker.progress(stops: stops, nearestIndex: nil, elapsed: (stops[4].minutesFromStart + 0.1) * 60)
        #expect(progress.currentIndex == 4)
        #expect(!progress.isTrackingByLocation)
        // The first stop takes longest to reach: it includes waiting for a train.
        #expect(stops[1].minutesFromStart > stops[2].minutesFromStart - stops[1].minutesFromStart)
    }

    @Test func aStrayFixBehindYouIsIgnored() {
        let stops = purpleRide.stops
        let progress = JourneyTracker.progress(stops: stops, nearestIndex: 0, elapsed: stops[5].minutesFromStart * 60)
        #expect(progress.currentIndex == 5)
    }

    @Test func arrivalEndsTheJourney() {
        let progress = JourneyTracker.progress(stops: purpleRide.stops, nearestIndex: 7, elapsed: 20 * 60)
        #expect(progress.hasArrived)
        #expect(progress.nextStationIndex == nil)
        #expect(JourneyTracker.summary(progress) == "You've arrived")
    }

    @Test func aChangeIsFlaggedTheStopBefore() {
        // Indiranagar → Lalbagh: Purple to Majestic, then Green.
        let journey = Journey.metro(MetroRouter.route(from: indiranagar, to: "Lalbagh", at: afternoon)!, startedAt: afternoon)
        let changeIndex = journey.stops.firstIndex { $0.name == majestic }!
        #expect(journey.stops[changeIndex].changeInstruction == "Change to the Green Line towards Silk Institute")
        let before = JourneyTracker.progress(stops: journey.stops, nearestIndex: changeIndex - 1, elapsed: 0)
        #expect(before.isChangingNext)
        #expect(before.nextChangeIndex == changeIndex)
        let after = JourneyTracker.progress(stops: journey.stops, nearestIndex: changeIndex, elapsed: 0)
        #expect(!after.isChangingNext)
        #expect(after.nextChangeIndex == nil)
    }

    @Test func nearestStopNeedsYouToBeNearIt() {
        let stops = purpleRide.stops
        let atIndiranagar = CLLocationCoordinate2D(latitude: stops[0].latitude + 0.0005, longitude: stops[0].longitude)
        #expect(JourneyTracker.nearestStopIndex(to: atIndiranagar, stops: stops, radius: 700) == 0)
        let farAway = CLLocationCoordinate2D(latitude: 12.90, longitude: 77.50)
        #expect(JourneyTracker.nearestStopIndex(to: farAway, stops: stops, radius: 700) == nil)
    }

    @Test func summaryAlwaysReadsAsAnEstimate() {
        let progress = JourneyTracker.progress(stops: purpleRide.stops, nearestIndex: 3, elapsed: 0)
        #expect(JourneyTracker.summary(progress).hasPrefix("4 stops · about "))
        #expect(JourneyTracker.summary(progress).hasSuffix(" min"))
    }
}
