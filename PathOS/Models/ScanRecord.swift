import Foundation
import SwiftData

nonisolated enum ScanKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case event
    case receipt
    case parking
    case note

    var id: String { rawValue }

    var label: String {
        switch self {
        case .event: "Event"
        case .receipt: "Receipt"
        case .parking: "Parking"
        case .note: "Note"
        }
    }

    var symbol: String {
        switch self {
        case .event: "calendar.badge.plus"
        case .receipt: "indianrupeesign.circle.fill"
        case .parking: "parkingsign.circle.fill"
        case .note: "note.text"
        }
    }
}

@Model
final class ScanRecord {
    var id: UUID = UUID()
    var kindRaw: String = ScanKind.note.rawValue
    var title: String = ""
    var summary: String = ""
    var rawText: String = ""
    var createdAt: Date = Date()
    var eventStart: Date?
    var venueName: String?
    var latitude: Double?
    var longitude: Double?

    init(kind: ScanKind, title: String, summary: String, rawText: String) {
        self.kindRaw = kind.rawValue
        self.title = title
        self.summary = summary
        self.rawText = rawText
    }

    var kind: ScanKind {
        get { ScanKind(rawValue: kindRaw) ?? .note }
        set { kindRaw = newValue.rawValue }
    }
}
