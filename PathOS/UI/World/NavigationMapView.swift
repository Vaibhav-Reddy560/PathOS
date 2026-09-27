import CoreLocation
import MapKit
import SwiftUI

/// The map while you're being led somewhere: MapKit's own, doing its own following.
///
/// Deliberately plain. The camera, the rotation and the smoothing of your position between fixes
/// are `MKMapView`'s, through `userTrackingMode = .followWithHeading` — the same thing every other
/// app on the phone uses. Hand-rolled versions of those (a look-ahead camera, a heading dead band,
/// an animation per location update) are what made it drift and lag.
///
/// Two things are PathOS's own. The line is drawn only ahead of you, in stretches coloured by the
/// traffic on them, and its head is carried forward between fixes so it keeps up with a puck MapKit
/// is moving smoothly. And the puck itself is drawn here, because MapKit's own comes with a wide
/// pale halo whenever the fix is poor, which reads on a dark map as a hole in the glass.
struct NavigationMapView: UIViewRepresentable {
    /// The leg's route, drawn as the line to follow.
    var route: [CLLocationCoordinate2D]
    /// Where you were on it at the last fix, and how fast: the line's head is drawn from this.
    var trim: RouteTrim.Anchor?
    /// How the traffic runs along it. Empty draws one aurora line, which is what it was before.
    var bands: [RouteTraffic.Band] = []
    /// Apple's own places, when you've asked to see them.
    var places = POIDisplay()
    /// The last fix, so the first frame opens on the road rather than on nothing.
    var here: CLLocationCoordinate2D?
    /// False once the map has been moved by hand; set back by Recentre.
    @Binding var isFollowing: Bool

    /// How much road is in view, in metres: close enough to see the turn you're taking.
    static let metresAcross = 420.0
    /// Three is enough for what the probe can tell apart, with one spare.
    static let bandSlots = 3

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = false
        map.showsScale = false
        map.isPitchEnabled = true
        map.overrideUserInterfaceStyle = .dark
        context.coordinator.apply(places, to: map)

        // Tracking is switched on in the coordinator, once there's a fix to zoom to. Asking for
        // it here instead makes MapKit pick its own region on the first fix, which is city-wide.
        context.coordinator.frame(on: route.first ?? here, in: map)
        context.coordinator.startDisplayLink()
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isFollowing = $isFollowing
        coordinator.apply(places, to: map)
        // The route is fetched over the network, so the first frames of a trip have none. Keep
        // the camera on wherever we do know about until MapKit has a fix of its own to follow.
        coordinator.frame(on: route.first ?? here, in: map)

        // Set before the route is laid out, so a new line starts where you are on it rather than
        // where you were on the old one.
        coordinator.bands = bands.isEmpty ? [RouteTraffic.Band(start: 0, end: 1, flow: .clear)] : bands
        coordinator.anchor = trim

        // Coordinates aren't comparable; the count and the ends say whether it's a new route.
        let fingerprint = Self.fingerprint(of: route)
        if coordinator.routeFingerprint != fingerprint {
            coordinator.routeFingerprint = fingerprint
            coordinator.layOutRoute(route, on: map)
        }
        coordinator.draw(force: true)
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
    }

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
        var bands: [RouteTraffic.Band] = []
        var anchor: RouteTrim.Anchor?
        var hasStartedFollowing = false
        var isSettingUp = false
        /// Whether the camera has ever been put somewhere real. Until it has, the zoom range is
        /// left alone.
        private var hasFramed = false

        /// The dark line under the coloured ones, and one line per stretch. All of them run over
        /// the same coordinates: which part each draws is a fraction of the line's length, so the
        /// colours meet on the road without the route being cut into pieces.
        private var casing: MKPolyline?
        private var bandLines: [BandLine] = []
        private var bandRenderers: [Int: MKPolylineRenderer] = [:]
        private var casingRenderer: MKPolylineRenderer?
        /// Where the head is drawn now, and the length it's measured against.
        private var shown = 0.0
        private var routeMetres = 0.0
        private var displayLink: CADisplayLink?
        private var poiFingerprint = ""

        init(isFollowing: Binding<Bool>) {
            self.isFollowing = isFollowing
        }

        // MARK: The camera

        /// Puts the camera on the road at street level, and only then narrows how far it may zoom.
        ///
        /// The order matters. `cameraZoomRange` clamps whatever region the map is showing, and the
        /// region a fresh `MKMapView` shows is the whole world centred on nothing — so setting the
        /// range first zooms the map to a few hundred metres of the Gulf of Guinea and leaves it
        /// there until the first fix arrives. That is the flat blue map with no route on it.
        func frame(on coordinate: CLLocationCoordinate2D?, in map: MKMapView) {
            // Once MapKit is following, the camera is its business.
            guard !hasStartedFollowing, let coordinate, CLLocationCoordinate2DIsValid(coordinate) else { return }
            map.setRegion(
                MKCoordinateRegion(center: coordinate, latitudinalMeters: NavigationMapView.metresAcross,
                                   longitudinalMeters: NavigationMapView.metresAcross),
                animated: false
            )
            guard !hasFramed else { return }
            hasFramed = true
            // Holds street level however MapKit moves the camera while it follows: a region set
            // once is overridden the moment tracking takes over.
            map.cameraZoomRange = MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: NavigationMapView.metresAcross * 0.6,
                maxCenterCoordinateDistance: NavigationMapView.metresAcross * 1.6
            )
        }

        // MARK: The route

        func layOutRoute(_ route: [CLLocationCoordinate2D], on map: MKMapView) {
            map.removeOverlays(map.overlays)
            bandRenderers = [:]
            casingRenderer = nil
            bandLines = []
            casing = nil
            shown = anchor?.fraction ?? 0
            routeMetres = anchor?.routeMetres ?? 0
            guard route.count > 1 else { return }

            let dark = MKPolyline(coordinates: route, count: route.count)
            casing = dark
            map.addOverlay(dark, level: .aboveRoads)
            // Added furthest-first so the stretch you're on is drawn last and sits on top: where
            // two stretches meet, its round cap overshoots into the one beyond rather than the
            // other way round.
            for slot in (0..<NavigationMapView.bandSlots).reversed() {
                let line = BandLine(coordinates: route, count: route.count)
                line.slot = slot
                bandLines.append(line)
                map.addOverlay(line, level: .aboveRoads)
            }
        }

        /// Where the head of the line is now, and what each stretch should draw.
        func draw(force: Bool = false, now: Date = Date()) {
            if let anchor {
                routeMetres = anchor.routeMetres
                shown = RouteTrim.shown(anchor, lastShown: shown, sinceFix: now.timeIntervalSince(anchor.at))
            }
            if let casingRenderer {
                set(casingRenderer, start: shown, end: 1, force: force)
            }
            for slot in 0..<NavigationMapView.bandSlots {
                guard let renderer = bandRenderers[slot] else { continue }
                guard let band = bands[safe: slot] else {
                    hide(renderer)
                    continue
                }
                renderer.strokeColor = UIColor(band.flow.role.color)
                set(renderer, start: max(band.start, shown), end: band.end, force: force)
            }
        }

        /// Half a metre of real road — below that nothing on screen would move, and a redraw walks
        /// the whole line. The old fixed fraction was 7 m on a long leg, which stepped visibly.
        private func set(_ renderer: MKPolylineRenderer, start: Double, end: Double, force: Bool) {
            guard start < end else {
                hide(renderer)
                return
            }
            let moved = abs(Double(renderer.strokeStart) - start) * max(routeMetres, 1)
            let wasHidden = renderer.alpha < 1
            guard force || wasHidden || moved > 0.5 else { return }
            renderer.alpha = 1
            renderer.strokeStart = CGFloat(min(0.999, max(0, start)))
            renderer.strokeEnd = CGFloat(min(1, max(0, end)))
            renderer.setNeedsDisplay()
        }

        /// Alpha rather than a zero-length stretch: a round cap still paints a dot at zero length.
        private func hide(_ renderer: MKPolylineRenderer) {
            guard renderer.alpha > 0 else { return }
            renderer.alpha = 0
            renderer.setNeedsDisplay()
        }

        // MARK: Keeping up between fixes

        func startDisplayLink() {
            guard displayLink == nil else { return }
            let proxy = DisplayLinkProxy()
            proxy.coordinator = self
            let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
            // A line's head needs nothing like the screen's full rate, and asking for it would
            // hold ProMotion at 120 for the whole drive.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        /// Nothing to carry forward: stopped at a light, or a fix so old that reckoning from it
        /// would be invention.
        private var isWorthReckoning: Bool {
            guard let anchor, !bandLines.isEmpty else { return false }
            guard anchor.metresPerSecond >= RouteTrim.stopped else { return false }
            return Date().timeIntervalSince(anchor.at) < 5
        }

        fileprivate func tick() {
            guard isWorthReckoning else { return }
            draw()
        }

        // MARK: Apple's own places

        func apply(_ places: POIDisplay, to map: MKMapView) {
            // Reassigning the configuration makes MapKit reload its tiles, so it happens only when
            // the answer actually changes — not on every fix.
            let fingerprint = places.fingerprint
            guard fingerprint != poiFingerprint else { return }
            poiFingerprint = fingerprint
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            configuration.pointOfInterestFilter = places.filter
            // Apple's own traffic on every other road. Set here, not on the map: the configuration
            // carries its own value and replaces whatever the map was told.
            configuration.showsTraffic = true
            map.preferredConfiguration = configuration
        }

        // MARK: MapKit's own reports

        /// The first fix sets street-level zoom, and only then is MapKit asked to follow: it
        /// keeps whatever zoom it is handed, and the one it picks for itself is city-wide.
        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !hasStartedFollowing, let here = userLocation.location?.coordinate else { return }
            frame(on: here, in: mapView)
            hasStartedFollowing = true
            isSettingUp = true
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

        /// Our own puck. MapKit's draws a wide pale circle around itself whenever the fix is poor
        /// or the position is being rounded, which on a dark map reads as a hole in the glass. The
        /// heading cone goes with it and isn't missed: the map turns to your heading, so a cone
        /// that always points up the screen says nothing.
        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard annotation is MKUserLocation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: PuckView.reuseID) as? PuckView
                ?? PuckView(annotation: annotation, reuseIdentifier: PuckView.reuseID)
            view.annotation = annotation
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.lineCap = .round
            renderer.lineJoin = .round
            if let band = line as? BandLine {
                renderer.lineWidth = 9
                renderer.strokeColor = UIColor(Color.aurora)
                bandRenderers[band.slot] = renderer
            } else {
                renderer.lineWidth = 15
                renderer.strokeColor = UIColor(Color.void).withAlphaComponent(0.9)
                casingRenderer = renderer
            }
            // MapKit can ask for a renderer again at any time, so it starts where the line is now.
            draw(force: true)
            return renderer
        }
    }
}

/// One stretch of the route. A subclass only so the renderer can tell them apart. Not a view and
/// not on any actor: MapKit makes and keeps these itself.
private nonisolated final class BandLine: MKPolyline {
    var slot = 0
}

/// Weak, because `CADisplayLink` keeps its target alive and the run loop keeps the link: a
/// coordinator as its own target would outlive the map and go on firing.
private final class DisplayLinkProxy: NSObject {
    weak var coordinator: NavigationMapView.Coordinator?

    // NSObject's own is nonisolated, so this one has to be too.
    override nonisolated init() {
        super.init()
    }

    @objc func tick() {
        coordinator?.tick()
    }
}

/// You, on the navigation map: the same dot the browsing map draws, without MapKit's halo.
private final class PuckView: MKAnnotationView {
    static let reuseID = "pathos.puck"

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        canShowCallout = false
        isEnabled = false
        zPriority = .max

        let ring = CAShapeLayer()
        ring.path = UIBezierPath(ovalIn: bounds).cgPath
        ring.fillColor = UIColor(Color.ice).cgColor
        ring.shadowColor = UIColor(Color.void).cgColor
        ring.shadowOpacity = 0.5
        ring.shadowRadius = 4
        ring.shadowOffset = .zero
        let dot = CAShapeLayer()
        dot.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 3.5, dy: 3.5)).cgPath
        dot.fillColor = UIColor(Color.aurora).cgColor
        // MapKit moves this view itself; Core Animation must not animate it as well.
        for layer in [ring, dot] {
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull()]
        }
        layer.addSublayer(ring)
        layer.addSublayer(dot)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
