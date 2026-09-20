import CoreLocation
import MapKit
import SwiftUI

/// The map while you're being led somewhere: MapKit's own, doing its own following.
///
/// Deliberately plain. The puck, the camera, the rotation and the smoothing between fixes are
/// `MKMapView`'s, through `userTrackingMode = .followWithHeading` — the same thing every other app
/// on the phone uses. Hand-rolled versions of those (a custom arrow, a look-ahead camera, a
/// heading dead band, an animation per location update) are what made it drift and lag.
struct NavigationMapView: UIViewRepresentable {
    /// The leg's route, drawn as the line to follow.
    var route: [CLLocationCoordinate2D]
    /// False once the map has been moved by hand; set back by Recentre.
    @Binding var isFollowing: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = false
        map.showsScale = false
        map.showsTraffic = false
        map.isPitchEnabled = true
        map.overrideUserInterfaceStyle = .dark

        // Holds street level however MapKit moves the camera while it follows: a region set once
        // is overridden the moment tracking takes over.
        map.cameraZoomRange = MKMapView.CameraZoomRange(
            minCenterCoordinateDistance: Self.metresAcross * 0.6,
            maxCenterCoordinateDistance: Self.metresAcross * 1.6
        )

        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = MKPointOfInterestFilter.excludingAll
        map.preferredConfiguration = configuration

        // Tracking is switched on in the coordinator, once there's a fix to zoom to. Asking for
        // it here instead makes MapKit pick its own region on the first fix, which is city-wide.
        if let first = route.first {
            map.setRegion(MKCoordinateRegion(center: first, latitudinalMeters: Self.metresAcross,
                                             longitudinalMeters: Self.metresAcross), animated: false)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.isFollowing = $isFollowing

        // Coordinates aren't comparable; the count and the ends say whether it's a new route.
        let fingerprint = Self.fingerprint(of: route)
        if context.coordinator.routeFingerprint != fingerprint {
            context.coordinator.routeFingerprint = fingerprint
            map.removeOverlays(map.overlays)
            if route.count > 1 {
                map.addOverlay(MKPolyline(coordinates: route, count: route.count), level: .aboveRoads)
            }
        }
        // Recentre. Before the first fix there's nothing to follow, so it waits.
        if isFollowing, context.coordinator.hasStartedFollowing, map.userTrackingMode == .none {
            map.setUserTrackingMode(Self.trackingMode, animated: true)
        }
    }

    /// How much road is in view, in metres: close enough to see the turn you're taking.
    static let metresAcross = 420.0

    /// Turned to the way you're facing where there's a compass to know it; simply centred where
    /// there isn't, as on a simulator — asking for a heading that can't be had leaves MapKit
    /// refusing to follow at all.
    static var trackingMode: MKUserTrackingMode {
        CLLocationManager.headingAvailable() ? .followWithHeading : .follow
    }

    /// Enough of the route to tell one from another: how many points, and where it starts and ends.
    static func fingerprint(of route: [CLLocationCoordinate2D]) -> String {
        guard let first = route.first, let last = route.last else { return "" }
        return String(format: "%d:%.5f,%.5f>%.5f,%.5f", route.count,
                      first.latitude, first.longitude, last.latitude, last.longitude)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isFollowing: $isFollowing)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var isFollowing: Binding<Bool>
        var routeFingerprint = ""
        var hasStartedFollowing = false
        var isSettingUp = false

        init(isFollowing: Binding<Bool>) {
            self.isFollowing = isFollowing
        }

        /// The first fix sets street-level zoom, and only then is MapKit asked to follow: it
        /// keeps whatever zoom it is handed, and the one it picks for itself is city-wide.
        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !hasStartedFollowing, let here = userLocation.location?.coordinate else { return }
            hasStartedFollowing = true
            isSettingUp = true
            mapView.setRegion(
                MKCoordinateRegion(center: here, latitudinalMeters: NavigationMapView.metresAcross,
                                   longitudinalMeters: NavigationMapView.metresAcross),
                animated: false
            )
            mapView.setUserTrackingMode(NavigationMapView.trackingMode, animated: true)
            isSettingUp = false
        }

        /// MapKit reports when it stops following because the map was moved by hand.
        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            // Zooming to the first fix drops tracking for an instant on its way to turning it on;
            // that isn't you moving the map.
            guard !isSettingUp else { return }
            let following = mode != .none
            // Reported from inside MapKit's own layout pass, so the write waits for the next turn
            // of the run loop: changing SwiftUI state during an update is dropped.
            DispatchQueue.main.async { [isFollowing] in
                if isFollowing.wrappedValue != following {
                    isFollowing.wrappedValue = following
                }
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = UIColor(Color.aurora)
            renderer.lineWidth = 9
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
    }
}
