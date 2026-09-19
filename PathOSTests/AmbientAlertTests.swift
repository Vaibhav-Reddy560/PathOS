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
}
