import SwiftData
import SwiftUI

/// Search: any place or address Apple Maps knows, and your own saved places and notes. A result
/// can be shown on the map, pointed to, booked a cab to, or made your Home or Work, which also
/// works from anywhere, not only while standing there.
struct SearchDeck: View {
    @Environment(AppState.self) private var state
    @Query(sort: \SavedPlace.createdAt) private var savedPlaces: [SavedPlace]
    @Query(filter: #Predicate<SpatialNote> { $0.isActive }) private var notes: [SpatialNote]

    @State private var isSearching = false
    @State private var problem: String?
    @State private var suggestions = SearchSuggestions()
    /// A suggestion picked, whose places are what's listed until the text changes.
    @State private var picked: SearchSuggestions.Suggestion?
    @FocusState private var isFocused: Bool

    // Kept by the app rather than here, so a search is still there after showing a result on
    // the map and opening its card.
    private var query: String {
        get { state.searchQuery }
        nonmutating set { state.searchQuery = newValue }
    }
    private var results: [PlaceSummary] {
        get { state.searchResults }
        nonmutating set { state.searchResults = newValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchField

                if let kind = state.searchSettingPlace {
                    settingBanner(kind)
                }

                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    placesToSet
                } else {
                    yours
                    if picked == nil, !suggestionsShown.isEmpty {
                        suggestionList
                    }
                    fromMaps
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .deckScroll()
        // Searching wants room for results, as it does in Maps.
        .onChange(of: isFocused) { _, focused in
            if focused { state.deckStop = .full }
        }
        .task(id: query) {
            // Suggestions on every letter, as in Maps; the full search once you pause.
            if picked.map({ query != $0.title }) ?? true {
                picked = nil
                suggestions.update(query, near: state.location.location)
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, picked == nil else { return }
            await search()
        }
    }

    // MARK: Pieces

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(.mist)
            TextField("Places and addresses", text: Binding { query } set: { query = $0 })
                .font(.body)
                .foregroundStyle(.ice)
                .focused($isFocused)
                .submitLabel(.search)
                .onSubmit { Task { await search() } }
                .autocorrectionDisabled()
            if isSearching {
                ProgressView()
                    .controlSize(.small)
                    .tint(.ion)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    state.searchPlace = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.mist)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .background(Color.elevatedSurface, in: .capsule)
    }

    private func settingBanner(_ kind: PlaceKind) -> some View {
        HStack(spacing: 12) {
            SignalGlyph(symbol: kind.symbol, role: .you, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Choosing your \(kind.label.lowercased())")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ice)
                Text("Search for it, then tap Set as \(kind.label).")
                    .font(.footnote)
                    .foregroundStyle(.mist)
            }
            Spacer(minLength: 0)
            Button("Cancel") { state.searchSettingPlace = nil }
                .font(.subheadline.weight(.semibold))
                .pathSecondaryAction()
        }
    }

    /// Before you type: Home and Work, and the two ways to put them anywhere.
    private var placesToSet: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: "Your places")
            ContentTile(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array([PlaceKind.home, .work].enumerated()), id: \.element) { index, kind in
                        if index > 0 { RowDivider() }
                        let place = savedPlaces.first { $0.kind == kind }
                        HStack(spacing: 14) {
                            SignalGlyph(symbol: kind.symbol, role: place == nil ? nil : .you)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(kind.label)
                                    .font(.headline)
                                    .foregroundStyle(.ice)
                                Text(place.map { $0.name == kind.label ? "Set" : $0.name } ?? "Not set")
                                    .font(.subheadline)
                                    .foregroundStyle(.mist)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            PlaceSetMenu(kind: kind, isSet: place != nil) {
                                state.searchSettingPlace = kind
                                isFocused = true
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }
            }
            Text("Home and Work power exit checks, travel times and the reminders to leave on time. Set them by searching, on the map, or where you're standing.")
                .font(.caption)
                .foregroundStyle(.mist)
                .padding(.horizontal, 4)
        }
    }

    /// Saved places and notes whose names match.
    @ViewBuilder
    private var yours: some View {
        let text = query.trimmingCharacters(in: .whitespaces)
        let places = savedPlaces.filter { $0.name.localizedCaseInsensitiveContains(text) || $0.kind.label.localizedCaseInsensitiveContains(text) }
        let memories = notes.filter { $0.title.localizedCaseInsensitiveContains(text) || $0.body.localizedCaseInsensitiveContains(text) }
        if !places.isEmpty || !memories.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                DeckSectionHeader(title: "Yours")
                ContentTile(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(places) { place in
                            yourRow(title: place.name, subtitle: place.kind.label, symbol: place.kind.symbol,
                                    id: place.id.uuidString, latitude: place.latitude, longitude: place.longitude)
                        }
                        ForEach(memories) { note in
                            yourRow(title: note.title, subtitle: note.body.isEmpty ? "Note" : note.body, symbol: "mappin.and.ellipse",
                                    id: note.geofenceID, latitude: note.latitude, longitude: note.longitude)
                        }
                    }
                }
            }
        }
    }

    private func yourRow(title: String, subtitle: String, symbol: String, id: String, latitude: Double, longitude: Double) -> some View {
        HStack(spacing: 14) {
            SignalGlyph(symbol: symbol, role: .you)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.ice)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.mist)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                state.startCompass(to: CompassTarget(id: id, name: title, latitude: latitude, longitude: longitude))
            } label: {
                Image(systemName: "location.north.line.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.aurora)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Point me to \(title)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Apple Maps' suggestions that aren't already among the places listed.
    private var suggestionsShown: [SearchSuggestions.Suggestion] {
        let listed = Set(results.map { $0.name.lowercased() })
        return suggestions.suggestions.filter { !listed.contains($0.title.lowercased()) }.prefix(6).map { $0 }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: "Suggestions")
            ContentTile(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(suggestionsShown.enumerated()), id: \.element.id) { index, suggestion in
                        if index > 0 { RowDivider() }
                        Button {
                            Task { await run(suggestion) }
                        } label: {
                            HStack(spacing: 14) {
                                SignalGlyph(symbol: suggestion.isQuery ? "magnifyingglass" : "mappin", role: .world, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title)
                                        .font(.headline)
                                        .foregroundStyle(.ice)
                                        .lineLimit(1)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(.subheadline)
                                            .foregroundStyle(.mist)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// A suggestion picked: its places become the list, the one place shown on the map.
    private func run(_ suggestion: SearchSuggestions.Suggestion) async {
        isSearching = true
        defer { isSearching = false }
        picked = suggestion
        query = suggestion.title
        let found = await suggestions.places(for: suggestion, near: state.location.location)
        results = found
        problem = nil
        if found.count == 1, let only = found.first {
            state.searchPlace = only
        }
    }

    @ViewBuilder
    private var fromMaps: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: "Places", trailing: results.isEmpty ? nil : "\(results.count)")
            if let problem {
                Text(problem)
                    .font(.subheadline)
                    .foregroundStyle(.amber)
                    .padding(.horizontal, 4)
            } else if results.isEmpty && !isSearching {
                Text("Nothing found. Try another name or an address.")
                    .font(.subheadline)
                    .foregroundStyle(.mist)
                    .padding(.horizontal, 4)
            }
            ForEach(results) { place in
                SearchResultRow(place: place)
            }
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            results = []
            problem = nil
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await state.places.find(text, near: state.location.location)
            problem = nil
        } catch {
            results = []
            problem = "Apple Maps couldn't search just now. Check your connection and try again."
        }
    }
}

/// Set as Home or Work: here, by searching, or on the map.
struct PlaceSetMenu: View {
    let kind: PlaceKind
    let isSet: Bool
    var search: () -> Void

    @Environment(AppState.self) private var state

    var body: some View {
        Menu {
            Button("Search for it", systemImage: "magnifyingglass", action: search)
            Button("Pick on the map", systemImage: "map") { state.startPickingPlace(kind) }
            Button("Where I am now", systemImage: "location.fill") {
                Task {
                    if await state.setPlaceHere(kind) {
                        state.showToast("\(kind.label) set where you are", symbol: kind.symbol)
                    } else {
                        state.showToast("Couldn't get your location", role: .attention, symbol: "location.slash.fill")
                    }
                }
            }
        } label: {
            Text(isSet ? "Change" : "Set")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
        }
        .pathSecondaryAction()
    }
}

/// One of Apple Maps' answers: tap it to see it on the map; its menu does the rest.
private struct SearchResultRow: View {
    let place: PlaceSummary

    @Environment(AppState.self) private var state

    var body: some View {
        ContentTile(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    SignalGlyph(symbol: place.symbol, role: .world)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(place.name)
                            .font(.headline)
                            .foregroundStyle(.ice)
                            .lineLimit(2)
                        Text([place.categoryName == "Address" ? nil : place.categoryName, place.address].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                            .lineLimit(2)
                        if place.distanceMeters > 0 {
                            InstrumentLabel(place.distanceMeters > 2_000
                                            ? "\(GeoMath.formatDistance(place.distanceMeters)) away"
                                            : "\(GeoMath.formatDistance(place.distanceMeters)) · \(place.walkMinutes) min walk")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
                .onTapGesture(perform: showOnMap)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows it on the map")

                HStack(spacing: 8) { buttons }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if let kind = state.searchSettingPlace {
            Button {
                Task {
                    state.searchSettingPlace = nil
                    await state.setPlace(kind, name: place.name, at: place.coordinate)
                }
            } label: {
                OneLineButtonLabel(title: "Set as \(kind.label)", symbol: kind.symbol)
                    .font(.subheadline.weight(.semibold))
            }
            .pathPrimaryAction()
        } else if state.isAt(place.coordinate) {
            // You're there: the map is the useful thing, not a pointer to where you stand.
            Button(action: showOnMap) {
                OneLineButtonLabel(title: "You're here · show on map", symbol: "map")
                    .font(.subheadline.weight(.semibold))
            }
            .pathSecondaryAction()
        } else {
            Button {
                state.startCompass(to: CompassTarget(id: "place:\(place.id)", name: place.name, latitude: place.latitude, longitude: place.longitude))
            } label: {
                OneLineButtonLabel(title: "Point me there", symbol: "location.north.line.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .pathPrimaryAction()
        }

        Menu {
            if !state.isTravelling, !state.isAt(place.coordinate) {
                Button("Ways to get there", systemImage: "arrow.triangle.turn.up.right.diamond.fill") {
                    state.showWays(to: place.name, at: place.coordinate, id: "place:\(place.id)")
                }
            }
            Button("Show on the map", systemImage: "map", action: showOnMap)
            Button("Set as Home", systemImage: PlaceKind.home.symbol) {
                Task { await state.setPlace(.home, name: place.name, at: place.coordinate) }
            }
            Button("Set as Work", systemImage: PlaceKind.work.symbol) {
                Task { await state.setPlace(.work, name: place.name, at: place.coordinate) }
            }
            ForEach(CabProvider.allCases) { provider in
                Button("Book \(provider.name)", systemImage: provider.symbol) {
                    CabLauncher.open(provider, drop: place.coordinate, pickup: state.location.location?.coordinate)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.bold))
                .frame(width: 36, height: 36)
        }
        .pathSecondaryAction()
        .buttonBorderShape(.circle)
        .accessibilityLabel("More for \(place.name)")
    }

    /// Puts it on the map, selected, with the deck out of the way.
    private func showOnMap() {
        state.searchPlace = place
        Task {
            // Once the map has it among its signals.
            try? await Task.sleep(for: .milliseconds(100))
            state.pointOut("place:\(place.id)")
        }
    }
}
