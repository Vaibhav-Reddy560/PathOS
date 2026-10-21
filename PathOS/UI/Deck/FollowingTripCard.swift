import SwiftUI

/// The journey you're making: the leg you're on, what's left, and whether you're behind the plan.
/// On the ride, it says what the ride needs of you — the train to board, the next station, the
/// change, getting off — rather than a second card saying it beside this one.
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
                        Text(ride?.headline ?? status.headline)
                            .font(.headline)
                            .foregroundStyle(.ice)
                            .lineLimit(2)
                        Text(ride?.detail ?? status.detail)
                            .font(.subheadline)
                            .foregroundStyle(status.isBehind ? .amber : .mist)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }

                legs

                HStack(spacing: 8) {
                    if let arrival = state.tripArrival {
                        // Arrived: the last steps to the door, or done.
                        if arrival.side != .here {
                            Button {
                                state.finishArrival(pointing: true)
                            } label: {
                                Label("Point me there", systemImage: "location.north.line.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, minHeight: 34)
                            }
                            .pathPrimaryAction()
                        }
                        Button {
                            state.finishArrival()
                        } label: {
                            Label("Done", systemImage: "checkmark")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .pathSecondaryAction()
                    // On the platform: say so, and the stops count from now.
                    } else if state.transit.progress?.isWaiting == true, ride != nil {
                        OnTheTrainButton()
                    // The pointer is for the last stretch — finding the building — not for a
                    // place kilometres off that the map is already leading you to.
                    } else if state.pointerIsUseful(to: currentLeg.endCoordinate) {
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

                    if state.tripArrival == nil {
                        EndRouteButton { state.endTrip() }
                    }
                }
            }
        }
    }

    /// What the ride needs of you, while you're on it.
    private var ride: JourneyTracker.Instruction? {
        currentLeg.mode == .metro || currentLeg.mode == .bus ? state.rideInstruction : nil
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

/// Ending what's being followed: said in words, the one way to do it, wherever it's offered.
struct EndRouteButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("End route", systemImage: "xmark")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(minHeight: 34)
        }
        .pathSecondaryAction()
    }
}

/// On the platform: once you're on the train, the stops and minutes count from here.
struct OnTheTrainButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button {
            state.boardTrain()
        } label: {
            Label("On the train", systemImage: "tram.fill")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .pathPrimaryAction()
    }
}
