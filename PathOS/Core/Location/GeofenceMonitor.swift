import CoreLocation
import Observation

nonisolated struct GeofenceRegion: Hashable, Sendable {
    var id: String
    var latitude: Double
    var longitude: Double
    var radius: Double
    /// Whether the user is inside right now; avoids a spurious enter/exit right after adding.
    var userIsInside: Bool
}

nonisolated enum GeofenceTransition: Sendable {
    case entered
    case exited
}

nonisolated struct GeofenceEvent: Sendable {
    var id: String
    var transition: GeofenceTransition
    var date: Date
}

/// Wraps CLMonitor. iOS relaunches the app in the background for these events.
@Observable
final class GeofenceMonitor {
    static let maxRegions = 20
    static let monitorName = "PathOSGeofences"

    private(set) var monitoredIDs: Set<String> = []

    @ObservationIgnored private var monitor: CLMonitor?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    /// Call as early as possible at launch so the event that woke the app is delivered.
    func start(onEvent: @escaping (GeofenceEvent) -> Void) async {
        guard monitor == nil else { return }
        let monitor = await CLMonitor(Self.monitorName)
        self.monitor = monitor
        monitoredIDs = Set(await monitor.identifiers)

        eventsTask = Task {
            do {
                for try await event in await monitor.events {
                    let transition: GeofenceTransition?
                    switch event.state {
                    case .satisfied: transition = .entered
                    case .unsatisfied: transition = .exited
                    default: transition = nil
                    }
                    if let transition {
                        onEvent(GeofenceEvent(id: event.identifier, transition: transition, date: event.date))
                    }
                }
            } catch {
                // Monitoring stream ended; restarted on next launch.
            }
        }
    }

    /// Makes the monitored set match `regions`, which the caller orders by priority.
    func sync(_ regions: [GeofenceRegion]) async {
        guard let monitor else { return }
        let wanted = Array(regions.prefix(Self.maxRegions))
        let wantedIDs = Set(wanted.map(\.id))
        let existingIDs = Set(await monitor.identifiers)

        for id in existingIDs.subtracting(wantedIDs) {
            await monitor.remove(id)
        }

        for region in wanted {
            let center = CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude)
            if existingIDs.contains(region.id),
               let record = await monitor.record(for: region.id),
               let existing = record.condition as? CLMonitor.CircularGeographicCondition,
               abs(existing.radius - region.radius) < 1,
               GeoMath.distance(from: existing.center, to: center) < 1 {
                continue
            }
            let condition = CLMonitor.CircularGeographicCondition(center: center, radius: region.radius)
            await monitor.add(condition, identifier: region.id, assuming: region.userIsInside ? .satisfied : .unsatisfied)
        }

        monitoredIDs = Set(await monitor.identifiers)
    }

    func remove(id: String) async {
        guard let monitor else { return }
        await monitor.remove(id)
        monitoredIDs.remove(id)
    }
}
