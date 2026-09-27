import MapKit
import SwiftUI

/// Glass controls floating over the map, top trailing, like Apple Maps.
struct ControlRail: View {
    let scope: Namespace.ID

    @Environment(AppState.self) private var state
    @State private var isShowingLayers = false

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
                    layersButton
                }
            }
        }
        .buttonBorderShape(.circle)
    }

    /// The panel stays open while you set the map up, rather than closing on every tap.
    private var layersButton: some View {
        Button {
            isShowingLayers = true
        } label: {
            RailGlyph(symbol: "square.3.layers.3d", role: state.poiDisplay.isOn ? .you : .world)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Map layers")
        .popover(isPresented: $isShowingLayers, arrowEdge: .trailing) {
            MapLayersPanel()
                // A popover on the map, anchored to its own button: as a sheet it would cover the
                // map you are setting up.
                .presentationCompactAdaptation(.popover)
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
