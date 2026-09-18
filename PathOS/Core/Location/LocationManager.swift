import CoreLocation
import Observation

@Observable
final class LocationManager: NSObject {
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var location: CLLocation?
    /// True-north heading in degrees (falls back to magnetic until a location fix exists).
    private(set) var headingDegrees: Double?
    /// Degrees of uncertainty; negative means the compass needs calibrating.
    private(set) var headingAccuracy: Double = -1

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    @ObservationIgnored private var headingClients = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 2
        authorization = manager.authorizationStatus
    }

    var hasAnyAccess: Bool { authorization == .authorizedAlways || authorization == .authorizedWhenInUse }
    var hasAlwaysAccess: Bool { authorization == .authorizedAlways }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// iOS only offers the Always upgrade after When-In-Use has been granted.
    func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    func startUpdates() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    guard let self else { return }
                    if let location = update.location {
                        self.location = location
                    }
                }
            } catch {
                // Stream ended (e.g. cancelled); a later startUpdates() restarts it.
            }
        }
    }

    func stopUpdates() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    /// Keeps live updates flowing in the background during commute/compass sessions.
    func setBackgroundSessionActive(_ active: Bool) {
        if active {
            if backgroundSession == nil {
                backgroundSession = CLBackgroundActivitySession()
            }
        } else {
            backgroundSession?.invalidate()
            backgroundSession = nil
        }
    }

    /// Reference-counted so the compass view and the compass Live Activity can share it.
    func beginHeadingUpdates() {
        headingClients += 1
        if headingClients == 1, CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    func endHeadingUpdates() {
        headingClients = max(0, headingClients - 1)
        if headingClients == 0 {
            manager.stopUpdatingHeading()
        }
    }

    /// A recent location, or the next reasonably accurate fix.
    func currentLocation() async -> CLLocation? {
        if let location, location.timestamp.timeIntervalSinceNow > -60 {
            return location
        }
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if let fix = update.location, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 100 {
                    location = fix
                    return fix
                }
                if update.authorizationDenied || update.authorizationDeniedGlobally {
                    return nil
                }
            }
        } catch {
            return location
        }
        return location
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            self.authorization = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        let accuracy = newHeading.headingAccuracy
        MainActor.assumeIsolated {
            self.headingDegrees = heading
            self.headingAccuracy = accuracy
        }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }
}
