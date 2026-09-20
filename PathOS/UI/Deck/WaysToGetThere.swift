import CoreLocation
import SwiftUI

/// Where you want to be, so the ways of getting there can be worked out.
nonisolated struct WaysRequest: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    /// When you need to be there, if it's for something with a start time.
    var arriveBy: Date?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Every way of getting somewhere, door to door: what to take, in what order, how long each part
/// takes and what it costs. Picking one follows it, so PathOS can say where you are along it.
struct WaysToGetThereView: View {
    let request: WaysRequest

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var options: [DoorToDoor.Option] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let arriveBy = request.arriveBy {
                        arrivalLine(arriveBy)
                    }
                    if isLoading && options.isEmpty {
                        loading
                    } else if options.isEmpty {
                        Text("No way of getting there could be worked out. Apple Maps may not have a route from where you are.")
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                    } else {
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            WayCard(option: option, request: request, tag: tag(for: option, index: index))
                        }
                        sources
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .background(Color.deepSurface)
            .navigationTitle("Ways to \(request.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    // MARK: Pieces

    private var loading: some View {
        HStack(spacing: 12) {
            ProgressView().tint(.ion)
            Text("Working out the ways there…")
                .font(.subheadline)
                .foregroundStyle(.mist)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }

    private func arrivalLine(_ arriveBy: Date) -> some View {
        let minutes = Int(arriveBy.timeIntervalSinceNow / 60)
        let quickest = options.first { $0.isAvailableNow }?.minutes
        let makesIt = quickest.map { $0 <= minutes }
        return ContentTile {
            HStack(spacing: 12) {
                SignalGlyph(symbol: "clock.fill", role: makesIt == false ? .attention : .you, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Starts at \(arriveBy.formatted(date: .omitted, time: .shortened))")
                        .font(.headline)
                        .foregroundStyle(.ice)
                    Text(makesIt == nil
                         ? "\(minutes) min from now"
                         : makesIt! ? "\(minutes) min from now · the quickest way takes about \(quickest!) min"
                                    : "\(minutes) min from now · every way takes longer than that")
                        .font(.subheadline)
                        .foregroundStyle(makesIt == false ? .amber : .mist)
                }
            }
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Every time and fare here is an estimate. Road times are Apple Maps'; metro times use BMRCL's published headways and PathOS's own running-time estimate; auto fares follow the city's meter rates, and app fares move with demand.")
            ForEach(RoadFares.data.sources, id: \.what) { source in
                Text("\(source.what) — \(source.licence)")
            }
        }
        .font(.caption)
        .foregroundStyle(.mist)
        .padding(.top, 4)
    }

    private func tag(for option: DoorToDoor.Option, index: Int) -> String? {
        guard option.isAvailableNow else { return "Not running now" }
        let running = options.filter(\.isAvailableNow)
        if option.minutes == running.map(\.minutes).min() { return "Quickest" }
        // Only where the fare is actually known: a bus whose fare PathOS can't read isn't
        // the cheapest, it's the unknown one.
        let priced = running.filter { !$0.fareIsUnknown }
        if !option.fareIsUnknown, option.fareLow == priced.map(\.fareLow).min(), priced.count > 1 { return "Cheapest" }
        return nil
    }

    private func load() async {
        guard let here = state.location.location else {
            isLoading = false
            return
        }
        isLoading = true
        options = await state.journeys.options(key: request.id, to: request.coordinate, named: request.name, from: here)
        isLoading = false
    }
}

/// One whole way there: its legs in order, with what each costs, and the buttons to act on it.
struct WayCard: View {
    let option: DoorToDoor.Option
    let request: WaysRequest
    var tag: String?

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ContentTile {
            VStack(alignment: .leading, spacing: 14) {
                header
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(option.legs) { leg in
                        LegRow(leg: leg, isLast: leg.id == option.legs.last?.id)
                    }
                }
                ForEach(option.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.mist)
                }
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(option.headline)
                    .font(.headline)
                    .foregroundStyle(.ice)
                Text("\(option.minutes) min · \(option.fareText)")
                    .font(.subheadline)
                    .foregroundStyle(.mist)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            if let tag {
                Text(tag)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(option.isAvailableNow ? .aurora : .amber)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background((option.isAvailableNow ? Color.aurora : Color.amber).opacity(0.14), in: Capsule())
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                state.startTrip(option, to: request.name, at: request.coordinate, arriveBy: request.arriveBy)
                // Out of the way: from here on it's the card in Now and the Lock Screen that
                // carry the journey.
                state.selectedTab = .now
                dismiss()
            } label: {
                Label("Follow this way", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .pathPrimaryAction()

            if option.legs.contains(where: { $0.mode == .auto }) {
                Menu {
                    ForEach(CabProvider.allCases) { provider in
                        Button(provider.name, systemImage: provider.symbol) {
                            CabLauncher.open(provider, drop: firstRoadLegEnd, pickup: state.location.location?.coordinate)
                        }
                    }
                } label: {
                    Image(systemName: "car.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 36, height: 36)
                }
                .pathSecondaryAction()
                .buttonBorderShape(.circle)
                .accessibilityLabel("Book a ride")
            }
        }
    }

    /// A cab is booked to where the road leg ends — the station, not the far end of the journey.
    private var firstRoadLegEnd: CLLocationCoordinate2D? {
        option.legs.first { $0.mode == .auto }?.endCoordinate
    }
}

/// One leg, as a row in a timeline.
private struct LegRow: View {
    let leg: DoorToDoor.Leg
    var isLast = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: leg.mode.symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(leg.mode == .walk ? .mist : .ion)
                    .frame(width: 26, height: 26)
                    .background(Color.elevatedSurface, in: .circle)
                if !isLast {
                    Rectangle()
                        .fill(Color.mist.opacity(0.3))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(minHeight: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(leg.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.ice)
                    .fixedSize(horizontal: false, vertical: true)
                Text(([leg.detail, "\(leg.minutes) min"].compactMap { $0 }).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.mist)
                    .lineLimit(2)
                if !leg.fares.isEmpty {
                    fares
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var fares: some View {
        // Every way of covering the leg, since an auto, a bike taxi and a cab are the same ride
        // at different prices. They wrap rather than shrink: three of them in one line pushed the
        // whole card off the side of the screen.
        FlowLayout(spacing: 8, lineSpacing: 6) {
            ForEach(leg.fares, id: \.mode) { fare in
                HStack(spacing: 4) {
                    Image(systemName: fare.mode.symbol)
                        .font(.caption2)
                    Text(fare.estimate.text)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.ice)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.elevatedSurface, in: Capsule())
            }
        }
        .padding(.top, 2)
    }
}
