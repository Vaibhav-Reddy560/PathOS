import Foundation
import Testing
@testable import PathOS

struct MailTriageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)  // 15 January 2027

    private func message(subject: String, body: String, snippet: String? = nil) -> MailMessage {
        MailMessage(
            id: "m1",
            threadID: "t1",
            subject: subject,
            senderName: "Priya",
            senderAddress: "priya@college.edu",
            receivedAt: now,
            snippet: snippet ?? String(body.prefix(100)),
            body: body,
            labels: ["INBOX"]
        )
    }

    // MARK: Rules, for when Apple Intelligence is off

    @Test func rulesFindADeadline() {
        let mail = message(subject: "DBMS assignment", body: "Submit your assignment by 20 January 2027 at 11:59 PM on the portal.")
        let proposal = MailTriage.heuristic(mail, now: now)
        #expect(proposal.kind == .task)
        #expect(proposal.start != nil)
        #expect(!proposal.usedAI)
    }

    @Test func rulesFindAnEvent() {
        let mail = message(subject: "Invitation: IEEE talk", body: "Join us for the workshop on 22 January 2027 at 2:00 PM in Seminar Hall 2.")
        #expect(MailTriage.heuristic(mail, now: now).kind == .event)
    }

    @Test func rulesKeepDatelessNewsAndSkipTheRest() {
        #expect(MailTriage.heuristic(message(subject: "Exam results are out", body: "Check the portal for your results."), now: now).kind == .update)
        #expect(MailTriage.heuristic(message(subject: "Your weekly digest", body: "Top stories from around the web."), now: now).kind == .ignore)
    }

    @Test func wordsMatchWholeWordsOnly() {
        #expect(MailTriage.mentions(["fest"], in: "Cultural fest this Friday"))
        #expect(!MailTriage.mentions(["fest"], in: "Package manifest updated"))
        #expect(!MailTriage.mentions(["due"], in: "Clear the residue"))
        #expect(MailTriage.mentions(["last date"], in: "LAST DATE to apply is Monday"))
    }

    // MARK: Tidying either reading

    @Test func somethingAlreadyOverIsNewsNotSomethingToSchedule() {
        let mail = message(subject: "Thanks for attending", body: "")
        let past = MailProposal(kind: .event, title: "Orientation", summary: "Thanks for coming.", start: now.addingTimeInterval(-3 * 3_600), usedAI: true)
        #expect(MailTriage.finalize(past, message: mail, now: now).kind == .update)

        let upcoming = MailProposal(kind: .event, title: "Orientation", summary: "", start: now.addingTimeInterval(3_600), usedAI: true)
        #expect(MailTriage.finalize(upcoming, message: mail, now: now).kind == .event)

        // An all-day deadline stays open until its day ends.
        let dueToday = MailProposal(kind: .task, title: "Pay fees", summary: "", start: Calendar.current.startOfDay(for: now), isAllDay: true, usedAI: true)
        #expect(MailTriage.finalize(dueToday, message: mail, now: now).kind == .task)
    }

    @Test func gapsAreFilledAndImpossibleTimesDropped() {
        let mail = message(subject: "Lab moved", body: "", snippet: "The DS lab moves to Friday.")
        let raw = MailProposal(kind: .event, title: "  ", summary: "", start: now.addingTimeInterval(7_200),
                               end: now.addingTimeInterval(3_600), place: "  ", usedAI: true)
        let result = MailTriage.finalize(raw, message: mail, now: now)
        #expect(result.title == "Lab moved")
        #expect(result.summary == "The DS lab moves to Friday.")
        #expect(result.end == nil)
        #expect(result.place == nil)
    }

    @Test func theModelsDatesKeepTheirMeaning() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))

        let timed = MailTriage.proposal(kind: .event, title: "Talk", summary: "", startISO: "2027-01-21T14:00",
                                        endISO: "2027-01-21T15:30", place: nil, calendar: calendar)
        let start = try #require(timed.start)
        #expect(!timed.isAllDay)
        #expect(calendar.component(.hour, from: start) == 14)
        #expect(timed.end?.timeIntervalSince(start) == 5_400)

        // A bare date is all day, not a midnight start.
        let dateOnly = MailTriage.proposal(kind: .task, title: "Fees", summary: "", startISO: "2027-01-25",
                                           endISO: nil, place: nil, calendar: calendar)
        #expect(dateOnly.isAllDay)
        #expect(dateOnly.start == calendar.date(from: DateComponents(year: 2027, month: 1, day: 25)))

        // The model is asked for local time; a zone it adds anyway mustn't shift the hour.
        let zoned = MailTriage.proposal(kind: .event, title: "Call", summary: "", startISO: "2027-01-21T14:00:00Z",
                                        endISO: nil, place: nil, calendar: calendar)
        #expect(zoned.start.map { calendar.component(.hour, from: $0) } == 14)

        #expect(MailTriage.proposal(kind: .update, title: "", summary: "", startISO: "soon", endISO: nil, place: nil).start == nil)
    }

    @Test func onlineMeetingsHaveNoPlaceToPointAt() {
        #expect(MailTriage.isOnline("Google Meet"))
        #expect(MailTriage.isOnline("Online (Zoom link below)"))
        #expect(!MailTriage.isOnline("Seminar Hall 2, RV College"))
    }

    // MARK: Your approval

    @Test func nothingIsSkippedOrAddedWithoutReason() {
        let mail = message(subject: "Fees", body: "")
        let task = MailSuggestion(message: mail, proposal: MailProposal(kind: .task, title: "Pay fees", summary: "Semester fees",
                                                                       start: now.addingTimeInterval(86_400), usedAI: true))
        #expect(task.status == .pending)
        #expect(task.canAddDirectly)
        // A task is a moment: it doesn't claim an hour of your day.
        #expect(MailService.end(for: task, start: now) == now)
        #expect(MailService.notes(for: task) == "Semester fees\n\nFrom Priya: “Fees”")

        let undated = MailSuggestion(message: mail, proposal: MailProposal(kind: .event, title: "Alumni meet", summary: "", usedAI: true))
        #expect(!undated.canAddDirectly)

        let noise = MailSuggestion(message: mail, proposal: MailProposal(kind: .ignore, title: "Digest", summary: "", usedAI: true))
        #expect(noise.status == .skipped)
    }
}
