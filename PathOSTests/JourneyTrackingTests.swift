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

    /// Once GPS has put you at a stop, a stray fix from the one before doesn't send you back.
    @Test func theRideNeverGoesBackAStop() {
        let stops = purpleRide.stops
        let progress = JourneyTracker.progress(stops: stops, nearestIndex: 3, elapsed: 0, reached: 4)
        #expect(progress.currentIndex == 4)
        // GPS is still believed over the clock when the train is running late.
        let late = JourneyTracker.progress(stops: stops, nearestIndex: 4, elapsed: (stops[5].minutesFromStart + 0.1) * 60,
                                           reached: 4)
        #expect(late.currentIndex == 4)
    }

    /// Halfway between two stations, the one ahead isn't reached yet; at its platform, it is.
    @Test func aStationIsReachedAtItNotHalfwayToIt() {
        let journey = Journey.metro(MetroRouter.route(from: "Ragigudda", to: "Central Silk Board", at: afternoon)!,
                                    startedAt: afternoon)
        let ragigudda = journey.stops[0].coordinate, jayadeva = journey.stops[1].coordinate
        let mostOfTheWay = CLLocationCoordinate2D(latitude: ragigudda.latitude + (jayadeva.latitude - ragigudda.latitude) * 0.7,
                                                  longitude: ragigudda.longitude + (jayadeva.longitude - ragigudda.longitude) * 0.7)
        #expect(JourneyTracker.reachedIndex(at: mostOfTheWay, stops: journey.stops, radius: 700) == 0)
        let atPlatform = GeoMath.coordinate(jayadeva, metres: 80, bearing: 270)
        #expect(JourneyTracker.reachedIndex(at: atPlatform, stops: journey.stops, radius: 700) == 1)
        #expect(JourneyTracker.reachedIndex(at: CLLocationCoordinate2D(latitude: 12.99, longitude: 77.59),
                                            stops: journey.stops, radius: 700) == nil)
    }

    // MARK: What to do

    @Test func atTheFirstStationItSaysWhichTrainToBoard() {
        let journey = Journey.metro(MetroRouter.route(from: "Ragigudda", to: "Central Silk Board", at: afternoon)!,
                                    startedAt: afternoon)
        let progress = JourneyTracker.progress(stops: journey.stops, nearestIndex: 0, elapsed: 0)
        let instruction = JourneyTracker.instruction(for: progress, in: journey)
        #expect(instruction.headline == "Board the Yellow Line towards Delta Electronics Bommasandra")
        #expect(instruction.detail.hasPrefix("Next: Jayadeva Hospital · 3 stops to Central Silk Board"))
        #expect(!instruction.isAction)
    }

    /// Pulled out of the first station, it's the next station, not which train to board.
    @Test func onceMovingItStopsSayingBoard() {
        let journey = Journey.metro(MetroRouter.route(from: "Ragigudda", to: "Central Silk Board", at: afternoon)!,
                                    startedAt: afternoon)
        var progress = JourneyTracker.progress(stops: journey.stops, nearestIndex: 0, elapsed: 0)
        progress.metresToNext = 400
        let instruction = JourneyTracker.instruction(for: progress, in: journey)
        #expect(instruction.headline == "Next: Jayadeva Hospital")
        #expect(instruction.detail.hasPrefix("400 m away"))
    }

    @Test func alongTheWayItSaysTheNextStation() {
        let journey = Journey.metro(MetroRouter.route(from: "Ragigudda", to: "Central Silk Board", at: afternoon)!,
                                    startedAt: afternoon)
        let progress = JourneyTracker.progress(stops: journey.stops, nearestIndex: 1, elapsed: 0)
        let instruction = JourneyTracker.instruction(for: progress, in: journey)
        #expect(instruction.headline == "Next: BTM Layout")
        #expect(instruction.detail.hasPrefix("2 stops to Central Silk Board · about "))
    }

    @Test func theStopBeforeItSaysToGetOffAndWhatsNext() {
        let journey = Journey.metro(MetroRouter.route(from: "Ragigudda", to: "Central Silk Board", at: afternoon)!,
                                    startedAt: afternoon)
        let progress = JourneyTracker.progress(stops: journey.stops, nearestIndex: 2, elapsed: 0)
        let instruction = JourneyTracker.instruction(for: progress, in: journey, then: "Walk to HSR BDA Complex")
        #expect(instruction.headline == "Get off at the next stop: Central Silk Board")
        #expect(instruction.detail.hasSuffix("then walk to HSR BDA Complex"))
        #expect(instruction.isAction)

        let off = JourneyTracker.progress(stops: journey.stops, nearestIndex: 3, elapsed: 0)
        let after = JourneyTracker.instruction(for: off, in: journey, then: "Walk to HSR BDA Complex")
        #expect(after.headline == "You're at Central Silk Board")
        #expect(after.detail == "Exit, then walk to HSR BDA Complex")
    }

    @Test func theStopBeforeAChangeSaysWhereToChangeTo() {
        let journey = Journey.metro(MetroRouter.route(from: indiranagar, to: "Lalbagh", at: afternoon)!, startedAt: afternoon)
        let changeIndex = journey.stops.firstIndex { $0.name == majestic }!
        let progress = JourneyTracker.progress(stops: journey.stops, nearestIndex: changeIndex - 1, elapsed: 0)
        let instruction = JourneyTracker.instruction(for: progress, in: journey)
        #expect(instruction.headline == "Change at the next stop: \(majestic)")
        #expect(instruction.detail == "To the Green Line towards Silk Institute")
        #expect(instruction.isAction)
        // Further back, the change is mentioned along with the next station.
        let earlier = JourneyTracker.progress(stops: journey.stops, nearestIndex: 1, elapsed: 0)
        #expect(JourneyTracker.instruction(for: earlier, in: journey).detail.contains("change at \(majestic)"))
    }

    @Test func summaryAlwaysReadsAsAnEstimate() {
        let progress = JourneyTracker.progress(stops: purpleRide.stops, nearestIndex: 3, elapsed: 0)
        #expect(JourneyTracker.summary(progress).hasPrefix("4 stops · about "))
        #expect(JourneyTracker.summary(progress).hasSuffix(" min"))
    }
}
