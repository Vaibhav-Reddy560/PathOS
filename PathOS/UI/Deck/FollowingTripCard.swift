import SwiftUI

/// The journey you're making: the leg you're on, what's left, and whether you're behind the plan.
///
/// The metro ride inside it is followed stop by stop by the journey card; this is the level above,
/// which knows that the ride is one part of getting somewhere.
struct FollowingTripCard: View {
    let trip: ActiveTrip
    let status: TripGuide.Status

    @Environment(AppState.self) private var state

    var body: some View {
        ContentTile {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    SignalGlyph(symbol: status.symbol, role: status.isBehind ? .attention : .you, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        InstrumentLabel("To \(trip.destinationName)", role: status.isBehind ? .attention : .you)
                        Text(status.headline)
                            .font(.headline)
                            .foregroundStyle(.ice)
                            .lineLimit(2)
                        Text(status.detail)
                            .font(.subheadline)
                            .foregroundStyle(status.isBehind ? .amber : .mist)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }

                legs

                HStack(spacing: 8) {
                    if !state.isAt(currentLeg.endCoordinate, within: TripGuide.radius(for: currentLeg)) {
                    Button {
                        state.perform(.pointTo(CompassTarget(
                            id: "trip:\(trip.option.id)",
                            name: currentLeg.endName,
                            latitude: currentLeg.endLatitude,
                            longitude: currentLeg.endLongitude
                        )))
                    } label: {
                        Label("Point me there", systemImage: "location.north.line.fill")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .pathPrimaryAction()
                    } else {
                        Spacer(minLength: 0)
                    }

                    Button("Stop", systemImage: "xmark") {
                        state.endTrip()
                    }
                    .labelStyle(.iconOnly)
                    .font(.subheadline.weight(.bold))
                    .frame(width: 36, height: 36)
                    .pathSecondaryAction()
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Stop following this way")
                }
            }
        }
    }

    private var currentLeg: DoorToDoor.Leg {
        trip.option.legs[min(status.legIndex, trip.option.legs.count - 1)]
    }

    /// The whole way at a glance: what's done, what you're on, what's left.
    private var legs: some View {
        HStack(spacing: 6) {
            ForEach(Array(trip.option.legs.enumerated()), id: \.element.id) { index, leg in
                let isDone = index < status.legIndex
                let isNow = index == status.legIndex
                HStack(spacing: 5) {
                    Image(systemName: isDone ? "checkmark" : leg.mode.symbol)
                        .font(.caption2.weight(.semibold))
                    if isNow {
                        Text(leg.endName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(isNow ? .ice : .mist)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isNow ? Color.aurora.opacity(0.16) : Color.elevatedSurface, in: Capsule())
                if leg.id != trip.option.legs.last?.id {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption2)
                        .foregroundStyle(.mist)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Leg \(status.legIndex + 1) of \(trip.option.legs.count): \(status.headline)")
    }
}
