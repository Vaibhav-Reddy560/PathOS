import CoreLocation
import Foundation

/// Changes to your schedule said in plain words: read on-device, checked against what's really
/// there, shown to you as a proposal, and applied only when you approve.
final class ChangeService {
    private let ai: AIClient
    private let timetable: TimetableService
    private let eventStore: EventStore
    private let trips: TripStore
    private let places: PlacesService

    init(ai: AIClient, timetable: TimetableService, eventStore: EventStore, trips: TripStore, places: PlacesService) {
        self.ai = ai
        self.timetable = timetable
        self.eventStore = eventStore
        self.trips = trips
        self.places = places
    }

    /// The next week of classes, and upcoming events and trip legs.
    func candidates(now: Date = Date()) -> [ChangeCandidate] {
        let sessions = (0..<7)
            .compactMap { Calendar.current.date(byAdding: .day, value: $0, to: now) }
            .flatMap { timetable.sessions(on: $0) }
        return ChangePlanner.candidates(
            sessions: sessions,
            events: eventStore.upcoming(after: now, limit: 25).map(EventStore.plannedEvent),
            legs: trips.all().flatMap(\.legs).map(TripStore.plannedLeg),
            now: now
        )
    }

    func propose(_ request: String, now: Date = Date()) async -> ChangeOutcome {
        let candidates = candidates(now: now)
        do {
            let reading = try await ai.readChange(request, candidates: candidates, now: now)
            return ChangePlanner.plan(reading, candidates: candidates, now: now)
        } catch {
            return .needs("I couldn't work out that change. You can edit it from the Day tab.")
        }
    }

    /// Applies an approved change and says what happened, for the toast and the assistant.
    func apply(_ change: ProposedChange, near location: CLLocation?) async -> String {
        switch change {
        case let .moveClass(slotID, subject, room, from, to, everyWeek):
            guard let entry = timetable.entry(id: slotID) else { return "That class is no longer in your timetable." }
            let calendar = Calendar.current
            let start = Self.minutes(of: to.start)
            let end = Self.minutes(of: to.end)
            if everyWeek {
                timetable.update(entry, weekday: calendar.component(.weekday, from: to.start), startMinutes: start, endMinutes: end)
                return "\(subject) now meets \(Self.weekdayName(to.start)) at \(Self.time(to.start)), every week."
            }
            if calendar.isDate(from.start, inSameDayAs: to.start) {
                timetable.moveOnce(entryID: slotID, on: from.start, startMinutes: start, endMinutes: end)
            } else {
                // A timetable slot belongs to its weekday, so a class moved to another day becomes
                // a one-off event there, and that day's usual class is cancelled.
                timetable.cancelOnce(entryID: slotID, on: from.start, reason: "Moved")
                eventStore.save(PathEvent(title: subject, start: to.start, endsAt: to.end, placeName: room, tags: ["Class"], origin: .assistant))
            }
            return "\(subject) moved to \(Self.day(to.start)) at \(Self.time(to.start))."

        case let .cancelClass(slotID, subject, at, everyWeek):
            guard let entry = timetable.entry(id: slotID) else { return "That class is no longer in your timetable." }
            if everyWeek {
                timetable.update(entry, isActive: false)
                return "\(subject) is off your timetable. Turn it back on from the Timetable sheet."
            }
            timetable.cancelOnce(entryID: slotID, on: at.start)
            return "\(subject) cancelled for \(Self.day(at.start))."

        case let .dayOff(day):
            timetable.setDayOff(day, isOff: true)
            return "No classes on \(Self.day(day)). Your events stay."

        case let .classesOn(day):
            timetable.setDayOff(day, isOff: false)
            return "Classes are back on for \(Self.day(day))."

        case let .moveEvent(id, title, _, to):
            guard let event = eventStore.all().first(where: { $0.id == id }) else { return "That event no longer exists." }
            event.start = to.start
            event.endsAt = to.end
            eventStore.save(event)
            return "\(title) moved to \(Self.day(to.start)) at \(Self.time(to.start))."

        case let .cancelEvent(id, title, _):
            guard let event = eventStore.all().first(where: { $0.id == id }) else { return "That event no longer exists." }
            eventStore.delete(event)
            return "\(title) cancelled."

        case let .renameEvent(id, _, newTitle):
            guard let event = eventStore.all().first(where: { $0.id == id }) else { return "That event no longer exists." }
            event.title = newTitle
            eventStore.save(event)
            return "Renamed to \(newTitle)."

        case let .addEvent(title, at, place):
            var coordinate: CLLocationCoordinate2D?
            if let place, !MailTriage.isOnline(place), let location {
                coordinate = (try? await places.search(place, near: location, radius: 30_000))?.first?.coordinate
            }
            eventStore.save(PathEvent(title: title, start: at.start, endsAt: at.end, placeName: place, coordinate: coordinate, origin: .assistant))
            return "\(title) added for \(Self.day(at.start)) at \(Self.time(at.start))."

        case let .moveLeg(id, title, from, to):
            guard let leg = trips.all().flatMap(\.legs).first(where: { $0.id == id }) else { return "That trip leg no longer exists." }
            let shift = to.timeIntervalSince(from)
            leg.departure = to
            leg.arrival = leg.arrival?.addingTimeInterval(shift)
            trips.update(leg)
            return "\(title) now leaves \(Self.day(to)) at \(Self.time(to))."

        case let .cancelLeg(id, title, _):
            guard let leg = trips.all().flatMap(\.legs).first(where: { $0.id == id }) else { return "That trip leg no longer exists." }
            trips.delete(leg)
            return "\(title) removed from your trip."
        }
    }

    private static func minutes(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private static func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "today" }
        if Calendar.current.isDateInTomorrow(date) { return "tomorrow" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private static func weekdayName(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide)) + "s"
    }
}
