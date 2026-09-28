import Foundation

/// Reminders: things to do on a day — at a time, or just some time that day — ticked off when
/// they're done.
///
/// Not events. An event has a length and usually a place; a reminder is a single moment, or no
/// moment at all. "Buy milk" is for today. "Call the bank at 4" is for four o'clock. Neither is
/// something you attend.
nonisolated enum Checklist {

    /// One thing to do, read out of text or typed, before it's saved.
    nonisolated struct Draft: Identifiable, Hashable, Sendable {
        var id = UUID()
        var title: String
        /// Midnight of the day it's for.
        var day: Date
        /// When, if the text said.
        var dueAt: Date?
        /// Written already ticked: "[x] Book tickets".
        var isDone = false
    }

    /// Reminders with no time are brought up together, once, at this time on their day.
    static let morningNudgeMinutes = 8 * 60 + 30

    // MARK: Reading a list

    /// A list, one thing to a line, the way people write them — rather than a paragraph or a
    /// conversation, which the on-device model reads better than rules do.
    static func looksLikeList(_ text: String) -> Bool {
        let lines = self.lines(of: text)
        guard let first = lines.first else { return false }
        if lines.count == 1 { return first.count <= 80 }
        return lines.allSatisfy { $0.count <= 80 }
    }

    /// Every thing to do in the text, one to a line. `day` is the day being added to, for lines
    /// that don't say; `now` places "today", "tomorrow" and a weekday.
    static func drafts(in text: String, on day: Date, now: Date, calendar: Calendar = .current) -> [Draft] {
        lines(of: text).compactMap { draft(from: $0, on: day, now: now, calendar: calendar) }
    }

    /// One line read into a reminder, or nil when nothing is left of it once its time is taken out.
    static func draft(from raw: String, on day: Date, now: Date, calendar: Calendar = .current) -> Draft? {
        var line = raw
        let isDone = stripMarker(&line)
        var dueDay = calendar.startOfDay(for: day)
        var cuts: [Range<String.Index>] = []

        if let written = EventListReader.date(in: line, now: now, calendar: calendar) {
            dueDay = calendar.startOfDay(for: written.date)
            cuts.append(written.range)
        } else if let relative = relativeDay(in: line, now: now, calendar: calendar) {
            dueDay = relative.day
            cuts.append(relative.range)
        }

        var minutes: Int?
        let times = EventListReader.timesIn(line)
        if let start = times.start {
            minutes = start
            cuts += times.ranges
        } else if let bare = bareHour(in: line) {
            minutes = bare.minutes
            cuts.append(bare.range)
        }

        let title = tidy(cutting: cuts, from: line)
        guard !title.isEmpty else { return nil }
        let dueAt = minutes.map { dueDay.addingTimeInterval(Double($0) * 60) }
        return Draft(title: title, day: dueDay, dueAt: dueAt, isDone: isDone)
    }

    // MARK: The day's list

    /// Done last, then by time: timed ones in order, then the ones for any time that day, in the
    /// order they were added.
    static func isBefore(_ first: (dueAt: Date?, done: Bool, created: Date),
                         _ second: (dueAt: Date?, done: Bool, created: Date)) -> Bool {
        if first.done != second.done { return !first.done }
        switch (first.dueAt, second.dueAt) {
        case let (a?, b?): return a < b
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return first.created < second.created
        }
    }

    /// Left undone on an earlier day: brought forward to today rather than lost with the day.
    static func isCarriedOver(day: Date, isDone: Bool, today: Date, calendar: Calendar = .current) -> Bool {
        !isDone && day < calendar.startOfDay(for: today)
    }

    // MARK: Pieces

    private static func lines(of text: String) -> [String] {
        text.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ";")))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Takes a bullet, a number or a checkbox off the front, and says whether it was ticked.
    private static func stripMarker(_ line: inout String) -> Bool {
        let ticked = #"^\s*(?:[-*•◦▪]\s*)?(?:\[[xX✓✔]\]|[☑✅✓✔])\s*"#
        if let range = line.range(of: ticked, options: .regularExpression) {
            line.removeSubrange(range)
            return true
        }
        let marker = #"^\s*(?:[-*•◦▪·]|\d{1,2}[.)]|\[\s?\]|☐)\s*"#
        if let range = line.range(of: marker, options: .regularExpression) {
            line.removeSubrange(range)
        }
        return false
    }

    /// "today", "tonight", "tomorrow", "day after tomorrow", or a weekday — the next one.
    private static func relativeDay(in line: String, now: Date, calendar: Calendar) -> (day: Date, range: Range<String.Index>)? {
        let today = calendar.startOfDay(for: now)
        let words: [(pattern: String, offset: Int)] = [
            (#"\b(?:the\s+)?day\s+after\s+tomorrow\b"#, 2),
            (#"\btomorrow\b|\btmrw?\b"#, 1),
            (#"\btoday\b|\btonight\b"#, 0),
        ]
        for word in words {
            if let range = line.range(of: word.pattern, options: [.regularExpression, .caseInsensitive]) {
                return (calendar.date(byAdding: .day, value: word.offset, to: today) ?? today, range)
            }
        }
        // A full day name always counts. A short one only after "on", "by", "this" or "next":
        // "sat", "wed" and "sun" are words too, and "sat down" is not a Saturday.
        let pattern = #"\b(?:(on|by|this|next)\s+)?(sun(?:day)?|mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:rs?(?:day)?)?|fri(?:day)?|sat(?:urday)?)\b"#
        let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let range = Range(match.range, in: line),
                  let nameRange = Range(match.range(at: 2), in: line),
                  let index = weekdays.firstIndex(of: String(line[nameRange].prefix(3)).lowercased()) else { continue }
            let isFullName = line[nameRange].lowercased().hasSuffix("day")
            let hasLeadIn = match.range(at: 1).location != NSNotFound
            guard isFullName || hasLeadIn else { continue }
            let wanted = index + 1
            var ahead = (wanted - calendar.component(.weekday, from: today) + 7) % 7
            // Said on a Monday, "on Monday" is next week's.
            if ahead == 0 { ahead = 7 }
            return (calendar.date(byAdding: .day, value: ahead, to: today) ?? today, range)
        }
        return nil
    }

    /// "at 6", "by 11" — an hour with no am or pm, which people write all the time. Taken as the
    /// waking hour it most likely is: one to seven is the afternoon or evening, eight to eleven
    /// the morning.
    private static func bareHour(in line: String) -> (minutes: Int, range: Range<String.Index>)? {
        let pattern = #"\b(?:at|by|before|around)\s+(\d{1,2})\b(?!\s*(?:km|kg|m\b|%|:|\.\d|th|st|nd|rd|/))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line),
              let hourRange = Range(match.range(at: 1), in: line),
              let hour = Int(line[hourRange]), (1...12).contains(hour) else { return nil }
        let clock = hour == 12 ? 12 : hour <= 7 ? hour + 12 : hour
        return (clock * 60, range)
    }

    /// What's left of the line once its day and time are cut out: "Call mom at 6 pm tomorrow"
    /// becomes "Call mom".
    private static func tidy(cutting cuts: [Range<String.Index>], from line: String) -> String {
        var rest = ""
        var cursor = line.startIndex
        for range in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= cursor {
            rest += line[cursor..<range.lowerBound] + " "
            cursor = range.upperBound
        }
        rest += line[cursor...]
        var title = rest
            .replacingOccurrences(of: #"^\s*(?:remind\s+me\s+to|remember\s+to|don'?t\s+forget\s+to|to-?do:?|task:)\s*"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—:,.|·")))
        // The word that led into a time or a day, now leading into nothing.
        while let dangling = title.range(of: #"\s+(?:at|by|on|before|around|from|this|next)$"#,
                                         options: [.regularExpression, .caseInsensitive]) {
            title.removeSubrange(dangling)
        }
        title = title.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—:,.")))
        return title.prefix(1).uppercased() + title.dropFirst()
    }
}

/// An item of the day marked done, and when: kept on the day's log beside what PathOS saw you
/// attend, since it's the same kind of fact about the same day.
nonisolated struct ItemCompletion: Codable, Hashable, Sendable {
    var id: String
    var at: Date
}

/// Finishing something before its planned end, and saying how long it took.
nonisolated enum Completion {

    /// When "done" counts it as finished: not before it began, and not past its planned end —
    /// marking yesterday's lecture done this morning doesn't make it a twenty-hour lecture.
    static func finishedAt(start: Date, plannedEnd: Date, now: Date) -> Date {
        max(start, min(now, max(start, plannedEnd)))
    }

    /// Only while it's on: before it starts there's nothing to finish, and once its time is up
    /// it's over whether or not anyone said so.
    static func canFinish(start: Date, plannedEnd: Date, now: Date) -> Bool {
        start <= now && now < plannedEnd
    }

    /// "Done at 10:40 · took 40 min, 20 early", for the row. A deadline has no length, so it's
    /// just when.
    static func note(start: Date, plannedEnd: Date, doneAt: Date) -> String {
        let at = "Done at \(doneAt.formatted(date: .omitted, time: .shortened))"
        let planned = plannedEnd.timeIntervalSince(start)
        guard planned > 0 else { return at }
        let took = max(0, doneAt.timeIntervalSince(start))
        var parts = ["took \(duration(took))"]
        let early = planned - took
        if early >= 5 * 60 {
            parts.append("\(duration(early)) early")
        }
        return at + " · " + parts.joined(separator: ", ")
    }

    /// "40 min", "1 h", "1 h 10 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 60 else { return "\(max(minutes, 0)) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
