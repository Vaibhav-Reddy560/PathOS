import MapKit
import SwiftData
import SwiftUI

/// Root of the app: the map fills the screen, controls float on glass, and the deck rises from the bottom.
/// While guiding, the deck steps aside for the guidance HUD.
struct WorldView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(filter: #Predicate<SpatialNote> { $0.isActive }, sort: \SpatialNote.createdAt, order: .reverse)
    private var notes: [SpatialNote]
    @Query(sort: \SavedPlace.createdAt) private var places: [SavedPlace]

    @State private var radar = RadarModel()
    @State private var scanFlow = ScanFlowModel()
    @State private var placeDetails = PlaceDetailsService()
    @State private var screenHeight: CGFloat = 900
    @Namespace private var mapScope

    var body: some View {
        @Bindable var state = state
        let alerts = state.ambientAlerts
        let signals = currentSignals

        ZStack(alignment: .topTrailing) {
            WorldMapView(signals: signals, scope: mapScope, bottomInset: mapBottomInset)
                .ignoresSafeArea()

            if state.isHeadsUp {
                Color.void.opacity(0.85)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            ControlRail(scope: mapScope)
                .padding(.top, 60)
                .padding(.trailing, 12)
        }
        .overlay(alignment: .top) {
            // Attention and urgency tint the top edge of the world, very faintly.
            if let top = alerts.first, top.role == .attention || top.role == .critical {
                AtmosphereField(role: top.role, diameter: 560, intensity: 0.1)
                    .offset(y: -330)
                    .ignoresSafeArea()
            }
        }
        .overlay(alignment: .topLeading) {
            MapScaleView(scope: mapScope)
                .padding(.top, 60)
                .padding(.leading, 16)
        }
        .overlay(alignment: .bottom) {
            if let target = state.compassTarget {
                GuidanceHUD(target: target)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            IslandView(alerts: alerts)
                .padding(.top, 6)
        }
        .animation(PathMotion.resolve(PathMotion.signal, reduceMotion: reduceMotion), value: state.compassTarget?.id)
        .mapScope(mapScope)
        .background(Color.void)
        .environment(radar)
        .environment(scanFlow)
        .environment(placeDetails)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { screenHeight = $0 }
        .task(id: RadarRefreshKey(category: radar.category, location: state.location.location?.coordinate)) {
            await radar.refresh(state: state)
        }
        .onChange(of: state.focusedNoteID) { _, id in
            guard let id else { return }
            state.selectedSignalID = "note:\(id.uuidString)"
        }
        #if DEBUG
        .onChange(of: signals.map(\.id)) { _, _ in
            // `-PathOSSelectFirstPlace YES` opens a place card for simulator screenshots.
            guard UserDefaults.standard.bool(forKey: "PathOSSelectFirstPlace"), state.selectedSignalID == nil,
                  let place = signals.first(where: { $0.kind == .place || $0.kind == .event }) else { return }
            state.selectedSignalID = place.id
        }
        #endif
        .sheet(isPresented: Binding { state.compassTarget == nil } set: { _ in }) {
            DeckView(signals: signals)
                .environment(radar)
                .environment(scanFlow)
                .environment(placeDetails)
                .presentationDetents([.deckPeek, .medium, .large], selection: $state.deckDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .interactiveDismissDisabled()
        }
    }

    /// Follows the resting detent rather than every drag frame, so the map doesn't re-layout while you drag.
    private var mapBottomInset: CGFloat {
        if state.compassTarget != nil {
            return 230
        }
        return switch state.deckDetent {
        case .deckPeek: DeckPeekDetent.height(for: dynamicTypeSize)
        default: screenHeight * 0.5
        }
    }

    private var currentSignals: [WorldSignal] {
        WorldSignalBuilder.build(
            memories: notes.map {
                MemoryInput(id: $0.id, title: $0.title, body: $0.body, latitude: $0.latitude, longitude: $0.longitude, radius: $0.radius)
            },
            places: places.map {
                SavedPlaceInput(id: $0.id, kind: $0.kind, name: $0.name, latitude: $0.latitude, longitude: $0.longitude, radius: $0.radius)
            },
            radar: radar.items,
            assistantPlaces: state.assistantTurns.first?.places ?? [],
            transit: state.transit.nearbyStops,
            origin: state.location.location?.coordinate,
            layers: state.mapLayers
        )
    }
}
