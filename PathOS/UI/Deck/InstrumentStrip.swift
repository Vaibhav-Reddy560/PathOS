import SwiftUI

/// The glanceable line in the peek deck: where you are, and a few numbers.
///
/// The venue and the readouts share one type size and one baseline, so the line reads as a
/// single instrument. Each readout is a number in Ice with its unit in the role colour, and a
/// hairline separates one readout from the next — without it "71% rain 901 m alt" runs together
/// into a single blur, because the gap between readouts is no bigger than the gap inside one.
/// Readouts drop from the right as space or Dynamic Type demands.
struct InstrumentStrip: View {
    @Environment(AppState.self) private var state
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility sizes the venue gets its own line instead of being squeezed to "…".
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
        let readouts = self.readouts

        layout {
            HStack(spacing: 7) {
                Image(systemName: "location.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.aurora)
                Text(venueName)
                    .font(.pathStrip)
                    .foregroundStyle(.ice)
                    .lineLimit(1)
            }
            // A short name like "Home" needs little; a long one gives way to the numbers first.
            .frame(minWidth: 56, alignment: .leading)

            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 8)
            }

            ViewThatFits(in: .horizontal) {
                ReadoutCluster(readouts: readouts)
                ReadoutCluster(readouts: readouts.dropLast(1))
                ReadoutCluster(readouts: readouts.dropLast(2))
                ReadoutCluster(readouts: readouts.dropLast(3))
            }
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onTapGesture { state.showDeck(.now) }
        .animation(PathMotion.control, value: state.tripStatus)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows what's around you now")
    }

    private var venueName: String {
        // Following a way, the strip carries the journey: where you are matters less than when
        // you'll be there.
        if state.trip != nil, let arrival = arrivalTime {
            return arrival
        }
        return state.context.venue.name ?? state.context.venue.kind.label
    }

    /// The clock time you'd arrive at, from what's left of the journey.
    private var arrivalTime: String? {
        guard let status = state.tripStatus, !status.hasArrived else { return nil }
        return Date().addingTimeInterval(TimeInterval(status.minutesRemaining * 60))
            .formatted(date: .omitted, time: .shortened)
    }

    /// Most useful first, because the tail is what gets dropped when space runs out.
    private var readouts: [Readout] {
        // While a way is being followed: when you'll arrive, how long is left, how far to the
        // next handover — the three numbers a journey is actually about.
        if state.trip != nil, let status = state.tripStatus, !status.hasArrived {
            var items = [Readout(id: "remaining", value: "\(status.minutesRemaining)", unit: "min",
                                 role: status.isBehind ? .attention : .you)]
            if let position = state.tripStep {
                items.append(Readout(id: "distance",
                                     value: GeoMath.formatDistance(position.metresRemaining)
                                        .replacingOccurrences(of: " km", with: "")
                                        .replacingOccurrences(of: " m", with: ""),
                                     unit: position.metresRemaining >= 1_000 ? "km" : "m",
                                     role: .world))
            }
            if status.isBehind {
                items.append(Readout(id: "behind", value: "\(status.minutesBehind)", unit: "min late", role: .attention))
            }
            return items
        }
        var items: [Readout] = []
        if let snapshot = state.weather.snapshot {
            items.append(Readout(id: "temperature", value: "\(Int(snapshot.temperatureC.rounded()))", unit: "°C", role: .world))
            items.append(Readout(
                id: "rain",
                value: "\(snapshot.rainChanceNext2h)",
                unit: "% rain",
                role: snapshot.isRainLikely ? .attention : .world
            ))
        }
        if let meters = state.barometer.absoluteAltitudeMeters {
            items.append(Readout(id: "altitude", value: "\(Int(meters.rounded()))", unit: "m alt", role: .world))
        }
        return items
    }
}

/// One number, its unit and what the unit means.
private struct Readout: Identifiable, Equatable {
    let id: String
    let value: String
    let unit: String
    let role: SignalRole
}

private struct ReadoutCluster: View {
    let readouts: [Readout]

    @ScaledMetric(relativeTo: .headline) private var ruleHeight: CGFloat = 15

    init(readouts: some Sequence<Readout>) {
        self.readouts = Array(readouts)
    }

    var body: some View {
        // Read outside the alignment closure, which can't reach main-actor state.
        let overhang = ruleHeight * 0.2

        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(readouts) { readout in
                if readout != readouts.first {
                    Rectangle()
                        .fill(Color.mist.opacity(0.3))
                        .frame(width: 1, height: ruleHeight)
                        // A rectangle has no baseline of its own, so place it across the digits
                        // rather than letting it hang from the top of the line.
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - overhang }
                        // Enough to part "15% rain" from "902 m alt"; any more and the card
                        // collapsed dropped altitude for want of room.
                        .padding(.horizontal, 8)
                }
                MetricText(
                    value: readout.value,
                    unit: readout.unit,
                    role: readout.role,
                    valueFont: .pathStrip,
                    unitFont: .pathStripUnit
                )
            }
        }
        .fixedSize()
    }
}
