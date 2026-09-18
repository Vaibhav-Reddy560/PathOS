import Foundation
import Testing
@testable import PathOS

struct ChangeRequestTests {
    private let calendar = Calendar.current
    /// 08:00 on 15 January 2027.
    private var now: Date {
        calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
    }
    private var today: Date { calendar.startOfDay(for: now) }
    private let slotID = UUID()
    private let eventID = UUID()

    private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        today.addingTimeInterval(Double(dayOffset * 86_400 + hour * 3_600 + minute * 60))
    }

    private var candidates: [ChangeCandidate] {
        [
            ChangeCandidate(id: "c1", kind: .classSession, targetID: slotID, title: "DBMS", start: at(15), end: at(15, 55), place: "304"),
            ChangeCandidate(id: "e1", kind: .event, targetID: eventID, title: "Dinner with Priya", start: at(20), end: at(21, 30)),
        ]
    }

    private func iso(dayOffset: Int) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: today.addingTimeInterval(Double(dayOffset) * 86_400))
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    // MARK: Routing

    @Test func changesAreToldApartFromQuestions() {
        #expect(ChangeIntent.looksLikeChange("Move my 3pm class to 4pm"))
        #expect(ChangeIntent.looksLikeChange("cancel Thursday's lab"))
        #expect(ChangeIntent.looksLikeChange("No classes on Monday, it's a holiday"))
        #expect(ChangeIntent.looksLikeChange("Can you push dinner to 9?"))
        #expect(!ChangeIntent.looksLikeChange("Is my lab cancelled?"))
        #expect(!ChangeIntent.looksLikeChange("Top cafés within a 5-minute walk"))
        #expect(!ChangeIntent.looksLikeChange("Where did I park?"))
    }

    // MARK: Planning

    @Test func movingOnlyTheStartKeepsTheLength() {
        let reading = ChangeReadingValues(action: .move, itemID: "c1", startTime: "16:00", scope: .unspecified)
        guard case let .proposal(.moveClass(id, subject, room, from, to, everyWeek)) = ChangePlanner.plan(reading, candidates: candidates, now: now, calendar: calendar) else {
            Issue.record("Expected a class move")
            return
        }
        #expect(id == slotID)
        #expect(subject == "DBMS")
        #expect(room == "304")
        #expect(from.start == at(15))
        #expect(to.start == at(16))
        #expect(to.end == at(16, 55))
        // Unless you say "every week", a class moves just this once.
        #expect(!everyWeek)
    }

    @Test func everyWeekIsOnlyForClasses() {
        let weekly = ChangeReadingValues(action: .move, itemID: "c1", date: iso(dayOffset: 1), startTime: "10:00", scope: .everyWeek)
        #expect(ChangePlanner.plan(weekly, candidates: candidates, now: now, calendar: calendar).proposedChange?.everyWeek == true)

        let event = ChangeReadingValues(action: .move, itemID: "e1", startTime: "21:00", scope: .everyWeek)
        guard case let .proposal(.moveEvent(_, _, _, to)) = ChangePlanner.plan(event, candidates: candidates, now: now, calendar: calendar) else {
            Issue.record("Expected an event move")
            return
        }
        #expect(to.end.timeIntervalSince(to.start) == 90 * 60)
    }

    @Test func theModelCanOnlyPointAtRealThings() {
        let invented = ChangeReadingValues(action: .cancel, itemID: "c9")
        #expect(ChangePlanner.plan(invented, candidates: candidates, now: now, calendar: calendar).isNeeds)
        let cancel = ChangeReadingValues(action: .cancel, itemID: " C1 ", scope: .once)
        #expect(ChangePlanner.plan(cancel, candidates: candidates, now: now, calendar: calendar).proposedChange
                == .cancelClass(slotID: slotID, subject: "DBMS", at: DateInterval(start: at(15), end: at(15, 55)), everyWeek: false))
    }

    @Test func impossibleOrMissingTimesAreQuestionsBack() {
        let noTime = ChangeReadingValues(action: .move, itemID: "e1")
        #expect(ChangePlanner.plan(noTime, candidates: candidates, now: now, calendar: calendar) == .needs("Move Dinner with Priya to when?"))
        let past = ChangeReadingValues(action: .move, itemID: "e1", startTime: "07:00")
        #expect(ChangePlanner.plan(past, candidates: candidates, now: now, calendar: calendar).isNeeds)
        let backwards = ChangeReadingValues(action: .move, itemID: "e1", startTime: "21:00", endTime: "20:00")
        #expect(ChangePlanner.plan(backwards, candidates: candidates, now: now, calendar: calendar).isNeeds)
        let same = ChangeReadingValues(action: .move, itemID: "c1", startTime: "15:00")
        #expect(ChangePlanner.plan(same, candidates: candidates, now: now, calendar: calendar).isNeeds)
    }

    @Test func daysOffAndNewEvents() {
        let holiday = ChangeReadingValues(action: .dayOff, date: iso(dayOffset: 4))
        #expect(ChangePlanner.plan(holiday, candidates: candidates, now: now, calendar: calendar).proposedChange == .dayOff(day: at(0, dayOffset: 4)))
        let yesterday = ChangeReadingValues(action: .dayOff, date: iso(dayOffset: -1))
        #expect(ChangePlanner.plan(yesterday, candidates: candidates, now: now, calendar: calendar).isNeeds)

        let add = ChangeReadingValues(action: .add, date: iso(dayOffset: 1), startTime: "19:30", title: "Gym", place: "Cult Indiranagar")
        #expect(ChangePlanner.plan(add, candidates: candidates, now: now, calendar: calendar).proposedChange
                == .addEvent(title: "Gym", at: DateInterval(start: at(19, 30, dayOffset: 1), end: at(20, 30, dayOffset: 1)), place: "Cult Indiranagar"))
        #expect(ChangePlanner.plan(ChangeReadingValues(action: .add, startTime: "19:30"), candidates: candidates, now: now, calendar: calendar).isNeeds)
        #expect(ChangePlanner.plan(ChangeReadingValues(action: .none), candidates: candidates, now: now, calendar: calendar) == .notAChange)
    }

    @Test func onlyEventsAreRenamed() {
        let event = ChangeReadingValues(action: .rename, itemID: "e1", title: "Dinner at Toit")
        #expect(ChangePlanner.plan(event, candidates: candidates, now: now, calendar: calendar).proposedChange
                == .renameEvent(id: eventID, from: "Dinner with Priya", to: "Dinner at Toit"))
        let lesson = ChangeReadingValues(action: .rename, itemID: "c1", title: "Databases")
        #expect(ChangePlanner.plan(lesson, candidates: candidates, now: now, calendar: calendar).isNeeds)
    }

    @Test func theScheduleIsListedWithShortIDs() {
        let session = ClassSession(id: "s", slotID: slotID, subject: "DBMS", room: "304", teacher: nil, start: at(15), end: at(15, 55))
        let finished = ClassSession(id: "f", slotID: UUID(), subject: "Maths", room: nil, teacher: nil, start: at(6), end: at(7))
        let event = PlannedEvent(id: eventID, title: "Dinner", start: at(20), end: at(21), isAllDay: false, placeName: "Toit", latitude: nil, longitude: nil)
        let list = ChangePlanner.candidates(sessions: [session, finished], events: [event], legs: [], now: now)
        #expect(list.map(\.id) == ["c1", "e1"])
        #expect(list[0].line(calendar: calendar).hasPrefix("c1 | class | DBMS | "))
        #expect(list[0].line(calendar: calendar).contains("15:00–15:55 | 304"))
    }

    @Test func twentyFourHourTimesAreReadStrictly() {
        #expect(ChangePlanner.minutes(from24Hour: "16:00") == 960)
        // Unlike a timetable's "5:00", a 24-hour "05:00" is the morning.
        #expect(ChangePlanner.minutes(from24Hour: "05:00") == 300)
        #expect(ChangePlanner.minutes(from24Hour: "25:00") == nil)
        #expect(ChangePlanner.minutes(from24Hour: "4pm") == nil)
    }
}

private extension ChangeOutcome {
    var proposedChange: ProposedChange? {
        if case .proposal(let change) = self { return change }
        return nil
    }

    var isNeeds: Bool {
        if case .needs = self { return true }
        return false
    }
}
