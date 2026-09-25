import Foundation

/// A programme read into events: a festival over a few days, a conference agenda, a fest's
/// schedule pasted from a message or read off a poster.
///
///     Day 1 · Wed 24 Sep
///     10:00 AM – 11:00 AM  Inauguration | Main stage
///     11:00 Tea break
///     Thursday, 25 September
///     2 PM - 4 PM | Hackathon finals | Seminar hall 2
///
/// A line that is only a date sets the day for the lines under it; a line with a time is an
/// event on that day. What's left of the line once its times are taken out is the title, and a
/// second column — after a "|", a tab or " @ " — is the place. An event with no end runs until
/// the next one that day starts, or an hour.
nonisolated enum EventListReader {

    nonisolated struct Item: Identifiable, Hashable, Sendable {
        var id = UUID()
        var title: String
        var start: Date
        var end: Date
        var place: String?
    }

    /// Reads every event it can find. `now` places dates written without a year.
    static func items(in text: String, now: Date, calendar: Calendar = .current) -> [Item] {
        var day: Date?
        var found: [(title: String, day: Date?, start: Int, end: Int?, place: String?)] = []
        /// A time on a line of its own, waiting for the title on the line after it.
        var pendingTime: (start: Int, end: Int?)?

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let dateMatch = date(in: line, now: now, calendar: calendar)
            let times = timesIn(line)
            if let dateMatch {
                day = dateMatch.date
            }

            // The line less its date and times, stitched from the pieces between them.
            let cut = (times.ranges + [dateMatch?.range].compactMap { $0 }).sorted { $0.lowerBound < $1.lowerBound }
            var rest = ""
            var cursor = line.startIndex
            for range in cut where range.lowerBound >= cursor {
                rest += line[cursor..<range.lowerBound] + " "
                cursor = range.upperBound
            }
            rest += line[cursor...]
            let columns = rest
                .components(separatedBy: CharacterSet(charactersIn: "|\t"))
                .flatMap { $0.components(separatedBy: " @ ") }
                .map(clean)
                .filter { !$0.isEmpty && !isFiller($0) }

            if let start = times.start {
                if columns.isEmpty {
                    pendingTime = (start, times.end)
                    continue
                }
                found.append((columns[0], day, start, times.end, columns.dropFirst().first))
                pendingTime = nil
            } else if let pending = pendingTime, dateMatch == nil, let title = columns.first {
                found.append((title, day, pending.start, pending.end, columns.dropFirst().first))
                pendingTime = nil
            }
        }

        let fallbackDay = calendar.startOfDay(for: now)
        var items: [Item] = found.map { entry in
            let dayStart = calendar.startOfDay(for: entry.day ?? fallbackDay)
            let start = dayStart.addingTimeInterval(Double(entry.start) * 60)
            let end = entry.end.map { dayStart.addingTimeInterval(Double($0) * 60) } ?? start
            return Item(title: entry.title, start: start, end: end, place: entry.place)
        }
        // Open-ended: until the next thing that day, or an hour.
        for index in items.indices where items[index].end <= items[index].start {
            let next = items[(index + 1)...].first {
                calendar.isDate($0.start, inSameDayAs: items[index].start) && $0.start > items[index].start
            }
            items[index].end = next?.start ?? items[index].start.addingTimeInterval(3_600)
        }
        return items
    }

    // MARK: Times

    private static func timesIn(_ line: String) -> (start: Int?, end: Int?, ranges: [Range<String.Index>]) {
        let cleaned = line.replacingOccurrences(of: #"[•·●▪◦∙]"#, with: " ", options: .regularExpression)
        let rangePattern = #/(\d{1,2}(?:[:.]\d{2})?)\s*([ap]\.?m\.?)?\s*(?:-|–|—|to)\s*(\d{1,2}(?:[:.]\d{2})?)\s*([ap]\.?m\.?)?/#
            .ignoresCase()
        if let match = cleaned.firstMatch(of: rangePattern),
           let range = TimeRange.all(in: String(cleaned[match.range])).first,
           let original = line.range(of: String(cleaned[match.range])) {
            return (range.start, range.end, [original])
        }
        let pointPattern = #/(\d{1,2}[:.]\d{2}\s*(?:[ap]\.?m\.?)?|\d{1,2}\s*[ap]\.?m\.?)/#.ignoresCase()
        for match in cleaned.matches(of: pointPattern) {
            // Not part of a date or a longer number: "24.09.2026", "C-508".
            if match.range.lowerBound > cleaned.startIndex {
                let before = cleaned[cleaned.index(before: match.range.lowerBound)]
                if before.isNumber || before == "." || before == "/" || before == "-" { continue }
            }
            if match.range.upperBound < cleaned.endIndex {
                let after = cleaned[match.range.upperBound]
                if after.isNumber || after == "." || after == "/" { continue }
            }
            let text = String(cleaned[match.range])
            let normalized = text.lowercased().contains("m")
                ? text.lowercased().replacingOccurrences(of: ".", with: "")
                : text.replacingOccurrences(of: ".", with: ":")
            guard let minutes = TimetableRoutine.minutes(fromTime: normalized),
                  let original = line.range(of: text) else { continue }
            return (minutes, nil, [original])
        }
        return (nil, nil, [])
    }

    // MARK: Dates

    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// "24 Sep", "24th September 2026", "Sep 24", "24/09/2026" or "24-09" — Indian day-first order
    /// for numbers. The weekday, if written, is ignored: the date says it.
    static func date(in line: String, now: Date, calendar: Calendar = .current) -> (date: Date, range: Range<String.Index>)? {
        let monthWord = #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"#
        let weekday = #"(?:(?:mon|tues?|wed(?:nes)?|thu(?:rs)?|fri|sat(?:ur)?|sun)(?:day)?,?\s*)?"#
        // Each pattern, and which groups hold the day, the month and the year.
        let patterns: [(pattern: String, day: Int, month: Int, year: Int, isNumeric: Bool)] = [
            (#"\b"# + weekday + #"(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?"# + monthWord + #"\b\.?,?(?:\s+(\d{4}))?"#, 1, 2, 3, false),
            (#"\b"# + weekday + monthWord + #"\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b,?(?:\s+(\d{4}))?"#, 2, 1, 3, false),
            (#"(?<![\d:.])(\d{1,2})[/.-](\d{1,2})(?:[/.-](\d{2,4}))?(?![\d:])"#, 1, 2, 3, true),
        ]
        let whole = NSRange(line.startIndex..., in: line)
        for entry in patterns {
            guard let regex = try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: line, range: whole),
                  let range = Range(match.range, in: line) else { continue }
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: line).map { String(line[$0]) }
            }
            guard let day = group(entry.day).flatMap({ Int($0) }), (1...31).contains(day) else { continue }
            let month = entry.isNumeric ? group(entry.month).flatMap { Int($0) } : monthNumber(group(entry.month))
            guard let month, (1...12).contains(month) else { continue }
            let year = group(entry.year).flatMap { Int($0) }.map { $0 < 100 ? 2000 + $0 : $0 }
            // A dash between two small numbers is usually a time ("9-10"), not a date.
            if entry.isNumeric, year == nil, !line.contains("/"), !TimeRange.all(in: line, allowingBareHours: true).isEmpty {
                continue
            }
            var components = DateComponents(year: year ?? calendar.component(.year, from: now), month: month, day: day)
            guard var date = calendar.date(from: components) else { continue }
            // Without a year, the next time that date comes round — a festival lists days ahead.
            if year == nil, date < calendar.startOfDay(for: now).addingTimeInterval(-86_400) {
                components.year = (components.year ?? 0) + 1
                date = calendar.date(from: components) ?? date
            }
            return (date, range)
        }
        return nil
    }

    private static func monthNumber(_ text: String?) -> Int? {
        guard let text else { return nil }
        let key = text.lowercased()
        return months[String(key.prefix(4))] ?? months[String(key.prefix(3))]
    }

    // MARK: Text

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—:,|·•()[]")))
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    /// What's left of a date line: "Day 1", "Schedule", a lone weekday.
    private static func isFiller(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.range(of: #"^(day|session)\s*\d+$"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"^(mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)(day|nesday|sday|urday)?$"#, options: .regularExpression) != nil { return true }
        return ["schedule", "agenda", "programme", "program", "time", "event", "venue", "day"].contains(lower)
    }
}
