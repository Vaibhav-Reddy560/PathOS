import Foundation

/// Public holidays, and your college's own: which are days off for you is yours to say.
///
/// The national and Karnataka lists ship with PathOS, from the state's own notification. A
/// holiday isn't assumed to be a day off — a college can teach through Mahanavami — so each is
/// asked about once, close to it, and the answer can be changed later in Day → Month or Year.
nonisolated enum Holidays {
    nonisolated enum Kind: String, Codable, CaseIterable, Sendable {
        case national
        case karnataka
        case college
        case own

        /// Where it comes from, not what it celebrates: the list has days of mourning as well as
        /// festivals, so nothing festive stands for all of them.
        var symbol: String {
            switch self {
            case .national: "flag.fill"
            case .karnataka: "building.columns.fill"
            case .college: "graduationcap.fill"
            case .own: "calendar"
            }
        }

        var label: String {
            switch self {
            case .national: "National holiday"
            case .karnataka: "Karnataka holiday"
            case .college: "From your college's calendar"
            case .own: "Added by you"
            }
        }
    }

    /// One line of a list: a day and what it's for.
    nonisolated struct Listed: Codable, Equatable, Sendable {
        /// yyyy-MM-dd.
        var date: String
        var name: String
        var kind: Kind
    }

    nonisolated struct Source: Codable, Equatable, Sendable {
        var what: String
        var notification: String
        var url: String
        var notes: String
        var retrieved: String
    }

    nonisolated struct File: Codable, Sendable {
        var sources: [Source]
        var holidays: [Listed]
    }

    /// The lists that ship with PathOS.
    static let bundled: File = {
        guard let url = Bundle.main.url(forResource: "holidays", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return File(sources: [], holidays: [])
        }
        return file
    }()

    /// The day a listed holiday falls on, at midnight where you are.
    static func day(_ date: String, calendar: Calendar = .current) -> Date? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// A holiday as PathOS keeps it, with your answer.
    nonisolated struct Entry: Identifiable, Equatable, Sendable {
        var id: UUID
        var day: Date
        var name: String
        var kind: Kind
        /// Nil until you've said: a day off for you, or a day like any other.
        var isOff: Bool?
    }

    /// How far ahead a holiday is asked about.
    static let askAhead = 30

    /// What to ask about now: unanswered, from today to `askAhead` days on, soonest first.
    static func toAsk(_ holidays: [Entry], today: Date, calendar: Calendar = .current) -> [Entry] {
        let start = calendar.startOfDay(for: today)
        guard let end = calendar.date(byAdding: .day, value: askAhead, to: start) else { return [] }
        return holidays
            .filter { $0.isOff == nil && $0.day >= start && $0.day < end }
            .sorted { $0.day < $1.day }
    }

    /// The same holiday from two lists — a college calendar repeating Gandhi Jayanthi — is one.
    static func isSame(_ day: Date, _ name: String, as other: Entry, calendar: Calendar = .current) -> Bool {
        guard calendar.isDate(day, inSameDayAs: other.day) else { return false }
        let a = plain(name), b = plain(other.name)
        return a == b || a.contains(b) || b.contains(a) || other.kind != .own
    }

    private static func plain(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter }
    }
}

/// Reads a holiday list — a college calendar's text, a circular — into days and names, by rule:
/// a date on a line, and what the line says it is. The on-device model reads what the rules
/// can't, such as a grid.
nonisolated enum HolidayListReader {
    nonisolated struct Row: Equatable, Sendable {
        var day: Date
        var name: String
    }

    /// Lines like "02.10.2026  Friday  Gandhi Jayanthi", "2 Oct 2026 – Gandhi Jayanti",
    /// "Oct 2, Fri: Gandhi Jayanti" or "2026-10-02 Gandhi Jayanthi". A date with no year is the
    /// next time it comes round after `today`.
    static func rows(in text: String, today: Date, calendar: Calendar = .current) -> [Row] {
        var rows: [Row] = []
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            guard let (day, range) = date(in: line, today: today, calendar: calendar) else { continue }
            var name = line
            name.removeSubrange(range)
            name = clean(name)
            guard name.count >= 3, name.contains(where: \.isLetter) else { continue }
            if !rows.contains(where: { calendar.isDate($0.day, inSameDayAs: day) && $0.name == name }) {
                rows.append(Row(day: day, name: name))
            }
        }
        return rows.sorted { $0.day < $1.day }
    }

    static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august",
                             "september", "october", "november", "december"]
    private static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                                   "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun"]

    /// The first date on the line, and where it was.
    static func date(in line: String, today: Date, calendar: Calendar) -> (Date, Range<String.Index>)? {
        let year = calendar.component(.year, from: today)
        // 2026-10-02
        if let match = line.firstMatch(of: /(\d{4})-(\d{1,2})-(\d{1,2})/),
           let day = make(Int(match.3), Int(match.2), Int(match.1), calendar) {
            return (day, match.range)
        }
        // 02.10.2026, 02/10/2026, 2-10-26 — day first, as India writes it.
        if let match = line.firstMatch(of: /\b(\d{1,2})[.\/-](\d{1,2})[.\/-](\d{2,4})\b/),
           let y = Int(match.3), let day = make(Int(match.1), Int(match.2), y < 100 ? 2000 + y : y, calendar) {
            return (day, match.range)
        }
        // 2 Oct 2026, 2nd October, 02-Oct-2026 — every candidate in turn, since "3 Week" looks
        // like the start of one until its month doesn't.
        for match in line.matches(of: /(?i)\b(\d{1,2})(?:st|nd|rd|th)?[\s\-]+([a-z]{3,9})\.?,?(?:[\s\-]+(\d{4}))?/) {
            guard let month = month(String(match.2)) else { continue }
            if let day = resolve(Int(match.1), month, match.3.flatMap { Int($0) }, year: year, today: today, calendar: calendar) {
                return (day, match.range)
            }
        }
        // Oct 2, 2026 / October 2
        for match in line.matches(of: /(?i)\b([a-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b,?(?:\s+(\d{4}))?/) {
            guard let month = month(String(match.1)) else { continue }
            if let day = resolve(Int(match.2), month, match.3.flatMap { Int($0) }, year: year, today: today, calendar: calendar) {
                return (day, match.range)
            }
        }
        return nil
    }

    /// A month's name or a short form of it — "Oct", "Sept", "October" — and nothing that merely
    /// starts like one: "Janmashtami" is not January.
    static func month(_ word: String) -> Int? {
        let lower = word.lowercased()
        guard lower.count >= 3 else { return nil }
        return monthNames.firstIndex { $0.hasPrefix(lower) }.map { $0 + 1 }
    }

    private static func make(_ day: Int?, _ month: Int?, _ year: Int?, _ calendar: Calendar) -> Date? {
        guard let day, let month, let year, (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    private static func resolve(_ day: Int?, _ month: Int, _ explicit: Int?, year: Int, today: Date,
                                calendar: Calendar) -> Date? {
        if let explicit { return make(day, month, explicit, calendar) }
        guard let thisYear = make(day, month, year, calendar) else { return nil }
        // Without a year: the next time it comes round, as a calendar for the year ahead means it.
        return thisYear >= calendar.startOfDay(for: today) ? thisYear : make(day, month, year + 1, calendar)
    }

    /// What's left of the line once the date is out: the weekday, numbering and punctuation go.
    private static func clean(_ text: String) -> String {
        var words = text
            .replacingOccurrences(of: #"^[\s\d.)\-–—:|•*]+"#, with: "", options: .regularExpression)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "|" })
            .map(String.init)
        words.removeAll { weekdays.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
        return words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,.()|•*\t"))
    }
}
