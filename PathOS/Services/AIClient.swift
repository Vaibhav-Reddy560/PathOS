import Foundation
import FoundationModels
import Observation

@Generable
nonisolated enum GeneratedScanKind {
    case event
    case receipt
    case parking
    case note
}

@Generable
nonisolated enum GeneratedExpenseCategory {
    case food
    case groceries
    case transport
    case shopping
    case entertainment
    case bills
    case health
    case other
}

@Generable
nonisolated struct ScanExtraction {
    @Guide(description: "What the text is: an event poster, a purchase receipt, a parking location sign, or anything else as a note")
    var kind: GeneratedScanKind

    @Guide(description: "Short title: the event name, the merchant, or e.g. 'Parked at B2 · C-14'")
    var title: String

    @Guide(description: "One sentence with the most useful details")
    var summary: String

    @Guide(description: "Event start as local ISO 8601 without timezone, like 2026-09-21T20:00. Only for events.")
    var eventStartISO: String?

    @Guide(description: "Venue name for events")
    var venue: String?

    @Guide(description: "Merchant or shop name for receipts")
    var merchant: String?

    @Guide(description: "Final total paid on a receipt, as a plain number")
    var totalAmount: Double?

    @Guide(description: "Spending category for receipts")
    var expenseCategory: GeneratedExpenseCategory?

    @Guide(description: "Parking level, pillar, slot or bay identifiers, e.g. 'B2 · C-14'")
    var parkingLabel: String?
}

@Generable
nonisolated struct EventRow {
    @Guide(description: "The event or session's name, without its time or place")
    var title: String

    @Guide(description: "Its date as yyyy-MM-dd")
    var date: String

    @Guide(description: "Start time, 24-hour HH:mm")
    var startTime: String

    @Guide(description: "End time, 24-hour HH:mm, only if the text gives one")
    var endTime: String?

    @Guide(description: "The venue, hall or room, only if the text gives one")
    var place: String?
}

@Generable
nonisolated struct EventListExtraction {
    @Guide(description: "Every event in the text: one per session, per day it happens")
    var events: [EventRow]
}

@Generable
nonisolated struct TaskRow {
    @Guide(description: "The thing to do, short and plain, starting with a verb, without its date or time: 'Call the bank', 'Buy milk'")
    var title: String

    @Guide(description: "The day it's for as yyyy-MM-dd, only if the text gives or implies one, like 'tomorrow' or 'Friday'")
    var date: String?

    @Guide(description: "The time it's due, 24-hour HH:mm, only if the text gives one")
    var time: String?

    @Guide(description: "True only if the text shows it already done, ticked or struck through")
    var isDone: Bool
}

@Generable
nonisolated struct TaskListExtraction {
    @Guide(description: "Every separate thing to do in the text, one per task", .maximumCount(30))
    var tasks: [TaskRow]
}

@Generable
nonisolated struct VibePick {
    @Guide(description: "The item's id, copied exactly from the list")
    var itemID: String

    @Guide(description: "A punchy headline under 8 words")
    var headline: String

    @Guide(description: "One short sentence on why it suits right now")
    var reason: String
}

@Generable
nonisolated struct VibeStream {
    @Guide(description: "The best picks, best first", .maximumCount(8))
    var picks: [VibePick]
}

nonisolated struct VibeCandidate: Sendable {
    var id: String
    /// Compact one-line description fed to the model.
    var line: String
}

@Generable
nonisolated enum GeneratedWeekday {
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case sunday
}

@Generable
nonisolated struct TimetableRow {
    @Guide(description: "Subject or class name, e.g. 'DBMS' or 'Data Structures Lab'")
    var subject: String

    @Guide(description: "Which day of the week this class is on")
    var day: GeneratedWeekday

    @Guide(description: "Start time in 24-hour HH:mm, e.g. 09:00")
    var startTime: String

    @Guide(description: "End time in 24-hour HH:mm, e.g. 09:55")
    var endTime: String

    @Guide(description: "Room, block or lab, if the timetable says")
    var room: String?

    @Guide(description: "Teacher or faculty name, if the timetable says")
    var teacher: String?
}

@Generable
nonisolated struct TimetableExtraction {
    @Guide(description: "Every class in the timetable, including labs and repeats. Do not skip any row or column.", .maximumCount(80))
    var rows: [TimetableRow]
}

@Generable
nonisolated enum GeneratedMailKind {
    case event
    case task
    case update
    case ignore
}

@Generable
nonisolated struct MailReading {
    @Guide(description: "event: something to attend at a time. task: something to do by a deadline. update: worth knowing, nothing to schedule. ignore: newsletters, marketing, codes, login alerts, social notifications")
    var kind: GeneratedMailKind

    @Guide(description: "What matters in the email, in one plain sentence under 25 words")
    var summary: String

    @Guide(description: "Short title for the event or task, e.g. 'IEEE talk on edge AI' or 'Submit DBMS assignment'")
    var title: String

    @Guide(description: "Event start or task deadline as local ISO 8601 without timezone, like 2026-09-21T14:00, or just 2026-09-25 when no time is given. Empty if the email gives no date.")
    var startISO: String?

    @Guide(description: "Event end as local ISO 8601, only if the email states it")
    var endISO: String?

    @Guide(description: "Venue or address for events, or 'Online' for video calls")
    var place: String?
}

@Generable
nonisolated enum GeneratedChangeAction {
    case move
    case cancel
    case rename
    case add
    case dayOff
    case classesOn
    case none
}

@Generable
nonisolated enum GeneratedChangeScope {
    case once
    case everyWeek
    case unspecified
}

@Generable
nonisolated struct ChangeReading {
    @Guide(description: "move: to a new time or day. cancel: call it off. rename: give an event a new name. add: a new event. dayOff: no classes on a whole day. classesOn: classes back on for a day that was off. none: not a change to the schedule")
    var action: GeneratedChangeAction

    @Guide(description: "For move, cancel and rename: the id of the item, copied exactly from the list, like c3 or e1. Empty otherwise.")
    var itemID: String?

    @Guide(description: "The new day for move, or the day meant for add, dayOff and classesOn, as yyyy-MM-dd")
    var date: String?

    @Guide(description: "New start time as 24-hour HH:mm, e.g. 16:00 for 4 pm")
    var startTime: String?

    @Guide(description: "New end time as 24-hour HH:mm, only if the person says one")
    var endTime: String?

    @Guide(description: "everyWeek if they say every week, from now on or permanently; once if they say just this time or name one date; unspecified otherwise")
    var scope: GeneratedChangeScope

    @Guide(description: "The new name for rename, or the name of a new event for add")
    var title: String?

    @Guide(description: "Where a new event is, if they say")
    var place: String?
}

/// On-device Apple Intelligence (Foundation Models). No network, no API key.
@Observable
final class AIClient {
    enum Status: Equatable {
        case available
        case unavailable(String)
    }

    private(set) var status: Status = .unavailable("Checking Apple Intelligence…")

    init() {
        refreshStatus()
    }

    var isAvailable: Bool { status == .available }

    func refreshStatus() {
        switch SystemLanguageModel.default.availability {
        case .available:
            status = .available
        case .unavailable(.deviceNotEligible):
            status = .unavailable("This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            status = .unavailable("Turn on Apple Intelligence in Settings to enable smart features.")
        case .unavailable(.modelNotReady):
            status = .unavailable("Apple Intelligence is still getting ready. Try again soon.")
        case .unavailable:
            status = .unavailable("Apple Intelligence is unavailable right now.")
        }
    }

    func extractScan(from text: String, now: Date = Date()) async throws -> ScanExtraction {
        let session = LanguageModelSession(instructions: """
            You turn text captured by a phone camera in India into structured data. \
            Amounts are in Indian rupees unless stated otherwise. \
            Today is \(now.formatted(date: .complete, time: .shortened)). \
            Resolve partial dates like "Sat 21 Sep, 8 PM" to the next matching future date.
            """)
        let response = try await session.respond(
            to: "Scanned text:\n\(text.prefix(3_000))",
            generating: ScanExtraction.self
        )
        return response.content
    }

    /// Reads a programme — a festival, a conference, a fest — into one row per session per day.
    func extractEvents(from text: String, now: Date = Date()) async throws -> [EventRow] {
        let session = LanguageModelSession(instructions: """
            You read event programmes, such as a festival over several days or a conference \
            agenda, into one row per session per day. \
            Today is \(now.formatted(date: .complete, time: .omitted)). \
            Resolve dates written without a year to the next time they come round. \
            A line that is just a date applies to the sessions under it. \
            Use 24-hour HH:mm times. Never invent sessions that aren't in the text.
            """)
        let response = try await session.respond(
            to: "Programme:\n\(text.prefix(5_000))",
            generating: EventListExtraction.self
        )
        return response.content.events
    }

    /// Reads notes, a message or a photographed list into separate things to do.
    func extractTasks(from text: String, now: Date = Date()) async throws -> [TaskRow] {
        let session = LanguageModelSession(instructions: """
            You turn notes, messages and photographed to-do lists into separate tasks. \
            Today is \(now.formatted(date: .complete, time: .omitted)). \
            One task per thing to do: split "buy milk and call mom" into two, but keep \
            "buy milk, eggs and bread" as one. Resolve "tomorrow" or a weekday to its date. \
            Give a date or time only when the text does. Leave out greetings, sign-offs, \
            timestamps and chat names. Never invent tasks that aren't there.
            """)
        let response = try await session.respond(
            to: "Text:\n\(text.prefix(4_000))",
            generating: TaskListExtraction.self
        )
        return response.content.tasks
    }

    /// Reads a college timetable — a photo's text or pasted text — into one row per class.
    func extractTimetable(from text: String) async throws -> [TimetableRow] {
        let session = LanguageModelSession(instructions: """
            You read college timetables into structured rows. \
            Timetables are usually a grid: days along one axis and time slots along the other. \
            Produce one row per class, per day it occurs. \
            Use 24-hour HH:mm times. Expand ranges like "9:00-9:55" into start and end. \
            Skip breaks, lunch and free periods. Never invent classes that aren't there.
            """)
        let response = try await session.respond(
            to: "Timetable text:\n\(text.prefix(6_000))",
            generating: TimetableExtraction.self
        )
        return response.content.rows
    }

    /// Reads one email and says what it asks of you. One session per message: the on-device
    /// model's context is small, and one email's headers and opening fit it comfortably.
    func readMail(_ message: MailMessage, now: Date = Date()) async throws -> MailProposal {
        let session = LanguageModelSession(instructions: """
            You sort one email for a college student in Bengaluru, India, and say what it asks of them. \
            event: something to attend at a time, such as a class, exam, meeting, interview, talk, \
            conference, workshop, booking, flight or train. \
            task: something to do by a deadline, such as submitting, paying, registering or replying. \
            update: worth knowing but nothing to schedule, such as results, changes or announcements. \
            ignore: newsletters, marketing, one-time codes, login alerts, social notifications. \
            Today is \(now.formatted(date: .complete, time: .shortened)). \
            Resolve relative dates like "tomorrow" or "this Friday" from when the email was sent. \
            Never invent a date, time or place the email doesn't give.
            """)
        let reading = try await session.respond(
            to: "Email:\n\(message.promptText())",
            generating: MailReading.self
        ).content
        let kind: MailKind = switch reading.kind {
        case .event: .event
        case .task: .task
        case .update: .update
        case .ignore: .ignore
        }
        return MailTriage.proposal(
            kind: kind,
            title: reading.title,
            summary: reading.summary,
            startISO: reading.startISO,
            endISO: reading.endISO,
            place: reading.place
        )
    }

    /// Reads a spoken or typed change against your real schedule. The model only chooses from the
    /// list it's given, so it can't point at a class or event that doesn't exist.
    func readChange(_ request: String, candidates: [ChangeCandidate], now: Date = Date()) async throws -> ChangeReadingValues {
        let list = candidates.prefix(40).map { $0.line() }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            You turn a request to change someone's schedule into a structured change. \
            Now is \(now.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())). \
            "My 3pm class" means the class at 15:00 on the nearest day that has one. \
            Resolve "tomorrow", "Thursday" and "next week" from now. \
            Only choose items from the list, by id. If nothing in the list matches, leave itemID empty.
            """)
        let reading = try await session.respond(
            to: "Schedule (id | kind | title | when | where):\n\(list.isEmpty ? "(nothing scheduled)" : list)\n\nRequest: \(request)",
            generating: ChangeReading.self
        ).content

        let action: ChangeAction = switch reading.action {
        case .move: .move
        case .cancel: .cancel
        case .rename: .rename
        case .add: .add
        case .dayOff: .dayOff
        case .classesOn: .classesOn
        case .none: .none
        }
        let scope: ChangeScope = switch reading.scope {
        case .once: .once
        case .everyWeek: .everyWeek
        case .unspecified: .unspecified
        }
        return ChangeReadingValues(
            action: action,
            itemID: reading.itemID,
            date: reading.date,
            startTime: reading.startTime,
            endTime: reading.endTime,
            scope: scope,
            title: reading.title,
            place: reading.place
        )
    }

    /// The model is busy or rationing requests: worth trying again later rather than falling back.
    static func isTransient(_ error: Error) -> Bool {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .rateLimited, .concurrentRequests: return true
            default: return false
            }
        }
        if #available(iOS 27.0, *) {
            if let error = error as? LanguageModelError, case .rateLimited = error { return true }
            if let error = error as? LanguageModelSession.Error, case .concurrentRequests = error { return true }
        }
        return false
    }

    /// Ranks nearby places and events into a short "what's good right now" stream.
    func vibeStream(candidates: [VibeCandidate], situation: String) async throws -> [VibePick] {
        guard !candidates.isEmpty else { return [] }
        let list = candidates.prefix(24).map { "\($0.id) | \($0.line)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            You are PathOS, a concise local guide. Pick what is most worth doing right now \
            given the time of day and situation. Prefer closer places and upcoming events. \
            Never invent places; only use ids from the list.
            """)
        let response = try await session.respond(
            to: "Situation: \(situation)\n\nOptions (id | details):\n\(list)",
            generating: VibeStream.self
        )
        let validIDs = Set(candidates.map(\.id))
        return response.content.picks.filter { validIDs.contains($0.itemID) }
    }

    /// Answers a spoken question, looking up real places, notes and weather through tools.
    func answer(_ question: String, situation: String) async throws -> String {
        let session = LanguageModelSession(
            tools: [SearchPlacesTool(), NearbyNotesTool(), WeatherTool()],
            instructions: """
                You are PathOS, a hands-free assistant heard through earbuds. \
                Answer in at most three short spoken sentences. \
                Always use the tools for places, saved notes and weather instead of guessing. \
                Mention walking minutes when recommending places. \
                Situation: \(situation)
                """
        )
        return try await session.respond(to: question).content
    }
}
