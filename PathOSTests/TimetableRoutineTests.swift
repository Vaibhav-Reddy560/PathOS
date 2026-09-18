import Foundation
import Testing
@testable import PathOS

struct TimetableRoutineTests {
    private let calendar = Calendar.current
    /// A Thursday.
    private let thursday = Date(timeIntervalSince1970: 1_800_000_000)

    private func slot(_ subject: String, weekday: Int, from start: Int, to end: Int, id: UUID = UUID()) -> TimetableSlot {
        TimetableSlot(id: id, subject: subject, weekday: weekday, startMinutes: start, endMinutes: end, room: "304", teacher: nil)
    }

    private var thursdayWeekday: Int { calendar.component(.weekday, from: thursday) }

    @Test func classesComeOutInOrderForTheRightDay() {
        let today = [
            slot("Networks", weekday: thursdayWeekday, from: 11 * 60, to: 12 * 60),
            slot("DBMS", weekday: thursdayWeekday, from: 9 * 60, to: 10 * 60),
        ]
        let otherDay = [slot("Maths", weekday: thursdayWeekday == 7 ? 1 : thursdayWeekday + 1, from: 9 * 60, to: 10 * 60)]

        let sessions = TimetableRoutine.sessions(slots: today + otherDay, on: thursday, calendar: calendar)
        #expect(sessions.map(\.subject) == ["DBMS", "Networks"])
        #expect(calendar.component(.hour, from: sessions[0].start) == 9)
    }

    @Test func aDayOffClearsEverything() {
        let slots = [slot("DBMS", weekday: thursdayWeekday, from: 9 * 60, to: 10 * 60)]
        let holiday = TimetableSkip(dayStart: calendar.startOfDay(for: thursday), entryID: nil, reason: "Holiday")
        #expect(TimetableRoutine.sessions(slots: slots, skips: [holiday], on: thursday, calendar: calendar).isEmpty)
    }

    @Test func oneCancelledClassLeavesTheRest() {
        let cancelledID = UUID()
        let slots = [
            slot("DBMS", weekday: thursdayWeekday, from: 9 * 60, to: 10 * 60, id: cancelledID),
            slot("Networks", weekday: thursdayWeekday, from: 11 * 60, to: 12 * 60),
        ]
        let skip = TimetableSkip(dayStart: calendar.startOfDay(for: thursday), entryID: cancelledID, reason: "Cancelled")
        let sessions = TimetableRoutine.sessions(slots: slots, skips: [skip], on: thursday, calendar: calendar)
        #expect(sessions.map(\.subject) == ["Networks"])
    }

    @Test func aClassMovedForOneDayKeepsItsPlaceInTheWeek() {
        let movedID = UUID()
        let slots = [
            slot("DBMS", weekday: thursdayWeekday, from: 9 * 60, to: 10 * 60, id: movedID),
            slot("Networks", weekday: thursdayWeekday, from: 11 * 60, to: 12 * 60),
        ]
        let move = TimetableSkip(dayStart: calendar.startOfDay(for: thursday), entryID: movedID, reason: "Moved",
                                 startMinutesOverride: 14 * 60, endMinutesOverride: 15 * 60, roomOverride: "Lab 2")
        let sessions = TimetableRoutine.sessions(slots: slots, skips: [move], on: thursday, calendar: calendar)
        #expect(sessions.map(\.subject) == ["Networks", "DBMS"])
        #expect(calendar.component(.hour, from: sessions[1].start) == 14)
        #expect(sessions[1].room == "Lab 2")
        #expect(sessions[1].isMoved)
        #expect(!sessions[0].isMoved)

        // Next week it's back at nine.
        let nextWeek = thursday.addingTimeInterval(7 * 86_400)
        let later = TimetableRoutine.sessions(slots: slots, skips: [move], on: nextWeek, calendar: calendar)
        #expect(later.first?.subject == "DBMS")
        #expect(calendar.component(.hour, from: later[0].start) == 9)
    }

    @Test func aRoomChangeAloneKeepsTheTime() {
        let id = UUID()
        let slots = [slot("DBMS", weekday: thursdayWeekday, from: 9 * 60, to: 10 * 60, id: id)]
        let relocation = TimetableSkip(dayStart: calendar.startOfDay(for: thursday), entryID: id, reason: "Moved", roomOverride: "Seminar Hall")
        let session = TimetableRoutine.sessions(slots: slots, skips: [relocation], on: thursday, calendar: calendar).first
        #expect(session?.room == "Seminar Hall")
        #expect(session.map { calendar.component(.hour, from: $0.start) } == 9)
        #expect(session.map { $0.end.timeIntervalSince($0.start) } == 3_600)
    }

    @Test func currentAndNextTrackTheClock() {
        let slots = [
            slot("DBMS", weekday: thursdayWeekday, from: 9 * 60, to: 10 * 60),
            slot("Networks", weekday: thursdayWeekday, from: 11 * 60, to: 12 * 60),
        ]
        let sessions = TimetableRoutine.sessions(slots: slots, on: thursday, calendar: calendar)
        let duringFirst = calendar.startOfDay(for: thursday).addingTimeInterval(9.5 * 3_600)

        #expect(TimetableRoutine.current(in: sessions, now: duringFirst)?.subject == "DBMS")
        #expect(TimetableRoutine.next(in: sessions, now: duringFirst)?.subject == "Networks")
        #expect(TimetableRoutine.minutesRemaining(in: sessions[0], now: duringFirst) == 30)
    }

    @Test func timesAreReadTheWayTimetablesWriteThem() {
        #expect(TimetableRoutine.minutes(fromTime: "09:00") == 540)
        #expect(TimetableRoutine.minutes(fromTime: "9:55") == 595)
        #expect(TimetableRoutine.minutes(fromTime: "9.30") == 570)
        #expect(TimetableRoutine.minutes(fromTime: "2:00 pm") == 840)
        #expect(TimetableRoutine.minutes(fromTime: "12:30 am") == 30)
        // Afternoon classes are often written bare: "1:00" means 13:00 on a college timetable.
        #expect(TimetableRoutine.minutes(fromTime: "1:00") == 780)
        #expect(TimetableRoutine.minutes(fromTime: "rubbish") == nil)
    }

    @Test func generatedWeekdaysMapToCalendarNumbers() {
        #expect(TimetableService.weekday(from: .sunday) == 1)
        #expect(TimetableService.weekday(from: .monday) == 2)
        #expect(TimetableService.weekday(from: .saturday) == 7)
    }
}
