import Foundation
import Observation
import SwiftData

/// Learns when you usually leave home and nudges you 15 minutes before.
@Observable
final class RoutineLearner {
    static let reminderPrefix = "pathos.commute.weekday."
    static let leadMinutes = 15

    /// Weekday (1 = Sunday) → typical departure in minutes since midnight.
    private(set) var typicalDepartures: [Int: Int] = [:]
    private(set) var loggedDepartures = 0

    var remindersEnabled: Bool = UserDefaults.standard.object(forKey: "pathos.commuteReminders") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(remindersEnabled, forKey: "pathos.commuteReminders")
            Task { await rescheduleReminders() }
        }
    }

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let notifications: NotificationService
    @ObservationIgnored private var model = RoutineModel(samples: [])

    init(context: ModelContext, notifications: NotificationService) {
        self.context = context
        self.notifications = notifications
        recompute()
    }

    func logDeparture(from kind: PlaceKind, at date: Date = Date()) {
        context.insert(DepartureLog(placeKind: kind, date: date))
        try? context.save()
        recompute()
    }

    func recompute() {
        let homeKind = PlaceKind.home.rawValue
        let descriptor = FetchDescriptor<DepartureLog>(predicate: #Predicate { $0.placeKindRaw == homeKind })
        let logs = (try? context.fetch(descriptor)) ?? []
        loggedDepartures = logs.count

        let samples = logs.map {
            DepartureSample(date: $0.date, weekday: $0.weekday, minutesSinceMidnight: $0.minutesSinceMidnight)
        }
        model = RoutineModel(samples: RoutineModel.firstPerDay(samples))

        var departures: [Int: Int] = [:]
        for weekday in 1...7 {
            departures[weekday] = model.typicalDeparture(weekday: weekday)
        }
        typicalDepartures = departures
    }

    func rescheduleReminders() async {
        await notifications.removePending(withPrefix: Self.reminderPrefix)
        guard remindersEnabled else { return }

        for weekday in 1...7 {
            guard let departure = typicalDepartures[weekday],
                  let reminder = model.reminderTime(weekday: weekday, leadMinutes: Self.leadMinutes) else { continue }
            notifications.scheduleWeekly(
                id: Self.reminderPrefix + String(weekday),
                weekday: weekday,
                hour: reminder.hour,
                minute: reminder.minute,
                title: "Heading out soon?",
                body: "You usually leave around \(Self.format(minutes: departure)). Tap for walking time, metro and cabs.",
                category: NotificationService.Category.commute,
                link: URL(string: "pathos://commute/start")
            )
        }
    }

    /// Today's typical departure, if one has been learned.
    func todaysDeparture(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        typicalDepartures[calendar.component(.weekday, from: now)]
    }

    static func format(minutes: Int) -> String {
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        guard let date = Calendar.current.date(from: components) else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
