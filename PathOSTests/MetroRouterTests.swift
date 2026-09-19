import CoreLocation
import Foundation
import Testing
@testable import PathOS

struct MetroRouterTests {
    private let majestic = "Nadaprabhu Kempegowda Station, Majestic"
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    private func date(weekday day: Int, hour: Int, minute: Int = 0) -> Date {
        // 13 September 2026 is a Sunday; day 0 = Sunday … 6 = Saturday.
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 13 + day, hour: hour, minute: minute))!
    }

    @Test func aSameLineRouteHasNoChanges() {
        let route = MetroRouter.route(from: "Indiranagar", to: majestic, at: date(weekday: 2, hour: 14), calendar: calendar)!
        #expect(route.rides.count == 1)
        #expect(route.rides[0].lineID == "purple")
        #expect(route.rides[0].towards == "Challaghatta")
        #expect(route.stationsTravelled == 7)
        #expect(route.changes.isEmpty)
        #expect(route.path.count == 8)
        #expect(route.arrivalMinutes.count == route.path.count)
    }

    @Test func crossingTownChangesAtMajestic() {
        let route = MetroRouter.route(from: "Whitefield (Kadugodi)", to: "Silk Institute", at: date(weekday: 2, hour: 14), calendar: calendar)!
        #expect(route.rides.map(\.lineID) == ["purple", "green"])
        #expect(route.changes == [majestic])
        #expect(route.rides[1].towards == "Silk Institute")
        #expect(route.lineSummary == "Purple → Green Line")
        // The change station is listed once, not twice.
        #expect(route.path.filter { $0.name == majestic }.count == 1)
        #expect(route.stationsTravelled == 22 + 15)
    }

    @Test func greenToYellowChangesAtRVRoad() {
        let route = MetroRouter.route(from: "Lalbagh", to: "Electronic City", at: date(weekday: 3, hour: 12), calendar: calendar)!
        #expect(route.changes == ["Rashtreeya Vidyalaya Road"])
        #expect(route.rides.last?.towards == "Delta Electronics Bommasandra")
    }

    @Test func endToEndTimeIsRealistic() {
        // BMRCL's Purple Line takes roughly 80 minutes end to end.
        let route = MetroRouter.route(from: "Whitefield (Kadugodi)", to: "Challaghatta", at: date(weekday: 2, hour: 14), calendar: calendar)!
        #expect((70...95).contains(route.minutes))
        #expect((40_000...48_000).contains(route.distanceMeters))
    }

    @Test func nothingToPlanBetweenAStationAndItself() {
        #expect(MetroRouter.route(from: majestic, to: majestic) == nil)
        #expect(MetroRouter.route(from: majestic, to: "Nowhere") == nil)
    }

    @Test func faresFollowTheStationSlabs() {
        let offPeak = date(weekday: 2, hour: 14)
        #expect(MetroRouter.fare(stationsTravelled: 1, at: offPeak, calendar: calendar).token == 10)
        #expect(MetroRouter.fare(stationsTravelled: 2, at: offPeak, calendar: calendar).token == 10)
        #expect(MetroRouter.fare(stationsTravelled: 3, at: offPeak, calendar: calendar).token == 20)
        #expect(MetroRouter.fare(stationsTravelled: 15, at: offPeak, calendar: calendar).token == 60)
        #expect(MetroRouter.fare(stationsTravelled: 16, at: offPeak, calendar: calendar).token == 70)
        #expect(MetroRouter.fare(stationsTravelled: 40, at: offPeak, calendar: calendar).token == 90)
        #expect(MetroRouter.fare(stationsTravelled: 0, at: offPeak, calendar: calendar).token == 10)
    }

    @Test func smartCardsSaveMoreOffPeak() {
        let peak = MetroRouter.fare(stationsTravelled: 7, at: date(weekday: 2, hour: 9), calendar: calendar)
        #expect(peak.isPeak)
        #expect(peak.smartCard == 38)
        let offPeak = MetroRouter.fare(stationsTravelled: 7, at: date(weekday: 2, hour: 14), calendar: calendar)
        #expect(!offPeak.isPeak)
        #expect(offPeak.smartCard == 36)
        // Sunday has no peak.
        #expect(!MetroRouter.fare(stationsTravelled: 7, at: date(weekday: 0, hour: 9), calendar: calendar).isPeak)
    }

    @Test func serviceHoursFollowTheDay() {
        let purple = MetroNetwork.line(id: "purple")!
        // Mondays start early, Sundays late.
        #expect(MetroSchedule.status(for: purple, at: date(weekday: 1, hour: 4, minute: 30), calendar: calendar)
                == .running(everyMinutes: 12, lastTrain: date(weekday: 1, hour: 23)))
        guard case .closed(let first) = MetroSchedule.status(for: purple, at: date(weekday: 0, hour: 6), calendar: calendar) else {
            Issue.record("Sunday at 6 should be closed")
            return
        }
        #expect(first == date(weekday: 0, hour: 7))
        guard case .closingSoon = MetroSchedule.status(for: purple, at: date(weekday: 3, hour: 22, minute: 45), calendar: calendar) else {
            Issue.record("Quarter to eleven is the last trains")
            return
        }
        guard case .closed(let tomorrow) = MetroSchedule.status(for: purple, at: date(weekday: 3, hour: 23, minute: 30), calendar: calendar) else {
            Issue.record("Half eleven is closed")
            return
        }
        #expect(tomorrow == date(weekday: 4, hour: 5))
        #expect(MetroSchedule.headway(for: purple, at: date(weekday: 2, hour: 9), calendar: calendar) == 8)
    }

    // MARK: Stations near you

    @Test func theNearestStationsShowEvenWhenNoneIsAWalkAway() {
        // Hebbal, over five kilometres from the nearest platform.
        let stations = MetroNetwork.nearbyStations(to: .init(latitude: 13.0358, longitude: 77.5970))
        #expect(stations.map(\.station.name) == ["Sandal Soap Factory", "Yeshwanthpur", "Srirampura"])
        #expect(stations[0].distance > 5_000)
    }

    @Test func everyStationInWalkingDistanceIsListedOnce() {
        // Majestic is on two lines; it's listed once, and the Railway Station is a walk away too.
        let stations = MetroNetwork.nearbyStations(to: .init(latitude: 12.9757, longitude: 77.5728), atLeast: 1)
        #expect(stations.map(\.station.name) == [majestic, "Krantivira Sangolli Rayanna Railway Station"])
        #expect(Set(MetroNetwork.nearbyStations(to: .init(latitude: 12.9757, longitude: 77.5728)).map(\.station.name)).count == 3)
    }

    @Test func anotherCityHasNoStations() {
        #expect(MetroNetwork.nearbyStations(to: .init(latitude: 28.6139, longitude: 77.2090)).isEmpty)
    }
}
