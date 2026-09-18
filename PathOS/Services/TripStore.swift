import CoreLocation
import Foundation
import Observation
import SwiftData

/// Trips and their legs, with a departure reminder for each leg.
@Observable
final class TripStore {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let notifications: NotificationService

    /// How long before a leg leaves to remind you.
    static let reminderMinutesBefore = 45

    init(context: ModelContext, notifications: NotificationService) {
        self.context = context
        self.notifications = notifications
    }

    func all() -> [Trip] {
        let descriptor = FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func trip(covering day: Date) -> Trip? {
        all().first { $0.covers(day) }
    }

    func legs(on day: Date) -> [TripLeg] {
        let planned = TripPlan.legs(all().flatMap { $0.legs }.map(Self.plannedLeg), on: day)
        let byID = Dictionary(uniqueKeysWithValues: all().flatMap { $0.legs }.map { ($0.id, $0) })
        return planned.compactMap { byID[$0.id] }
    }

    static func plannedLeg(_ leg: TripLeg) -> PlannedLeg {
        var distance: Double?
        if let originLatitude = leg.originLatitude, let originLongitude = leg.originLongitude,
           let destination = leg.destinationCoordinate {
            distance = GeoMath.distance(
                from: CLLocationCoordinate2D(latitude: originLatitude, longitude: originLongitude),
                to: destination
            )
        }
        return PlannedLeg(
            id: leg.id,
            mode: leg.mode,
            origin: leg.origin,
            destination: leg.destination,
            departure: leg.departure,
            arrival: leg.arrival,
            distanceMeters: distance
        )
    }

    // MARK: Writing

    @discardableResult
    func save(_ trip: Trip) -> Trip {
        if trip.modelContext == nil {
            context.insert(trip)
        }
        persist()
        refreshReminders()
        return trip
    }

    func add(_ leg: TripLeg, to trip: Trip) {
        leg.trip = trip
        context.insert(leg)
        persist()
        refreshReminders()
    }

    /// Saves a changed leg and moves its departure reminder with it.
    func update(_ leg: TripLeg) {
        Task { await notifications.removePending(withPrefix: leg.notificationID) }
        persist()
        refreshReminders()
    }

    func delete(_ leg: TripLeg) {
        Task { await notifications.removePending(withPrefix: leg.notificationID) }
        context.delete(leg)
        persist()
    }

    func delete(_ trip: Trip) {
        for leg in trip.legs {
            Task { await notifications.removePending(withPrefix: leg.notificationID) }
        }
        context.delete(trip)
        persist()
    }

    /// A reminder before each upcoming departure.
    func refreshReminders() {
        Task {
            let upcoming = all().flatMap(\.legs).filter { $0.departure > Date() }
            for leg in upcoming.prefix(30) {
                await notifications.removePending(withPrefix: leg.notificationID)
                guard let fireDate = DayPlan.reminderDate(start: leg.departure, minutesBefore: Self.reminderMinutesBefore, now: Date()) else { continue }
                notifications.schedule(
                    id: leg.notificationID,
                    at: fireDate,
                    title: "\(leg.mode.label) to \(leg.destination)",
                    body: "Leaves \(leg.departure.formatted(date: .omitted, time: .shortened)) from \(leg.origin)",
                    category: NotificationService.Category.tripLeg,
                    link: URL(string: "pathos://leg/\(leg.id.uuidString)"),
                    timeSensitive: true
                )
            }
        }
    }

    func leg(id: UUID) -> TripLeg? {
        all().flatMap(\.legs).first { $0.id == id }
    }

    /// Puts both ends of a leg on the map from what you typed. "Home" and "Work" use your saved
    /// places; anything else is looked up in Apple Maps. Ends you've already pinned are kept.
    func pinEnds(of leg: TripLeg, places: PlacesService, vault: SpatialVaultService, near here: CLLocation?) async {
        let search = here ?? CLLocation(latitude: 12.9716, longitude: 77.5946)
        func locate(_ name: String) async -> CLLocationCoordinate2D? {
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            if key == "home", let home = vault.place(ofKind: .home) { return home.coordinate }
            if key == "work", let work = vault.place(ofKind: .work) { return work.coordinate }
            if key == "here" || key == "current location" { return here?.coordinate }
            return (try? await places.search(name, near: search, radius: 200_000))?.first?.coordinate
        }
        if leg.originCoordinate == nil, let origin = await locate(leg.origin) {
            leg.originLatitude = origin.latitude
            leg.originLongitude = origin.longitude
        }
        if leg.destinationCoordinate == nil, let destination = await locate(leg.destination) {
            leg.destinationLatitude = destination.latitude
            leg.destinationLongitude = destination.longitude
        }
        persist()
    }

    private func persist() {
        try? context.save()
    }
}

/// Trip legs on the map and in Radar: where you need to be before a leg leaves, and where
/// you're headed once it has.
final class TripEventSource: EventSource {
    private let store: TripStore

    /// Legs further ahead than this stay in the Day tab, not on today's map.
    static let horizon: TimeInterval = 36 * 3_600

    init(store: TripStore) {
        self.store = store
    }

    func events(near location: CLLocation) async -> [LocalEvent] {
        let now = Date()
        return store.all().flatMap(\.legs).compactMap { leg in
            let arrival = TripStore.plannedLeg(leg).arrivalEstimate() ?? leg.departure.addingTimeInterval(3_600)
            guard arrival > now, leg.departure < now.addingTimeInterval(Self.horizon) else { return nil }
            let isUnderway = leg.departure <= now
            let pin = isUnderway ? leg.destinationCoordinate : (leg.originCoordinate ?? leg.destinationCoordinate)
            let time = (isUnderway ? arrival : leg.departure).formatted(date: .omitted, time: .shortened)
            return LocalEvent(
                id: "leg:\(leg.id.uuidString)",
                title: "\(leg.mode.label) to \(leg.destination)",
                subtitle: isUnderway ? "Arrives about \(time)" : "Leaves \(time) from \(leg.origin)",
                start: leg.departure,
                latitude: pin?.latitude,
                longitude: pin?.longitude,
                distanceMeters: pin.map { location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) },
                source: .trip,
                symbol: leg.mode.symbol
            )
        }
    }
}
