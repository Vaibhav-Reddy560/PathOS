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
    @State private var screenCornerRadius: CGFloat = 0
    @State private var bottomSafeArea: CGFloat = 34
    @State private var topSafeArea: CGFloat = 59
    @State private var screenHeight: CGFloat = 0
    @Namespace private var mapScope

    var body: some View {
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
        .overlay {
            if isDeckShowing, screenHeight > 0 {
                DeckPanel(signals: signals, screenCornerRadius: screenCornerRadius, screenHeight: screenHeight, topSafeArea: topSafeArea)
                    .transition(.move(edge: .bottom))
            }
        }
        .overlay(alignment: .top) {
            IslandView(alerts: alerts)
                .padding(.top, 6)
        }
        .animation(PathMotion.resolve(PathMotion.signal, reduceMotion: reduceMotion), value: state.compassTarget?.id)
        .mapScope(mapScope)
        .background {
            ZStack {
                Color.void
                ScreenCornerReader { screenCornerRadius = $0 }
            }
            .ignoresSafeArea()
        }
        // Inside the environment below, which what it presents needs.
        .modifier(DeckPresentations())
        .environment(radar)
        .environment(scanFlow)
        .environment(placeDetails)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomSafeArea = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topSafeArea = $0 }
        // The whole screen, the keyboard included: the safe areas grow as the view shrinks.
        .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom } action: { screenHeight = $0 }
        .task(id: RadarRefreshKey(category: radar.category, location: state.location.location?.coordinate)) {
            await radar.refresh(state: state)
        }
        .onChange(of: state.focusedNoteID) { _, id in
            guard let id else { return }
            state.selectedSignalID = "note:\(id.uuidString)"
        }
        #if DEBUG
        .onAppear {
            // `-PathOSRadarCategory transit` opens Radar on a category for screenshots.
            if let raw = UserDefaults.standard.string(forKey: "PathOSRadarCategory"), let category = RadarCategory(rawValue: raw) {
                radar.category = category
            }
        }
        .onChange(of: signals.map(\.id)) { _, _ in
            // `-PathOSSelectFirstPlace YES` opens a place card for simulator screenshots.
            guard UserDefaults.standard.bool(forKey: "PathOSSelectFirstPlace"), state.selectedSignalID == nil,
                  let place = signals.first(where: { $0.kind == .place || $0.kind == .event }) else { return }
            state.selectedSignalID = place.id
        }
        #endif
        .animation(PathMotion.resolve(PathMotion.signal, reduceMotion: reduceMotion), value: isDeckShowing)
    }

    /// The deck steps aside while guiding, and waits for the launch view to lift.
    private var isDeckShowing: Bool {
        state.compassTarget == nil && state.isLaunchComplete
    }

    /// The map keeps you centred above the collapsed card, and stays put while the deck opens and
    /// collapses, as Apple Maps does. Moving it with the deck either jumped it in one frame or,
    /// animated, resized the map faster than it could draw, leaving a dark band that filled in a
    /// second later. Centred above the card, you are still above the half-open deck.
    private var mapBottomInset: CGFloat {
        if state.compassTarget != nil {
            return 230
        }
        // The card's top, above the safe area the map already keeps clear, and a little more so
        // Apple's map logo sits clear of the card instead of on its edge.
        return DeckLayout.cardHeight(for: dynamicTypeSize) + DeckLayout.bottomMargin - bottomSafeArea + 8
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
