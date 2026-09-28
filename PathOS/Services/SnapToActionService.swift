import CoreLocation
import Foundation
import Observation
import SwiftData
import UIKit

nonisolated struct ScanDraft: Identifiable, Sendable {
    var id = UUID()
    var kind: ScanKind
    var title: String
    var summary: String
    var rawText: String
    var eventStart: Date?
    var venue: String?
    var merchant: String?
    var amount: Double?
    var category: ExpenseCategory
    var parkingLabel: String?
    var usedAI: Bool
}

/// Camera text → structured draft → OS actions (calendar, expense, spatial note).
@Observable
final class SnapToActionService {
    enum SnapError: LocalizedError {
        case noText

        var errorDescription: String? { "No readable text found. Try getting closer or improving the lighting." }
    }

    @ObservationIgnored private let ai: AIClient
    @ObservationIgnored private let context: ModelContext

    init(ai: AIClient, context: ModelContext) {
        self.ai = ai
        self.context = context
    }

    func analyze(image: UIImage) async throws -> ScanDraft {
        let ocr = try await OCRParser.recognizeText(in: image)
        guard !ocr.isEmpty else { throw SnapError.noText }
        return await analyze(text: ocr.fullText)
    }

    func analyze(text: String) async -> ScanDraft {
        let heuristic = ScanHeuristics.analyze(text)

        if ai.isAvailable, let extraction = try? await ai.extractScan(from: text) {
            let kind = Self.kind(from: extraction.kind)
            return ScanDraft(
                kind: kind,
                title: extraction.title.isEmpty ? heuristic.title : extraction.title,
                summary: extraction.summary,
                rawText: text,
                eventStart: extraction.eventStartISO.flatMap(Self.parseLocalISO) ?? heuristic.eventDate,
                venue: extraction.venue,
                merchant: extraction.merchant,
                amount: extraction.totalAmount ?? heuristic.amount,
                category: extraction.expenseCategory.map(Self.category(from:)) ?? .other,
                parkingLabel: extraction.parkingLabel ?? heuristic.parkingLabel,
                usedAI: true
            )
        }

        return ScanDraft(
            kind: heuristic.kind,
            title: heuristic.title,
            summary: String(text.prefix(140)),
            rawText: text,
            eventStart: heuristic.eventDate,
            venue: nil,
            merchant: heuristic.kind == .receipt ? heuristic.title : nil,
            amount: heuristic.amount,
            category: .other,
            parkingLabel: heuristic.parkingLabel,
            usedAI: false
        )
    }

    // MARK: Several events at once

    /// A programme read into events. Laid out one to a line, it's read exactly by rules; the
    /// on-device model is only asked when the rules find less than two, which is when the layout
    /// is something they don't know.
    func readEvents(text: String, on day: Date? = nil, now: Date = Date()) async -> (items: [EventListReader.Item], usedAI: Bool) {
        let reference = day ?? now
        let byRule = EventListReader.items(in: text, now: reference)
        if byRule.count >= 2 || !ai.isAvailable {
            return (byRule, false)
        }
        guard let rows = try? await ai.extractEvents(from: text, now: reference), !rows.isEmpty else {
            return (byRule, false)
        }
        let items = rows.compactMap { row -> EventListReader.Item? in
            guard let date = Self.parseLocalISO(row.date),
                  let start = TimetableRoutine.minutes(fromTime: row.startTime) else { return nil }
            let dayStart = Calendar.current.startOfDay(for: date)
            let begins = dayStart.addingTimeInterval(Double(start) * 60)
            let end = row.endTime.flatMap(TimetableRoutine.minutes(fromTime:)).map { dayStart.addingTimeInterval(Double($0) * 60) }
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return EventListReader.Item(title: title, start: begins,
                                        end: end.flatMap { $0 > begins ? $0 : nil } ?? begins.addingTimeInterval(3_600),
                                        place: row.place?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        }
        return items.isEmpty ? (byRule, false) : (items.sorted { $0.start < $1.start }, true)
    }

    /// A photo of a programme: its text, read the same way.
    func readEvents(image: UIImage, on day: Date? = nil) async throws -> (items: [EventListReader.Item], usedAI: Bool, text: String) {
        let ocr = try await OCRParser.recognizeText(in: image)
        guard !ocr.isEmpty else { throw SnapError.noText }
        let read = await readEvents(text: ocr.fullText, on: day)
        return (read.items, read.usedAI, ocr.fullText)
    }

    // MARK: Things to do

    /// Reminders read out of text. A list written one to a line is read exactly by rules; a
    /// paragraph or a conversation goes to the on-device model, which can tell "buy milk and call
    /// mom" is two things and "Sure, see you then" is none. Rules again if the model has nothing.
    func readTasks(text: String, on day: Date, now: Date = Date()) async -> (drafts: [Checklist.Draft], usedAI: Bool) {
        let byRule = Checklist.drafts(in: text, on: day, now: now)
        if Checklist.looksLikeList(text) || !ai.isAvailable {
            return (byRule, false)
        }
        return await readTasksWithAI(text: text, on: day, now: now) ?? (byRule, false)
    }

    /// A photo of a list, a whiteboard or a chat: its text read the model's way first, since
    /// photographed text is rarely a tidy list.
    func readTasks(image: UIImage, on day: Date, now: Date = Date()) async throws -> (drafts: [Checklist.Draft], usedAI: Bool, text: String) {
        let ocr = try await OCRParser.recognizeText(in: image)
        guard !ocr.isEmpty else { throw SnapError.noText }
        if ai.isAvailable, let read = await readTasksWithAI(text: ocr.fullText, on: day, now: now) {
            return (read.drafts, read.usedAI, ocr.fullText)
        }
        return (Checklist.drafts(in: ocr.fullText, on: day, now: now), false, ocr.fullText)
    }

    private func readTasksWithAI(text: String, on day: Date, now: Date) async -> (drafts: [Checklist.Draft], usedAI: Bool)? {
        guard let rows = try? await ai.extractTasks(from: text, now: now), !rows.isEmpty else { return nil }
        let calendar = Calendar.current
        let drafts = rows.compactMap { row -> Checklist.Draft? in
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let taskDay = row.date.flatMap(Self.parseLocalISO).map { calendar.startOfDay(for: $0) }
                ?? calendar.startOfDay(for: day)
            let dueAt = row.time.flatMap(TimetableRoutine.minutes(fromTime:)).map { taskDay.addingTimeInterval(Double($0) * 60) }
            return Checklist.Draft(title: title, day: taskDay, dueAt: dueAt, isDone: row.isDone)
        }
        return drafts.isEmpty ? nil : (drafts, true)
    }

    @discardableResult
    func saveRecord(_ draft: ScanDraft, at location: CLLocation?) -> ScanRecord {
        let record = ScanRecord(kind: draft.kind, title: draft.title, summary: draft.summary, rawText: draft.rawText)
        record.eventStart = draft.eventStart
        record.venueName = draft.venue
        record.latitude = location?.coordinate.latitude
        record.longitude = location?.coordinate.longitude
        context.insert(record)
        try? context.save()
        return record
    }

    @discardableResult
    func saveExpense(_ draft: ScanDraft) -> Expense? {
        guard let amount = draft.amount else { return nil }
        let expense = Expense(
            merchant: draft.merchant ?? draft.title,
            amount: amount,
            category: draft.category,
            note: draft.summary
        )
        context.insert(expense)
        try? context.save()
        return expense
    }

    // MARK: Mapping

    static func kind(from generated: GeneratedScanKind) -> ScanKind {
        switch generated {
        case .event: .event
        case .receipt: .receipt
        case .parking: .parking
        case .note: .note
        }
    }

    static func category(from generated: GeneratedExpenseCategory) -> ExpenseCategory {
        switch generated {
        case .food: .food
        case .groceries: .groceries
        case .transport: .transport
        case .shopping: .shopping
        case .entertainment: .entertainment
        case .bills: .bills
        case .health: .health
        case .other: .other
        }
    }

    static func parseLocalISO(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }
}
