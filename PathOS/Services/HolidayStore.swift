import Foundation
import Observation
import SwiftData

/// The holidays PathOS knows of, and your answers. A holiday you say is a day off is taken off
/// your weekly schedule like any other day off, so its sessions, its "time to leave" and Now's
/// leave-by all stand down with it.
@Observable
final class HolidayStore {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let timetable: TimetableService
    /// Bumped on every change, for views that list holidays.
    private(set) var version = 0

    init(context: ModelContext, timetable: TimetableService) {
        self.context = context
        self.timetable = timetable
    }

    func all() -> [Holiday] {
        let descriptor = FetchDescriptor<Holiday>(sortBy: [SortDescriptor(\.dayStart)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func holidays(on day: Date, calendar: Calendar = .current) -> [Holiday] {
        all().filter { calendar.isDate($0.dayStart, inSameDayAs: day) }
    }

    /// The lists that ship with PathOS, added once each. Your answers are never touched.
    func addBundled(calendar: Calendar = .current) {
        let existing = all()
        var added = false
        for listed in Holidays.bundled.holidays {
            guard let day = Holidays.day(listed.date, calendar: calendar),
                  !existing.contains(where: { calendar.isDate($0.dayStart, inSameDayAs: day) && $0.name == listed.name })
            else { continue }
            context.insert(Holiday(dayStart: day, name: listed.name, kind: listed.kind))
            added = true
        }
        if added { save() }
    }

    /// Holidays from your college's calendar, or added by hand. One already known for that day —
    /// the college repeating Gandhi Jayanthi — isn't added twice. Returns how many were new.
    @discardableResult
    func add(_ rows: [HolidayListReader.Row], kind: Holidays.Kind, calendar: Calendar = .current) -> Int {
        let existing = all().map(\.entry)
        var count = 0
        for row in rows {
            let day = calendar.startOfDay(for: row.day)
            guard !existing.contains(where: { Holidays.isSame(day, row.name, as: $0, calendar: calendar) }) else { continue }
            context.insert(Holiday(dayStart: day, name: row.name, kind: kind))
            count += 1
        }
        if count > 0 { save() }
        return count
    }

    /// A day off for you, or not. The day follows the answer whatever it was before: yes takes
    /// it off your schedule, no puts it back — "Undo day off" on a holiday is answering no.
    func answer(_ holiday: Holiday, isOff: Bool) {
        holiday.isOff = isOff
        holiday.answeredAt = Date()
        save()
        if timetable.isDayOff(holiday.dayStart) != isOff {
            timetable.setDayOff(holiday.dayStart, isOff: isOff, reason: holiday.name)
        }
    }

    func delete(_ holiday: Holiday) {
        if holiday.isOff == true {
            timetable.setDayOff(holiday.dayStart, isOff: false)
        }
        context.delete(holiday)
        save()
    }

    /// What to ask about now: unanswered, within the month ahead.
    func toAsk(today: Date = Date()) -> [Holiday] {
        let asked = Set(Holidays.toAsk(all().map(\.entry), today: today).map(\.id))
        return all().filter { asked.contains($0.id) }
    }

    private func save() {
        try? context.save()
        version += 1
    }
}
