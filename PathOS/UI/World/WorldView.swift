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
    /// MapKit stops following as soon as you move the map by hand; this brings the button back.
    @State private var isFollowingRoute = true

    var body: some View {
        let alerts = state.ambientAlerts
        let signals = currentSignals

        ZStack(alignment: .topTrailing) {
            // Driving a leg, the map is MapKit's own, following you the way every other app on
            // the phone does. Everything else — browsing, picking places, a metro ride — is the
            // usual map.
            if isDrivingALeg {
                NavigationMapView(route: state.tripNav?.coordinates ?? [], trim: state.tripTrim,
                                  traffic: state.tripFlow?.shown(on: state.tripNav) ?? [],
                                  destination: legEnd,
                                  places: state.poiDisplay, here: state.location.location?.coordinate,
                                  isFollowing: $isFollowingRoute)
                    .ignoresSafeArea()
            } else {
                WorldMapView(signals: signals, scope: mapScope, bottomInset: mapBottomInset)
                    .ignoresSafeArea()
            }

            if state.isHeadsUp {
                Color.void.opacity(0.85)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            ControlRail(scope: mapScope)
                // Clear of the turn banner while the map is leading you.
                .padding(.top, isNavigating ? 210 : 60)
                .padding(.trailing, 12)
                .animation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion), value: isNavigating)
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
            // The scale belongs to the browsing map; MapKit's navigation map hides its own.
            if !isDrivingALeg {
                MapScaleView(scope: mapScope)
                    .padding(.top, 60)
                    .padding(.leading, 16)
            }
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
        .overlay(alignment: .bottomTrailing) {
            if isDrivingALeg, !isFollowingRoute {
                Button {
                    isFollowingRoute = true
                } label: {
                    Label("Recentre", systemImage: "location.fill")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                }
                .pathPrimaryAction()
                .padding(.trailing, 12)
                .padding(.bottom, mapBottomInset + 12)
            }
        }
        .overlay(alignment: .bottom) {
            if let kind = state.placePicking {
                PlacePickBar(kind: kind)
                    .padding(.horizontal, 12)
                    .padding(.bottom, mapBottomInset + 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion), value: state.placePicking)
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                IslandView(alerts: alerts)
                // While a way is being followed, the map leads with the turn ahead.
                // It belongs to the map, so it shows while the map is what you're looking at.
                if isNavigating, let trip = state.trip, let status = state.tripStatus {
                    NavigationBanner(trip: trip, status: status)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 6)
            .animation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion), value: state.tripStatus)
            .animation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion), value: state.deckStop)
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
        // Not while you're travelling: crossing a cell every few hundred metres would scan Apple
        // Maps and re-rank everything once every twenty seconds for the whole drive.
        .task(id: RadarRefreshKey(category: radar.category,
                                  location: state.trip == nil ? state.location.location?.coordinate : nil)) {
            guard state.trip == nil else { return }
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

    /// Being led along a way, with the map there to see it on: the deck open means you're reading
    /// something else, so the banner and the rail's offset stand down.
    private var isNavigating: Bool {
        state.isLeadingTheWay && state.deckStop == .collapsed
    }

    /// On a leg you travel along a road for, with the map showing it — MapKit's map takes over.
    private var isDrivingALeg: Bool {
        isNavigating && state.isNavigatingByRoad
    }

    /// Where the leg you're on ends: the destination, or the station a first leg takes you to.
    /// The pin goes where the line goes.
    private var legEnd: CLLocationCoordinate2D? {
        guard let trip = state.trip, let status = state.tripStatus else { return nil }
        return trip.option.legs[safe: status.legIndex]?.endCoordinate
    }

    /// The deck steps aside while guiding, and waits for the launch view to lift.
    private var isDeckShowing: Bool {
        state.compassTarget == nil && state.isLaunchComplete
    }

    /// The map keeps you centred above the collapsed card, and stays put while the deck opens and
    /// collapses, as Apple Maps does. Moving it with the deck either jumped it in one frame or,
    /// animated, resized the map faster than it could draw, leaving a dark band that filled in a
    /// second later.
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
            assistantPlaces: (state.assistantTurns.first?.places ?? []) + [state.searchPlace].compactMap { $0 },
            transit: state.transit.nearbyStops,
            origin: state.location.location?.coordinate,
            layers: state.mapLayers
        )
    }
}

/// While choosing Home or Work on the map: what to do, and the way out.
private struct PlacePickBar: View {
    let kind: PlaceKind

    @Environment(AppState.self) private var state
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move the map so the pin is on your \(kind.label.lowercased()).")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ice)
            HStack(spacing: 10) {
                Button {
                    state.placePicking = nil
                } label: {
                    OneLineButtonLabel(title: "Cancel", symbol: "xmark")
                        .font(.subheadline.weight(.semibold))
                }
                .pathSecondaryAction()

                Button {
                    isSaving = true
                    Task {
                        await state.finishPickingPlace()
                        isSaving = false
                    }
                } label: {
                    OneLineButtonLabel(title: isSaving ? "Saving…" : "Set \(kind.label) here", symbol: "checkmark")
                        .font(.subheadline.weight(.semibold))
                }
                .pathPrimaryAction()
                .disabled(isSaving)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
