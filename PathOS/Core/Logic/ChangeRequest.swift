import Foundation

/// Whether something said to the assistant is a change to your schedule rather than a question.
nonisolated enum ChangeIntent {
    static let verbs = ["move", "moved", "shift", "reschedule", "postpone", "prepone", "push", "bring forward",
                        "cancel", "cancelled", "canceled", "skip", "delete", "remove", "drop", "rename", "call it",
                        "add", "schedule", "book", "put", "set up", "change", "day off", "no class", "no classes",
                        "holiday", "classes are on", "classes back on", "bunk"]
    /// Questions about a change ("is my lab cancelled?") are answered, not acted on.
    static let questionWords = ["what", "when", "where", "which", "who", "why", "how", "is", "are", "am", "do", "does", "did", "will", "was", "were", "should"]

    static func looksLikeChange(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstWord = trimmed.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        if trimmed.hasSuffix("?"), questionWords.contains(firstWord) {
            return false
        }
        return MailTriage.mentions(verbs, in: trimmed)
    }
}

/// Something in your schedule a change can be about, as the model sees it: a short id it copies
/// back, so it can only ever point at things that exist.
nonisolated struct ChangeCandidate: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: String, Sendable {
        case classSession = "class"
        case event
        case leg = "trip leg"
    }

    /// "c3", "e1", "l2".
    var id: String
    var kind: Kind
    /// The timetable entry, event or leg behind it.
    var targetID: UUID
    var title: String
    var start: Date
    var end: Date
    var place: String?

    func line(calendar: Calendar = .current) -> String {
        let day = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let times = "\(ChangePlanner.clock(start, calendar: calendar))–\(ChangePlanner.clock(end, calendar: calendar))"
        return [id, kind.rawValue, title, "\(day) \(times)", place].compactMap { $0 }.joined(separator: " | ")
    }
}

nonisolated enum ChangeAction: String, Sendable {
    case move
    case cancel
    case rename
    case add
    case dayOff
    case classesOn
    case none
}

nonisolated enum ChangeScope: String, Sendable {
    case once
    case everyWeek
    case unspecified
}

/// The model's reading of a change, as plain values.
nonisolated struct ChangeReadingValues: Equatable, Sendable {
    var action: ChangeAction
    var itemID: String?
    /// yyyy-MM-dd
    var date: String?
    /// 24-hour HH:mm
    var startTime: String?
    var endTime: String?
    var scope: ChangeScope = .unspecified
    var title: String?
    var place: String?
}

/// A change PathOS proposes and you approve. Nothing is applied until you do.
nonisolated enum ProposedChange: Equatable, Sendable {
    case moveClass(slotID: UUID, subject: String, room: String?, from: DateInterval, to: DateInterval, everyWeek: Bool)
    case cancelClass(slotID: UUID, subject: String, at: DateInterval, everyWeek: Bool)
    case dayOff(day: Date)
    case classesOn(day: Date)
    case moveEvent(id: UUID, title: String, from: DateInterval, to: DateInterval)
    case cancelEvent(id: UUID, title: String, at: DateInterval)
    case renameEvent(id: UUID, from: String, to: String)
    case addEvent(title: String, at: DateInterval, place: String?)
    case moveLeg(id: UUID, title: String, from: Date, to: Date)
    case cancelLeg(id: UUID, title: String, at: Date)

    /// Classes can change once or every week; you choose on the card.
    var everyWeek: Bool? {
        switch self {
        case .moveClass(_, _, _, _, _, let everyWeek), .cancelClass(_, _, _, let everyWeek): everyWeek
        default: nil
        }
    }

    func withEveryWeek(_ everyWeek: Bool) -> ProposedChange {
        switch self {
        case let .moveClass(slotID, subject, room, from, to, _):
            .moveClass(slotID: slotID, subject: subject, room: room, from: from, to: to, everyWeek: everyWeek)
        case let .cancelClass(slotID, subject, at, _):
            .cancelClass(slotID: slotID, subject: subject, at: at, everyWeek: everyWeek)
        default:
            self
        }
    }
}

/// What came of reading a change.
nonisolated enum ChangeOutcome: Equatable, Sendable {
    case proposal(ProposedChange)
    /// It's a change, but something is missing or wrong. The text says what, to be spoken.
    case needs(String)
    /// Not a change after all; answer it as a question.
    case notAChange
}

nonisolated enum ChangePlanner {
    /// Upcoming classes, events and legs, oldest first, with short ids for the model.
    static func candidates(
        sessions: [ClassSession],
        events: [PlannedEvent],
        legs: [PlannedLeg],
        now: Date
    ) -> [ChangeCandidate] {
        let classes = sessions.filter { $0.end > now }.sorted { $0.start < $1.start }.enumerated().map { index, session in
            ChangeCandidate(id: "c\(index + 1)", kind: .classSession, targetID: session.slotID, title: session.subject,
                            start: session.start, end: session.end, place: session.room)
        }
        let upcoming = events.filter { $0.end > now }.sorted { $0.start < $1.start }.enumerated().map { index, event in
            ChangeCandidate(id: "e\(index + 1)", kind: .event, targetID: event.id, title: event.title,
                            start: event.start, end: event.end, place: event.placeName)
        }
        let trips = legs.filter { ($0.arrivalEstimate() ?? $0.departure) > now }.sorted { $0.departure < $1.departure }.enumerated().map { index, leg in
            ChangeCandidate(id: "l\(index + 1)", kind: .leg, targetID: leg.id, title: "\(leg.mode.label) to \(leg.destination)",
                            start: leg.departure, end: leg.arrivalEstimate() ?? leg.departure, place: leg.origin)
        }
        return classes + upcoming + trips
    }

    /// Checks the model's reading against your real schedule and turns it into a proposal,
    /// or says what's missing. Durations are kept when only a new start is given.
    static func plan(
        _ reading: ChangeReadingValues,
        candidates: [ChangeCandidate],
        now: Date,
        calendar: Calendar = .current
    ) -> ChangeOutcome {
        let date = MailTriage.parseModelDate(reading.date, timeZone: calendar.timeZone).map { calendar.startOfDay(for: $0.date) }
        let startMinutes = reading.startTime.flatMap(minutes(from24Hour:))
        let endMinutes = reading.endTime.flatMap(minutes(from24Hour:))
        let today = calendar.startOfDay(for: now)

        switch reading.action {
        case .none:
            return .notAChange

        case .dayOff, .classesOn:
            guard let date else { return .needs("Which day do you mean?") }
            guard date >= today else { return .needs("That day has already passed.") }
            return .proposal(reading.action == .dayOff ? .dayOff(day: date) : .classesOn(day: date))

        case .add:
            let title = reading.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return .needs("What should the event be called?") }
            guard let startMinutes else { return .needs("What time is \(title)?") }
            let day = date ?? today
            let start = day.addingTimeInterval(Double(startMinutes) * 60)
            let end = endMinutes.map { day.addingTimeInterval(Double($0) * 60) } ?? start.addingTimeInterval(3_600)
            guard end > start else { return .needs("That ends before it starts.") }
            guard start > now else { return .needs("That time has already passed today. Say which day.") }
            let place = reading.place?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .proposal(.addEvent(title: title, at: DateInterval(start: start, end: end), place: place?.isEmpty == false ? place : nil))

        case .move, .cancel, .rename:
            guard let id = reading.itemID?.trimmingCharacters(in: .whitespaces).lowercased(),
                  let target = candidates.first(where: { $0.id == id }) else {
                return .needs("I couldn't find that in your schedule. Try naming the class or event.")
            }
            switch reading.action {
            case .cancel:
                return .proposal(cancel(target, everyWeek: reading.scope == .everyWeek))
            case .rename:
                let title = reading.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard target.kind == .event else { return .needs("Only events can be renamed this way. Classes are renamed in your timetable.") }
                guard !title.isEmpty, title != target.title else { return .needs("What should it be called?") }
                return .proposal(.renameEvent(id: target.targetID, from: target.title, to: title))
            default:
                return move(target, to: date, startMinutes: startMinutes, endMinutes: endMinutes, scope: reading.scope, now: now, calendar: calendar)
            }
        }
    }

    private static func cancel(_ target: ChangeCandidate, everyWeek: Bool) -> ProposedChange {
        let at = DateInterval(start: target.start, end: max(target.end, target.start))
        return switch target.kind {
        case .classSession: .cancelClass(slotID: target.targetID, subject: target.title, at: at, everyWeek: everyWeek)
        case .event: .cancelEvent(id: target.targetID, title: target.title, at: at)
        case .leg: .cancelLeg(id: target.targetID, title: target.title, at: target.start)
        }
    }

    private static func move(
        _ target: ChangeCandidate,
        to date: Date?,
        startMinutes: Int?,
        endMinutes: Int?,
        scope: ChangeScope,
        now: Date,
        calendar: Calendar
    ) -> ChangeOutcome {
        guard date != nil || startMinutes != nil else { return .needs("Move \(target.title) to when?") }
        let day = date ?? calendar.startOfDay(for: target.start)
        let originalStart = calendar.dateComponents([.hour, .minute], from: target.start)
        let start = day.addingTimeInterval(Double(startMinutes ?? ((originalStart.hour ?? 0) * 60 + (originalStart.minute ?? 0))) * 60)
        let duration = target.end.timeIntervalSince(target.start)
        let end = endMinutes.map { day.addingTimeInterval(Double($0) * 60) } ?? start.addingTimeInterval(duration)

        guard end >= start else { return .needs("That ends before it starts.") }
        let everyWeek = target.kind == .classSession && scope == .everyWeek
        // A weekly change only needs a weekday and a time; a one-off has to be in the future.
        guard everyWeek || start > now else { return .needs("That time has already passed. Say which day.") }
        guard start != target.start || end != target.end else { return .needs("\(target.title) is already at that time.") }

        let from = DateInterval(start: target.start, end: max(target.end, target.start))
        let to = DateInterval(start: start, end: end)
        return switch target.kind {
        case .classSession:
            .proposal(.moveClass(slotID: target.targetID, subject: target.title, room: target.place, from: from, to: to, everyWeek: everyWeek))
        case .event:
            .proposal(.moveEvent(id: target.targetID, title: target.title, from: from, to: to))
        case .leg:
            .proposal(.moveLeg(id: target.targetID, title: target.title, from: target.start, to: start))
        }
    }

    /// Strict 24-hour "HH:mm". The timetable reader's guesswork ("1:00" means 1 PM) would be wrong
    /// here: the model is asked for 24-hour times, so "05:00" means five in the morning.
    static func minutes(from24Hour text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1].prefix(2)),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// "15:00", for the model's list. Locale-free so it reads the same everywhere.
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
