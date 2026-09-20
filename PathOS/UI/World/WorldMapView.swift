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

    /// Pulls Apple's dark map toward Void while annotations stay bright. Set to 0 to turn off.
    static let veilOpacity = 0.28
    static let walkRingMinutes = [5, 10, 15]

    var body: some View {
        @Bindable var state = state
        let here = state.location.location?.coordinate

        Map(position: $camera, selection: $state.selectedSignalID, scope: scope) {
            if Self.veilOpacity > 0, let here {
                MapPolygon(coordinates: Self.veil(around: here))
                    .foregroundStyle(Color.void.opacity(reduceTransparency ? 0.45 : Self.veilOpacity))
                    .mapOverlayLevel(level: .aboveRoads)
            }

            // The walking rings are for browsing what's around you, not for driving through.
            if let here, state.mapLayers.contains(.rings), state.trip == nil {
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

            if let nav = state.tripNav, nav.coordinates.count > 1 {
                MapPolyline(coordinates: nav.coordinates)
                    .stroke(Color.void.opacity(0.9), style: StrokeStyle(lineWidth: 18, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
                MapPolyline(coordinates: nav.coordinates)
                    .stroke(Color.aurora, style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
            }

            // On the train, the ride itself is the line, with the stations along it.
            if let ride = state.rideBeingFollowed {
                MapPolyline(coordinates: ride.map(\.coordinate))
                    .stroke(Color.void.opacity(0.8), style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
                MapPolyline(coordinates: ride.map(\.coordinate))
                    .stroke(Color.ion, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
                ForEach(Array(ride.enumerated()), id: \.offset) { index, stop in
                    Annotation(stop.name, coordinate: stop.coordinate, anchor: .center) {
                        RideStopDot(isEnd: index == 0 || index == ride.count - 1)
                    }
                    .annotationTitles(.hidden)
                }
            }

            if let route = state.guidanceRoute, route.coordinates.count > 1 {
                MapPolyline(coordinates: route.coordinates)
                    .stroke(Color.void, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
                MapPolyline(coordinates: route.coordinates)
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
                .annotationTitles(.hidden)
                .tag(signal.id)
            }

            UserAnnotation {
                UserMarker(isScanning: radar.isLoading)
            }
            .annotationSubtitles(.hidden)
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {}
        .safeAreaPadding(.bottom, bottomInset)
        .onMapCameraChange(frequency: .onEnd) { context in
            state.mapCenter = context.camera.centerCoordinate
        }
        .overlay(alignment: .bottomTrailing) {
            // Moved the map yourself while following a way: it stays where you put it until this.
            if state.trip != nil, !isFollowingMap {
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
            if state.trip != nil { isFollowingMap = false }
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
        guard let trip = state.trip, let status = state.tripStatus else { return "none" }
        return "\(trip.option.id)-\(status.legIndex)"
    }

    /// Frames the ride you're on, so its stops read. Road legs are led by `NavigationMapView`,
    /// which is MapKit following you itself: a camera driven by hand, a fix at a time, is what
    /// made the map drift and lag behind.
    private func followNavigation(animated: Bool) {
        guard state.isLeadingTheWay, isFollowingMap, state.rideBeingFollowed != nil else { return }
        // Between fixes the map slides at a constant rate, which is what makes a navigation map
        // glide rather than hop: each fix starts a linear move that the next one takes over.
        let motion = PathMotion.resolve(animated ? PathMotion.signal : .linear(duration: 1), reduceMotion: reduceMotion)

        if let ride = state.rideBeingFollowed, ride.count > 1 {
            withAnimation(motion) {
                camera = .region(Self.region(around: ride.map(\.coordinate) + [state.location.location?.coordinate].compactMap { $0 }))
            }
            return
        }
    }



    /// Everything on the map, or — while you're being led somewhere — only what the journey is
    /// about: where this leg ends, and where you're going in the end.
    private var shownSignals: [WorldSignal] {
        guard let trip = state.trip, let status = state.tripStatus, isFollowingMap else { return signals }
        let leg = trip.option.legs[min(status.legIndex, trip.option.legs.count - 1)]
        let keep = Set([leg.endName, trip.destinationName])
        return signals.filter { keep.contains($0.title) }
    }

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

    /// A stop along the ride being followed: the ends stand out from the ones passed through.
    private struct RideStopDot: View {
        var isEnd = false

        var body: some View {
            Circle()
                .fill(isEnd ? Color.ion : Color.void)
                .stroke(Color.ion, lineWidth: isEnd ? 0 : 2)
                .frame(width: isEnd ? 12 : 8, height: isEnd ? 12 : 8)
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
