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
        var mode: TravelTimes.Mode
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
        /// When to set off for the next place you need to be.
        var departure: AlertSnapshot.Departure? = nil
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

    /// A card is short: two lines under the title are all that fit without the last one being
    /// cut off at the card's edge.
    static let mostNotes = 2

    static func content(for inputs: Inputs) -> Content {
        let now = inputs.now
        // Still to come or under way; a deadline counts until it's due.
        let timed = inputs.agenda
            .filter { max($0.end, $0.start) > now }
            .sorted { $0.start < $1.start }
        let lead = leading(in: timed, now: now)
        let umbrella = umbrellaLine(inputs)
        let state: ContentState
        var staleDate = now.addingTimeInterval(longestStale)

        if let lead {
            let isUnderway = lead.start <= now
            state = ContentState(
                mode: .venue,
                title: lead.title,
                // One line: the time and the room. The building is where you always go, and
                // saying it on every line is what made each card say the same thing.
                subtitle: [timeRange(lead), lead.place].compactMap { $0 }.joined(separator: " · "),
                symbol: lead.symbol,
                deepLink: URL(string: "pathos://day"),
                startDate: lead.start,
                endDate: lead.end,
                role: isUnderway ? lead.role : .attention
            )
            staleDate = isUnderway ? lead.end : lead.start
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

        // Most pressing first; the card keeps the first two.
        var notes: [PathOSActivityAttributes.Note] = []
        if let leave = leaveLine(inputs, lead: lead) {
            notes.append(leave.note)
            if let changesAt = leave.changesAt {
                staleDate = min(staleDate, max(changesAt, now.addingTimeInterval(60)))
            }
        }
        if lead != nil, let memory = inputs.memory {
            notes.append(.init(symbol: "mappin.and.ellipse", text: memory.title, role: .you))
        }
        if let umbrella, state.title != "Take an umbrella" {
            notes.append(.init(symbol: "umbrella.fill", text: umbrella.note, role: .attention))
        }
        let later = timed.first { $0.start > now && $0.id != lead?.id && $0.start >= (lead?.start ?? now) }
        if let later, inputs.calendar.isDate(later.start, inSameDayAs: now) {
            let at = later.start.formatted(date: .omitted, time: .shortened)
            notes.append(.init(
                symbol: later.symbol,
                text: ["Next: \(later.title) at \(at)", later.place].compactMap { $0 }.joined(separator: " · "),
                role: later.role,
                // Gone once it starts, rather than announcing something already under way.
                until: later.start
            ))
            if lead == nil {
                // Redrawn when it comes close enough to lead.
                staleDate = min(staleDate, max(later.start.addingTimeInterval(-leadTime), now))
            }
        }
        if let commute = commuteLine(inputs) {
            notes.append(commute)
        }
        if lead != nil, umbrella == nil, let weather = inputs.weather {
            notes.append(.init(symbol: weather.symbol, text: "\(weather.summary) · \(Int(weather.temperatureC.rounded()))°C", role: .world))
        }

        var shown = state
        shown.notes = notes.isEmpty ? nil : Array(notes.prefix(mostNotes))
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

    /// "12:10–2:00 PM": the shared AM or PM said once, so it fits on the line with the room.
    static func timeRange(_ entry: Entry) -> String {
        let start = entry.start.formatted(date: .omitted, time: .shortened)
        guard entry.end > entry.start else { return "Due \(start)" }
        let end = entry.end.formatted(date: .omitted, time: .shortened)
        return compactRange(start, end)
    }

    static func compactRange(_ start: String, _ end: String) -> String {
        // The meridiem is the last word, after a space iOS writes as a narrow no-break one.
        let separators: Set<Character> = [" ", "\u{202F}", "\u{00A0}"]
        if let startSplit = start.lastIndex(where: { separators.contains($0) }),
           let endSplit = end.lastIndex(where: { separators.contains($0) }),
           start[start.index(after: startSplit)...] == end[end.index(after: endSplit)...],
           start[start.index(after: startSplit)...].allSatisfy(\.isLetter) {
            return String.range(String(start[..<startSplit]), end, separator: "–")
        }
        return String.range(start, end, separator: "–")
    }

    /// Whether to take an umbrella: exactly when the exit check says so, which weighs a station's
    /// report and how much rain the forecasts expect, not just the odds.
    private static func umbrellaLine(_ inputs: Inputs) -> (detail: String, note: String)? {
        guard let advice = inputs.exitAdvice else { return nil }
        let chance = inputs.weather?.rainChanceNext2h ?? 0
        let note = advice.headline.hasPrefix("Raining nearby")
            ? "Take an umbrella · raining nearby"
            : chance >= ExitCheckEvaluator.rainChanceThreshold ? "Take an umbrella · \(chance)% rain in 2 h" : "Take an umbrella · the weather may turn"
        return (advice.detail, note)
    }

    /// "Leave by 8:35 · 25 min by road", turning into "Leave now" at 8:35 on its own, or how late
    /// you'll be. It names what it's for only when that isn't the card's own title. Quiet once
    /// you're there, and while you're on your way in good time.
    private static func leaveLine(_ inputs: Inputs, lead: Entry?) -> (note: PathOSActivityAttributes.Note, changesAt: Date?)? {
        guard let departure = inputs.departure else { return nil }
        let what = lead?.title == departure.title ? "" : " for \(departure.title)"
        let how = "\(departure.travelMinutes) min \(departure.byRoad ? "by road" : "on foot")"
        switch departure.status {
        case .there, .inGoodTime:
            return nil
        case .leaveSoon(let leaveBy):
            guard !departure.isOnTheWay else { return nil }
            return (.init(
                symbol: "figure.walk.departure",
                text: "Leave by \(leaveBy.formatted(date: .omitted, time: .shortened))\(what) · \(how)",
                role: .you,
                until: leaveBy,
                laterText: "Leave now\(what) · \(how)"
            ), leaveBy)
        case .leaveNow:
            guard !departure.isOnTheWay else { return nil }
            return (.init(symbol: "figure.walk.departure", text: "Leave now\(what) · \(how)", role: .attention), nil)
        case .late(_, let minutes):
            return (.init(symbol: "clock.badge.exclamationmark", text: "About \(minutes) min late\(what) · \(how)", role: .attention), nil)
        }
    }

    /// The travel time, around when you usually leave.
    private static func commuteLine(_ inputs: Inputs) -> PathOSActivityAttributes.Note? {
        guard let commute = inputs.commute else { return nil }
        let parts = inputs.calendar.dateComponents([.hour, .minute], from: inputs.now)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard (commute.usualDeparture - commuteLeadMinutes)...(commute.usualDeparture + commuteTrailMinutes) ~= minutes else { return nil }
        return .init(
            symbol: commute.mode.symbol,
            text: "\(commute.destination): \(commute.minutes) min \(commute.mode.phrase)",
            role: .you
        )
    }
}
