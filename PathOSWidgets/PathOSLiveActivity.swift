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
                        InstrumentLabel(state.caption(at: .now), role: state.captionRole)
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
                        if let (note, text) = state.shownNotes(at: .now).first {
                            NoteLine(note: note, text: text)
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

        // A Lock Screen card is at most 160 points tall; past that iOS cuts it off mid-line. So
        // every line is one line, and there are two notes at most — one under a journey, whose
        // title may need two.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ModeGlyph(state: state, size: 42)
                    .background(state.tint.color.opacity(0.14), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    InstrumentLabel(state.caption(at: .now), role: state.captionRole)
                    Text(state.title)
                        .font(.headline)
                        .foregroundStyle(.ice)
                        .lineLimit(state.isJourney ? 2 : 1)
                    Text(state.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.mist)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
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
            let notes = state.shownNotes(at: .now).prefix(state.isJourney ? 1 : 2)
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(notes), id: \.0) { note, text in
                        NoteLine(note: note, text: text)
                    }
                }
            }
            if state.mode == .commute {
                CabLinksRow()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

/// A short line under the main one: "Take an umbrella · 70% rain in 2 h".
private struct NoteLine: View {
    let note: PathOSActivityAttributes.Note
    /// What it says now: some lines change or go at a set time.
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: note.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(note.role.color)
                .frame(width: 18)
            // One line, shrinking a little before it would be cut: two lines each made the card
            // taller than iOS allows, and the last line was the one clipped.
            Text(text)
                .font(.footnote)
                .foregroundStyle(.ice)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
        if let arrival = state.arrivalDate {
            // Counted down by the Lock Screen itself, so it's right whenever you look.
            timed(to: arrival, label: "arrive \(arrival.formatted(date: .omitted, time: .shortened))")
        } else if let timing = state.timing(at: .now) {
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
        case .journey where state.arrivalDate != nil:
            Countdown(to: state.arrivalDate ?? .now, font: .caption.weight(.semibold))
                .foregroundStyle(.ice)
                .frame(maxWidth: 44)
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
    /// Getting somewhere: a way, a ride or a trip leg.
    var isJourney: Bool { mode == .journey || mode == .trip }

    /// The notes as they read at `now`, less any whose moment has passed.
    func shownNotes(at now: Date) -> [(PathOSActivityAttributes.Note, String)] {
        (notes ?? []).compactMap { note in note.text(at: now).map { (note, $0) } }
    }

    /// The label over the title. Every one of these cards is PathOS's, so every one carries the
    /// app's name rather than a word for the mode: what it's about is the line under it, and
    /// whether something is starting or under way is the countdown beside it.
    func caption(at now: Date) -> String { "PathOS" }

    /// The name is always in Ion, the app's own teal, whatever colour the news under it is.
    var captionRole: SignalRole { .world }
}

extension PathOSActivityAttributes.Mode {
    /// A word for the mode, for accessibility rather than for the card's label.
    var caption: String {
        switch self {
        case .exitCheck: "Exit check"
        case .commute: "Commute"
        case .compass: "Pointer"
        case .spatialNote: "Spatial memory"
        case .venue: "PathOS"
        case .journey: "Journey"
        case .trip: "Trip"
        }
    }
}
