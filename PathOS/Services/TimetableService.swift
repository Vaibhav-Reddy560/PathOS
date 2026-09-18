import CoreLocation
import Foundation
import Observation
import SwiftData
import UIKit

/// Your timetable: imported once, then it runs every week until you say a day is off.
@Observable
final class TimetableService {
    private(set) var lastImportSummary: String?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let ai: AIClient
    @ObservationIgnored private let notifications: NotificationService

    /// How long before a class to remind you.
    static let reminderMinutesBefore = 10

    init(context: ModelContext, ai: AIClient, notifications: NotificationService) {
        self.context = context
        self.ai = ai
        self.notifications = notifications
    }

    // MARK: Reading

    func entries() -> [TimetableEntry] {
        let descriptor = FetchDescriptor<TimetableEntry>(sortBy: [SortDescriptor(\.weekday), SortDescriptor(\.startMinutes)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func exceptions() -> [TimetableException] {
        (try? context.fetch(FetchDescriptor<TimetableException>())) ?? []
    }

    var hasTimetable: Bool { !entries().isEmpty }

    func sessions(on day: Date) -> [ClassSession] {
        TimetableRoutine.sessions(slots: entries().map(Self.slot), skips: exceptions().map(Self.skip), on: day)
    }

    func isDayOff(_ day: Date) -> Bool {
        let dayStart = Calendar.current.startOfDay(for: day)
        return exceptions().contains { $0.entryID == nil && Calendar.current.isDate($0.dayStart, inSameDayAs: dayStart) }
    }

    static func slot(_ entry: TimetableEntry) -> TimetableSlot {
        TimetableSlot(
            id: entry.id,
            subject: entry.subject,
            weekday: entry.weekday,
            startMinutes: entry.startMinutes,
            endMinutes: entry.endMinutes,
            room: entry.room,
            teacher: entry.teacher,
            isActive: entry.isActive
        )
    }

    static func skip(_ exception: TimetableException) -> TimetableSkip {
        TimetableSkip(dayStart: exception.dayStart, entryID: exception.entryID, reason: exception.reason)
    }

    // MARK: Importing

    /// Reads a timetable out of pasted text. Returns what it found; nothing is saved until `replaceAll`.
    func readTimetable(from text: String) async -> [TimetableEntry] {
        guard ai.isAvailable, let rows = try? await ai.extractTimetable(from: text) else {
            lastImportSummary = ai.isAvailable
                ? "Couldn't read that as a timetable. Try a clearer photo, or add classes by hand."
                : "Apple Intelligence is off, so PathOS can't read timetables. Add classes by hand."
            return []
        }

        let entries = rows.compactMap(Self.entry(from:))
        lastImportSummary = entries.isEmpty
            ? "No classes found in that text."
            : "Found \(entries.count) classes across \(Set(entries.map(\.weekday)).count) days. Check them before saving."
        return entries
    }

    func readTimetable(from image: UIImage) async -> [TimetableEntry] {
        guard let ocr = try? await OCRParser.recognizeText(in: image), !ocr.isEmpty else {
            lastImportSummary = "No readable text in that image."
            return []
        }
        return await readTimetable(from: ocr.fullText)
    }

    private static func entry(from row: TimetableRow) -> TimetableEntry? {
        let subject = row.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty,
              let start = TimetableRoutine.minutes(fromTime: row.startTime),
              let end = TimetableRoutine.minutes(fromTime: row.endTime),
              end > start else { return nil }
        return TimetableEntry(
            subject: subject,
            weekday: weekday(from: row.day),
            startMinutes: start,
            endMinutes: end,
            room: row.room?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            teacher: row.teacher?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        )
    }

    /// `Calendar` numbers Sunday as 1.
    static func weekday(from day: GeneratedWeekday) -> Int {
        switch day {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        }
    }

    // MARK: Writing

    func replaceAll(with entries: [TimetableEntry]) {
        for existing in self.entries() {
            context.delete(existing)
        }
        for entry in entries where entry.modelContext == nil {
            context.insert(entry)
        }
        save()
        refreshReminders()
    }

    func add(_ entry: TimetableEntry) {
        context.insert(entry)
        save()
        refreshReminders()
    }

    func delete(_ entry: TimetableEntry) {
        context.delete(entry)
        save()
        refreshReminders()
    }

    func setDayOff(_ day: Date, isOff: Bool, reason: String = "No classes") {
        let dayStart = Calendar.current.startOfDay(for: day)
        let existing = exceptions().filter { $0.entryID == nil && Calendar.current.isDate($0.dayStart, inSameDayAs: dayStart) }
        if isOff {
            guard existing.isEmpty else { return }
            context.insert(TimetableException(dayStart: dayStart, reason: reason))
        } else {
            for exception in existing {
                context.delete(exception)
            }
        }
        save()
        refreshReminders()
    }

    // MARK: Reminders

    /// Schedules the next two days of classes. iOS caps pending notifications, and
    /// background refresh tops this up as days roll over.
    func refreshReminders() {
        Task {
            await notifications.removePending(withPrefix: "pathos.class.")
            for dayOffset in 0...1 {
                guard let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) else { continue }
                for session in sessions(on: day) {
                    guard let fireDate = DayPlan.reminderDate(start: session.start, minutesBefore: Self.reminderMinutesBefore, now: Date()) else { continue }
                    let place = session.room.map { " · \($0)" } ?? ""
                    notifications.schedule(
                        id: session.notificationID,
                        at: fireDate,
                        title: session.subject,
                        body: "Starts \(session.start.formatted(date: .omitted, time: .shortened))\(place)",
                        category: NotificationService.Category.event,
                        link: URL(string: "pathos://day"),
                        timeSensitive: true
                    )
                }
            }
        }
    }

    private func save() {
        try? context.save()
    }
}

/// Today's and tomorrow's classes flow into Radar, the map and the island like any other event.
final class TimetableEventSource: EventSource {
    private let service: TimetableService

    init(service: TimetableService) {
        self.service = service
    }

    func events(near location: CLLocation) async -> [LocalEvent] {
        let now = Date()
        return (0...1)
            .compactMap { Calendar.current.date(byAdding: .day, value: $0, to: now) }
            .flatMap { service.sessions(on: $0) }
            .filter { $0.end > now }
            .map { session in
                LocalEvent(
                    id: "class:\(session.id)",
                    title: session.subject,
                    subtitle: session.room ?? "Class",
                    start: session.start,
                    source: .scanned,
                    symbol: "graduationcap.fill"
                )
            }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
