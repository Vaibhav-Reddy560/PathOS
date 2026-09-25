import Foundation
import Testing
@testable import PathOS

struct AmbientAlertTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        location: AlertSnapshot.LocationAccess = .always,
        exitAdvice: ExitAdvice? = nil,
        trend: PressureTrend = .steady,
        guidance: AlertSnapshot.Guidance? = nil,
        event: AlertSnapshot.Event? = nil,
        weather: AlertSnapshot.Weather? = nil
    ) -> AlertSnapshot {
        AlertSnapshot(location: location, exitAdvice: exitAdvice, pressureTrend: trend, guidance: guidance,
                      nextEvent: event, weather: weather,
                      venueName: "MG Road", venueSymbol: "location.fill", now: now)
    }

    private let rain = ExitAdvice(headline: "Rain likely — take an umbrella", detail: "70% chance.", symbol: "cloud.rain.fill", severity: .medium)
    private let sunny = AlertSnapshot.Weather(temperatureC: 27.4, summary: "Clear", symbol: "sun.max.fill", rainChanceNext2h: 10)
    private let target = CompassTarget(id: "note:1", name: "Car", latitude: 12.97, longitude: 77.59)

    @Test func deniedLocationIsCriticalAndCannotBeDismissed() {
        let alerts = AmbientAlerts.prioritized(snapshot(location: .denied, exitAdvice: rain, weather: sunny), dismissed: ["location.denied"])
        #expect(alerts.first?.id == "location.denied")
        #expect(alerts.first?.role == .critical)
    }

    @Test func attentionOutranksYourActivityWhichOutranksTheWorld() {
        let guidance = AlertSnapshot.Guidance(target: target, distanceMeters: 184, needsCalibration: false)
        let alerts = AmbientAlerts.prioritized(snapshot(exitAdvice: rain, guidance: guidance, weather: sunny))
        #expect(alerts.map(\.role).prefix(3) == [.attention, .you, .world])
        #expect(alerts.first?.compactText == "Rain likely")
        #expect(alerts.first?.metric == "10%")
    }

    @Test func eventsWithinThirtyMinutesAskForAttention() {
        let soon = AlertSnapshot.Event(id: "e", title: "Jazz", start: now.addingTimeInterval(12 * 60), latitude: 12.97, longitude: 77.59)
        let alert = AmbientAlerts.prioritized(snapshot(event: soon)).first
        #expect(alert?.role == .attention)
        #expect(alert?.metric == "12 min")
        #expect(alert?.buttons.first?.action == .pointTo(CompassTarget(id: "e", name: "Jazz", latitude: 12.97, longitude: 77.59)))
    }

    @Test func laterEventsTodayAreWorldInformation() {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let evening = calendar.date(bySettingHour: 23, minute: 30, second: 0, of: now) ?? now
        let laterNow = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        let event = AlertSnapshot.Event(id: "e", title: "Late show", start: evening)
        var input = snapshot(event: event)
        input.now = laterNow
        let alerts = AmbientAlerts.prioritized(input)
        #expect(alerts.first { $0.id == "event.today.e" }?.role == .world)
    }

    @Test func dismissedAlertsStayHidden() {
        let alerts = AmbientAlerts.prioritized(snapshot(exitAdvice: rain, weather: sunny), dismissed: ["exit.advice"])
        #expect(alerts.first?.id == "weather")
    }

    @Test func calibrationOnlyMattersWhileGuiding() {
        let guidance = AlertSnapshot.Guidance(target: target, distanceMeters: nil, needsCalibration: true)
        let alerts = AmbientAlerts.prioritized(snapshot(guidance: guidance))
        #expect(alerts.first?.id == "guidance.calibrate")
        #expect(alerts.contains { $0.id == "guidance" && $0.detail == "Finding your location…" })
    }

    @Test func onlyNewlyRaisedAlertsNotify() {
        let alerts = AmbientAlerts.prioritized(snapshot(exitAdvice: rain, weather: sunny))
        let first = AmbientAlerts.notifiable(previous: [], current: alerts)
        #expect(first.map(\.id) == ["exit.advice"])

        // The world doesn't get a notification, and the same advice never repeats.
        let announced = AmbientAlerts.announcedIDs(alerts)
        #expect(announced == ["exit.advice"])
        #expect(AmbientAlerts.notifiable(previous: announced, current: alerts).isEmpty)
    }

    @Test func anAlertThatReturnsLaterNotifiesAgain() {
        let quiet = AmbientAlerts.prioritized(snapshot(weather: sunny))
        let announced = AmbientAlerts.announcedIDs(quiet)
        #expect(announced.isEmpty)

        let rainy = AmbientAlerts.prioritized(snapshot(exitAdvice: rain, weather: sunny))
        #expect(AmbientAlerts.notifiable(previous: announced, current: rainy).map(\.id) == ["exit.advice"])
    }

    @Test func theIslandRestsOnItsNameWhenThereIsNoNews() {
        #expect(AmbientAlerts.isQuiet(AmbientAlerts.prioritized(snapshot())))
        #expect(AmbientAlerts.isQuiet(AmbientAlerts.prioritized(snapshot(weather: sunny))))
    }

    @Test func anythingWorthAGlanceTakesTheNamesPlace() {
        #expect(!AmbientAlerts.isQuiet(AmbientAlerts.prioritized(snapshot(exitAdvice: rain, weather: sunny))))
        #expect(!AmbientAlerts.isQuiet(AmbientAlerts.prioritized(snapshot(location: .notDetermined, weather: sunny))))
        let guidance = AlertSnapshot.Guidance(target: target, distanceMeters: 184, needsCalibration: false)
        #expect(!AmbientAlerts.isQuiet(AmbientAlerts.prioritized(snapshot(guidance: guidance, weather: sunny))))

        // A plan later today is news, even though it is only information.
        var calendar = Calendar.current
        calendar.timeZone = .current
        let evening = calendar.date(bySettingHour: 23, minute: 30, second: 0, of: now) ?? now
        var input = snapshot(event: AlertSnapshot.Event(id: "e", title: "Late show", start: evening), weather: sunny)
        input.now = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        #expect(!AmbientAlerts.isQuiet(AmbientAlerts.prioritized(input)))
    }

    @Test func idleIsAlwaysLast() {
        let alerts = AmbientAlerts.prioritized(snapshot())
        #expect(alerts.map(\.id) == ["idle"])
        #expect(AmbientAlerts.prioritized(snapshot(weather: sunny)).last?.id == "idle")
    }

    // MARK: Leaving on time

    private func departure(_ status: LeaveOnTime.Status, onTheWay: Bool = false) -> AlertSnapshot.Departure {
        .init(id: "class:1", title: "Physics", placeName: "BMS College", start: now.addingTimeInterval(3_600),
              travelMinutes: 25, byRoad: true, status: status, isOnTheWay: onTheWay, latitude: 12.94, longitude: 77.56)
    }

    @Test func leavingSoonIsAQuietGreenNote() {
        let alert = AmbientAlerts.departureAlert(departure(.leaveSoon(leaveBy: now.addingTimeInterval(1_500))))
        #expect(alert?.role == .you)
        #expect(alert?.detail.hasPrefix("25 min by road to BMS College") == true)
    }

    @Test func timeToGoAndRunningLateAskForAttention() {
        let go = AmbientAlerts.departureAlert(departure(.leaveNow(leaveBy: now)))
        #expect(go?.role == .attention)
        #expect(go?.buttons.map(\.title) == ["Point me there", "Book a cab"])

        let late = AmbientAlerts.departureAlert(departure(.late(arrival: now.addingTimeInterval(4_320), minutes: 12)))
        #expect(late?.metric == "+12 min")
        #expect(late?.headline == "You'll be about 12 min late for Physics")
    }

    /// Getting closer in good time needs no reminder; running late does, even on the way.
    @Test func onTheWayItOnlySpeaksUpIfYoureLate() {
        #expect(AmbientAlerts.departureAlert(departure(.leaveNow(leaveBy: now), onTheWay: true)) == nil)
        #expect(AmbientAlerts.departureAlert(departure(.late(arrival: now, minutes: 5), onTheWay: true)) != nil)
        #expect(AmbientAlerts.departureAlert(departure(.there)) == nil)
    }

    /// Far too late and not moving, it stops saying "you'll be late" and asks instead, with the
    /// answer on the alert itself.
    @Test func farTooLateItAsksWhetherYoureStillGoing() {
        var asking = departure(.late(arrival: now.addingTimeInterval(5_400), minutes: 35))
        asking.isAskingToDrop = true
        let alert = AmbientAlerts.departureAlert(asking)
        #expect(alert?.id == "leave.drop.class:1")
        #expect(alert?.headline == "Still going to Physics?")
        #expect(alert?.buttons.map(\.action) == [.dropDeparture("class:1"), .keepDeparture("class:1")])
    }

    /// Something from your mail you haven't added, or anything else already at hand, gets no
    /// "Point me there": an event you're standing at has nothing to point to.
    @Test func noPointerToWhereYouAlreadyAre() {
        let soon = now.addingTimeInterval(600)
        let here = AmbientAlerts.prioritized(snapshot(event: AlertSnapshot.Event(
            id: "event:1", title: "Episode 6", start: soon, latitude: 12.9, longitude: 77.5, distanceMeters: 20)))
        #expect(here.first { $0.id == "event.soon.event:1" }?.buttons.isEmpty == true)
        let away = AmbientAlerts.prioritized(snapshot(event: AlertSnapshot.Event(
            id: "event:1", title: "Episode 6", start: soon, latitude: 12.9, longitude: 77.5, distanceMeters: 4_000)))
        #expect(away.first { $0.id == "event.soon.event:1" }?.buttons.map(\.title) == ["Point me there"])
    }

    /// The way you're making leads the island: quietly while it's going to plan, and for
    /// attention once you've fallen behind it.
    @Test func thePlanYoureFollowingLeadsUntilYouBoard() {
        var snapshot = snapshot()
        snapshot.way = AlertSnapshot.Way(
            destination: "BMS College",
            headline: "Take an auto to Jayadeva Hospital",
            detail: "2.4 km · about 30 min to go",
            symbol: "car.rear.fill",
            minutesBehind: 0,
            minutesRemaining: 30,
            target: CompassTarget(id: "way", name: "Jayadeva Hospital", latitude: 12.9167, longitude: 77.6004)
        )
        let calm = AmbientAlerts.prioritized(snapshot)
        #expect(calm.first?.id == "way")
        #expect(calm.first?.role == .you)
        // On the island: when you'll get there, which the turn banner doesn't say.
        #expect(calm.first?.compactText.hasPrefix("Arrive ") == true)

        // Traffic Apple Maps reports makes it worth a look, before any leg is missed.
        snapshot.way?.trafficNote = "Heavy traffic · +7 min"
        snapshot.way?.isTrafficSlow = true
        let slow = AmbientAlerts.prioritized(snapshot)
        #expect(slow.first?.compactText == "Heavy traffic · +7 min")
        #expect(slow.first?.role == .attention)
        snapshot.way?.trafficNote = nil
        snapshot.way?.isTrafficSlow = false

        snapshot.way?.minutesBehind = 12
        let late = AmbientAlerts.prioritized(snapshot)
        #expect(late.first?.id == "way")
        #expect(late.first?.role == .attention)
        #expect(late.first?.buttons.contains { $0.action == .endWay } == true)

        // On the train, the ride's own alert says where to get off, so the way stands aside.
        snapshot.journey = AlertSnapshot.Journey(destination: "MG Road", lineName: "Purple Line",
                                                 stopsRemaining: 4, minutesRemaining: 9, isArrivingNext: false)
        #expect(!AmbientAlerts.prioritized(snapshot).contains { $0.id == "way" })
    }
}
