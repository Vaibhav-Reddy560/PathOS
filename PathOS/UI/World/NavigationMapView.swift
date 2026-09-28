import CoreLocation
import MapKit
import os
import SwiftUI

/// The map while you're being led somewhere.
///
/// Everything on it is drawn, every frame, from one `NavigationPose`: where you are — on the
/// route when you're on it — and which way the road is taking you. The camera sits a little ahead
/// of that and turns to it; your arrow sits on it; the line is cut off at it. Nothing can lag
/// anything else, because nothing is worked out twice.
///
/// It used to be MapKit's own following, with the map turned by the phone's compass. The compass
/// in a car points wherever the phone faces, not where the car is going, so on a winding road
/// the map stayed put while the road turned under it; MapKit's dot sat at the raw GPS position,
/// beside the line more often than on it; and the line, trimmed by a separate clock, trailed
/// behind the dot.
///
/// The route is drawn with a clear middle. Apple's own traffic — the orange and red Apple Maps
/// shows — is drawn on the road beneath it, and shows through where there is any.
struct NavigationMapView: UIViewRepresentable {
    /// The leg's route, drawn as the line to follow.
    var route: [CLLocationCoordinate2D]
    /// The last fix: where, which way, how fast, and where that is on the route.
    var fix: NavigationPose.Fix?
    /// Where the line ends: the pin.
    var destination: CLLocationCoordinate2D?
    /// Apple's own places, when you've asked to see them.
    var places = POIDisplay()
    /// Where you last were, so the first frame opens on the road rather than on nothing.
    var here: CLLocationCoordinate2D?
    /// False once the map has been moved by hand; set back by Recentre.
    @Binding var isFollowing: Bool

    /// How much road is in view, in metres: close enough to see the turn you're taking.
    static let metresAcross = 420.0
    /// The camera's distance from the road at street level, and how far a pinch may take it.
    /// Fixed numbers, not read back from the map: read while the map has no size yet, the
    /// distance came back as nothing, and every frame after drew black.
    static let streetDistance = 680.0
    static let zoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 250,
                                                     maxCenterCoordinateDistance: 1_300)
    /// The middle of the screen is this far ahead of you, so more of the road is in front than
    /// behind.
    static let lookAhead = 50.0
    /// How long the map takes to turn to a new direction: quick enough for a zigzag, slow enough
    /// not to jerk at every kink in the line.
    static let turnTime = 0.35
    /// Drawn a little larger than on the launch screen: it has to be found at a glance.
    static let pinScale = 1.3

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        let coordinator = context.coordinator
        map.delegate = coordinator
        // You're drawn here, on the route: MapKit's own dot can only sit where GPS says.
        map.showsUserLocation = false
        map.showsCompass = false
        map.showsScale = false
        map.isPitchEnabled = false
        map.overrideUserInterfaceStyle = .dark
        coordinator.attach(to: map)
        coordinator.apply(places, to: map)
        coordinator.frame(on: route.first ?? here, in: map)
        coordinator.startDisplayLink()
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isFollowing = $isFollowing
        coordinator.apply(places, to: map)
        // The route comes over the network, so the first frames of a trip have none.
        if fix == nil {
            coordinator.frame(on: route.first ?? here, in: map)
        }
        coordinator.fix = fix

        // Coordinates aren't comparable; the count and the ends say whether it's a new route.
        let fingerprint = Self.fingerprint(of: route)
        if coordinator.routeFingerprint != fingerprint {
            coordinator.routeFingerprint = fingerprint
            coordinator.layOutRoute(route, on: map)
        }
        coordinator.place(destination, on: map)
        // Recentre.
        if isFollowing, !coordinator.isDriving {
            coordinator.resumeFollowing()
        }
        coordinator.tick(force: true)
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
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

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var isFollowing: Binding<Bool>
        var fix: NavigationPose.Fix?
        var routeFingerprint = ""
        /// Following: the camera is this coordinator's, and moves with you every frame.
        private(set) var isDriving = true

        private weak var map: MKMapView?
        private var line: NavigationPose.Line?
        private var routeRenderer: RouteRenderer?
        private var you: YouAnnotation?
        private weak var youView: ArrowView?
        private var destinationPin: DestinationPin?
        private var displayLink: CADisplayLink?
        private var poiFingerprint = ""
        private var hasFramed = false

        /// What was drawn last frame: how far along, which way, where the camera pointed.
        private var along: Double?
        private var heading = 0.0
        private var cameraHeading: Double?
        private var drawnHead = -1.0
        private var lastTick: CFTimeInterval?
        /// A Recentre is gliding back; the frames leave the camera alone until it lands.
        private var glidingUntil: CFTimeInterval = 0

        init(isFollowing: Binding<Bool>) {
            self.isFollowing = isFollowing
        }

        func attach(to map: MKMapView) {
            self.map = map
            // Your own hand on the map stops it following you. Recognisers of our own, alongside
            // MapKit's: they see a drag or a pinch begin, and change nothing about how it feels.
            let recognisers: [UIGestureRecognizer] = [
                UIPanGestureRecognizer(target: self, action: #selector(handGesture(_:))),
                UIPinchGestureRecognizer(target: self, action: #selector(handGesture(_:))),
                UIRotationGestureRecognizer(target: self, action: #selector(handGesture(_:))),
            ]
            for recogniser in recognisers {
                recogniser.delegate = self
                recogniser.cancelsTouchesInView = false
                map.addGestureRecognizer(recogniser)
            }
        }

        // MARK: The camera

        /// Before the first fix: street level on the route's start, or where you last were. Only
        /// then is the zoom range narrowed — set first, it clamps the whole-world region a fresh
        /// map opens on to a few hundred metres of the ocean.
        func frame(on coordinate: CLLocationCoordinate2D?, in map: MKMapView) {
            guard !hasFramed, let coordinate, CLLocationCoordinate2DIsValid(coordinate) else { return }
            map.setRegion(
                MKCoordinateRegion(center: coordinate, latitudinalMeters: NavigationMapView.metresAcross,
                                   longitudinalMeters: NavigationMapView.metresAcross),
                animated: false
            )
            hasFramed = true
            map.cameraZoomRange = NavigationMapView.zoomRange
        }

        @objc private func handGesture(_ recogniser: UIGestureRecognizer) {
            guard recogniser.state == .began, isDriving else { return }
            isDriving = false
            // Outside SwiftUI's update, or the write is dropped.
            DispatchQueue.main.async { [isFollowing] in
                if isFollowing.wrappedValue { isFollowing.wrappedValue = false }
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// Back to you, at street level, turning with the road again — gliding there rather than
        /// jumping, then frame by frame as before.
        func resumeFollowing() {
            isDriving = true
            guard let map, let fix else { return }
            let pose = NavigationPose.pose(fix, on: line, lastAlong: along, lastHeading: heading, now: Date())
            guard let camera = Self.camera(on: pose.coordinate, heading: pose.heading) else { return }
            map.setCamera(camera, animated: true)
            cameraHeading = pose.heading
            glidingUntil = CACurrentMediaTime() + 0.45
        }

        /// One frame: where you are, the line's head, your arrow, and the camera.
        func tick(force: Bool = false) {
            guard let map, let fix else { return }
            let clock = CACurrentMediaTime()
            let dt = lastTick.map { clock - $0 } ?? 0
            lastTick = clock

            let pose = NavigationPose.pose(fix, on: line, lastAlong: along, lastHeading: heading, now: Date())
            along = pose.along ?? along
            heading = pose.heading

            // The line starts where your arrow is. Off the route it stays where you left it.
            if let at = pose.along, force || abs(at - drawnHead) >= 0.5, let line, let head = line.point(at: at) {
                drawnHead = at
                routeRenderer?.setHead(segment: head.segment, point: MKMapPoint(head.coordinate))
            }

            if isDriving, clock >= glidingUntil {
                let turned = cameraHeading.map {
                    NavigationPose.turn(from: $0, toward: pose.heading, dt: dt, timeConstant: NavigationMapView.turnTime)
                } ?? pose.heading
                if let camera = Self.camera(on: pose.coordinate, heading: turned) {
                    cameraHeading = turned
                    map.camera = camera
                }
            }

            placeYou(at: pose.coordinate, on: map)
            // The arrow points the way you're going, on a map that may be turned.
            youView?.point(at: pose.heading - map.camera.heading)
        }

        /// Street level, looking the way you're going, with you a little below the middle. Nil
        /// rather than a camera made of a number that isn't one — which draws nothing at all.
        private static func camera(on coordinate: CLLocationCoordinate2D, heading: Double) -> MKMapCamera? {
            guard heading.isFinite, CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            let centre = GeoMath.coordinate(coordinate, metres: NavigationMapView.lookAhead, bearing: heading)
            guard CLLocationCoordinate2DIsValid(centre) else { return nil }
            return MKMapCamera(lookingAtCenter: centre, fromDistance: NavigationMapView.streetDistance,
                               pitch: 0, heading: heading)
        }

        private func placeYou(at coordinate: CLLocationCoordinate2D, on map: MKMapView) {
            if let you {
                you.coordinate = coordinate
            } else {
                let annotation = YouAnnotation()
                annotation.coordinate = coordinate
                map.addAnnotation(annotation)
                you = annotation
            }
        }

        // MARK: The route

        func layOutRoute(_ route: [CLLocationCoordinate2D], on map: MKMapView) {
            map.removeOverlays(map.overlays)
            routeRenderer = nil
            along = nil
            drawnHead = -1
            guard route.count > 1 else {
                line = nil
                return
            }
            line = NavigationPose.Line(route)
            map.addOverlay(MKPolyline(coordinates: route, count: route.count), level: .aboveRoads)
        }

        /// The pin at the end of the line: moved when the leg's end moves, gone when there's none.
        func place(_ destination: CLLocationCoordinate2D?, on map: MKMapView) {
            guard let destination, CLLocationCoordinate2DIsValid(destination) else {
                if let pin = destinationPin {
                    map.removeAnnotation(pin)
                    destinationPin = nil
                }
                return
            }
            if let pin = destinationPin {
                if pin.coordinate.latitude != destination.latitude || pin.coordinate.longitude != destination.longitude {
                    pin.coordinate = destination
                }
            } else {
                let pin = DestinationPin()
                pin.coordinate = destination
                map.addAnnotation(pin)
                destinationPin = pin
            }
        }

        // MARK: Every frame

        func startDisplayLink() {
            guard displayLink == nil else { return }
            let proxy = DisplayLinkProxy()
            proxy.coordinator = self
            let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
            // Smooth enough for a map that moves with you, without holding ProMotion at 120.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        fileprivate func frameTick() {
            tick()
        }

        // MARK: Apple's own map

        func apply(_ places: POIDisplay, to map: MKMapView) {
            // Reassigning the configuration makes MapKit reload its tiles, so it happens only when
            // the answer actually changes — not on every fix.
            let fingerprint = places.fingerprint
            guard fingerprint != poiFingerprint else { return }
            poiFingerprint = fingerprint
            // Not muted: in every test, the muted style left Apple's traffic off the roads, and
            // that traffic is the only traffic this map shows.
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
            configuration.pointOfInterestFilter = places.filter
            // Set on the configuration, not the map: the configuration replaces what the map was told.
            configuration.showsTraffic = true
            map.preferredConfiguration = configuration
        }

        // MARK: MapKit's own reports

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if annotation is YouAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: ArrowView.reuseID) as? ArrowView
                    ?? ArrowView(annotation: annotation, reuseIdentifier: ArrowView.reuseID)
                view.annotation = annotation
                youView = view
                return view
            }
            if annotation is DestinationPin {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: PinView.reuseID) as? PinView
                    ?? PinView(annotation: annotation, reuseIdentifier: PinView.reuseID)
                view.annotation = annotation
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            // MapKit can ask more than once for the same line, and goes on drawing with the first
            // renderer it was given. Two of them meant the head was moved on one while the other,
            // never told, drew the whole route — the line behind you that wouldn't go away.
            if let routeRenderer, routeRenderer.polyline === polyline {
                return routeRenderer
            }
            let renderer = RouteRenderer(polyline: polyline)
            routeRenderer = renderer
            drawnHead = -1
            tick(force: true)
            return renderer
        }
    }
}

// MARK: - Drawing

/// The route: a dark edge, the aurora line, and a clear middle where Apple's traffic colour on the
/// road beneath shows through. Drawn only from your arrow onwards — what's behind you is gone.
///
/// MapKit draws overlays in tiles, on its own threads, so where the head is sits behind a lock.
private nonisolated final class RouteRenderer: MKPolylineRenderer {
    private struct Head: Sendable {
        var segment: Int
        var x: Double
        var y: Double
    }

    private let head = OSAllocatedUnfairLock<Head?>(initialState: nil)
    private let casing = UIColor(PathOSPalette.color(PathOSPalette.void)).withAlphaComponent(0.9).cgColor
    private let aurora = UIColor(PathOSPalette.color(PathOSPalette.aurora)).cgColor

    /// Widths in points: the edge, the line, and the clear middle.
    static let casingWidth: CGFloat = 16
    static let lineWidth: CGFloat = 11
    static let clearWidth: CGFloat = 5

    func setHead(segment: Int, point: MKMapPoint) {
        head.withLock { $0 = Head(segment: segment, x: point.x, y: point.y) }
        setNeedsDisplay()
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let count = polyline.pointCount
        guard count > 1 else { return }
        let points = polyline.points()
        let start = head.withLock { $0 }

        let path = CGMutablePath()
        if let start {
            guard start.segment + 1 < count else { return }
            path.move(to: point(for: MKMapPoint(x: start.x, y: start.y)))
            for index in (start.segment + 1)..<count {
                path.addLine(to: point(for: points[index]))
            }
        } else {
            path.move(to: point(for: points[0]))
            for index in 1..<count {
                path.addLine(to: point(for: points[index]))
            }
        }

        context.setLineCap(.round)
        context.setLineJoin(.round)
        func stroke(_ width: CGFloat, _ color: CGColor?) {
            context.addPath(path)
            if let color { context.setStrokeColor(color) }
            context.setLineWidth(width / zoomScale)
            context.strokePath()
        }
        stroke(Self.casingWidth, casing)
        stroke(Self.lineWidth, aurora)
        // The middle, cut out of both: the road, and any traffic on it, show through.
        context.setBlendMode(.clear)
        stroke(Self.clearWidth, nil)
    }
}

/// You, on the map that leads you.
private nonisolated final class YouAnnotation: MKPointAnnotation {}

/// Where the line ends.
private nonisolated final class DestinationPin: MKPointAnnotation {}

/// You, as an arrowhead: pointed at the front, swept back on both sides, notched behind — the way
/// every navigation app draws the car, so which way you're heading is never a question. Aurora,
/// since it's you, edged in Ice so it holds up on any road.
private final class ArrowView: MKAnnotationView {
    static let reuseID = "pathos.you"
    static let size: CGFloat = 34

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let side = Self.size
        frame = CGRect(x: 0, y: 0, width: side, height: side)
        canShowCallout = false
        isEnabled = false
        displayPriority = .required
        zPriority = .max

        let shape = UIBezierPath()
        shape.move(to: CGPoint(x: side * 0.5, y: side * 0.08))
        shape.addLine(to: CGPoint(x: side * 0.86, y: side * 0.88))
        shape.addLine(to: CGPoint(x: side * 0.5, y: side * 0.68))
        shape.addLine(to: CGPoint(x: side * 0.14, y: side * 0.88))
        shape.close()

        let arrow = CAShapeLayer()
        arrow.path = shape.cgPath
        arrow.fillColor = UIColor(Color.aurora).cgColor
        arrow.strokeColor = UIColor(Color.ice).cgColor
        arrow.lineWidth = 2.5
        arrow.lineJoin = .round
        arrow.shadowColor = UIColor(Color.void).cgColor
        arrow.shadowOpacity = 0.55
        arrow.shadowRadius = 4
        arrow.shadowOffset = .zero
        arrow.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "transform": NSNull()]
        layer.addSublayer(arrow)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Turned to a bearing relative to the screen's up, without Core Animation easing it too.
    func point(at degrees: Double) {
        let angle = CGFloat(degrees * .pi / 180)
        guard abs(atan2(transform.b, transform.a) - angle) > 0.002 else { return }
        UIView.performWithoutAnimation {
            transform = CGAffineTransform(rotationAngle: angle)
        }
    }
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
        coordinator?.frameTick()
    }
}

/// The pin at the end of the line: the launch screen's pin, amber, the same shape.
private final class PinView: MKAnnotationView {
    static let reuseID = "pathos.destination"

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let scale = NavigationMapView.pinScale
        let width = (PinShape.headRadius * 2 + 4) * scale
        let height = (PinShape.height + 4) * scale
        frame = CGRect(x: 0, y: 0, width: width, height: height)
        canShowCallout = false
        isEnabled = false
        // Never hidden to make room for Apple's own labels: it's the one thing on the map that
        // says where you're going.
        displayPriority = .required
        zPriority = .defaultSelected
        // The point of the pin on the place, not its middle.
        centerOffset = CGPoint(x: 0, y: -height / 2 + 2 * scale)

        let tip = CGPoint(x: width / 2 / scale, y: height / scale - 2)
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        let outline = CAShapeLayer()
        outline.path = PinShape.path(tip: tip).cgPath.copy(using: &transform)
        outline.fillColor = UIColor(Color.void).cgColor
        let body = CAShapeLayer()
        body.path = PinShape.path(tip: tip, inset: 1.5).cgPath.copy(using: &transform)
        body.fillColor = UIColor(Color.amber).cgColor
        body.fillRule = .evenOdd
        for layer in [outline, body] {
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull()]
            self.layer.addSublayer(layer)
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
