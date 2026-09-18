import CoreLocation
import EventKit
import Foundation
import Observation
import SwiftData

/// Events live here; Apple Calendar gets a copy so they show up on the Lock Screen and watch.
@Observable
final class EventStore {
    private(set) var lastCalendarError: String?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let notifications: NotificationService
    @ObservationIgnored private let calendar = EKEventStore()

    init(context: ModelContext, notifications: NotificationService) {
        self.context = context
        self.notifications = notifications
    }

    // MARK: Reading

    func all() -> [PathEvent] {
        let descriptor = FetchDescriptor<PathEvent>(sortBy: [SortDescriptor(\.start)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func events(on day: Date, calendar: Calendar = .current) -> [PathEvent] {
        let planned = DayPlan.events(all().map(Self.plannedEvent), on: day, calendar: calendar)
        let byID = Dictionary(uniqueKeysWithValues: all().map { ($0.id, $0) })
        return planned.compactMap { byID[$0.id] }
    }

    func upcoming(after now: Date = Date(), limit: Int = 5) -> [PathEvent] {
        all().filter { $0.end > now }.prefix(limit).map { $0 }
    }

    /// Days that have something in them, newest first — the Day log's history.
    func daysWithEvents(calendar: Calendar = .current) -> [Date] {
        Array(Set(all().map { calendar.startOfDay(for: $0.start) })).sorted(by: >)
    }

    static func plannedEvent(_ event: PathEvent) -> PlannedEvent {
        PlannedEvent(
            id: event.id,
            title: event.title,
            start: event.start,
            end: event.end,
            isAllDay: event.isAllDay,
            placeName: event.placeName,
            latitude: event.latitude,
            longitude: event.longitude
        )
    }

    // MARK: Writing

    @discardableResult
    func save(_ event: PathEvent, mirrorToCalendar: Bool = true) -> PathEvent {
        if event.modelContext == nil {
            context.insert(event)
        }
        persist()
        scheduleReminder(for: event)
        if mirrorToCalendar {
            Task { await mirror(event) }
        }
        return event
    }

    func delete(_ event: PathEvent) {
        Task { await notifications.removePending(withPrefix: event.notificationID) }
        removeFromCalendar(event)
        context.delete(event)
        persist()
    }

    func scheduleReminder(for event: PathEvent) {
        Task {
            await notifications.removePending(withPrefix: event.notificationID)
            guard let fireDate = DayPlan.reminderDate(start: event.start, minutesBefore: event.reminderMinutesBefore, now: Date()) else { return }
            let place = event.placeName.map { " · \($0)" } ?? ""
            notifications.schedule(
                id: event.notificationID,
                at: fireDate,
                title: event.title,
                body: "\(event.start.formatted(date: .omitted, time: .shortened))\(place)",
                category: NotificationService.Category.event,
                link: URL(string: "pathos://day"),
                timeSensitive: true
            )
        }
    }

    /// Reschedules everything, e.g. after a background relaunch.
    func refreshReminders() {
        for event in upcoming(limit: 50) {
            scheduleReminder(for: event)
        }
    }

    // MARK: Apple Calendar mirror

    private func mirror(_ event: PathEvent) async {
        guard await requestCalendarAccess() else { return }
        let calendarEvent = existingCalendarEvent(for: event) ?? EKEvent(eventStore: calendar)
        calendarEvent.title = event.title
        calendarEvent.startDate = event.start
        calendarEvent.endDate = event.end
        calendarEvent.isAllDay = event.isAllDay
        calendarEvent.location = event.placeName
        calendarEvent.notes = event.notes.isEmpty ? "Added by PathOS" : event.notes
        if calendarEvent.calendar == nil {
            calendarEvent.calendar = calendar.defaultCalendarForNewEvents
        }
        guard calendarEvent.calendar != nil else { return }

        do {
            try calendar.save(calendarEvent, span: .thisEvent, commit: true)
            event.calendarEventID = calendarEvent.eventIdentifier
            persist()
            lastCalendarError = nil
        } catch {
            lastCalendarError = error.localizedDescription
        }
    }

    private func removeFromCalendar(_ event: PathEvent) {
        guard let calendarEvent = existingCalendarEvent(for: event) else { return }
        try? calendar.remove(calendarEvent, span: .thisEvent, commit: true)
    }

    private func existingCalendarEvent(for event: PathEvent) -> EKEvent? {
        guard let id = event.calendarEventID else { return nil }
        return calendar.event(withIdentifier: id)
    }

    private func requestCalendarAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly:
            return true
        case .notDetermined:
            return (try? await calendar.requestWriteOnlyAccessToEvents()) ?? false
        default:
            lastCalendarError = "Calendar access is off, so events stay in PathOS only."
            return false
        }
    }

    private func persist() {
        try? context.save()
    }
}

/// PathOS events also flow into Radar, the map and the island, through the existing event pipeline.
final class PathOSEventSource: EventSource {
    private let store: EventStore

    init(store: EventStore) {
        self.store = store
    }

    func events(near location: CLLocation) async -> [LocalEvent] {
        let now = Date()
        return store.all()
            .filter { $0.end > now && $0.start < now.addingTimeInterval(7 * 86_400) }
            .map { event in
                LocalEvent(
                    id: "event:\(event.id.uuidString)",
                    title: event.title,
                    subtitle: event.placeName ?? event.origin.label,
                    start: event.start,
                    latitude: event.latitude,
                    longitude: event.longitude,
                    distanceMeters: event.coordinate.map {
                        location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                    },
                    source: .scanned,
                    symbol: "calendar"
                )
            }
    }
}
