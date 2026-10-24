import CoreLocation
import Foundation
import Observation
import UIKit

/// The metro or bus journey you're on, and how far along you are.
///
/// No Indian metro or bus service publishes live vehicle positions, so this tracks *you*: your
/// GPS position snapped to the stops, with the clock carrying the estimate underground.
@Observable
final class TransitService {
    private(set) var journey: Journey?
    private(set) var progress: JourneyProgress?
    /// Where you are on the ride, kept from fix to fix.
    private(set) var track = RideTrack()
    /// Bus stops and metro stations around you, for the map.
    private(set) var nearbyStops: [TransitStopInput] = []
    /// Loaded the first time it's needed; decoding takes a moment, so never on launch.
    private(set) var busNetwork: BusNetwork?
    @ObservationIgnored private var lastNearbyLocation: CLLocation?
    /// Told whenever the ride moves on, so it can be kept across PathOS being closed.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let notifications: NotificationService
    /// "change@3", "getOff" — each said once per journey.
    @ObservationIgnored private var announced: Set<String> = []

    /// Waiting this long on a platform, you're asked whether you're on the train.
    static let askAfter: TimeInterval = 4 * 60

    init(notifications: NotificationService) {
        self.notifications = notifications
        // Station coordinates used to be looked up in Apple Maps and cached; they're bundled now.
        UserDefaults.standard.removeObject(forKey: "pathos.stationFixes")
    }

    /// Starts following a ride — afresh, or where it had got to before PathOS was closed.
    func start(_ journey: Journey, track: RideTrack = RideTrack(), location: CLLocation? = nil) {
        guard journey.stops.count > 1 else { return }
        self.journey = journey
        self.track = track
        announced = []
        update(location: location)
    }

    func end() {
        if let journey {
            Task { await notifications.removePending(withPrefix: "pathos.journey.\(journey.id.uuidString)") }
        }
        journey = nil
        progress = nil
        track = RideTrack()
        onChange?()
    }

    /// Moves the ride on by the latest fix. Called on every fix while you're on it, in the
    /// background too.
    func update(location: CLLocation?, now: Date = Date()) {
        guard let journey else { return }
        let fix = location.map {
            RideFix(coordinate: $0.coordinate, accuracy: $0.horizontalAccuracy, at: $0.timestamp, speed: $0.speed >= 0 ? $0.speed : nil)
        }
        let moved = JourneyTracker.advance(track, in: journey, fix: fix, now: now)
        let changed = moved != track
        track = moved
        let updated = JourneyTracker.progress(of: track, in: journey, now: now)
        progress = updated
        announceIfNeeded(updated, journey: journey, now: now)
        if changed { onChange?() }
    }

    /// You've said you're on the train: the minutes count from now.
    func board(now: Date = Date()) {
        guard journey != nil else { return }
        track = JourneyTracker.board(track, now: now)
        update(location: nil, now: now)
        onChange?()
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

        // The nearest few even when none is a walk away: a metro across town still beats not
        // knowing where it is.
        for (station, distance) in MetroNetwork.nearbyStations(to: location.coordinate) {
            found.append(TransitStopInput(
                kind: .metro,
                name: station.name,
                subtitle: MetroNetwork.interchangeLines(for: station.name).map(\.name).joined(separator: " · "),
                latitude: station.lat,
                longitude: station.lon,
                distanceMeters: distance
            ))
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

    /// One notification before each change, one when your stop is next, and — after a while on a
    /// platform with PathOS in your pocket — one asking whether you're on the train yet.
    private func announceIfNeeded(_ progress: JourneyProgress, journey: Journey, now: Date) {
        if progress.isWaiting, let since = track.since, now.timeIntervalSince(since) >= Self.askAfter,
           !track.askedOnBoard.contains(track.part), UIApplication.shared.applicationState != .active {
            track.askedOnBoard.append(track.part)
            notifications.post(
                id: "pathos.journey.\(journey.id.uuidString).aboard\(track.part)",
                title: "On the \(progress.train ?? journey.lineName)?",
                body: "Tap On the train once you've boarded, and the stops count from there.",
                category: NotificationService.Category.ride,
                link: URL(string: "pathos://ride/boarded"),
                timeSensitive: true
            )
        }
        if progress.isChangingNext, let index = progress.nextStationIndex,
           let instruction = journey.stops[safe: index]?.changeInstruction,
           announced.insert("change@\(index)").inserted {
            notifications.post(
                id: "pathos.journey.\(journey.id.uuidString).change\(index)",
                title: "Change at the next stop: \(journey.stationName(at: index))",
                body: instruction,
                category: NotificationService.Category.journey,
                link: URL(string: "pathos://dashboard"),
                timeSensitive: true
            )
        }
        if progress.isArrivingNext, announced.insert("getOff").inserted {
            notifications.post(
                id: "pathos.journey.\(journey.id.uuidString).next",
                title: "Get off at the next stop: \(journey.destination)",
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
