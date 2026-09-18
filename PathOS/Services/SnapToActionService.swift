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
