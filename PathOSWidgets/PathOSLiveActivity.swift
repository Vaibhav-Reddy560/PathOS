import ActivityKit
import SwiftUI
import WidgetKit

struct PathOSLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PathOSActivityAttributes.self) { context in
            LockScreenActivityView(state: context.state)
                .activityBackgroundTint(Color.void.opacity(0.9))
                .activitySystemActionForegroundColor(.ice)
                .widgetURL(context.state.deepLink)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ModeGlyph(state: state, size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrailingMetric(state: state)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        InstrumentLabel(state.mode.caption, role: state.mode.role)
                        Text(state.title)
                            .font(.headline)
                            .foregroundStyle(.ice)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        Text(state.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        if state.mode == .commute {
                            CabLinksRow()
                        }
                    }
                }
            } compactLeading: {
                ModeGlyph(state: state, size: 22)
            } compactTrailing: {
                CompactMetric(state: state)
            } minimal: {
                ModeGlyph(state: state, size: 20)
            }
            .widgetURL(state.deepLink)
            .keylineTint(state.mode.role.color)
        }
    }
}

private struct LockScreenActivityView: View {
    let state: PathOSActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ModeGlyph(state: state, size: 46)
                    .background(state.mode.role.color.opacity(0.14), in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    InstrumentLabel(state.mode.caption, role: state.mode.role)
                    Text(state.title)
                        .font(.headline)
                        .foregroundStyle(.ice)
                        .lineLimit(1)
                    Text(state.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.mist)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                TrailingMetric(state: state)
            }
            if state.mode == .commute {
                CabLinksRow()
            }
        }
        .padding(16)
    }
}

/// The mode's symbol, or a rotating arrow when a bearing is known.
private struct ModeGlyph: View {
    let state: PathOSActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        Group {
            if let bearing = state.relativeBearing {
                Image(systemName: "location.north.fill")
                    .rotationEffect(.degrees(bearing))
            } else {
                Image(systemName: state.symbol)
            }
        }
        .font(.system(size: size * 0.5, weight: .semibold))
        .foregroundStyle(state.mode.role.color)
        .frame(width: size, height: size)
    }
}

private struct TrailingMetric: View {
    let state: PathOSActivityAttributes.ContentState

    var body: some View {
        if let eta = state.etaMinutes {
            MetricText(value: "\(eta)", unit: "min", role: state.mode.role)
        } else if let distance = state.distanceMeters {
            Text(GeoMath.formatDistance(distance))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.ice)
        }
    }
}

private struct CompactMetric: View {
    let state: PathOSActivityAttributes.ContentState

    var body: some View {
        switch state.mode {
        case .compass:
            Text(state.distanceMeters.map(GeoMath.formatDistance) ?? "—")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.ice)
        case .commute:
            Text(state.etaMinutes.map { "\($0)m" } ?? "Go")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.ice)
        case .exitCheck:
            Image(systemName: "umbrella.fill")
                .foregroundStyle(state.mode.role.color)
        case .spatialNote:
            Text("Note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.ice)
        case .venue:
            Image(systemName: "sparkle")
                .foregroundStyle(state.mode.role.color)
        case .journey:
            Text(state.etaMinutes.map { "\($0)m" } ?? "Metro")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.ice)
        case .trip:
            Text(state.etaMinutes.map { "\($0)m" } ?? state.distanceMeters.map(GeoMath.formatDistance) ?? "Trip")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.ice)
        }
    }
}

private struct CabLinksRow: View {
    private let providers: [(id: String, name: String)] = [("uber", "Uber"), ("ola", "Ola"), ("rapido", "Rapido")]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(providers, id: \.id) { provider in
                Link(destination: URL(string: "pathos://cab?provider=\(provider.id)")!) {
                    Text(provider.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.ice)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.elevatedSurface, in: Capsule())
                }
            }
        }
    }
}

extension PathOSActivityAttributes.Mode {
    var caption: String {
        switch self {
        case .exitCheck: "Exit check"
        case .commute: "Commute"
        case .compass: "Pointer"
        case .spatialNote: "Spatial memory"
        case .venue: "Context"
        case .journey: "Journey"
        case .trip: "Trip"
        }
    }
}
