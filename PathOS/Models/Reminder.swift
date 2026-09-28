import Foundation
import SwiftData

/// Something to do on a day: at a time, or just some time that day. Ticked off, not attended —
/// see `Checklist` for why it isn't an event.
@Model
final class Reminder {
    var id: UUID = UUID()
    var title: String = ""
    var notes: String = ""
    /// Midnight of the day it's for.
    var day: Date = Date()
    /// When it needs doing, when it needs doing at a time. Nil is any time that day.
    var dueAt: Date?
    var completedAt: Date?
    var originRaw: String = EventOrigin.manual.rawValue
    var createdAt: Date = Date()

    init(title: String, day: Date, dueAt: Date? = nil, notes: String = "", origin: EventOrigin = .manual) {
        self.title = title
        self.day = Calendar.current.startOfDay(for: day)
        self.dueAt = dueAt
        self.notes = notes
        originRaw = origin.rawValue
    }

    var origin: EventOrigin {
        get { EventOrigin(rawValue: originRaw) ?? .manual }
        set { originRaw = newValue.rawValue }
    }

    var isDone: Bool { completedAt != nil }

    var notificationID: String { "pathos.reminder.\(id.uuidString)" }
}
