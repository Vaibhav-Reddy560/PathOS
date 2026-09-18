import CoreLocation
import Foundation
import Observation

/// The metro or bus journey you're on, and how far along you are.
///
/// No Indian metro or bus service publishes live vehicle positions, so this tracks *you*: your
/// GPS position snapped to the stops, with the clock carrying the estimate underground.
@Observable
final class TransitService {
    private(set) var journey: Journey?
    private(set) var progress: JourneyProgress?
    /// Bus stops and metro stations around you, for the map.
    private(set) var nearbyStops: [TransitStopInput] = []
    /// Loaded the first time it's needed; decoding takes a moment, so never on launch.
    private(set) var busNetwork: BusNetwork?
    @ObservationIgnored private var lastNearbyLocation: CLLocation?

    @ObservationIgnored private let notifications: NotificationService
    /// "change@3", "getOff" — each said once per journey.
    @ObservationIgnored private var announced: Set<String> = []

    init(notifications: NotificationService) {
        self.notifications = notifications
        // Station coordinates used to be looked up in Apple Maps and cached; they're bundled now.
        UserDefaults.standard.removeObject(forKey: "pathos.stationFixes")
    }

    func start(_ journey: Journey) {
        guard journey.stops.count > 1 else { return }
        self.journey = journey
        announced = []
        update(location: nil)
    }

    func end() {
        if let journey {
            Task { await notifications.removePending(withPrefix: "pathos.journey.\(journey.id.uuidString)") }
        }
        journey = nil
        progress = nil
    }

    /// Recomputes progress. Called every few seconds while travelling, in the background too.
    func update(location: CLLocation?) {
        guard let journey else { return }
        let nearest = location.flatMap {
            JourneyTracker.nearestStopIndex(to: $0.coordinate, stops: journey.stops, radius: journey.stopRadius)
        }
        let updated = JourneyTracker.progress(
            stops: journey.stops,
            nearestIndex: nearest,
            elapsed: Date().timeIntervalSince(journey.startedAt)
        )
        progress = updated
        announceIfNeeded(updated, journey: journey)
    }

    /// Loads the bus network if it isn't already, off the main thread.
    @discardableResult
    func loadBusNetwork() async -> BusNetwork? {
        if busNetwork == nil {
            busNetwork = await BusNetwork.load()
        }
        return busNetwork
    }

    /// Finds stops around you. Skipped until you've moved a little, since stops don't move.
    func refreshNearby(location: CLLocation) async {
        if let last = lastNearbyLocation, last.distance(from: location) < 80, !nearbyStops.isEmpty { return }
        lastNearbyLocation = location
        var found: [TransitStopInput] = []

        for line in MetroNetwork.lines {
            for station in line.stops {
                let distance = location.distance(from: CLLocation(latitude: station.lat, longitude: station.lon))
                guard distance <= 900, !found.contains(where: { $0.name == station.name }) else { continue }
                found.append(TransitStopInput(
                    kind: .metro,
                    name: station.name,
                    subtitle: MetroNetwork.interchangeLines(for: station.name).map(\.name).joined(separator: " · "),
                    latitude: station.lat,
                    longitude: station.lon,
                    distanceMeters: distance
                ))
            }
        }

        if let network = await loadBusNetwork() {
            // One pin per stop name: the pair on either side of the road would only crowd the map.
            var byName: [String: (stop: BusStop, distance: Double)] = [:]
            for entry in network.nearbyStops(to: location.coordinate, within: 450) where byName[entry.stop.name] == nil {
                byName[entry.stop.name] = entry
            }
            for (name, entry) in byName {
                let routes = Set(network.stops(named: name).flatMap { network.services(at: $0.id) }.map(\.pattern.route.number))
                found.append(TransitStopInput(
                    kind: .bus,
                    name: name,
                    subtitle: routes.count == 1 ? "Bus stop · 1 route" : "Bus stop · \(routes.count) routes",
                    latitude: entry.stop.latitude,
                    longitude: entry.stop.longitude,
                    distanceMeters: entry.distance
                ))
            }
        }
        nearbyStops = found.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    /// One notification before each change, and one when your stop is next.
    private func announceIfNeeded(_ progress: JourneyProgress, journey: Journey) {
        if progress.isChangingNext, let index = progress.nextStationIndex,
           let instruction = journey.stops[safe: index]?.changeInstruction,
           announced.insert("change@\(index)").inserted {
            notifications.post(
                id: "pathos.journey.\(journey.id.uuidString).change\(index)",
                title: "Change next: \(journey.stationName(at: index))",
                body: instruction,
                category: NotificationService.Category.journey,
                link: URL(string: "pathos://dashboard"),
                timeSensitive: true
            )
        }
        if progress.isArrivingNext, announced.insert("getOff").inserted {
            notifications.post(
                id: "pathos.journey.\(journey.id.uuidString).next",
                title: "Get off next: \(journey.destination)",
                body: "\(journey.lineName) · about \(progress.estimatedMinutesRemaining) min",
                category: NotificationService.Category.journey,
                link: URL(string: "pathos://dashboard"),
                timeSensitive: true
            )
        }
    }
}

extension Array {
    nonisolated subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
