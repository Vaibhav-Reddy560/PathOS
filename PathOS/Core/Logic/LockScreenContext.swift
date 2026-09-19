import Foundation

/// What the pinned context says on the Lock Screen, chosen from what's true right now.
///
/// One thing leads: a class or event under way or starting within the hour, else a note you left
/// here, else a rain warning, else where you are and the weather. Up to two short notes follow:
/// the umbrella, when to leave, what's next.
///
/// iOS doesn't wake PathOS on the minute, so anything timed carries its start and end and the Lock
/// Screen counts down on its own, and the content goes stale at the next moment it would change.
nonisolated enum LockScreenContext {
    typealias ContentState = PathOSActivityAttributes.ContentState

    /// A class, an event or a calendar entry today.
    nonisolated struct Entry: Hashable, Sendable {
        var id: String
        var title: String
        var place: String?
        var start: Date
        /// The same as `start` for a deadline, which has no length.
        var end: Date
        var symbol: String
        /// Classes are yours (green); events are the world's (cyan).
        var role: SignalRole = .you
    }

    /// Travel time from home to where you usually go, and when you usually leave.
    nonisolated struct Commute: Sendable {
        var destination: String
        var minutes: Int
        var byTransit: Bool
        /// Minutes after midnight.
        var usualDeparture: Int
    }

    /// A note you left at this spot, just brought back.
    nonisolated struct Memory: Sendable {
        var title: String
        var body: String
    }

    nonisolated struct Inputs: Sendable {
        var venueName: String
        var venueSymbol: String
        var weather: AlertSnapshot.Weather?
        var exitAdvice: ExitAdvice?
        var agenda: [Entry]
        var commute: Commute? = nil
        var memory: Memory? = nil
        var now: Date
        var calendar: Calendar = .current
    }

    nonisolated struct Content: Sendable {
        var state: ContentState
        /// When it next needs redrawing: the lead's start or end, or when the next class comes
        /// close enough to lead.
        var staleDate: Date
    }

    /// A class or event leads the Lock Screen from this long before it starts.
    static let leadTime: TimeInterval = 60 * 60
    /// When one class ends and the next starts within this, the next one leads.
    static let changeover: TimeInterval = 15 * 60
    /// The travel time shows from this long before you usually leave…
    static let commuteLeadMinutes = 90
    /// …until this long after.
    static let commuteTrailMinutes = 45
    /// Redrawn at least this often, for the weather.
    static let longestStale: TimeInterval = 60 * 60

    static func content(for inputs: Inputs) -> Content {
        let now = inputs.now
        // Still to come or under way; a deadline counts until it's due.
        let timed = inputs.agenda
            .filter { max($0.end, $0.start) > now }
            .sorted { $0.start < $1.start }
        let lead = leading(in: timed, now: now)
        let umbrella = umbrellaLine(inputs)
        var notes: [PathOSActivityAttributes.Note] = []
        let state: ContentState
        var staleDate = now.addingTimeInterval(longestStale)

        if let lead {
            let isUnderway = lead.start <= now
            state = ContentState(
                mode: .venue,
                title: lead.title,
                // The room on a line of its own: beside the times, it wrapped mid-phrase.
                subtitle: [timeRange(lead), lead.place].compactMap { $0 }.joined(separator: "\n"),
                symbol: lead.symbol,
                deepLink: URL(string: "pathos://day"),
                startDate: lead.start,
                endDate: lead.end,
                role: isUnderway ? lead.role : .attention
            )
            staleDate = isUnderway ? lead.end : lead.start
            if let memory = inputs.memory {
                notes.append(.init(symbol: "mappin.and.ellipse", text: memory.title, role: .you))
            }
        } else if let memory = inputs.memory {
            state = ContentState(
                mode: .venue,
                title: memory.title,
                subtitle: memory.body.isEmpty ? "You left a note here" : memory.body,
                symbol: "mappin.and.ellipse",
                deepLink: URL(string: "pathos://vault"),
                role: .you
            )
        } else if let umbrella {
            state = ContentState(
                mode: .venue,
                title: "Take an umbrella",
                subtitle: umbrella.detail,
                symbol: "umbrella.fill",
                deepLink: URL(string: "pathos://dashboard"),
                role: .attention
            )
        } else {
            state = ContentState(
                mode: .venue,
                title: inputs.venueName,
                subtitle: inputs.weather.map { "\($0.summary) · \(Int($0.temperatureC.rounded()))°C · \($0.rainChanceNext2h)% rain" }
                    ?? "PathOS is watching the way",
                symbol: inputs.venueSymbol,
                deepLink: URL(string: "pathos://dashboard")
            )
        }

        if let umbrella, state.title != "Take an umbrella" {
            notes.append(.init(symbol: "umbrella.fill", text: umbrella.note, role: .attention))
        }
        if let commute = commuteLine(inputs) {
            notes.append(commute)
        }
        let later = timed.first { $0.start > now && $0.id != lead?.id && $0.start >= (lead?.start ?? now) }
        if let later, inputs.calendar.isDate(later.start, inSameDayAs: now) {
            let at = later.start.formatted(date: .omitted, time: .shortened)
            notes.append(.init(
                symbol: later.symbol,
                text: ["Next: \(later.title) at \(at)", later.place].compactMap { $0 }.joined(separator: " · "),
                role: later.role
            ))
            if lead == nil {
                // Redrawn when it comes close enough to lead.
                staleDate = min(staleDate, max(later.start.addingTimeInterval(-leadTime), now))
            }
        }
        if lead != nil, umbrella == nil, let weather = inputs.weather {
            notes.append(.init(symbol: weather.symbol, text: "\(weather.summary) · \(Int(weather.temperatureC.rounded()))°C", role: .world))
        }

        var shown = state
        shown.notes = notes.isEmpty ? nil : Array(notes.prefix(2))
        return Content(state: shown, staleDate: max(staleDate, now.addingTimeInterval(60)))
    }

    // MARK: Pieces

    /// What's under way, or starting within the hour. Between two classes, the next one leads once
    /// the first is nearly over.
    static func leading(in agenda: [Entry], now: Date) -> Entry? {
        let underway = agenda.filter { $0.start <= now && $0.end > now }.min { $0.end < $1.end }
        let upcoming = agenda.first { $0.start > now && $0.start.timeIntervalSince(now) <= leadTime }
        if let underway, let upcoming,
           underway.end.timeIntervalSince(now) <= changeover, upcoming.start.timeIntervalSince(now) <= changeover {
            return upcoming
        }
        return underway ?? upcoming
    }

    private static func timeRange(_ entry: Entry) -> String {
        let start = entry.start.formatted(date: .omitted, time: .shortened)
        guard entry.end > entry.start else { return "Due \(start)" }
        return "\(start) to \(entry.end.formatted(date: .omitted, time: .shortened))"
    }

    /// Whether to take an umbrella, from the same rules as the exit check.
    private static func umbrellaLine(_ inputs: Inputs) -> (detail: String, note: String)? {
        let chance = inputs.weather?.rainChanceNext2h ?? 0
        let rainLikely = chance >= ExitCheckEvaluator.rainChanceThreshold
        guard rainLikely || inputs.exitAdvice != nil else { return nil }
        let detail = inputs.exitAdvice?.detail ?? "There's a \(chance)% chance of rain in the next 2 hours."
        let note = rainLikely ? "Take an umbrella · \(chance)% rain in 2 h" : "Take an umbrella · the weather may turn"
        return (detail, note)
    }

    /// The travel time, around when you usually leave.
    private static func commuteLine(_ inputs: Inputs) -> PathOSActivityAttributes.Note? {
        guard let commute = inputs.commute else { return nil }
        let parts = inputs.calendar.dateComponents([.hour, .minute], from: inputs.now)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard (commute.usualDeparture - commuteLeadMinutes)...(commute.usualDeparture + commuteTrailMinutes) ~= minutes else { return nil }
        return .init(
            symbol: commute.byTransit ? "tram.fill" : "figure.walk",
            text: "\(commute.destination): \(commute.minutes) min \(commute.byTransit ? "by transit" : "walk")",
            role: .you
        )
    }
}
