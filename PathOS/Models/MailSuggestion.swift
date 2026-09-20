import Foundation
import SwiftData

/// What PathOS made of one email, and what you decided about it.
///
/// Only the summary is kept, never the message body. Skipped mail is recorded too, so the same
/// message is never read twice.
@Model
final class MailSuggestion {
    var id: UUID = UUID()
    /// Gmail's id for the message, which also opens it in Gmail.
    var messageID: String = ""
    var senderName: String = ""
    var senderAddress: String = ""
    var subject: String = ""
    var receivedAt: Date = Date()
    var kindRaw: String = MailKind.update.rawValue
    var title: String = ""
    var summary: String = ""
    var start: Date?
    var endsAt: Date?
    var isAllDay: Bool = false
    var placeName: String?
    var usedAI: Bool = false
    var statusRaw: String = MailStatus.pending.rawValue
    /// The event it became, once you approved it.
    var eventID: UUID?
    /// The Gmail address it arrived at, when PathOS reads more than one. Nil from before that.
    var account: String?
    /// Gmail's conversation, which is what its app opens. Nil from before it was kept.
    var threadID: String?
    var createdAt: Date = Date()

    /// An empty one, filled field by field when a backup is put back.
    init() {}

    init(message: MailMessage, proposal: MailProposal, account: String? = nil) {
        self.account = account
        messageID = message.id
        threadID = message.threadID
        senderName = message.senderName
        senderAddress = message.senderAddress
        subject = message.subject
        receivedAt = message.receivedAt
        kindRaw = proposal.kind.rawValue
        title = proposal.title
        summary = proposal.summary
        start = proposal.start
        endsAt = proposal.end
        isAllDay = proposal.isAllDay
        placeName = proposal.place
        usedAI = proposal.usedAI
        statusRaw = (proposal.kind == .ignore ? MailStatus.skipped : .pending).rawValue
    }

    var kind: MailKind {
        get { MailKind(rawValue: kindRaw) ?? .update }
        set { kindRaw = newValue.rawValue }
    }

    var status: MailStatus {
        get { MailStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    /// Events and tasks with a date can be added in one tap; without one, they open the editor.
    var canAddDirectly: Bool {
        (kind == .event || kind == .task) && start != nil
    }

    /// When a task is due or an event starts, for the card: "Sat 21 Sep, 2:00 PM" or "Thu 25 Sep".
    var whenText: String? {
        guard let start else { return nil }
        let date = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return isAllDay ? date : "\(date), \(start.formatted(date: .omitted, time: .shortened))"
    }
}
