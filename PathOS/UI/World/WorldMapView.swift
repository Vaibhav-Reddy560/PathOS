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

            if let here, state.mapLayers.contains(.rings) {
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

            ForEach(signals.filter { $0.radius != nil }) { signal in
                MapCircle(center: signal.coordinate, radius: signal.radius ?? 0)
                    .foregroundStyle(signal.role.color.opacity(0.06))
                    .stroke(signal.role.color.opacity(0.35), lineWidth: 1)
            }

            ForEach(signals) { signal in
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
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {}
        .safeAreaPadding(.bottom, bottomInset)
        .onChange(of: state.compassTarget?.id) { _, id in
            withAnimation(PathMotion.resolve(PathMotion.signal, reduceMotion: reduceMotion)) {
                camera = .userLocation(followsHeading: id != nil, fallback: .automatic)
            }
        }
        .onChange(of: state.selectedSignalID) { _, id in
            guard let id, let signal = signals.first(where: { $0.id == id }) else { return }
            if state.deckDetent == .deckPeek {
                state.deckDetent = .medium
            }
            withAnimation(PathMotion.resolve(PathMotion.signal, reduceMotion: reduceMotion)) {
                camera = .camera(MapCamera(centerCoordinate: signal.coordinate, distance: 1_600))
            }
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
