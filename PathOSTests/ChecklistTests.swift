import Foundation
import Testing
@testable import PathOS

@Suite("Reminders read from text")
struct ChecklistTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    /// Monday 28 September 2026, a quarter to ten in the morning.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 9, minute: 45))!
    }

    private var today: Date { calendar.startOfDay(for: now) }

    private func read(_ text: String, on day: Date? = nil) -> [Checklist.Draft] {
        Checklist.drafts(in: text, on: day ?? today, now: now, calendar: calendar)
    }

    private func clock(_ date: Date?) -> String? {
        date.map {
            let parts = calendar.dateComponents([.hour, .minute], from: $0)
            return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
    }

    // MARK: A list

    @Test func aListIsOneReminderALine() {
        let drafts = read("""
        - Buy milk
        • Call the bank at 4 pm
        3. Submit DBMS assignment
        """)
        #expect(drafts.map(\.title) == ["Buy milk", "Call the bank", "Submit DBMS assignment"])
        #expect(drafts.allSatisfy { $0.day == today })
        #expect(drafts.map { clock($0.dueAt) } == [nil, "16:00", nil])
    }

    @Test func tickedItemsComeInDone() {
        let drafts = read("[x] Book tickets\n[ ] Pack bag\n✓ Pay rent")
        #expect(drafts.map(\.title) == ["Book tickets", "Pack bag", "Pay rent"])
        #expect(drafts.map(\.isDone) == [true, false, true])
    }

    @Test func blankLinesAndBareMarkersAreNothing() {
        #expect(read("\n\n  - \n•\n").isEmpty)
    }

    // MARK: When

    @Test func timesAreTakenOutOfTheTitle() {
        let drafts = read("Remind me to call mom at 6:30 pm\nGym 7am")
        #expect(drafts.map(\.title) == ["Call mom", "Gym"])
        #expect(drafts.map { clock($0.dueAt) } == ["18:30", "07:00"])
    }

    /// "at 6" is how people write it. One to seven is the afternoon, eight to eleven the morning.
    @Test func aBareHourIsTheWakingOne() {
        #expect(clock(read("Call mom at 6").first?.dueAt) == "18:00")
        #expect(clock(read("Standup by 10").first?.dueAt) == "10:00")
        #expect(clock(read("Lunch at 12").first?.dueAt) == "12:00")
        // Numbers that aren't hours stay in the title.
        #expect(read("Run 5 km").first?.dueAt == nil)
        #expect(read("Buy 2 at 50").first?.title == "Buy 2 at 50")
    }

    @Test func relativeDays() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let drafts = read("Pay electricity bill tomorrow\nReturn books day after tomorrow\nWater plants today")
        #expect(drafts.map(\.title) == ["Pay electricity bill", "Return books", "Water plants"])
        #expect(drafts[0].day == tomorrow)
        #expect(drafts[1].day == calendar.date(byAdding: .day, value: 2, to: today))
        #expect(drafts[2].day == today)
    }

    @Test func weekdaysAreTheNextOne() {
        // Today is a Monday: Friday is in four days, and "on Monday" is next week's.
        let friday = read("Submit report by Friday").first
        #expect(friday?.title == "Submit report")
        #expect(friday?.day == calendar.date(byAdding: .day, value: 4, to: today))
        #expect(read("Haircut on Monday").first?.day == calendar.date(byAdding: .day, value: 7, to: today))
        #expect(read("Call on sat").first?.day == calendar.date(byAdding: .day, value: 5, to: today))
    }

    /// Words that start like a day, and short day names used as words, are not days.
    @Test func notEveryDayishWordIsADay() {
        #expect(read("Buy sunscreen").first?.day == today)
        #expect(read("Buy sunscreen").first?.title == "Buy sunscreen")
        #expect(read("Fix the chair I sat on").first?.day == today)
        #expect(read("Get married wed").first?.day == today)
    }

    @Test func aWrittenDateIsUsed() {
        let draft = read("Renew passport 5 Oct").first
        #expect(draft?.title == "Renew passport")
        #expect(draft?.day == calendar.date(from: DateComponents(year: 2026, month: 10, day: 5)))
    }

    /// Added from another day's list, a line that doesn't say is for that day.
    @Test func withoutADayItsTheDayBeingAddedTo() {
        let thursday = calendar.date(byAdding: .day, value: 3, to: today)!
        #expect(read("Buy flowers", on: thursday).first?.day == thursday)
        #expect(clock(read("Buy flowers at 5 pm", on: thursday).first?.dueAt) == "17:00")
    }

    // MARK: List or prose

    @Test func aListLooksLikeAList() {
        #expect(Checklist.looksLikeList("Buy milk\nCall mom"))
        #expect(Checklist.looksLikeList("Buy milk"))
        #expect(!Checklist.looksLikeList(String(repeating: "Can you please remember to pick up the laundry ", count: 3)))
    }

    // MARK: The day's list

    @Test func openFirstThenTimedThenTheRest() {
        let early = now.addingTimeInterval(3_600)
        let late = now.addingTimeInterval(7_200)
        let made = Date(timeIntervalSince1970: 0)
        let items: [(dueAt: Date?, done: Bool, created: Date)] = [
            (nil, true, made), (late, false, made), (nil, false, made.addingTimeInterval(5)),
            (early, false, made), (nil, false, made),
        ]
        let order = items.indices.sorted { Checklist.isBefore(items[$0], items[$1]) }
        #expect(order == [3, 1, 4, 2, 0])
    }

    @Test func undoneYesterdayIsCarriedToToday() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        #expect(Checklist.isCarriedOver(day: yesterday, isDone: false, today: now, calendar: calendar))
        #expect(!Checklist.isCarriedOver(day: yesterday, isDone: true, today: now, calendar: calendar))
        #expect(!Checklist.isCarriedOver(day: today, isDone: false, today: now, calendar: calendar))
    }
}

@Suite("Marking things done")
struct CompletionTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// The reason to say it's done: it took forty minutes of the hour.
    @Test func earlyIsSaid() {
        let note = Completion.note(start: start, plannedEnd: start.addingTimeInterval(3_600),
                                   doneAt: start.addingTimeInterval(40 * 60))
        #expect(note.hasSuffix("· took 40 min, 20 min early"))
        #expect(note.hasPrefix("Done at "))
    }

    @Test func onTimeIsJustHowLong() {
        let note = Completion.note(start: start, plannedEnd: start.addingTimeInterval(3_600),
                                   doneAt: start.addingTimeInterval(58 * 60))
        #expect(note.hasSuffix("· took 58 min"))
    }

    @Test func aDeadlineIsJustWhen() {
        let note = Completion.note(start: start, plannedEnd: start, doneAt: start.addingTimeInterval(600))
        #expect(!note.contains("took"))
    }

    /// Marked done after it's over, it finished when it was meant to; before it began, it can't be.
    @Test func finishingIsHeldToTheEvent() {
        let end = start.addingTimeInterval(3_600)
        #expect(Completion.finishedAt(start: start, plannedEnd: end, now: start.addingTimeInterval(1_200)) == start.addingTimeInterval(1_200))
        #expect(Completion.finishedAt(start: start, plannedEnd: end, now: end.addingTimeInterval(20 * 3_600)) == end)
        #expect(!Completion.canFinish(start: start, plannedEnd: end, now: start.addingTimeInterval(-60)))
        #expect(Completion.canFinish(start: start, plannedEnd: end, now: start))
        // Once its time is up it's over, said or not.
        #expect(!Completion.canFinish(start: start, plannedEnd: end, now: end))
    }

    @Test func durationsReadNaturally() {
        #expect(Completion.duration(40 * 60) == "40 min")
        #expect(Completion.duration(3_600) == "1 h")
        #expect(Completion.duration(70 * 60) == "1 h 10 min")
    }
}
