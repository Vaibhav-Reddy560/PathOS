import SwiftUI

/// The turn coming up, over the map, while you're following a way somewhere.
///
/// Apple Maps' own wording for the turn, PathOS's distance to it, and what happens at the end of
/// this leg — the station you're heading for, the train you'll take — so the handover from a
/// road to a ride is never a surprise.
struct NavigationBanner: View {
    let trip: ActiveTrip
    let status: TripGuide.Status

    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(status.isBehind || ride?.isAction == true ? .amber : .aurora)
                    .frame(width: 46, height: 46)
                    .background(Color.elevatedSurface, in: .circle)

                VStack(alignment: .leading, spacing: 3) {
                    // Read at a glance from a dashboard, so the turn is the biggest thing here.
                    Text(headline)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.ice)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(status.isBehind ? .amber : .mist)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            // On the platform: the stops count from when you say you're on.
            if ride != nil, state.transit.progress?.isWaiting == true {
                OnTheTrainButton()
            }
            // A leg by road, as it starts: how you're doing it, until you've said.
            if !isRide, let leg = state.legAwaitingChoice {
                LegChoiceMenu(leg: leg, chosen: nil)
            }
        }
        .bannerCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(detail)")
    }

    /// On the road it's the turn; on the train it's the ride.
    private var headline: String {
        // Off the route: said at once, while the new one is fetched.
        if state.isRerouting, !isRide {
            return "Finding a new route…"
        }
        if let step = currentStep, let position = state.tripStep, !isRide {
            return StepGuide.sentence(for: step, metresToStep: position.metresToStep)
        }
        // On the train: the next station, the change, the stop to get off at.
        if let ride { return ride.headline }
        return status.headline
    }

    /// What to do on the ride, while you're on it.
    private var ride: JourneyTracker.Instruction? {
        isRide ? state.rideInstruction : nil
    }

    /// Where this leg ends, what happens after it, and the time left — each said once.
    private var detail: String {
        var parts: [String] = []
        if let ride {
            // It already says what comes after the ride.
            parts.append(ride.detail)
            if status.isBehind { parts.append("\(status.minutesBehind) min behind") }
            return parts.joined(separator: " · ")
        } else if isRide, let progress = state.transit.progress {
            parts.append(JourneyTracker.summary(progress))
        } else if !isRide, state.tripStep != nil {
            parts.append("to \(currentLeg.endName)")
        }
        if let next = nextLeg {
            let instruction = TripGuide.instruction(for: next)
            parts.append("then \(instruction.prefix(1).lowercased() + instruction.dropFirst())")
        }
        parts.append("\(status.minutesRemaining) min to go")
        if status.isBehind {
            parts.append("\(status.minutesBehind) min behind")
        }
        return parts.joined(separator: " · ")
    }

    /// The turn itself, drawn from Apple Maps' wording for it.
    private var symbol: String {
        if state.isRerouting, !isRide { return "arrow.triangle.2.circlepath" }
        if let ride { return ride.symbol }
        guard !isRide, let step = currentStep else { return currentLeg.mode.symbol }
        return StepGuide.symbol(for: step.instruction)
    }

    private var currentLeg: DoorToDoor.Leg {
        trip.option.legs[min(status.legIndex, trip.option.legs.count - 1)]
    }

    private var nextLeg: DoorToDoor.Leg? {
        trip.option.legs[safe: status.legIndex + 1]
    }

    private var isRide: Bool {
        currentLeg.mode == .metro || currentLeg.mode == .bus
    }

    private var currentStep: StepGuide.Step? {
        guard let nav = state.tripNav, let position = state.tripStep else { return nil }
        return nav.steps[safe: position.stepIndex]
    }
}

/// A metro or bus journey followed stop by stop on its own, without a way around it: what to do
/// next on the ride — the train to board, the next station, a change, getting off.
struct RideBanner: View {
    let instruction: JourneyTracker.Instruction

    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: instruction.symbol)
                .font(.title.weight(.semibold))
                .foregroundStyle(instruction.isAction ? .amber : .aurora)
                .frame(width: 46, height: 46)
                .background(Color.elevatedSurface, in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(instruction.headline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.ice)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(instruction.detail)
                    .font(.footnote)
                    .foregroundStyle(.mist)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(instruction.headline). \(instruction.detail)")
            if state.transit.progress?.isWaiting == true {
                OnTheTrainButton()
            }
        }
        .bannerCard()
    }
}

/// Arrived: said over the map, with which side of the road the place is on, as a navigation app
/// does — rather than the map that led you there vanishing a street short. Point me there hands
/// over to the pointer for the last few steps to the door; Done puts it all away.
struct ArrivalBanner: View {
    let arrival: TripArrival

    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "flag.checkered")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.aurora)
                    .frame(width: 46, height: 46)
                    .background(Color.elevatedSurface, in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text("You've arrived")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.ice)
                    Text(arrival.sentence)
                        .font(.subheadline)
                        .foregroundStyle(.ice)
                        .lineLimit(2)
                    Text("\(arrival.minutesDoorToDoor) min door to door")
                        .font(.footnote)
                        .foregroundStyle(.mist)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if arrival.side != .here {
                    Button {
                        state.finishArrival(pointing: true)
                    } label: {
                        OneLineButtonLabel(title: "Point me there", symbol: "location.north.line.fill")
                    }
                    .pathPrimaryAction()
                }
                Button {
                    state.finishArrival()
                } label: {
                    OneLineButtonLabel(title: "Done", symbol: "checkmark")
                }
                .pathSecondaryAction()
            }
        }
        .bannerCard()
        .accessibilityElement(children: .contain)
    }
}

private extension View {
    /// The banners' card over the map: one shape for the turn, the ride and the arrival.
    func bannerCard() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.void.opacity(0.92))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Hairline.style, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            }
            .padding(.horizontal, DeckLayout.sideMargin)
    }
}
