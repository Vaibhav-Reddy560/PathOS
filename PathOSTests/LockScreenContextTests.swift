import Foundation
import Testing
@testable import PathOS

/// The pinned context on the Lock Screen: what leads, what follows, and when it next needs
/// redrawing, since iOS won't wake PathOS on the minute to do it.
struct LockScreenContextTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    /// Thursday 17 September 2026 in Bengaluru.
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: hour, minute: minute))!
    }

    private func lesson(_ title: String, _ start: Date, _ end: Date, room: String? = nil) -> LockScreenContext.Entry {
        .init(id: title, title: title, place: room, start: start, end: end, symbol: "graduationcap.fill")
    }

    private let dry = AlertSnapshot.Weather(temperatureC: 24, summary: "Cloudy", symbol: "cloud.fill", rainChanceNext2h: 10)
    private let wet = AlertSnapshot.Weather(temperatureC: 22, summary: "Showers", symbol: "cloud.rain.fill", rainChanceNext2h: 70)
    private let rain = ExitAdvice(headline: "Rain likely — take an umbrella", detail: "There's a 70% chance of rain in the next 2 hours.",
                                  symbol: "cloud.rain.fill", severity: .medium)

    private func content(
        now: Date,
        agenda: [LockScreenContext.Entry] = [],
        weather: AlertSnapshot.Weather? = nil,
        advice: ExitAdvice? = nil,
        commute: LockScreenContext.Commute? = nil,
        memory: LockScreenContext.Memory? = nil
    ) -> LockScreenContext.Content {
        LockScreenContext.content(for: .init(
            venueName: "Home", venueSymbol: "house.fill", weather: weather ?? dry, exitAdvice: advice,
            agenda: agenda, commute: commute, memory: memory, now: now, calendar: calendar
        ))
    }

    @Test func aClassStartingWithinTheHourLeadsAndCountsDownToItsStart() {
        let physics = lesson("Physics", at(11, 15), at(12, 10), room: "LH-3")
        let shown = content(now: at(10, 40), agenda: [physics])
        #expect(shown.state.title == "Physics")
        #expect(shown.state.subtitle.hasSuffix("\nLH-3"))
        #expect(shown.state.startDate == physics.start)
        #expect(shown.state.endDate == physics.end)
        #expect(shown.state.tint == .attention)
        // Redrawn at the start, when the Lock Screen turns the countdown into the time left.
        #expect(shown.staleDate == physics.start)
        #expect(shown.state.timing(at: at(10, 40)) == .startsIn(physics.start))
        #expect(shown.state.timing(at: at(11, 30)) == .endsIn(start: physics.start, end: physics.end))
        #expect(shown.state.timing(at: at(12, 30)) == .over)
    }

    @Test func aClassUnderWayLeadsUntilItEnds() {
        let physics = lesson("Physics", at(11, 15), at(12, 10))
        let shown = content(now: at(11, 30), agenda: [physics])
        #expect(shown.state.title == "Physics")
        #expect(shown.state.tint == .you)
        #expect(shown.staleDate == physics.end)
    }

    @Test func nearTheEndTheNextClassTakesOver() {
        let physics = lesson("Physics", at(11, 15), at(12, 10))
        let maths = lesson("Maths", at(12, 15), at(13, 10), room: "204")
        // Twenty minutes left: Physics still leads, and Maths is next.
        let during = content(now: at(11, 50), agenda: [physics, maths])
        #expect(during.state.title == "Physics")
        #expect(during.state.notes?.contains { $0.text.hasPrefix("Next: Maths at") && $0.text.hasSuffix("· 204") } == true)
        // Five minutes left, and Maths starts in ten: Maths leads.
        #expect(content(now: at(12, 5), agenda: [physics, maths]).state.title == "Maths")
    }

    @Test func laterClassesWaitAsANoteAndRedrawWhenTheyComeClose() {
        let lab = lesson("Chemistry lab", at(14), at(16))
        let shown = content(now: at(9), agenda: [lab])
        #expect(shown.state.title == "Home")
        #expect(shown.state.startDate == nil)
        #expect(shown.state.notes?.first?.text.hasPrefix("Next: Chemistry lab at") == true)
        #expect(shown.staleDate == at(9).addingTimeInterval(LockScreenContext.longestStale))
        // Within the hour's redraw window, it's redrawn exactly when the lab would lead.
        #expect(content(now: at(12, 30), agenda: [lab]).staleDate == at(13))
    }

    @Test func rainLeadsWhenNothingElseDoes() {
        let shown = content(now: at(9), weather: wet, advice: rain)
        #expect(shown.state.title == "Take an umbrella")
        #expect(shown.state.tint == .attention)
        #expect(shown.state.notes == nil)
    }

    @Test func rainIsANoteWhenAClassLeads() {
        let physics = lesson("Physics", at(9, 30), at(10, 30))
        let shown = content(now: at(9), agenda: [physics], weather: wet, advice: rain)
        #expect(shown.state.title == "Physics")
        #expect(shown.state.notes?.first == .init(symbol: "umbrella.fill", text: "Take an umbrella · 70% rain in 2 h", role: .attention))
    }

    /// Odds alone don't mean an umbrella: that's the exit check's call, which also weighs how much
    /// rain is expected and what stations report.
    @Test func highOddsWithoutAdviceAreNoUmbrella() {
        #expect(content(now: at(9), weather: wet).state.title == "Home")
    }

    @Test func dryAndFreeItShowsWhereYouAre() {
        let shown = content(now: at(9))
        #expect(shown.state.title == "Home")
        #expect(shown.state.subtitle == "Cloudy · 24°C · 10% rain")
        #expect(shown.state.tint == .world)
    }

    @Test func theTravelTimeShowsAroundWhenYouUsuallyLeave() {
        let commute = LockScreenContext.Commute(destination: "Work", minutes: 35, mode: .car, usualDeparture: 9 * 60 + 10)
        let note = PathOSActivityAttributes.Note(symbol: "car.fill", text: "Work: 35 min by car", role: .you)
        #expect(content(now: at(8), commute: commute).state.notes == [note])
        #expect(content(now: at(9, 50), commute: commute).state.notes == [note])
        #expect(content(now: at(6), commute: commute).state.notes == nil)
        #expect(content(now: at(11), commute: commute).state.notes == nil)
    }

    @Test func aNoteYouLeftHereLeadsUnlessAClassDoes() {
        let memory = LockScreenContext.Memory(title: "Parked at B2, pillar 14", body: "")
        let shown = content(now: at(9), memory: memory)
        #expect(shown.state.title == "Parked at B2, pillar 14")
        #expect(shown.state.subtitle == "You left a note here")

        let physics = lesson("Physics", at(9, 15), at(10))
        let busy = content(now: at(9), agenda: [physics], memory: memory)
        #expect(busy.state.title == "Physics")
        #expect(busy.state.notes?.first?.text == "Parked at B2, pillar 14")
    }

    @Test func finishedAndTomorrowsClassesAreLeftOut() {
        let done = lesson("Physics", at(8), at(9))
        let tomorrow = lesson("Maths", at(9).addingTimeInterval(86_400), at(10).addingTimeInterval(86_400))
        let shown = content(now: at(9, 30), agenda: [done, tomorrow])
        #expect(shown.state.title == "Home")
        #expect(shown.state.notes == nil)
    }

    @Test func neverMoreThanTwoNotes() {
        let physics = lesson("Physics", at(9, 15), at(10))
        let maths = lesson("Maths", at(10, 15), at(11))
        let commute = LockScreenContext.Commute(destination: "Work", minutes: 35, mode: .car, usualDeparture: 9 * 60)
        let shown = content(now: at(9), agenda: [physics, maths], weather: wet, advice: rain, commute: commute,
                            memory: .init(title: "Locker 12", body: ""))
        #expect(shown.state.notes?.count == 2)
    }

    @Test func aDeadlineCountsDownToWhenItsDue() {
        let essay = LockScreenContext.Entry(id: "essay", title: "Essay due", start: at(17), end: at(17), symbol: "calendar", role: .world)
        let shown = content(now: at(16, 30), agenda: [essay])
        #expect(shown.state.title == "Essay due")
        #expect(shown.state.subtitle.hasPrefix("Due "))
        #expect(shown.staleDate == at(17))
        #expect(content(now: at(17, 5), agenda: [essay]).state.title == "Home")
    }

    @Test func whenToLeaveIsTheFirstNote() {
        let physics = lesson("Physics", at(9), at(10), room: "LH-3")
        let leave = AlertSnapshot.Departure(id: "Physics", title: "Physics", placeName: "BMS College", start: at(9), travelMinutes: 25,
                                            byRoad: true, status: .leaveNow(leaveBy: at(8, 30)), isOnTheWay: false, latitude: 12.94, longitude: 77.56)
        let shown = LockScreenContext.content(for: .init(
            venueName: "Home", venueSymbol: "house.fill", weather: dry, exitAdvice: nil,
            agenda: [physics], departure: leave, now: at(8, 31), calendar: calendar
        ))
        #expect(shown.state.notes?.first?.text == "Leave now · 25 min by road to BMS College")
        #expect(shown.state.notes?.first?.role == .attention)
    }
}
