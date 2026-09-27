import MapKit
import SwiftUI

/// Glass controls floating over the map, top trailing, like Apple Maps.
struct ControlRail: View {
    let scope: Namespace.ID

    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 10) {
            MapUserLocationButton(scope: scope)
            MapCompass(scope: scope)

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    // Only while a way is being followed, where spoken turns are the thing you
                    // most want to silence without stopping the journey.
                    if state.trip != nil {
                        RailButton(
                            symbol: state.speaksDirections ? "speaker.wave.2.fill" : "speaker.slash.fill",
                            role: state.speaksDirections ? .you : nil,
                            label: state.speaksDirections ? "Mute directions" : "Speak directions"
                        ) {
                            state.speaksDirections.toggle()
                        }
                    }
                    // The scanner is presented from the deck, which steps aside while guiding.
                    if state.compassTarget == nil {
                        RailButton(symbol: "camera.viewfinder", role: .you, label: "Scan") {
                            state.beginScan()
                        }
                    }
                    RailButton(symbol: "waveform", label: "Ask PathOS") {
                        state.activateAssistant(listen: true)
                    }
                    layersMenu
                }
            }
        }
        .buttonBorderShape(.circle)
    }

    private var layersMenu: some View {
        Menu {
            // Apple's own map, under PathOS's: off by default, and as much of it as you want.
            Menu("Apple Maps places", systemImage: "mappin.circle") {
                Toggle("Everything", systemImage: "globe.asia.australia", isOn: everything)
                Section("Or just these") {
                    ForEach(POIGroups.each, id: \.rawValue) { group in
                        Toggle(group.label, systemImage: group.symbol, isOn: places(group))
                            .disabled(state.poiDisplay.showsEverything)
                    }
                }
            }
            Section("What PathOS shows") {
                Toggle("Walk rings", systemImage: "circle.dotted", isOn: layer(.rings))
                Toggle("Places", systemImage: "mappin", isOn: layer(.places))
                Toggle("Events", systemImage: "ticket", isOn: layer(.events))
                Toggle("Your memories", systemImage: "bookmark", isOn: layer(.memories))
                Toggle("Bus stops & metro", systemImage: "bus", isOn: layer(.transit))
            }
        } label: {
            RailGlyph(symbol: "square.3.layers.3d", role: .world)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Map layers")
    }

    /// Everything Apple knows, which replaces any chosen kinds rather than adding to them.
    private var everything: Binding<Bool> {
        Binding {
            state.poiDisplay.showsEverything
        } set: { isOn in
            state.poiDisplay.showsEverything = isOn
            if isOn {
                state.poiDisplay.groups = []
            }
        }
    }

    private func places(_ group: POIGroups) -> Binding<Bool> {
        Binding {
            state.poiDisplay.groups.contains(group)
        } set: { isOn in
            if isOn {
                state.poiDisplay.groups.insert(group)
            } else {
                state.poiDisplay.groups.remove(group)
            }
        }
    }

    private func layer(_ layer: MapLayers) -> Binding<Bool> {
        Binding {
            state.mapLayers.contains(layer)
        } set: { isOn in
            if isOn {
                state.mapLayers.insert(layer)
            } else {
                state.mapLayers.remove(layer)
            }
        }
    }
}

private struct RailButton: View {
    let symbol: String
    var role: SignalRole?
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RailGlyph(symbol: symbol, role: role)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

private struct RailGlyph: View {
    let symbol: String
    var role: SignalRole?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(role?.color ?? .ice)
            .frame(width: 46, height: 46)
            .contentShape(.circle)
    }
}
