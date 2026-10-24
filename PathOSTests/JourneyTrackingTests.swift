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

    // MARK: Following a ride

    /// Your morning ride: Jayadeva Hospital to Konanakunte Cross, Yellow Line to Rashtreeya
    /// Vidyalaya Road, then the Green Line.
    private var forumRide: Journey {
        Journey.metro(MetroRouter.route(from: "Jayadeva Hospital", to: "Konanakunte Cross", at: afternoon)!,
                      startedAt: afternoon)
    }

    /// A good fix this far along the ride's line, `metres` off it to one side.
    private func fix(_ journey: Journey, along: Double, off metres: Double = 0, at: Date) -> RideFix {
        let point = RideLine.point(at: along, on: RideLine.geometry(of: journey))!
        return RideFix(coordinate: GeoMath.coordinate(point, metres: metres, bearing: 0), accuracy: 10, at: at)
    }

    private func along(_ journey: Journey, stop: Int) -> Double {
        RideLine.geometry(of: journey).stops[stop]
    }

    /// Follows a fix at each station in turn, a minute and a half apart.
    private func ride(_ journey: Journey, to stop: Int, from start: Date) -> (RideTrack, Date) {
        var track = RideTrack()
        var now = start
        for index in 0...stop {
            track = JourneyTracker.advance(track, in: journey, fix: fix(journey, along: along(journey, stop: index), at: now), now: now)
            // Changing: on the next train once it's moving.
            if track.isOnBoard == false, index > 0, index < stop {
                track = JourneyTracker.board(track, now: now)
            }
            now = now.addingTimeInterval(90)
        }
        return (track, now)
    }

    @Test func theRideIsBuiltAsItsTrains() {
        let journey = forumRide
        #expect(journey.stops.map(\.name) == ["Jayadeva Hospital", "Ragigudda", "Rashtreeya Vidyalaya Road", "Banashankari",
                                               "Jaya Prakash Nagar", "Yelachenahalli", "Konanakunte Cross"])
        #expect(journey.parts.count == 2)
        #expect(journey.parts[0].train.hasPrefix("Yellow Line towards"))
        #expect(journey.parts[1].train == "Green Line towards Silk Institute")
        #expect(journey.parts[0].lastStop == 2 && journey.parts[1].firstStop == 2)
    }

    /// On the platform: which train, nothing counted down, and the wait for it in the minutes.
    @Test func onThePlatformItSaysWhichTrainToBoard() {
        let journey = forumRide
        let start = afternoon
        let track = JourneyTracker.advance(RideTrack(), in: journey, fix: fix(journey, along: 20, at: start), now: start)
        let progress = JourneyTracker.progress(of: track, in: journey, now: start)
        #expect(progress.isWaiting && !progress.isChanging)
        #expect(progress.currentIndex == 0 && progress.stopsRemaining == 6)
        let instruction = JourneyTracker.instruction(for: progress, in: journey)
        #expect(instruction.headline.hasPrefix("Board the Yellow Line towards"))
        #expect(instruction.detail.contains("Next: Ragigudda"))
    }

    /// The fault on the morning ride: twenty minutes on the platform used to count as twenty
    /// minutes of riding, and "get off at the next stop" came while you were three stops short.
    @Test func waitingForATrainDoesntMoveYouAlong() {
        let journey = forumRide
        let start = afternoon
        var track = JourneyTracker.advance(RideTrack(), in: journey, fix: fix(journey, along: 20, at: start), now: start)
        let later = start.addingTimeInterval(20 * 60)
        track = JourneyTracker.advance(track, in: journey, fix: fix(journey, along: 40, at: later), now: later)
        let progress = JourneyTracker.progress(of: track, in: journey, now: later)
        #expect(progress.currentIndex == 0)
        #expect(progress.stopsRemaining == 6)
        #expect(!progress.isArrivingNext)
    }

    /// Moving along the line is boarding, without being told.
    @Test func movingAlongTheLineIsBeingOnTheTrain() {
        let journey = forumRide
        let start = afternoon
        var track = JourneyTracker.advance(RideTrack(), in: journey, fix: fix(journey, along: 0, at: start), now: start)
        let moving = start.addingTimeInterval(60)
        track = JourneyTracker.advance(track, in: journey, fix: fix(journey, along: 500, at: moving), now: moving)
        #expect(track.isOnBoard)
        let progress = JourneyTracker.progress(of: track, in: journey, now: moving)
        #expect(!progress.isWaiting)
        #expect(JourneyTracker.instruction(for: progress, in: journey).headline == "Next: Ragigudda")
        #expect(progress.metresToNext.map { abs($0 - (along(journey, stop: 1) - 500)) < 1 } == true)
    }

    /// The dot that jumped back to Jayadeva: a fix behind where you've been seen is left out, and
    /// so is one further ahead than any train could have gone.
    @Test func aFixThatJumpsIsLeftOut() {
        let journey = forumRide
        let (track, now) = ride(journey, to: 1, from: afternoon)
        let back = JourneyTracker.advance(track, in: journey, fix: fix(journey, along: 0, at: now), now: now)
        #expect(back.along == track.along)
        let leap = JourneyTracker.advance(track, in: journey, fix: fix(journey, along: along(journey, stop: 5), at: now.addingTimeInterval(10)),
                                          now: now.addingTimeInterval(10))
        #expect(leap.along == track.along)
    }

    /// A fix well off the line — a road beside it, a poor reading — doesn't move you along it.
    @Test func aFixOffTheLineDoesntCount() {
        let journey = forumRide
        let (track, now) = ride(journey, to: 1, from: afternoon)
        let off = JourneyTracker.advance(track, in: journey, fix: fix(journey, along: along(journey, stop: 1) + 600, off: 900, at: now), now: now)
        #expect(off.along == track.along)
    }

    /// Underground, with no fix, you're carried on at a little under the trains' pace — through
    /// the stations between, but a guess never gets you to where you get off, and never says
    /// you've arrived.
    @Test func withoutAFixTheGuessStopsShortOfGettingOff() {
        let journey = forumRide
        let (track, now) = ride(journey, to: 4, from: afternoon)
        let much = now.addingTimeInterval(20 * 60)
        let progress = JourneyTracker.progress(of: track, in: journey, now: much)
        #expect(progress.currentIndex <= 5)
        #expect(!progress.hasArrived)
    }

    /// On the Green Line with no fix after boarding: carried through Banashankari and on, not held
    /// at the next station — the ride that ran a station or two behind.
    @Test func withoutAFixTheRideStillMovesThroughStations() {
        let journey = forumRide
        let (atChange, now) = ride(journey, to: 2, from: afternoon)
        let boarded = JourneyTracker.board(atChange, now: now)
        // Six minutes on, a couple of stations' worth at the trains' pace.
        let later = now.addingTimeInterval(6 * 60)
        let carried = JourneyTracker.advance(boarded, in: journey, fix: nil, now: later)
        #expect(JourneyTracker.progress(of: carried, in: journey, now: later).currentIndex >= 4)
        // A fix from behind doesn't take the dot back.
        let behind = JourneyTracker.advance(carried, in: journey, fix: fix(journey, along: along(journey, stop: 3), at: later), now: later)
        #expect(JourneyTracker.progress(of: behind, in: journey, now: later).currentIndex >= 4)
    }

    /// Inside a coach GPS says ±250 m: still on the line, and it moves you — by less than it says.
    @Test func aVagueFixStillMovesYouAlong() {
        let journey = forumRide
        let (track, now) = ride(journey, to: 1, from: afternoon)
        var vague = fix(journey, along: along(journey, stop: 1) + 800, at: now.addingTimeInterval(60))
        vague.accuracy = 250
        let moved = JourneyTracker.advance(track, in: journey, fix: vague, now: now.addingTimeInterval(60))
        #expect(moved.along > track.along)
        #expect(moved.along <= along(journey, stop: 1) + 800 - 150 + 1)
    }

    /// At the change, you're on the next train's platform: said, and asked.
    @Test func atTheChangeItSaysWhereToChangeTo() {
        let journey = forumRide
        var track = RideTrack()
        var now = afternoon
        for stop in 0...2 {
            track = JourneyTracker.advance(track, in: journey, fix: fix(journey, along: along(journey, stop: stop), at: now), now: now)
            now = now.addingTimeInterval(90)
        }
        let progress = JourneyTracker.progress(of: track, in: journey, now: now)
        #expect(progress.isWaiting && progress.isChanging)
        #expect(progress.currentIndex == 2)
        #expect(JourneyTracker.instruction(for: progress, in: journey).headline == "Change here: Green Line towards Silk Institute")
        // The stop before: said while still on the Yellow Line.
        var before = RideTrack()
        now = afternoon
        for stop in 0...1 {
            before = JourneyTracker.advance(before, in: journey, fix: fix(journey, along: along(journey, stop: stop), at: now), now: now)
            now = now.addingTimeInterval(90)
        }
        let coming = JourneyTracker.progress(of: before, in: journey, now: now)
        #expect(coming.isChangingNext)
        #expect(JourneyTracker.instruction(for: coming, in: journey).detail.hasSuffix("To the Green Line towards Silk Institute"))
    }

    /// Arriving is GPS putting you at the last station, nothing less.
    @Test func arrivingIsBeingAtTheLastStation() {
        let journey = forumRide
        let (nearly, now) = ride(journey, to: 5, from: afternoon)
        let coming = JourneyTracker.progress(of: nearly, in: journey, now: now)
        #expect(coming.isArrivingNext && !coming.hasArrived)
        #expect(JourneyTracker.instruction(for: coming, in: journey, then: "Walk to PVR INOX").headline
                == "Get off at the next stop: Konanakunte Cross")
        let there = JourneyTracker.advance(nearly, in: journey, fix: fix(journey, along: along(journey, stop: 6) - 40, at: now), now: now)
        let progress = JourneyTracker.progress(of: there, in: journey, now: now)
        #expect(progress.hasArrived)
        #expect(JourneyTracker.instruction(for: progress, in: journey, then: "Walk to PVR INOX").detail == "Exit, then walk to PVR INOX")
        #expect(JourneyTracker.summary(progress) == "You've arrived")
    }

    /// The minutes left come from how much line is left and the waits still ahead.
    @Test func minutesLeftComeFromTheLineLeft() {
        let journey = forumRide
        let (early, now) = ride(journey, to: 1, from: afternoon)
        let (late, then) = ride(journey, to: 4, from: afternoon)
        #expect(JourneyTracker.progress(of: early, in: journey, now: now).estimatedMinutesRemaining
                > JourneyTracker.progress(of: late, in: journey, now: then).estimatedMinutesRemaining)
    }

    /// The ride follows the rails: a little longer than straight lines between its stations,
    /// with every station on it, in order.
    @Test func aRideFollowsTheTrack() {
        let journey = forumRide
        let line = RideLine.geometry(of: journey)
        #expect(line.followsTrack)
        #expect(line.points.count > journey.stops.count)
        let straight = zip(journey.stops, journey.stops.dropFirst())
            .map { GeoMath.distance(from: $0.coordinate, to: $1.coordinate) }.reduce(0, +)
        #expect(line.length > straight && line.length < straight * 1.3)
        for stop in journey.stops {
            #expect(RideLine.locate(stop.coordinate, on: line)!.offset < 150)
        }
        #expect(line.stops == line.stops.sorted())
        #expect(line.stops.first == 0)
    }

    /// A bus has no track to follow: its line runs straight from stop to stop.
    @Test func aBusRunsStraightBetweenStops() {
        let stops = [JourneyStop(name: "A", latitude: 12.97, longitude: 77.59, minutesFromStart: 0),
                     JourneyStop(name: "B", latitude: 12.98, longitude: 77.60, minutesFromStart: 4)]
        let line = RideLine.geometry(of: Journey(kind: .bus, lineName: "500D", stops: stops, startedAt: afternoon))
        #expect(!line.followsTrack)
        #expect(line.points.count == 2)
        #expect(abs(line.length - GeoMath.distance(from: stops[0].coordinate, to: stops[1].coordinate)) < 1)
    }

    /// Drawn on the line, always: the point the map puts you at is on the ride.
    @Test func youAreDrawnOnTheLine() {
        let journey = forumRide
        let start = afternoon
        let track = JourneyTracker.advance(RideTrack(), in: journey,
                                           fix: fix(journey, along: 700, off: 120, at: start), now: start)
        let progress = JourneyTracker.progress(of: track, in: journey, now: start)
        let drawn = try! #require(progress.coordinate)
        #expect(RideLine.locate(drawn, on: RideLine.geometry(of: journey))!.offset < 1)
    }

    @Test func summaryAlwaysReadsAsAnEstimate() {
        let journey = forumRide
        let (track, now) = ride(journey, to: 2, from: afternoon)
        let summary = JourneyTracker.summary(JourneyTracker.progress(of: track, in: journey, now: now))
        #expect(summary.hasPrefix("4 stops · about "))
        #expect(summary.hasSuffix(" min"))
    }
}
