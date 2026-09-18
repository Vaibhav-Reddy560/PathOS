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
