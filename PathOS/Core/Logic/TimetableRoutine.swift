import Foundation

/// Plain copies of a timetable row and a day off, so the routine can be tested on its own.
nonisolated struct TimetableSlot: Identifiable, Hashable, Sendable {
    var id: UUID
    var subject: String
    /// 1 = Sunday … 7 = Saturday.
    var weekday: Int
    var startMinutes: Int
    var endMinutes: Int
    var room: String?
    var teacher: String?
    var isActive: Bool = true
}

/// A day off, one cancelled class, or one class moved for a single day.
nonisolated struct TimetableSkip: Hashable, Sendable {
    var dayStart: Date
    var entryID: UUID?
    var reason: String
    var startMinutesOverride: Int? = nil
    var endMinutesOverride: Int? = nil
    var roomOverride: String? = nil

    /// A class that still happens that day, just differently, rather than not at all.
    var isMove: Bool {
        entryID != nil && (startMinutesOverride != nil || roomOverride != nil)
    }
}

/// One class on one real date.
nonisolated struct ClassSession: Identifiable, Hashable, Sendable {
    var id: String
    var slotID: UUID
    var subject: String
    var room: String?
    var teacher: String?
    var start: Date
    var end: Date
    /// Moved or relocated for this day only.
    var isMoved = false
    /// Where the weekly schedule happens: your Work place, which for a student is college.
    var placeName: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil

    /// "LH-3 · BMS College": the room, and the place it's in.
    var whereText: String? {
        let parts = [room, placeName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Sets each session at `place`, which is where you go for your weekly schedule.
    static func at(_ sessions: [ClassSession], name: String?, latitude: Double?, longitude: Double?) -> [ClassSession] {
        sessions.map { session in
            var session = session
            session.placeName = name
            session.latitude = latitude
            session.longitude = longitude
            return session
        }
    }

    var notificationID: String { "pathos.class.\(id)" }
}

nonisolated enum TimetableRoutine {
    /// Classes on `day`, earliest first, with days off and cancelled classes removed and
    /// one-day moves applied.
    static func sessions(
        slots: [TimetableSlot],
        skips: [TimetableSkip] = [],
        on day: Date,
        calendar: Calendar = .current
    ) -> [ClassSession] {
        let dayStart = calendar.startOfDay(for: day)
        let todaysSkips = skips.filter { calendar.isDate($0.dayStart, inSameDayAs: dayStart) }
        if todaysSkips.contains(where: { $0.entryID == nil }) { return [] }

        let cancelled = Set(todaysSkips.filter { !$0.isMove }.compactMap(\.entryID))
        let moves = Dictionary(todaysSkips.filter(\.isMove).map { ($0.entryID!, $0) }, uniquingKeysWith: { _, latest in latest })
        let weekday = calendar.component(.weekday, from: dayStart)

        return slots
            .filter { $0.isActive && $0.weekday == weekday && !cancelled.contains($0.id) }
            .map { slot in
                let move = moves[slot.id]
                let start = move?.startMinutesOverride ?? slot.startMinutes
                let end = move?.endMinutesOverride ?? (start + slot.endMinutes - slot.startMinutes)
                return ClassSession(
                    id: "\(slot.id.uuidString)@\(dayKey(for: dayStart, calendar: calendar))",
                    slotID: slot.id,
                    subject: slot.subject,
                    room: move?.roomOverride ?? slot.room,
                    teacher: slot.teacher,
                    start: dayStart.addingTimeInterval(Double(start) * 60),
                    end: dayStart.addingTimeInterval(Double(end) * 60),
                    isMoved: move != nil
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// `2026-09-17` — a stable id suffix without needing a shared formatter.
    static func dayKey(for day: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func current(in sessions: [ClassSession], now: Date) -> ClassSession? {
        sessions.first { $0.start <= now && $0.end > now }
    }

    static func next(in sessions: [ClassSession], now: Date) -> ClassSession? {
        sessions.filter { $0.start > now }.min { $0.start < $1.start }
    }

    static func minutesRemaining(in session: ClassSession, now: Date) -> Int {
        max(0, Int((session.end.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// "09:00" → 540. Also accepts "9:00", "9.00" and "9 am".
    static func minutes(fromTime text: String) -> Int? {
        let cleaned = text.lowercased().replacingOccurrences(of: ".", with: ":").trimmingCharacters(in: .whitespaces)
        let isPM = cleaned.contains("pm")
        let isAM = cleaned.contains("am")
        let digits = cleaned.replacingOccurrences(of: "am", with: "").replacingOccurrences(of: "pm", with: "").trimmingCharacters(in: .whitespaces)
        let parts = digits.split(separator: ":")
        guard let hourPart = parts.first, var hour = Int(hourPart), hour >= 0, hour <= 24 else { return nil }
        let minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        guard minute >= 0, minute < 60 else { return nil }
        if isPM, hour < 12 { hour += 12 }
        if isAM, hour == 12 { hour = 0 }
        // College timetables write afternoon classes as 1:00–4:00 without "pm".
        if !isAM, !isPM, hour >= 1, hour <= 6 { hour += 12 }
        return hour * 60 + minute
    }

    /// "09:00" for a minutes-since-midnight value.
    static func timeText(minutes: Int, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let reference = calendar.startOfDay(for: Date()).addingTimeInterval(Double(minutes) * 60)
        return reference.formatted(.dateTime.hour().minute().locale(locale))
    }
}


