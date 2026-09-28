import Foundation
import Observation
import SwiftData

/// Reminders live here, and so do their notifications: one at the time for a reminder that has
/// one, and one in the morning for the day's reminders that don't — otherwise a reminder with no
/// time would never remind you of anything.
@Observable
final class ReminderStore {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let notifications: NotificationService

    init(context: ModelContext, notifications: NotificationService) {
        self.context = context
        self.notifications = notifications
    }

    // MARK: Reading

    func all() -> [Reminder] {
        (try? context.fetch(FetchDescriptor<Reminder>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    func reminder(id: UUID) -> Reminder? {
        all().first { $0.id == id }
    }

    /// Done on the day, for the day's summary.
    func doneCount(on day: Date, calendar: Calendar = .current) -> Int {
        all().filter { $0.completedAt.map { calendar.isDate($0, inSameDayAs: day) } ?? false }.count
    }

    // MARK: Writing

    /// Several at once, as a list read from a message or a photo arrives.
    @discardableResult
    func add(_ drafts: [Checklist.Draft], origin: EventOrigin, now: Date = Date()) -> [Reminder] {
        let made = drafts.map { draft in
            let reminder = Reminder(title: draft.title, day: draft.day, dueAt: draft.dueAt, origin: origin)
            if draft.isDone { reminder.completedAt = now }
            context.insert(reminder)
            return reminder
        }
        persist()
        made.forEach(schedule)
        Set(made.map(\.day)).forEach(scheduleMorning)
        return made
    }

    func save(_ reminder: Reminder, movedFrom oldDay: Date? = nil) {
        if reminder.modelContext == nil {
            context.insert(reminder)
        }
        persist()
        schedule(reminder)
        scheduleMorning(for: reminder.day)
        if let oldDay, oldDay != reminder.day {
            scheduleMorning(for: oldDay)
        }
    }

    func setDone(_ reminder: Reminder, _ isDone: Bool, now: Date = Date()) {
        reminder.completedAt = isDone ? now : nil
        persist()
        schedule(reminder)
        scheduleMorning(for: reminder.day)
    }

    func delete(_ reminder: Reminder) {
        let day = reminder.day
        Task { await notifications.removePending(withPrefix: reminder.notificationID) }
        context.delete(reminder)
        persist()
        scheduleMorning(for: day)
    }

    /// Everything still to come, set again: after a relaunch, pending notifications can be gone.
    func refreshAlerts(now: Date = Date()) {
        let upcoming = all().filter { !$0.isDone && $0.day >= Calendar.current.startOfDay(for: now) }
        upcoming.forEach(schedule)
        Set(upcoming.map(\.day)).forEach(scheduleMorning)
    }

    // MARK: Notifications

    private func schedule(_ reminder: Reminder) {
        let id = reminder.notificationID
        let title = reminder.title
        let notes = reminder.notes
        let dueAt = reminder.isDone ? nil : reminder.dueAt
        Task {
            await notifications.removePending(withPrefix: id)
            guard let dueAt, dueAt > Date() else { return }
            notifications.schedule(
                id: id,
                at: dueAt,
                title: title,
                body: notes.isEmpty ? "Reminder · \(dueAt.formatted(date: .omitted, time: .shortened))" : notes,
                link: URL(string: "pathos://day"),
                timeSensitive: true
            )
        }
    }

    /// The day's reminders without a time, together, once, in the morning — and nothing when
    /// they're all done or the morning has already gone.
    private func scheduleMorning(for day: Date) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let id = "pathos.reminders.morning.\(Int(dayStart.timeIntervalSince1970))"
        let open = all()
            .filter { calendar.isDate($0.day, inSameDayAs: dayStart) && $0.dueAt == nil && !$0.isDone }
            .map(\.title)
        let at = dayStart.addingTimeInterval(Double(Checklist.morningNudgeMinutes) * 60)
        Task {
            await notifications.removePending(withPrefix: id)
            guard !open.isEmpty, at > Date() else { return }
            let list = open.prefix(3).joined(separator: ", ") + (open.count > 3 ? " and \(open.count - 3) more" : "")
            notifications.schedule(
                id: id,
                at: at,
                title: open.count == 1 ? "To do today" : "\(open.count) things to do today",
                body: list,
                link: URL(string: "pathos://day")
            )
        }
    }

    private func persist() {
        try? context.save()
    }
}
