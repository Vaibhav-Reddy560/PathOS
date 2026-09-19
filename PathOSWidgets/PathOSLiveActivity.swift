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
                        InstrumentLabel(state.caption(at: .now), role: state.tint)
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
                        if let note = state.notes?.first {
                            NoteLine(note: note)
                        }
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
            .keylineTint(state.tint.color)
        }
    }
}

private struct LockScreenActivityView: View {
    let state: PathOSActivityAttributes.ContentState

    var body: some View {
        // Read when drawn. The content goes stale at a class's start, which redraws this, so the
        // countdown to the start becomes the time left without PathOS having to run.
        let timing = state.timing(at: .now)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ModeGlyph(state: state, size: 46)
                    .background(state.tint.color.opacity(0.14), in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    InstrumentLabel(state.caption(at: .now), role: state.tint)
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
            if case .endsIn(let start, let end) = timing {
                ProgressView(timerInterval: start...end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .tint(state.tint.color)
            }
            if let notes = state.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(notes, id: \.self) { note in
                        NoteLine(note: note)
                    }
                }
            }
            if state.mode == .commute {
                CabLinksRow()
            }
        }
        .padding(16)
    }
}

/// A short line under the main one: "Take an umbrella · 70% rain in 2 h".
private struct NoteLine: View {
    let note: PathOSActivityAttributes.Note

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: note.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(note.role.color)
                .frame(width: 18)
            Text(note.text)
                .font(.footnote)
                .foregroundStyle(.ice)
                .lineLimit(1)
        }
    }
}

/// Counts down to a start or an end on its own, between PathOS's updates.
private struct Countdown: View {
    let to: Date
    var font: Font = .title3.weight(.semibold)

    var body: some View {
        // A timer's text takes all the width it's offered, so it's given only what it needs.
        Text(timerInterval: Date.now...max(to, .now), countsDown: true)
            .font(font.monospacedDigit())
            .multilineTextAlignment(.trailing)
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
        .foregroundStyle(state.tint.color)
        .frame(width: size, height: size)
    }
}

private struct TrailingMetric: View {
    let state: PathOSActivityAttributes.ContentState

    var body: some View {
        if let timing = state.timing(at: .now) {
            switch timing {
            case .startsIn(let start):
                timed(to: start, label: "to start")
            case .endsIn(_, let end):
                timed(to: end, label: "left")
            case .over:
                EmptyView()
            }
        } else if let eta = state.etaMinutes {
            MetricText(value: "\(eta)", unit: "min", role: state.tint)
        } else if let distance = state.distanceMeters {
            Text(GeoMath.formatDistance(distance))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.ice)
        }
    }
}

extension TrailingMetric {
    private func timed(to date: Date, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Countdown(to: date)
                .foregroundStyle(.ice)
                .frame(maxWidth: 88, alignment: .trailing)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(state.tint.color)
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
                .foregroundStyle(state.tint.color)
        case .spatialNote:
            Text("Note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.ice)
        case .venue:
            switch state.timing(at: .now) {
            case .startsIn(let date), .endsIn(_, let date):
                Countdown(to: date, font: .caption.weight(.semibold))
                    .foregroundStyle(.ice)
                    .frame(maxWidth: 44)
            default:
                if state.notes?.contains(where: { $0.symbol == "umbrella.fill" }) == true {
                    Image(systemName: "umbrella.fill")
                        .foregroundStyle(SignalRole.attention.color)
                } else {
                    Image(systemName: "sparkle")
                        .foregroundStyle(state.tint.color)
                }
            }
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

extension PathOSActivityAttributes.ContentState {
    /// The small label over the title: what a timed item is doing, else the mode.
    func caption(at now: Date) -> String {
        switch timing(at: now) {
        case .startsIn: "Starting soon"
        case .endsIn: "On now"
        case .over: "Just finished"
        case nil: mode.caption
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
