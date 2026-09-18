import CoreLocation
import Foundation
import Testing
@testable import PathOS

struct TripPlanTests {
    private let calendar = Calendar.current
    private let morning = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!

    private func leg(_ mode: TravelMode, from: String, to: String, at offsetHours: Double, arrivesAfter hours: Double? = nil, distance: Double? = nil) -> PlannedLeg {
        let departure = morning.addingTimeInterval(offsetHours * 3_600)
        return PlannedLeg(
            id: UUID(),
            mode: mode,
            origin: from,
            destination: to,
            departure: departure,
            arrival: hours.map { departure.addingTimeInterval($0 * 3_600) },
            distanceMeters: distance
        )
    }

    @Test func legsComeOutInOrderForTheirDay() {
        let today = [
            leg(.train, from: "Bengaluru", to: "Mysuru", at: 3, arrivesAfter: 2),
            leg(.metro, from: "Home", to: "Majestic", at: 1, arrivesAfter: 0.5),
        ]
        let tomorrow = [leg(.flight, from: "Mysuru", to: "Goa", at: 26)]
        let day = TripPlan.legs(today + tomorrow, on: morning, calendar: calendar)
        #expect(day.map(\.destination) == ["Majestic", "Mysuru"])
    }

    @Test func currentLegIsTheOneYoureOn() {
        let legs = [
            leg(.metro, from: "Home", to: "Majestic", at: 1, arrivesAfter: 0.5),
            leg(.train, from: "Bengaluru", to: "Mysuru", at: 3, arrivesAfter: 2),
        ]
        let duringTrain = morning.addingTimeInterval(4 * 3_600)
        #expect(TripPlan.current(in: legs, now: duringTrain)?.destination == "Mysuru")
        #expect(TripPlan.next(in: legs, now: morning)?.destination == "Majestic")
    }

    @Test func arrivalIsEstimatedWhenYouDidntGiveOne() {
        // 90 km by train at 60 km/h is about an hour and a half.
        let train = leg(.train, from: "Bengaluru", to: "Mysuru", at: 0, distance: 90_000)
        let arrival = train.arrivalEstimate()
        #expect(arrival != nil)
        let minutes = (arrival?.timeIntervalSince(train.departure) ?? 0) / 60
        #expect(abs(minutes - 90) < 1)
        // Without a distance or an arrival, nothing is invented.
        #expect(leg(.car, from: "A", to: "B", at: 0).arrivalEstimate() == nil)
    }

    @Test func modesAreListedInTheOrderYouTravel() {
        let legs = [
            leg(.walk, from: "Hotel", to: "Pier", at: 5),
            leg(.metro, from: "Home", to: "Majestic", at: 1),
            leg(.ferry, from: "Pier", to: "Island", at: 6),
        ]
        #expect(TripPlan.modeSummary(legs) == "Metro · Walk · Ferry")
        #expect(TripPlan.plannedDistance([leg(.car, from: "A", to: "B", at: 0, distance: 1_200)]) == 1_200)
    }

    @Test func aDaySummaryOnlyClaimsWhatHappened() {
        let quiet = DaySummary(distanceMeters: 0, eventCount: 0, classCount: 0, legCount: 0, memoryCount: 0)
        #expect(quiet.isEmpty)
        #expect(quiet.sentence == "Nothing recorded for this day.")

        // 8_400 rather than 8_450: 8.45 sits just below the rounding boundary in binary.
        let busy = DaySummary(distanceMeters: 8_400, eventCount: 2, classCount: 3, legCount: 0, memoryCount: 1)
        #expect(busy.sentence == "Travelled 8.4 km, 3 classes, 2 events and saved 1 spot.")

        let onTrip = DaySummary(distanceMeters: 120_000, eventCount: 0, classCount: 0, legCount: 2,
                                memoryCount: 0, tripName: "Goa", tripDayNumber: 2, tripDayCount: 5)
        #expect(onTrip.sentence == "Goa, day 2 of 5: Travelled 120.0 km and 2 trip legs.")
    }

    // MARK: Following a leg

    private let majestic = CLLocationCoordinate2D(latitude: 12.9767, longitude: 77.5713)
    private let mysuru = CLLocationCoordinate2D(latitude: 12.3052, longitude: 76.6552)

    @Test func progressIsMeasuredByWhereYouAre() {
        let train = leg(.train, from: "Bengaluru", to: "Mysuru", at: 0, arrivesAfter: 2.5)
        let halfway = CLLocationCoordinate2D(latitude: (majestic.latitude + mysuru.latitude) / 2,
                                             longitude: (majestic.longitude + mysuru.longitude) / 2)
        let progress = TripTracker.progress(leg: train, origin: majestic, destination: mysuru, location: halfway,
                                            now: morning.addingTimeInterval(3_600))
        #expect(!progress.hasArrived)
        #expect(!progress.isLate)
        #expect(abs((progress.fractionDone ?? 0) - 0.5) < 0.02)
        #expect(progress.eta == train.arrival)
        #expect(progress.minutesRemaining == 90)
    }

    @Test func arrivingCountsAStationsWorthOfDistance() {
        let train = leg(.train, from: "Bengaluru", to: "Mysuru", at: 0, arrivesAfter: 2.5)
        // 400 m short of the pin is the station forecourt for a train, not for a cab.
        let forecourt = CLLocationCoordinate2D(latitude: mysuru.latitude + 0.0036, longitude: mysuru.longitude)
        #expect(TripTracker.progress(leg: train, origin: majestic, destination: mysuru, location: forecourt, now: morning).hasArrived)
        let cab = leg(.cab, from: "Bengaluru", to: "Mysuru", at: 0, arrivesAfter: 2.5)
        #expect(!TripTracker.progress(leg: cab, origin: majestic, destination: mysuru, location: forecourt, now: morning).hasArrived)
    }

    @Test func runningLateIsSaidOutLoud() {
        let train = leg(.train, from: "Bengaluru", to: "Mysuru", at: 0, arrivesAfter: 2.5)
        // Still near Bengaluru when you should be arriving.
        let late = TripTracker.progress(leg: train, origin: majestic, destination: mysuru, location: majestic,
                                        now: morning.addingTimeInterval(2.5 * 3_600 + 60))
        #expect(late.isLate)
        #expect(TripTracker.summary(late).hasPrefix("Running late"))
        #expect((late.minutesRemaining ?? 0) > 60)
    }

    @Test func withoutALocationTheClockCarriesIt() {
        let flight = leg(.flight, from: "BLR", to: "GOI", at: 0, arrivesAfter: 1.5)
        let progress = TripTracker.progress(leg: flight, origin: nil, destination: nil, location: nil,
                                            now: morning.addingTimeInterval(45 * 60))
        #expect(progress.distanceRemaining == nil)
        #expect(abs((progress.fractionDone ?? 0) - 0.5) < 0.01)
        #expect(progress.minutesRemaining == 45)
        #expect(TripTracker.summary(progress).hasPrefix("Arrives"))
    }

    @Test func aTripLegShowsOnTheIsland() {
        let snapshot = AlertSnapshot(
            location: .always, exitAdvice: nil, pressureTrend: .steady, guidance: nil, journey: nil,
            trip: AlertSnapshot.Trip(title: "Train to Mysuru", destination: "Mysuru", symbol: "train.side.front.car",
                                     summary: "Running late · about 25 min to go", minutesRemaining: 25, isLate: true),
            commute: nil, nextEvent: nil, weather: nil, venueName: "Here", venueSymbol: "mappin", now: morning
        )
        let alert = AmbientAlerts.prioritized(snapshot).first { $0.id == "trip" }
        #expect(alert?.role == .attention)
        #expect(alert?.metric == "25 min")
        #expect(alert?.buttons.first?.action == .endTrip)
    }

    @Test func tripDaysAreCountedInclusively() {
        let trip = Trip(name: "Goa", startDate: morning, endDate: morning.addingTimeInterval(4 * 86_400))
        #expect(trip.dayCount == 5)
        #expect(trip.dayNumber(for: morning) == 1)
        #expect(trip.dayNumber(for: morning.addingTimeInterval(2 * 86_400)) == 3)
        #expect(trip.dayNumber(for: morning.addingTimeInterval(9 * 86_400)) == nil)
        #expect(trip.covers(morning.addingTimeInterval(86_400)))
    }
}
