import SwiftUI

/// A barely-there field of a role's colour (5–10% opacity), used instead of gradients:
/// green around you, cyan around environmental information, amber at the edge during an alert.
struct AtmosphereField: View {
    let role: SignalRole
    var diameter: CGFloat = 160
    var intensity: Double = 0.08

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if !reduceTransparency {
            Circle()
                .fill(role.color.opacity(intensity))
                .frame(width: diameter, height: diameter)
                .blur(radius: diameter * 0.22)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
