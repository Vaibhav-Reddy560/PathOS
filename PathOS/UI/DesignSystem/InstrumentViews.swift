import SwiftUI

/// An SF Symbol in its role colour on a faint role-coloured disc. Without a role it stays neutral (Ice on graphite).
struct SignalGlyph: View {
    let symbol: String
    var role: SignalRole?
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(role?.color ?? .ice)
            .frame(width: size, height: size)
            .background(role?.color.opacity(0.14) ?? Color.ice.opacity(0.08), in: .circle)
            .accessibilityHidden(true)
    }
}

/// A readout: optional instrument caption, a monospaced number, and a unit.
struct MetricView: View {
    var label: String?
    let value: String
    var unit: String?
    /// Colours the unit, so the number stays Ice and the meaning stays visible.
    var role: SignalRole?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label {
                InstrumentLabel(label)
            }
            MetricText(value: value, unit: unit, role: role)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A capsule readout for status rows, e.g. "AI READY".
struct SignalChip: View {
    let symbol: String
    let text: String
    var role: SignalRole?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(role?.color ?? .mist)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.ice)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.elevatedSurface.opacity(0.72), in: .capsule)
        .overlay { Capsule().strokeBorder(Hairline.style, lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}
