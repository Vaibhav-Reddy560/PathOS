import Foundation
import Observation
import SwiftData

/// Keeps a record of when you leave home.
///
/// It used to learn one usual time per weekday and say "You usually leave around 11:18" every
/// week, whatever the day held — a day off, a holiday, a class moved to the afternoon. When to
/// leave comes from the day's own plan now (`LeaveOnTime`); this only keeps the record, which
/// backups carry.
@Observable
final class RoutineLearner {
    /// The weekly reminders it used to set, taken back from phones that still have them.
    static let reminderPrefix = "pathos.commute.weekday."

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let notifications: NotificationService

    init(context: ModelContext, notifications: NotificationService) {
        self.context = context
        self.notifications = notifications
    }

    func logDeparture(from kind: PlaceKind, at date: Date = Date()) {
        context.insert(DepartureLog(placeKind: kind, date: date))
        try? context.save()
    }

    /// Takes back the old weekly "Heading out soon?" reminders.
    func removeWeeklyReminders() async {
        await notifications.removePending(withPrefix: Self.reminderPrefix)
    }
}
