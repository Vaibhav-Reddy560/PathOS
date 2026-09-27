import SwiftUI

/// What the map draws, all on one panel.
///
/// This used to be a menu inside a menu. iOS closes a menu the moment you tap a row, so turning on
/// food and transit meant opening the rail, opening the submenu, tapping one, and doing the whole
/// thing again for the other — and the rows in a menu are laid out by iOS, which put a checkmark
/// in front of some and not others and left the two panels out of line with each other.
///
/// Here every row is the same shape — symbol, name, and a tick on the right — and the panel stays
/// open, so you set the map up in one go and dismiss it when you're done.
struct MapLayersPanel: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    /// Wide enough for "Parks & outdoors" on one line at the default text size.
    static let width: CGFloat = 288

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                places
                pathOS
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Self.width)
        .background(Color.deepSurface)
    }

    // MARK: Apple's own map

    private var places: some View {
        VStack(alignment: .leading, spacing: 2) {
            Header("Apple Maps places")
            LayerRow(symbol: "globe.asia.australia", label: "Everything", isOn: state.poiDisplay.showsEverything) {
                state.poiDisplay.showsEverything.toggle()
                if state.poiDisplay.showsEverything {
                    state.poiDisplay.groups = []
                }
            }
            ForEach(POIGroups.each, id: \.rawValue) { group in
                LayerRow(
                    symbol: group.symbol,
                    label: group.label,
                    // Everything covers them all, so they read as on while it is.
                    isOn: state.poiDisplay.showsEverything || state.poiDisplay.groups.contains(group),
                    isImplied: state.poiDisplay.showsEverything
                ) {
                    // Picking a kind is a narrower answer than everything, so it replaces it.
                    if state.poiDisplay.showsEverything {
                        state.poiDisplay.showsEverything = false
                        state.poiDisplay.groups = [group]
                    } else if state.poiDisplay.groups.contains(group) {
                        state.poiDisplay.groups.remove(group)
                    } else {
                        state.poiDisplay.groups.insert(group)
                    }
                }
            }
        }
    }

    // MARK: What PathOS found

    private var pathOS: some View {
        VStack(alignment: .leading, spacing: 2) {
            Header("What PathOS shows")
            LayerRow(symbol: "circle.dotted", label: "Walk rings", isOn: layer(.rings)) { toggle(.rings) }
            LayerRow(symbol: "mappin", label: "Places", isOn: layer(.places)) { toggle(.places) }
            LayerRow(symbol: "ticket", label: "Events", isOn: layer(.events)) { toggle(.events) }
            LayerRow(symbol: "bookmark", label: "Your memories", isOn: layer(.memories)) { toggle(.memories) }
            LayerRow(symbol: "bus", label: "Bus stops & metro", isOn: layer(.transit)) { toggle(.transit) }
        }
    }

    private func layer(_ layer: MapLayers) -> Bool {
        state.mapLayers.contains(layer)
    }

    private func toggle(_ layer: MapLayers) {
        if state.mapLayers.contains(layer) {
            state.mapLayers.remove(layer)
        } else {
            state.mapLayers.insert(layer)
        }
    }
}

private struct Header: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        InstrumentLabel(title)
            .padding(.leading, 4)
            .padding(.bottom, 6)
    }
}

/// One line of the panel: symbol, name, tick. Every row is this shape, so the column of symbols
/// and the column of ticks each line up down the whole panel.
private struct LayerRow: View {
    let symbol: String
    let label: String
    let isOn: Bool
    /// On because something above it is on, rather than because you chose it.
    var isImplied = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion)) {
                action()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isOn ? .aurora : .mist)
                    .frame(width: 24, alignment: .center)
                Text(label)
                    .font(.body)
                    .foregroundStyle(.ice)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.aurora)
                    .opacity(isOn ? (isImplied ? 0.35 : 1) : 0)
                    .frame(width: 16)
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 40)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
