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
    /// The direction you're actually travelling, from GPS rather than the compass. In a vehicle
    /// this is what to turn a map by: the compass reads whichever way the phone happens to face.
    private(set) var courseDegrees: Double?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    @ObservationIgnored private var headingClients = 0
    /// The course, averaged over the last few fixes and held through a stop.
    @ObservationIgnored private var course = TravelCourse.Reading(degrees: nil, at: .distantPast)
    /// True while a way is being followed by road, which asks CoreLocation for its best.
    @ObservationIgnored private var isNavigating = false
    /// Called when a move of a few hundred metres wakes PathOS; see `setSignificantChangesActive`.
    @ObservationIgnored var onSignificantChange: ((CLLocation) -> Void)?
    /// Called with every fix, from either source: what the day's distance is counted from.
    @ObservationIgnored var onFix: ((CLLocation) -> Void)?

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
        let configuration: CLLocationUpdate.LiveConfiguration = isNavigating ? .automotiveNavigation : .otherNavigation
        updatesTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(configuration) {
                    guard let self else { return }
                    if let location = update.location {
                        self.location = location
                        self.onFix?(location)
                        // Where you're going, not where the phone is pointing. Read here rather
                        // than in the significant-change delegate, which this stream outruns: its
                        // freshness guard always lost, so the course was never set while driving.
                        self.course = TravelCourse.update(
                            self.course,
                            course: location.course,
                            accuracy: location.courseAccuracy,
                            speed: location.speed,
                            at: location.timestamp
                        )
                        self.courseDegrees = self.course.degrees
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

    /// Following a road leg asks CoreLocation for navigation-grade fixes, which arrive about once
    /// a second and carry a usable course. It's restarted only when the answer changes, since a
    /// restart costs a fix.
    func setNavigating(_ navigating: Bool) {
        guard navigating != isNavigating else { return }
        isNavigating = navigating
        guard updatesTask != nil else { return }
        stopUpdates()
        startUpdates()
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

    /// Wakes PathOS, even after it has been closed, each time you've moved a few hundred metres.
    /// Cheap enough to leave on all day, unlike live updates; needs Always access to work in the
    /// background.
    func setSignificantChangesActive(_ active: Bool) {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        if active {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
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

    /// Only significant changes arrive here; live updates come through `CLLocationUpdate`.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        MainActor.assumeIsolated {
            if self.location.map({ latest.timestamp > $0.timestamp }) ?? true {
                self.location = latest
                self.onFix?(latest)
                // The course is read from the live stream, which is fresher than anything that
                // reaches here; a wake from a few hundred metres away says nothing about which
                // way you're pointing now.
            }
            self.onSignificantChange?(latest)
        }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }
}
