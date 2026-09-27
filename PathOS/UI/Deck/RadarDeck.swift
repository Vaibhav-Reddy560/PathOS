import SwiftUI

/// Radar: what PathOS has discovered around you. Everything here is world information, so it's cyan;
/// the only green is the "point me" action.
struct RadarDeck: View {
    @Environment(AppState.self) private var state
    @Environment(RadarModel.self) private var radar

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                categoryChips
                statusLine

                if let error = radar.errorMessage {
                    EmptyState(symbol: "location.slash", title: "Radar needs your location", message: error, role: .attention)
                } else if radar.items.isEmpty && !radar.isLoading {
                    EmptyState(symbol: "dot.radiowaves.left.and.right", title: "Nothing found nearby", message: "Pull to refresh or try another category.")
                }

                if !radar.items.isEmpty {
                    // Split by kind where the category has kinds (metro, bus, train), so you can
                    // tell a station from a stop at a glance.
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            if let title = section.title {
                                DeckSectionHeader(title: title, trailing: "\(section.items.count)")
                            }
                            GroupedRows(section.items) { item in
                                RadarRow(item: item)
                            }
                        }
                    }
                }

                Text("Places come from Apple Maps and are kept for three days. Your own events, schedule and mail are in Day, so Radar only shows what's around you.")
                    .font(.caption)
                    .foregroundStyle(.mist)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .deckScroll(lowersOnPull: false)
        // Pulling down is the one way to scan an area again before its three days are up.
        .refreshable { await radar.refresh(state: state, force: true) }
    }

    private var sections: [(title: String?, items: [RadarItem])] {
        var result: [(title: String?, items: [RadarItem])] = []
        for item in radar.items {
            if let index = result.firstIndex(where: { $0.title == item.section }) {
                result[index].items.append(item)
            } else {
                result.append((item.section, [item]))
            }
        }
        return result
    }

    private var categoryChips: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(RadarCategory.allCases) { category in
                        let isSelected = radar.category == category
                        Button {
                            withAnimation(PathMotion.control) {
                                radar.category = category
                            }
                        } label: {
                            Label(category.label, systemImage: category.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(isSelected ? .ion : .mist)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 40)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(isSelected ? .regular.interactive() : .identity, in: .capsule)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var statusLine: some View {
        if radar.isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.ion)
                InstrumentLabel("Scanning around you", role: .world)
            }
            .padding(.horizontal, 4)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if radar.rankedByAI {
                    HStack(spacing: 6) {
                        Image(systemName: "apple.intelligence")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.ion)
                        InstrumentLabel("Ranked on-device for you")
                    }
                }
                if let scannedAt = radar.scannedAt, Date().timeIntervalSince(scannedAt) > 3_600 {
                    InstrumentLabel("Found \(scannedAt.formatted(.relative(presentation: .named))) · pull down to scan again")
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct RadarRow: View {
    let item: RadarItem

    @Environment(AppState.self) private var state

    var body: some View {
        let role = item.isEvent || item.start != nil ? WorldSignalBuilder.eventRole(start: item.start, now: Date()) : .world

        HStack(spacing: 14) {
            SignalGlyph(symbol: item.symbol, role: role)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(.ice)
                    .lineLimit(1)
                Text(item.reason ?? item.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.mist)
                    .lineLimit(2)
                if let metrics {
                    InstrumentLabel(metrics, role: role == .attention ? .attention : nil)
                }
            }

            Spacer(minLength: 0)

            if let target {
                // Close enough to see from here: a route has nothing to say, so the arrow points.
                let canRoute = state.routeIsWorthIt(to: target.coordinate)
                Button {
                    if canRoute {
                        state.showWays(to: item.title, at: target.coordinate, id: item.id, arriveBy: item.start)
                    } else {
                        state.startCompass(to: target)
                    }
                } label: {
                    Image(systemName: canRoute ? "arrow.triangle.turn.up.right.diamond.fill" : "location.north.line.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.aurora)
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(canRoute ? "Ways to \(item.title)" : "Point me to \(item.title)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .onTapGesture {
            if target != nil {
                state.selectedSignalID = item.id
            }
        }
        .contextMenu {
            if let target {
                ForEach(CabProvider.allCases) { provider in
                    Button("Book \(provider.name)", systemImage: provider.symbol) {
                        CabLauncher.open(provider, drop: target.coordinate, pickup: state.location.location?.coordinate)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var target: CompassTarget? {
        guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
        // Nothing to point at when you're already there.
        if let distance = item.distanceMeters, distance < WorldSignalBuilder.hereRadius { return nil }
        return CompassTarget(id: item.id, name: item.title, latitude: latitude, longitude: longitude)
    }

    private var metrics: String? {
        var parts: [String] = []
        if let distance = item.distanceMeters {
            // Past a couple of kilometres nobody walks, so the minutes would only mislead.
            parts.append(distance < WorldSignalBuilder.hereRadius
                         ? "Here"
                         : distance > 2_000
                         ? "\(GeoMath.formatDistance(distance)) away"
                         : "\(GeoMath.formatDistance(distance)) · \(GeoMath.walkingMinutes(forDistance: distance)) min")
        }
        if let start = item.start {
            parts.append(start.formatted(date: Calendar.current.isDateInToday(start) ? .omitted : .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Empty and error states inside the deck.
struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var role: SignalRole?

    var body: some View {
        ContentTile {
            HStack(alignment: .top, spacing: 14) {
                SignalGlyph(symbol: symbol, role: role)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.ice)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.mist)
                }
            }
        }
    }
}
