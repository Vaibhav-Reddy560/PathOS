import CoreLocation
import MapKit
import SwiftUI

/// The map is the interface: you, your memories, and the living city PathOS discovers around you.
struct WorldMapView: View {
    let signals: [WorldSignal]
    let scope: Namespace.ID
    /// Height covered by the deck, so the map centres you in the part you can see.
    let bottomInset: CGFloat

    @Environment(AppState.self) private var state
    @Environment(RadarModel.self) private var radar
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    /// False once you've moved the map yourself while following a way.
    @State private var isFollowingMap = true

    /// Pulls Apple's dark map toward Void while annotations stay bright. It sits under the labels,
    /// so it darkens the ground they stand on rather than dimming them — and it leans in while
    /// Apple's own pins are showing, so PathOS's aurora and ion markers still lead the eye.
    static func veilOpacity(showingPlaces: Bool, reduceTransparency: Bool) -> Double {
        if reduceTransparency { return 0.45 }
        return showingPlaces ? 0.38 : 0.28
    }
    static let walkRingMinutes = [5, 10, 15]

    /// Names under the markers, the way Apple Maps names its own places: MapKit shows each one
    /// where there's room and drops the ones that would collide, so a few read at a glance from
    /// far out and the rest appear as you zoom in — no tapping each marker to find out what it is.
    /// Not for bus stops, whose long names would bury the places; and not for the one selected,
    /// which carries its own name tag.
    static func titles(for signal: WorldSignal, isSelected: Bool) -> Visibility {
        if isSelected || signal.kind == .transitStop { return .hidden }
        return .automatic
    }

    var body: some View {
        @Bindable var state = state
        let here = state.location.location?.coordinate
        let routeAhead: [CLLocationCoordinate2D] = state.tripNav.map { nav in
            state.tripMatch.map { RouteProgress.ahead(of: nav.coordinates, from: $0) } ?? nav.coordinates
        } ?? []

        Map(position: $camera, selection: $state.selectedSignalID, scope: scope) {
            if let here {
                MapPolygon(coordinates: Self.veil(around: here))
                    .foregroundStyle(Color.void.opacity(Self.veilOpacity(showingPlaces: state.poiDisplay.isOn,
                                                                        reduceTransparency: reduceTransparency)))
                    .mapOverlayLevel(level: .aboveRoads)
            }

            // The walking rings are for browsing what's around you, not for driving through.
            if let here, state.mapLayers.contains(.rings), !isTravelling {
                ForEach(Self.walkRingMinutes, id: \.self) { minutes in
                    let radius = GeoMath.walkingRadius(minutes: minutes)
                    MapCircle(center: here, radius: radius)
                        .foregroundStyle(.clear)
                        .stroke(Color.mist.opacity(contrast == .increased ? 0.45 : 0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                    Annotation("", coordinate: GeoMath.coordinate(here, offsetNorthBy: radius), anchor: .center) {
                        Text("\(minutes) min")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.mist)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.void.opacity(0.7), in: .capsule)
                            .accessibilityHidden(true)
                    }
                    .annotationTitles(.hidden)
                }
            }

            // Only what's ahead of you: the line starts where you are.
            if routeAhead.count > 1 {
                MapPolyline(coordinates: routeAhead)
                    .stroke(Color.void.opacity(0.9), style: StrokeStyle(lineWidth: 18, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
                MapPolyline(coordinates: routeAhead)
                    .stroke(Color.aurora, style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
            }

            // On the train, the ride itself is the line, with the stations along it.
            // Along the rails, where the track is known.
            if let ride = state.rideBeingFollowed {
                let shape = state.rideShape ?? ride.map(\.coordinate)
                MapPolyline(coordinates: shape)
                    .stroke(Color.void.opacity(0.8), style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
                MapPolyline(coordinates: shape)
                    .stroke(Color.ion, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
                // Every station named, always: MapKit's own titles dropped the one you were nearing
                // whenever your dot sat over it. Where you board, change and get off stand out, and
                // the next station most of all.
                let next = state.transit.progress?.nextStationIndex
                ForEach(Array(ride.enumerated()), id: \.offset) { index, stop in
                    let isKey = index == 0 || index == ride.count - 1 || stop.changeInstruction != nil
                    Annotation(stop.name, coordinate: stop.coordinate, anchor: .center) {
                        RideStopDot(name: stop.name, isEnd: isKey, isNext: index == next)
                    }
                    .annotationTitles(.hidden)
                }
                // You, on the line: where the ride has you, not wherever GPS wandered.
                if let onLine = state.transit.progress?.coordinate {
                    Annotation("You", coordinate: onLine, anchor: .center) {
                        UserMarker(isScanning: false)
                    }
                    .annotationTitles(.hidden)
                }
            }

            if let walk = Self.walkAhead(state.guidanceRoute?.coordinates ?? [], from: here,
                                         to: state.compassTarget?.coordinate) {
                MapPolyline(coordinates: walk)
                    .stroke(Color.void, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
                MapPolyline(coordinates: walk)
                    .stroke(Color.aurora, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
            }

            if let target = state.compassTarget, !signals.contains(where: { $0.id == target.id }) {
                Annotation(target.name, coordinate: target.coordinate, anchor: .center) {
                    GuidanceTargetMarker()
                }
                .annotationTitles(.hidden)
            }

            ForEach(shownSignals.filter { $0.radius != nil }) { signal in
                MapCircle(center: signal.coordinate, radius: signal.radius ?? 0)
                    .foregroundStyle(signal.role.color.opacity(0.06))
                    .stroke(signal.role.color.opacity(0.35), lineWidth: 1)
            }

            ForEach(shownSignals) { signal in
                Annotation(signal.title, coordinate: signal.coordinate, anchor: .center) {
                    SignalMarker(signal: signal, isSelected: state.selectedSignalID == signal.id) {
                        state.selectedSignalID = signal.id
                    }
                }
                .annotationTitles(Self.titles(for: signal, isSelected: state.selectedSignalID == signal.id))
                .tag(signal.id)
            }

            // On a ride you're drawn on its line instead.
            if !isOnRideLine {
                UserAnnotation {
                    UserMarker(isScanning: radar.isLoading && state.trip == nil)
                }
                .annotationSubtitles(.hidden)
            }
        }
        // On your way, the map is the journey and nothing else: no cafés along the route, and no
        // traffic drawn beside every road — the route carries its own.
        .mapStyle(.standard(elevation: .realistic, emphasis: .muted,
                            pointsOfInterest: isTravelling ? .excludingAll : state.poiDisplay.categories,
                            showsTraffic: false))
        .mapControls {}
        .safeAreaPadding(.bottom, bottomInset)
        // A ride is framed clear of the banner above it and the buttons down its right edge, so
        // the stations at either end aren't hidden under them.
        .safeAreaPadding(.top, state.rideBeingFollowed == nil ? 0 : 150)
        .safeAreaPadding(.trailing, state.rideBeingFollowed == nil ? 0 : 64)
        .onMapCameraChange(frequency: .onEnd) { context in
            state.mapCenter = context.camera.centerCoordinate
        }
        .overlay(alignment: .bottomTrailing) {
            // Moved the map yourself while following a way: it stays where you put it until this.
            if isTravelling, !isFollowingMap {
                Button {
                    isFollowingMap = true
                    followNavigation(animated: true)
                } label: {
                    Label("Recentre", systemImage: "location.fill")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                }
                .pathPrimaryAction()
                .padding(.trailing, 12)
                .padding(.bottom, bottomInset + 12)
                .transition(.opacity)
            }
        }
        .overlay {
            // Picking Home or Work: the pin stays put in the middle while the map moves under it.
            if let kind = state.placePicking {
                PlacePickPin(kind: kind)
                    .padding(.bottom, bottomInset)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        // Following a way: the map leads. On a road leg it sits behind you, tilted and close, the
        // way you'd hold a phone on a dashboard; on the train it pulls back to the whole ride.
        // Moving the map yourself stops it following until you tap Recentre.
        .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in
            if isTravelling { isFollowingMap = false }
        })
        .onChange(of: navigationKey) { _, _ in
            isFollowingMap = true
            followNavigation(animated: true)
        }
        // Every fix, not just the ones that change your latitude: driving due east used to move
        // the map only as far as GPS noise did.
        .onChange(of: state.location.location?.timestamp) { _, _ in
            followNavigation(animated: false)
        }
        .onChange(of: state.compassTarget?.id) { _, id in
            withAnimation(PathMotion.resolve(PathMotion.signal, reduceMotion: reduceMotion)) {
                camera = .userLocation(followsHeading: id != nil, fallback: .automatic)
            }
        }
        .onChange(of: state.placePicking) { _, kind in
            // Close in on where it is now, or on you, so the pin can go on the right building.
            guard let kind else { return }
            let start = state.vault.place(ofKind: kind)?.coordinate ?? state.location.location?.coordinate
            guard let start else { return }
            withAnimation(PathMotion.resolve(PathMotion.signal, reduceMotion: reduceMotion)) {
                camera = .camera(MapCamera(centerCoordinate: start, distance: 1_200))
            }
        }
        .onChange(of: state.selectedSignalID) { _, id in
            guard let id, let signal = signals.first(where: { $0.id == id }) else { return }
            // Tapped on the map, the deck opens on its card; pointed out from elsewhere, the map
            // is what you wanted to see.
            if state.isPointingOut {
                state.isPointingOut = false
            } else if state.deckStop == .collapsed {
                state.deckStop = .full
            }
            withAnimation(PathMotion.resolve(PathMotion.signal, reduceMotion: reduceMotion)) {
                camera = .camera(MapCamera(centerCoordinate: signal.coordinate, distance: 1_600))
            }
        }
    }

    /// What the camera should be doing: which leg, and whether it's a ride.
    private var navigationKey: String {
        if let trip = state.trip, let status = state.tripStatus {
            return "\(trip.option.id)-\(status.legIndex)-\(state.transit.journey?.id.uuidString ?? "")"
        }
        return state.transit.journey?.id.uuidString ?? "none"
    }

    /// On a ride with a place on its line to draw you at.
    private var isOnRideLine: Bool {
        state.rideBeingFollowed != nil && state.transit.progress?.coordinate != nil
    }

    /// A way or a ride being followed: the map is about the journey.
    private var isTravelling: Bool {
        state.trip != nil || state.transit.journey != nil
    }

    /// Frames the ride you're on, so its stops read. Road legs are led by `NavigationMapView`,
    /// which is MapKit following you itself: a camera driven by hand, a fix at a time, is what
    /// made the map drift and lag behind.
    private func followNavigation(animated: Bool) {
        guard state.isLeadingTheWay || state.transit.journey != nil, isFollowingMap,
              state.rideBeingFollowed != nil else { return }
        // Between fixes the map slides at a constant rate, which is what makes a navigation map
        // glide rather than hop: each fix starts a linear move that the next one takes over.
        let motion = PathMotion.resolve(animated ? PathMotion.signal : .linear(duration: 1), reduceMotion: reduceMotion)

        if let ride = state.rideBeingFollowed, ride.count > 1 {
            withAnimation(motion) {
                camera = .region(Self.region(around: ride.map(\.coordinate)
                    + [state.transit.progress?.coordinate ?? state.location.location?.coordinate].compactMap { $0 }))
            }
            return
        }
    }



    /// Everything on the map, or — while you're on your way — only what the journey is about:
    /// where this leg ends and where you're going in the end. Whether or not the map is following
    /// you: one drag used to bring back every café and bus stop around. A ride's stations are
    /// drawn with the ride.
    private var shownSignals: [WorldSignal] {
        if let trip = state.trip {
            let leg = trip.option.legs[min(state.tripStatus?.legIndex ?? 0, trip.option.legs.count - 1)]
            let keep = Set([leg.endName, trip.destinationName])
            return signals.filter { $0.kind != .transitStop && keep.contains($0.title) }
        }
        if let journey = state.transit.journey {
            return signals.filter { $0.kind != .transitStop && $0.title == journey.destination }
        }
        return signals
    }

    /// The part of a walk to a saved spot still ahead of you — and none of it once you're close or
    /// have left it. The whole route was drawn as fetched when you set off, so walking past part
    /// of it, or coming at the spot another way, left its tail poking out of the marker.
    static func walkAhead(_ route: [CLLocationCoordinate2D], from here: CLLocationCoordinate2D?,
                          to target: CLLocationCoordinate2D?) -> [CLLocationCoordinate2D]? {
        guard route.count > 1, let here else { return nil }
        // Within sight of it, the pointer does the rest.
        if let target, GeoMath.distance(from: here, to: target) <= lastStretch { return nil }
        guard let match = RouteProgress.match(route, at: here), match.offset <= offWalk else { return nil }
        let ahead = RouteProgress.ahead(of: route, from: match)
        return ahead.count > 1 ? ahead : nil
    }

    /// Nearer the spot than this, a line to it is only in the way.
    static let lastStretch = 60.0
    /// Further off the walk than this and it's no longer the way you're going.
    static let offWalk = 40.0

    /// A region holding all of these, with room around them.
    static func region(around coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coordinates.first else { return MKCoordinateRegion() }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for point in coordinates {
            minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.004, (maxLat - minLat) * 1.5),
                                   longitudeDelta: max(0.004, (maxLon - minLon) * 1.5))
        )
    }

    /// A stop along the ride being followed: where you board, change and get off stand out, with
    /// their names always shown, from the ones passed through.
    private struct RideStopDot: View {
        var name: String?
        var isEnd = false
        /// The station coming up.
        var isNext = false

        var body: some View {
            Circle()
                .fill(isEnd || isNext ? Color.ion : Color.void)
                .stroke(Color.ion, lineWidth: isEnd || isNext ? 0 : 2)
                .frame(width: isEnd || isNext ? 12 : 8, height: isEnd || isNext ? 12 : 8)
                // Under the dot, outside its frame, so the dot itself stays on the station.
                .overlay(alignment: .top) {
                    if let name {
                        Text(name)
                            .font(.caption.weight(isEnd || isNext ? .bold : .semibold))
                            .foregroundStyle(isNext ? Color.void : .ice)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(isNext ? Color.ion : Color.void.opacity(0.85), in: .capsule)
                            .offset(y: 16)
                    }
                }
                .accessibilityHidden(true)
        }
    }

    /// A box around you, snapped to a 0.1° grid so it isn't rebuilt on every location update.
    static func veil(around coordinate: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let latitude = (coordinate.latitude * 10).rounded() / 10
        let longitude = (coordinate.longitude * 10).rounded() / 10
        let span = 1.0
        return [
            CLLocationCoordinate2D(latitude: latitude - span, longitude: longitude - span),
            CLLocationCoordinate2D(latitude: latitude - span, longitude: longitude + span),
            CLLocationCoordinate2D(latitude: latitude + span, longitude: longitude + span),
            CLLocationCoordinate2D(latitude: latitude + span, longitude: longitude - span),
        ]
    }
}

/// The pin in the middle of the map while you choose where Home or Work is: its tip marks the spot.
private struct PlacePickPin: View {
    let kind: PlaceKind

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: kind.symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.void)
                .frame(width: 44, height: 44)
                .background(Color.aurora, in: .circle)
                .overlay { Circle().strokeBorder(Color.void, lineWidth: 3) }
            Rectangle()
                .fill(Color.aurora)
                .frame(width: 3, height: 18)
            Circle()
                .fill(Color.void)
                .frame(width: 8, height: 8)
                .overlay { Circle().strokeBorder(Color.aurora, lineWidth: 2) }
        }
        // The tip, not the middle of the drawing, sits on the map's centre.
        .offset(y: -31)
        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
        .accessibilityHidden(true)
    }
}
