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
                    category: NotificationService.Category.journey,
                    link: URL(string: "pathos://day"),
                    timeSensitive: true
                )
            }
        }
    }

    private func persist() {
        try? context.save()
    }
}
