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
    @State private var screenWidth: CGFloat = 0
    /// Whether the deck's sheet is up. Collapsing, it rests where the card will be and then hands
    /// over to the card, which can sit higher than iOS holds a sheet.
    @State private var isDeckSheetUp = false
    /// Taking over, the card is drawn as the resting sheet was, glass and rows, then tucks its
    /// bottom edge up. It keeps the sheet's top and rows exactly, rather than easing to where the
    /// arithmetic says they should be: iOS rounds the sheet's height to the pixel grid, a point
    /// either way, and easing that away moved the strip. See `DeckCard`.
    @State private var cardExtraTop: CGFloat = 0
    @State private var cardExtraBottom: CGFloat = 0
    @State private var cardContentShift: CGFloat = 0
    @State private var handOver: Task<Void, Never>?
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
        .overlay(alignment: .bottom) {
            if isCardShowing {
                DeckCard(
                    cornerRadius: DeckLayout.cornerRadius(screen: screenCornerRadius, margin: DeckLayout.sideMargin),
                    scale: sheetScale,
                    screenWidth: screenWidth,
                    extraTop: cardExtraTop,
                    extraBottom: cardExtraBottom,
                    contentShift: cardContentShift
                )
                    .padding(.bottom, DeckLayout.cardBottomMargin - cardExtraBottom)
                    .ignoresSafeArea(edges: .bottom)
                    // Appearing, it takes the resting sheet's place in the same frame. Opening, it
                    // waits for the sheet to rise over it before fading. The animations ride on the
                    // transition rather than on a change to the whole screen, which moved the map.
                    .transition(.asymmetric(
                        insertion: .identity,
                        removal: .opacity.animation(.easeIn(duration: 0.15).delay(0.12))
                    ))
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
        .modifier(CollapsedDeckPresentations(isCollapsed: isCardShowing))
        .environment(radar)
        .environment(scanFlow)
        .environment(placeDetails)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomSafeArea = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { screenWidth = $0 }
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
        // Pulling the sheet down shrinks it to the card's size, where it rests; it can't be pulled
        // away. It waits for the launch view to lift.
        .sheet(isPresented: Binding {
            isDeckSheetUp && state.compassTarget == nil && state.isLaunchComplete
        } set: { isPresented in
            if !isPresented {
                isDeckSheetUp = false
                state.deckDetent = .deckPeek
            }
        }) {
            DeckView(signals: signals, screenCornerRadius: screenCornerRadius, onRestCollapsed: handOverToCard(from:))
                .environment(radar)
                .environment(scanFlow)
                .environment(placeDetails)
                .presentationDetents([.deckPeek, .medium, .large], selection: $state.deckDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .interactiveDismissDisabled()
        }
        .onChange(of: state.deckDetent, initial: true) { _, detent in
            handOver?.cancel()
            if detent == .deckPeek {
                // The sheet says when it has come to rest (`SheetRestProbe`); this is only in case
                // it never does, so the card can't be left waiting.
                handOver = Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled else { return }
                    handOverToCard(from: nil)
                }
            } else {
                isDeckSheetUp = true
            }
        }
    }

    /// Swaps the resting sheet for the card in the same frame, drawn exactly as the sheet was, glass
    /// and rows, then tucks up the few points of glass iOS holds a sheet lower than the card.
    private func handOverToCard(from rest: SheetRest?) {
        guard isDeckSheetUp, state.deckDetent == .deckPeek else { return }
        handOver?.cancel()
        // A sheet drawn some other way than expected, such as iOS's compact style, can't be matched,
        // so the card just takes its own place.
        if let rest, abs(rest.scale - sheetScale) < 0.005 {
            let bottom = rest.screenHeight - DeckLayout.cardBottomMargin
            let top = bottom - DeckLayout.restingCardHeight(for: dynamicTypeSize) * sheetScale
            cardExtraTop = top - rest.glass.minY
            cardExtraBottom = rest.glass.maxY - bottom
            cardContentShift = (rest.contentTop - rest.glass.minY) / sheetScale
        } else {
            cardExtraTop = 0
            cardExtraBottom = DeckLayout.sheetOverhang
            cardContentShift = 0
        }
        var instantly = Transaction()
        instantly.disablesAnimations = true
        withTransaction(instantly) { isDeckSheetUp = false }
        handOver = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            withAnimation(PathMotion.resolve(.smooth(duration: 0.25), reduceMotion: reduceMotion)) {
                cardExtraBottom = 0
            }
        }
    }

    private var sheetScale: CGFloat {
        DeckLayout.sheetScale(screenWidth: screenWidth)
    }

    private var isCardShowing: Bool {
        isDeckCollapsed && !isDeckSheetUp
    }

    private var isDeckCollapsed: Bool {
        state.compassTarget == nil && state.isLaunchComplete && state.deckDetent == .deckPeek
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
        return DeckLayout.restingCardHeight(for: dynamicTypeSize) * sheetScale + DeckLayout.cardBottomMargin - bottomSafeArea + 8
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
