import CoreLocation
import Foundation
import MapKit
import Observation

/// Works out whole ways to get somewhere, and remembers the answer for a few minutes.
///
/// The planning is `DoorToDoor`'s; this fetches the road and walking times it needs from Apple
/// Maps. Those calls are the slow part, so each pair of points is asked for once and kept.
@Observable
final class JourneyPlanner {
    /// What a destination's options were, and when they were worked out.
    nonisolated struct Plan: Sendable {
        var destinationName: String
        var destination: CLLocationCoordinate2D
        var options: [DoorToDoor.Option]
        var from: CLLocationCoordinate2D
        var at: Date
    }

    private(set) var plans: [String: Plan] = [:]
    private(set) var planning: Set<String> = []

    @ObservationIgnored private let places: PlacesService
    @ObservationIgnored private let transit: TransitService
    /// Apple Maps times, by the two points and the mode.
    @ObservationIgnored private var hops: [String: DoorToDoor.RoadHop] = [:]

    /// Worked out again once you've moved this far, or after this long.
    private let staleDistance = 400.0
    private let staleAge: TimeInterval = 8 * 60

    init(places: PlacesService, transit: TransitService) {
        self.places = places
        self.transit = transit
    }

    func plan(for key: String) -> Plan? { plans[key] }

    func isPlanning(_ key: String) -> Bool { planning.contains(key) }

    /// The ways to reach a place from where you are. `key` identifies the destination, so Work's
    /// options and an event's are kept apart.
    @discardableResult
    func options(key: String, to destination: CLLocationCoordinate2D, named name: String,
                 from origin: CLLocation, now: Date = Date(), force: Bool = false) async -> [DoorToDoor.Option] {
        if !force, let plan = plans[key],
           GeoMath.distance(from: plan.from, to: origin.coordinate) < staleDistance,
           now.timeIntervalSince(plan.at) < staleAge,
           GeoMath.distance(from: plan.destination, to: destination) < 100 {
            return plan.options
        }
        guard !planning.contains(key) else { return plans[key]?.options ?? [] }
        planning.insert(key)
        defer { planning.remove(key) }

        let options = await DoorToDoor.options(
            from: origin.coordinate,
            to: destination,
            destinationName: name,
            now: now,
            bus: transit.busNetwork,
            road: { [weak self] from, to, byRoad in
                await self?.hop(from: from, to: to, byRoad: byRoad)
            }
        )
        plans[key] = Plan(destinationName: name, destination: destination, options: options, from: origin.coordinate, at: now)
        return options
    }

    func forget(_ key: String) {
        plans[key] = nil
    }

    /// One Apple Maps time, kept so the same hop isn't asked for twice while planning.
    private func hop(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, byRoad: Bool) async -> DoorToDoor.RoadHop? {
        let key = String(format: "%.4f,%.4f>%.4f,%.4f,%@", from.latitude, from.longitude, to.latitude, to.longitude, byRoad ? "road" : "foot")
        if let hop = hops[key] { return hop }
        guard let measured = await places.hop(to: to, from: CLLocation(latitude: from.latitude, longitude: from.longitude),
                                              transport: byRoad ? .automobile : .walking) else { return nil }
        let hop = DoorToDoor.RoadHop(minutes: measured.minutes, distanceMeters: measured.distanceMeters)
        hops[key] = hop
        return hop
    }
}
