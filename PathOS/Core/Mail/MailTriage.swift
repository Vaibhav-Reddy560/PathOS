import Foundation

/// What an email asks of you.
nonisolated enum MailKind: String, Codable, CaseIterable, Sendable {
    /// Something to be at: a meeting, class, talk, booking or trip.
    case event
    /// Something to do by a time: a submission, payment or registration.
    case task
    /// Worth knowing, with nothing to schedule.
    case update
    /// Newsletters, receipts with nothing to act on, one-time codes and other noise.
    case ignore

    var label: String {
        switch self {
        case .event: "Event"
        case .task: "To do"
        case .update: "Update"
        case .ignore: "Skipped"
        }
    }

    var symbol: String {
        switch self {
        case .event: "calendar.badge.plus"
        case .task: "checklist"
        case .update: "envelope.open"
        case .ignore: "tray"
        }
    }
}

/// Where a mail suggestion stands. Nothing reaches your Day until you approve it.
nonisolated enum MailStatus: String, Codable, Sendable {
    /// Waiting for you.
    case pending
    /// You approved it and it's on your Day.
    case added
    /// You declined it, or read the update.
    case dismissed
    /// Judged not worth showing. Kept so the same message isn't read twice.
    case skipped
}

/// What PathOS proposes from one email, before you approve it.
nonisolated struct MailProposal: Equatable, Sendable {
    var kind: MailKind
    var title: String
    var summary: String
    var start: Date?
    var end: Date?
    var isAllDay = false
    var place: String?
    var usedAI: Bool
}

nonisolated enum MailTriage {
    static let taskWords = ["deadline", "due", "submit", "submission", "last date", "register by", "registration closes",
                            "complete by", "pay by", "payment due", "renew", "expires", "reminder to"]
    static let eventWords = ["invite", "invitation", "invited", "meeting", "webinar", "conference", "workshop", "seminar",
                             "session", "interview", "appointment", "event", "hackathon", "fest", "exam", "viva",
                             "booking", "reservation", "check-in", "flight", "boarding", "pnr", "e-ticket", "rescheduled"]

    /// Without Apple Intelligence: a date plus the words that usually travel with one. Conservative
    /// on purpose — mail it can't place is skipped rather than shown as noise.
    static func heuristic(_ message: MailMessage, now: Date = Date()) -> MailProposal {
        let text = "\(message.subject)\n\(message.body.prefix(4_000))"
        let date = ScanHeuristics.eventDate(in: text, now: now)
        let isTask = mentions(taskWords, in: text)
        let isEvent = mentions(eventWords, in: text)

        let kind: MailKind = switch (date != nil, isTask, isEvent) {
        case (true, true, _): .task
        case (true, false, true): .event
        case (false, true, _), (false, _, true): .update
        default: .ignore
        }
        return MailProposal(
            kind: kind,
            title: message.subject,
            summary: String(message.snippet.prefix(160)),
            start: kind == .event || kind == .task ? date : nil,
            usedAI: false
        )
    }

    /// Whole-word match, so "fest" doesn't fire on "manifest" or "due" on "residue".
    static func mentions(_ words: [String], in text: String) -> Bool {
        let alternatives = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return text.range(of: #"(?i)\b(?:\#(alternatives))\b"#, options: .regularExpression) != nil
    }

    /// Makes a proposal from either path safe to show: a title, a summary, times that make sense,
    /// and nothing offered for scheduling that has already happened.
    static func finalize(_ proposal: MailProposal, message: MailMessage, now: Date = Date()) -> MailProposal {
        var result = proposal
        let title = proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        result.title = String((title.isEmpty ? (subject.isEmpty ? "Email from \(message.senderName)" : subject) : title).prefix(90))

        let summary = proposal.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        result.summary = summary.isEmpty ? String(message.snippet.prefix(160)) : summary

        let place = proposal.place?.trimmingCharacters(in: .whitespacesAndNewlines)
        result.place = place?.isEmpty == false ? place : nil

        if let start = result.start, let end = result.end, end <= start {
            result.end = nil
        }
        if result.kind == .event || result.kind == .task, let start = result.start {
            let finish = result.isAllDay
                ? Calendar.current.startOfDay(for: start).addingTimeInterval(86_400)
                : (result.end ?? start.addingTimeInterval(result.kind == .task ? 0 : 3_600))
            // News about something already over isn't something to schedule.
            if finish < now {
                result.kind = .update
            }
        }
        return result
    }

    /// The model's reading as a proposal. A bare date makes an all-day item; an end is kept only
    /// when it's a real time.
    static func proposal(
        kind: MailKind,
        title: String,
        summary: String,
        startISO: String?,
        endISO: String?,
        place: String?,
        calendar: Calendar = .current
    ) -> MailProposal {
        let start = parseModelDate(startISO, timeZone: calendar.timeZone)
        let end = parseModelDate(endISO, timeZone: calendar.timeZone)
        let isAllDay = start.map { !$0.hasTime } ?? false
        return MailProposal(
            kind: kind,
            title: title,
            summary: summary,
            start: start.map { isAllDay ? calendar.startOfDay(for: $0.date) : $0.date },
            end: isAllDay ? nil : end.flatMap { $0.hasTime ? $0.date : nil },
            isAllDay: isAllDay,
            place: place,
            usedAI: true
        )
    }

    /// Online meetings have no place to point you at.
    static func isOnline(_ place: String) -> Bool {
        mentions(["online", "virtual", "zoom", "google meet", "meet.google.com", "teams", "microsoft teams", "webex", "remote"], in: place)
    }

    /// Reads the model's local ISO 8601 date. `hasTime` is false for a bare date like "2026-09-25",
    /// which makes the item all-day rather than pretending it starts at midnight.
    static func parseModelDate(_ iso: String?, timeZone: TimeZone = .current) -> (date: Date, hasTime: Bool)? {
        guard var text = iso?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // The model is asked for local time; a stray zone suffix would shift it, so drop it.
        text = text.replacingOccurrences(of: #"(Z|[+-]\d{2}:?\d{2})$"#, with: "", options: .regularExpression)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return (date, true)
            }
        }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text).map { ($0, false) }
    }
}
