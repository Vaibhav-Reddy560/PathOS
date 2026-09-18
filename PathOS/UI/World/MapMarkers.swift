import SwiftUI

/// You: an Aurora dot in an Ice ring, sitting in a faint green field.
/// While Radar is discovering, cyan sonar rings ripple out from it.
struct UserMarker: View {
    var isScanning: Bool

    var body: some View {
        ZStack {
            AtmosphereField(role: .you, diameter: 120, intensity: 0.1)
            if isScanning {
                RadarPing(diameter: 150)
            }
            Circle()
                .fill(Color.ice)
                .frame(width: 22, height: 22)
                .shadow(color: .void.opacity(0.5), radius: 4)
            Circle()
                .fill(Color.aurora)
                .frame(width: 15, height: 15)
        }
        .frame(width: 150, height: 150)
        .accessibilityElement()
        .accessibilityLabel("Your location")
    }
}

/// Cyan sonar rings rippling out while PathOS scans. A ring has no direction, so a paused frame
/// can never be mistaken for a heading cone. A still ring with Reduce Motion.
private struct RadarPing: View {
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    var body: some View {
        ZStack {
            if reduceMotion {
                Circle()
                    .strokeBorder(Color.ion.opacity(0.35), lineWidth: 1)
            } else {
                ForEach(0..<2, id: \.self) { ring in
                    Circle()
                        .strokeBorder(Color.ion.opacity(0.5), lineWidth: 1.5)
                        .scaleEffect(isExpanded ? 1 : 0.2)
                        .opacity(isExpanded ? 0 : 1)
                        .animation(.easeOut(duration: 2).repeatForever(autoreverses: false).delay(Double(ring)), value: isExpanded)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .onAppear { isExpanded = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Where guidance is taking you, when it isn't already one of your signals.
struct GuidanceTargetMarker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.aurora.opacity(0.5), lineWidth: 1.5)
                .frame(width: 44, height: 44)
            Image(systemName: "scope")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.void)
                .frame(width: 26, height: 26)
                .background(Color.aurora, in: .circle)
                .symbolEffect(.breathe, isActive: !reduceMotion)
        }
        .accessibilityElement()
        .accessibilityLabel("Guidance destination")
    }
}

/// A signal on the map. World signals are small cyan discs; yours are Aurora.
/// The title only appears when selected, so the city stays readable.
struct SignalMarker: View {
    let signal: WorldSignal
    let isSelected: Bool
    var onTap: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 6) {
            glyph
                .scaleEffect(isSelected ? 1.25 : 1)
            if isSelected {
                Text(signal.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.ice)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.void.opacity(0.85), in: .capsule)
                    .overlay { Capsule().strokeBorder(Hairline.style, lineWidth: 1) }
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
        .animation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion), value: isSelected)
        .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.4)
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            withAnimation(PathMotion.signal.delay(Double(abs(signal.id.hashValue) % 8) * 0.04)) {
                hasAppeared = true
            }
        }
        .accessibilityElement()
        .accessibilityLabel(signal.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var glyph: some View {
        switch signal.kind {
        case .memory:
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.aurora)
                    .frame(width: 20, height: 20)
                    .rotationEffect(.degrees(45))
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.void)
            }
            .frame(width: 30, height: 30)
            .shadow(color: .void.opacity(0.6), radius: 3)
        case .home, .work:
            Image(systemName: signal.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.aurora)
                .frame(width: 30, height: 30)
                .background(Color.void, in: .circle)
                .overlay { Circle().strokeBorder(Color.aurora, lineWidth: 1.5) }
        case .transitStop:
            // Infrastructure, not a destination: a small square, quieter than a place.
            Image(systemName: signal.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(signal.role.color)
                .frame(width: 20, height: 20)
                .background(Color.void.opacity(0.85), in: .rect(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(signal.role.color.opacity(0.6), lineWidth: 1)
                }
        case .place, .event, .assistantPick:
            ZStack {
                if signal.isHighlighted {
                    Circle()
                        .fill(signal.role.color.opacity(0.2))
                        .frame(width: 38, height: 38)
                }
                Image(systemName: signal.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.void)
                    .symbolEffect(.breathe, isActive: signal.role == .attention && !reduceMotion)
                    .frame(width: 24, height: 24)
                    .background(signal.role.color, in: .circle)
                    .overlay { Circle().strokeBorder(Color.void.opacity(0.6), lineWidth: 1) }
            }
        }
    }
}
