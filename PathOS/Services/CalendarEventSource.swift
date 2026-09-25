import CoreLocation
import EventKit
import Foundation
import SwiftData

/// Looks up where a typed place is, once. Calendar and mail events name their places in words;
/// this turns "Toit, Indiranagar" into a pin and remembers it, so the map doesn't search every refresh.
final class PlaceGeocoder {
    private let places: PlacesService
    private var cache: [String: CLLocationCoordinate2D] = [:]
    /// Names that found nothing, so they aren't searched again this session.
    private var misses: Set<String> = []
    private static let cacheKey = "pathos.geocodeCache"

    init(places: PlacesService) {
        self.places = places
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let saved = try? JSONDecoder().decode([String: [Double]].self, from: data) {
            cache = saved.compactMapValues { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
        }
    }

    func coordinate(for place: String, near location: CLLocation) async -> CLLocationCoordinate2D? {
        let key = place.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, !MailTriage.isOnline(place) else { return nil }
        if let known = cache[key] { return known }
        guard !misses.contains(key) else { return nil }
        guard let match = (try? await places.search(place, near: location, radius: 30_000))?.first else {
            misses.insert(key)
            return nil
        }
        cache[key] = match.coordinate
        save()
        return match.coordinate
    }

    private func save() {
        // A few hundred places at most; the oldest don't matter enough to track.
        let trimmed = cache.count > 400 ? Dictionary(uniqueKeysWithValues: cache.prefix(400).map { ($0.key, $0.value) }) : cache
        let encodable = trimmed.mapValues { [$0.latitude, $0.longitude] }
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
}

/// An Apple Calendar event as plain values, so the selection rules can be tested.
nonisolated struct CalendarItem: Hashable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var calendarName: String
    var latitude: Double?
    var longitude: Double?
}

nonisolated enum CalendarEvents {
    /// How far ahead the map looks.
    static let horizon: TimeInterval = 7 * 86_400

    /// Upcoming calendar events that PathOS didn't put there itself — its own events are already
    /// on the map from its own store, and would otherwise appear twice.
    static func select(_ items: [CalendarItem], mirroredIDs: Set<String>, now: Date) -> [CalendarItem] {
        items
            .filter { !mirroredIDs.contains($0.id) && $0.end > now && $0.start < now.addingTimeInterval(horizon) }
            .sorted { $0.start < $1.start }
    }

    static func localEvent(_ item: CalendarItem, coordinate: CLLocationCoordinate2D?, from location: CLLocation) -> LocalEvent {
        let place = item.location?.split(separator: "\n").first.map(String.init)
        return LocalEvent(
            id: "calendar:\(item.id)",
            title: item.title,
            subtitle: [place, item.calendarName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "),
            start: item.start,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude,
            distanceMeters: coordinate.map { location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) },
            source: .calendar,
            symbol: "calendar"
        )
    }
}

/// Events from your Apple Calendar — including public calendars you subscribe to, like a Meetup
/// group, a college fest or a team's fixtures — on the map and in Radar with real times.
///
/// Off until you turn it on in Settings, because it needs full calendar access.
final class CalendarEventSource: EventSource {
    nonisolated static let enabledKey = "pathos.calendarEvents"

    private let store: EventStore
    private let geocoder: PlaceGeocoder
    private let eventKit = EKEventStore()

    init(store: EventStore, geocoder: PlaceGeocoder) {
        self.store = store
        self.geocoder = geocoder
    }

    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey) && EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func events(near location: CLLocation) async -> [LocalEvent] {
        guard Self.isEnabled else { return [] }
        let now = Date()
        let predicate = eventKit.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3_600), end: now.addingTimeInterval(CalendarEvents.horizon), calendars: nil)
        let items = eventKit.events(matching: predicate).map(Self.item(from:))
        let mirrored = Set(store.all().compactMap(\.calendarEventID))
        var result: [LocalEvent] = []
        for item in CalendarEvents.select(items, mirroredIDs: mirrored, now: now).prefix(20) {
            var coordinate: CLLocationCoordinate2D?
            if let latitude = item.latitude, let longitude = item.longitude {
                coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            } else if let place = item.location {
                coordinate = await geocoder.coordinate(for: place, near: location)
            }
            result.append(CalendarEvents.localEvent(item, coordinate: coordinate, from: location))
        }
        return result
    }

    nonisolated static func item(from event: EKEvent) -> CalendarItem {
        CalendarItem(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Event",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            calendarName: event.calendar?.title ?? "Calendar",
            latitude: event.structuredLocation?.geoLocation?.coordinate.latitude,
            longitude: event.structuredLocation?.geoLocation?.coordinate.longitude
        )
    }

    /// Only ever read from, which EventKit allows from any thread.
    nonisolated(unsafe) private static let reader = EKEventStore()

    /// Your Apple Calendar's events between two dates, less the ones PathOS put there itself, for
    /// Day. Online meetings belong here rather than on the map. Empty until calendars are turned
    /// on in Settings.
    nonisolated static func items(from start: Date, to end: Date, excluding mirrored: Set<String>) -> [CalendarItem] {
        guard isEnabled, start < end else { return [] }
        let predicate = reader.predicateForEvents(withStart: start, end: end, calendars: nil)
        return reader.events(matching: predicate)
            .map(item(from:))
            .filter { !mirrored.contains($0.id) }
            .sorted { $0.start < $1.start }
    }

    /// Asks for full calendar access. PathOS already writes to your calendar; reading it is new.
    static func requestAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }
}

/// Events Gmail suggested that you haven't decided on yet, so you can see them where they happen.
final class MailEventSource: EventSource {
    private let context: ModelContext
    private let geocoder: PlaceGeocoder

    init(context: ModelContext, geocoder: PlaceGeocoder) {
        self.context = context
        self.geocoder = geocoder
    }

    func events(near location: CLLocation) async -> [LocalEvent] {
        let pending = MailStatus.pending.rawValue
        let event = MailKind.event.rawValue
        let descriptor = FetchDescriptor<MailSuggestion>(predicate: #Predicate { $0.statusRaw == pending && $0.kindRaw == event })
        let now = Date()
        var result: [LocalEvent] = []
        for suggestion in (try? context.fetch(descriptor)) ?? [] {
            guard let start = suggestion.start, start > now, start < now.addingTimeInterval(CalendarEvents.horizon) else { continue }
            let coordinate = await suggestion.placeName.asyncMap { await geocoder.coordinate(for: $0, near: location) } ?? nil
            result.append(LocalEvent(
                id: "mail:\(suggestion.id.uuidString)",
                title: suggestion.title,
                subtitle: ["From your mail · not added yet", suggestion.placeName].compactMap { $0 }.joined(separator: " · "),
                start: start,
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude,
                distanceMeters: coordinate.map { location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) },
                source: .mail,
                symbol: "envelope"
            ))
        }
        return result
    }
}

extension Optional {
    fileprivate func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
