import CoreLocation
import Foundation
import Testing
@testable import PathOS

/// The day's travel: stretches noticed from movement, receipts matched to them, totals by mode.
struct TravelLogTests {
    let start = Date(timeIntervalSince1970: 1_792_000_000)
    let home = CLLocationCoordinate2D(latitude: 12.9105, longitude: 77.6004)

    /// Feeds fixes every `step` seconds at `metresPerSecond`, heading `bearing`.
    private func move(_ segmenter: inout MotionSegmenter, from origin: CLLocationCoordinate2D, at time: Date,
                      seconds: Int, metresPerSecond: Double, bearing: Double = 0, step: Int = 5) -> (CLLocationCoordinate2D, Date, [MotionSegmenter.Piece]) {
        var here = origin, now = time, pieces: [MotionSegmenter.Piece] = []
        for _ in 0..<(seconds / step) {
            here = GeoMath.coordinate(here, metres: metresPerSecond * Double(step), bearing: bearing)
            now = now.addingTimeInterval(Double(step))
            pieces += segmenter.feed(here, at: now, speed: metresPerSecond, accuracy: 10)
        }
        return (here, now, pieces)
    }

    @Test func aWalkThenARideAreTwoStretches() {
        var segmenter = MotionSegmenter()
        _ = segmenter.feed(home, at: start, speed: 0, accuracy: 10)
        var (here, now, pieces) = move(&segmenter, from: home, at: start, seconds: 300, metresPerSecond: 1.4)
        let ride = move(&segmenter, from: here, at: now, seconds: 600, metresPerSecond: 8, bearing: 90)
        (here, now) = (ride.0, ride.1)
        pieces += ride.2
        // Still for a while: the ride is over.
        for minute in 1...4 { pieces += segmenter.feed(here, at: now.addingTimeInterval(Double(minute) * 60), speed: 0, accuracy: 10) }
        #expect(pieces.map(\.mode) == [.walk, .road])
        #expect(pieces.first.map { abs($0.distanceMeters - 420) < 60 } == true)
        #expect(pieces.last.map { abs($0.distanceMeters - 4_800) < 300 } == true)
    }

    /// A short stop at a signal isn't the end of a ride, and a moment's slow crawl isn't a walk.
    @Test func aPauseOrAJamDoesntSplitARide() {
        var segmenter = MotionSegmenter()
        _ = segmenter.feed(home, at: start, speed: 0, accuracy: 10)
        var (here, now, pieces) = move(&segmenter, from: home, at: start, seconds: 300, metresPerSecond: 8)
        let crawl = move(&segmenter, from: here, at: now, seconds: 30, metresPerSecond: 1.5)
        pieces += crawl.2
        let more = move(&segmenter, from: crawl.0, at: crawl.1, seconds: 300, metresPerSecond: 8)
        (here, now) = (more.0, more.1)
        pieces += more.2 + segmenter.finish()
        #expect(pieces.map(\.mode) == [.road])
    }

    /// Along a metro line between stations: the metro, not a road beside it.
    @Test func alongAMetroLineIsTheMetro() {
        let yellow = MetroNetwork.line(id: "yellow")!.stops
        let trail = yellow[2...5].map(\.coordinate)
        #expect(TravelLog.isAlongMetro(trail))
        let roadAway = [home, GeoMath.coordinate(home, metres: 2_000, bearing: 200), GeoMath.coordinate(home, metres: 4_000, bearing: 200)]
        #expect(!TravelLog.isAlongMetro(roadAway))
    }

    /// The receipt that came as a ride ended puts its fare and vehicle on it.
    @Test func aReceiptReplacesTheEstimate() {
        let stretch = TravelLog.Stretch(id: UUID(), mode: .road, start: start, end: start.addingTimeInterval(1_200),
                                        distanceMeters: 5_000, from: "Home", to: "Office", fare: 110, fareIsEstimate: true)
        let receipt = TravelLog.Receipt(at: start.addingTimeInterval(1_320), fare: 132, vehicle: .auto, provider: "Uber")
        let matched = TravelLog.matching(stretch, receipts: [receipt])
        #expect(matched.fare == 132 && !matched.fareIsEstimate)
        #expect(matched.mode == .auto)
        // A receipt from hours later isn't this ride's.
        let late = TravelLog.Receipt(at: start.addingTimeInterval(4 * 3_600), fare: 80, vehicle: .cab, provider: "Ola")
        #expect(TravelLog.matching(stretch, receipts: [late]) == stretch)
    }

    /// A receipt prices one ride, not two; one PathOS never saw is a ride of its own.
    @Test func eachReceiptCountsOnce() {
        let first = TravelLog.Stretch(id: UUID(), mode: .road, start: start, end: start.addingTimeInterval(900),
                                      distanceMeters: 4_000, fare: 90, fareIsEstimate: true)
        let second = TravelLog.Stretch(id: UUID(), mode: .road, start: start.addingTimeInterval(1_200),
                                       end: start.addingTimeInterval(1_800), distanceMeters: 2_000, fare: 60, fareIsEstimate: true)
        let receipt = TravelLog.Receipt(at: start.addingTimeInterval(1_000), fare: 120, vehicle: .cab, provider: "Uber")
        let evening = TravelLog.Receipt(at: start.addingTimeInterval(10 * 3_600), fare: 75, vehicle: .bikeTaxi,
                                        provider: "Rapido", distanceMeters: 3_500, minutes: 14, pickup: "Office", drop: "Home")
        let day = TravelLog.priced([second, first], receipts: [evening, receipt])
        #expect(day.count == 3)
        #expect(day[0].fare == 120 && day[0].mode == .cab && day[0].provider == "Uber")
        #expect(day[1].fare == 60 && day[1].fareIsEstimate)
        #expect(day[2].mode == .bikeTaxi && day[2].distanceMeters == 3_500 && day[2].minutes == 14 && day[2].to == "Home")
    }

    @Test func theDayAddsUpByMode() {
        func stretch(_ mode: WayTravelled, _ metres: Double, minutes: Double, fare: Double?) -> TravelLog.Stretch {
            .init(id: UUID(), mode: mode, start: start, end: start.addingTimeInterval(minutes * 60), distanceMeters: metres,
                  fare: fare, fareIsEstimate: true)
        }
        let day = [stretch(.walk, 700, minutes: 9, fare: nil), stretch(.metro, 6_000, minutes: 20, fare: 30),
                   stretch(.walk, 400, minutes: 5, fare: nil)]
        let totals = TravelLog.byMode(day)
        #expect(totals.map(\.mode) == [.metro, .walk])
        #expect(totals.last?.distanceMeters == 1_100 && totals.last?.minutes == 14)
        #expect(totals.first?.fare == 30)
        #expect(TravelLog.otherMovement(total: 8_000, stretches: day) == 900)
    }
}
