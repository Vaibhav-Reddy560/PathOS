import CoreLocation
import SwiftUI

/// Plan a metro or bus journey. For the metro: which lines, which direction to board, where to
/// change, and roughly how long and how much. For buses: the direct routes between two stops.
/// Then start it and PathOS follows you stop by stop.
struct JourneySheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Journey.Kind = .metro
    @State private var origin: String?
    @State private var destination: String?
    @State private var busOrigin: String?
    @State private var busDestination: String?
    @State private var busOptions: [BusOption] = []
    @State private var chosenBus: BusOption?
    @State private var now = Date()

    private var route: MetroRoute? {
        guard let origin, let destination else { return nil }
        return MetroRouter.route(from: origin, to: destination, at: now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Travel by", selection: $mode) {
                        Text("Metro").tag(Journey.Kind.metro)
                        Text("Bus").tag(Journey.Kind.bus)
                    }
                    .pickerStyle(.segmented)
                }
                if mode == .bus {
                    busSections
                } else {
                    metroSections
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle("Plan a journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", action: start)
                        .disabled(mode == .metro ? route == nil : chosenBus == nil)
                }
            }
            .task {
                if let preset = state.journeyPreset {
                    state.journeyPreset = nil
                    switch preset {
                    case let .metro(from, to):
                        mode = .metro
                        origin = from.isEmpty ? nil : from
                        destination = to
                    case let .bus(from, to):
                        mode = .bus
                        busOrigin = from.isEmpty ? nil : from
                        busDestination = to
                    }
                } else {
                    useNearestStation(quietly: true)
                }
                await state.transit.loadBusNetwork()
                if busOrigin == nil { useNearestBusStop() }
            }
            .task(id: [busOrigin ?? "", busDestination ?? ""]) {
                await findBuses()
            }
        }
    }

    private func start() {
        if mode == .metro, let route {
            state.startJourney(.metro(route))
        } else if let chosenBus, let network = state.transit.busNetwork {
            state.startJourney(.bus(chosenBus, network: network))
        } else {
            return
        }
        state.haptics.success()
        dismiss()
    }

    // MARK: Metro

    @ViewBuilder
    private var metroSections: some View {
        stationsSection
        if let route {
            routeSection(route)
            costSection(route)
        } else if origin != nil, origin == destination {
            Section {
                Text("Pick two different stations.")
                    .foregroundStyle(.mist)
            }
        }
        if let origin {
            stationSection(origin)
        }
        Section {
            Text("Times are estimated from station distances and published train frequencies. Fares follow BMRCL's station-count slabs in force since 14 February 2025 and may differ by a slab. BMRCL publishes no live train positions or platform numbers, so PathOS tracks **you** and shows which direction to board.")
                .font(.footnote)
                .foregroundStyle(.mist)
        }
    }

    // MARK: Bus

    @ViewBuilder
    private var busSections: some View {
        Section {
            NavigationLink {
                BusStopPicker(title: "From", selection: $busOrigin)
            } label: {
                LabeledContent("From", value: busOrigin ?? "Choose a stop")
            }
            NavigationLink {
                BusStopPicker(title: "To", selection: $busDestination)
            } label: {
                LabeledContent("To", value: busDestination ?? "Choose a stop")
            }
            HStack(spacing: 10) {
                Button {
                    useNearestBusStop()
                } label: {
                    Label("Nearest", systemImage: "location.fill")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)

                Button {
                    swap(&busOrigin, &busDestination)
                } label: {
                    Label("Swap", systemImage: "arrow.up.arrow.down")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .disabled(busOrigin == nil && busDestination == nil)
            }
            .labelStyle(.titleAndIcon)
        } header: {
            InstrumentLabel("Stops")
        }

        if busOrigin != nil, busDestination != nil {
            if busOptions.isEmpty {
                Section {
                    Text("No direct bus between these stops in BMTC's data. Try a stop nearby, or the metro.")
                        .foregroundStyle(.mist)
                }
            } else {
                Section {
                    ForEach(busOptions.prefix(8), id: \.service.pattern.id) { option in
                        Button {
                            chosenBus = option
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(option.service.pattern.route.number)
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(option.service.isRunningNow ? Color.ion : .mist)
                                    .frame(minWidth: 64, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Towards \(option.service.pattern.headsign)")
                                        .foregroundStyle(.ice)
                                    Text("\(option.stopsCount) stops · about \(option.rideMinutes) min on the bus")
                                        .font(.subheadline)
                                        .foregroundStyle(.mist)
                                    Text(BusNetwork.describe(option.service))
                                        .font(.footnote)
                                        .foregroundStyle(.mist)
                                    if !option.fromStop.towards.isEmpty {
                                        Text("Board on the side towards \(option.fromStop.towards)")
                                            .font(.footnote)
                                            .foregroundStyle(.mist)
                                    }
                                }
                                Spacer(minLength: 0)
                                if chosenBus?.service.pattern.id == option.service.pattern.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.aurora)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    InstrumentLabel("Direct buses")
                }
            }
        }

        Section {
            Text("Stops, routes and timings come from a community copy of the Namma BMTC app's data (ODbL). BMTC's own timetables are often wrong, so every time here is approximate, and there are no live bus positions: PathOS tracks **you** along the route.")
                .font(.footnote)
                .foregroundStyle(.mist)
        }
    }

    private func findBuses() async {
        chosenBus = nil
        guard let busOrigin, let busDestination, let network = await state.transit.loadBusNetwork() else {
            busOptions = []
            return
        }
        let options = await Task.detached(priority: .userInitiated) {
            network.directOptions(from: busOrigin, to: busDestination)
        }.value
        busOptions = options
        chosenBus = options.first
    }

    private func useNearestBusStop() {
        guard let here = state.location.location?.coordinate,
              let nearest = state.transit.busNetwork?.nearbyStops(to: here, within: 800).first else { return }
        busOrigin = nearest.stop.name
    }

    // MARK: Sections

    private var stationsSection: some View {
        Section {
            NavigationLink {
                StationPicker(title: "From", selection: $origin)
            } label: {
                LabeledContent("From", value: origin ?? "Choose a station")
            }
            NavigationLink {
                StationPicker(title: "To", selection: $destination)
            } label: {
                LabeledContent("To", value: destination ?? "Choose a station")
            }
            HStack(spacing: 10) {
                Button {
                    useNearestStation(quietly: false)
                } label: {
                    Label("Nearest", systemImage: "location.fill")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)

                Button {
                    swap(&origin, &destination)
                } label: {
                    Label("Swap", systemImage: "arrow.up.arrow.down")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .disabled(origin == nil && destination == nil)
            }
            .labelStyle(.titleAndIcon)
        } header: {
            InstrumentLabel("Stations")
        }
    }

    private func routeSection(_ route: MetroRoute) -> some View {
        Section {
            ForEach(Array(route.rides.enumerated()), id: \.offset) { index, ride in
                if index > 0 {
                    Label {
                        Text("Change at \(ride.boardAt) · about \(MetroNetwork.interchangeWalkMinutes(at: ride.boardAt)) min to walk between platforms")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "arrow.triangle.swap")
                            .foregroundStyle(.ion)
                    }
                }
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(ride.lineName) towards \(ride.towards)")
                            .font(.headline)
                            .foregroundStyle(.ice)
                        // Platforms are signed by the end of the line, so the heading is the platform sign.
                        Text("Board at \(ride.boardAt) · \(ride.stops == 1 ? "1 stop" : "\(ride.stops) stops")")
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                        Text("Get off at \(ride.getOffAt)")
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                    }
                } icon: {
                    Image(systemName: "tram.fill")
                        .foregroundStyle(.aurora)
                }
            }
        } header: {
            InstrumentLabel(route.changes.isEmpty ? "Route · no changes" : "Route · \(route.changes.count == 1 ? "1 change" : "\(route.changes.count) changes")")
        }
    }

    private func costSection(_ route: MetroRoute) -> some View {
        let fare = MetroRouter.fare(stationsTravelled: route.stationsTravelled, at: now)
        return Section {
            LabeledContent("Time", value: "about \(route.minutes) min")
            LabeledContent("Distance", value: GeoMath.formatDistance(route.distanceMeters))
            LabeledContent("Token or QR ticket", value: "₹\(fare.token)")
            LabeledContent("Smart card", value: "₹\(fare.smartCard.formatted(.number.precision(.fractionLength(0...2))))")
        } header: {
            InstrumentLabel("Estimated")
        } footer: {
            Text("\(route.stationsTravelled) stations travelled. Smart cards save \(fare.isPeak ? "5% in peak hours" : "10% off-peak and on Sundays").")
        }
        .monospacedDigit()
    }

    private func stationSection(_ station: String) -> some View {
        Section {
            ForEach(MetroNetwork.interchangeLines(for: station)) { line in
                let status = MetroSchedule.status(for: line, at: now)
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.name)
                        .foregroundStyle(.ice)
                    Text(MetroSchedule.describe(status))
                        .font(.subheadline)
                        .foregroundStyle(isClosed(status) ? .amber : .mist)
                    if let index = line.stations.firstIndex(of: station) {
                        Text(platforms(on: line, at: index))
                            .font(.footnote)
                            .foregroundStyle(.mist)
                    }
                }
            }
        } header: {
            InstrumentLabel(station)
        }
    }

    // MARK: Helpers

    /// Platforms are signed by the end of the line each train is heading for.
    private func platforms(on line: MetroLine, at index: Int) -> String {
        let ends = [index > 0 ? line.stations.first : nil, index < line.stations.count - 1 ? line.stations.last : nil].compactMap { $0 }
        return "Platforms: towards " + ends.joined(separator: " · towards ")
    }

    private func isClosed(_ status: MetroStatus) -> Bool {
        if case .closed = status { return true }
        return false
    }

    /// Stations are bundled with coordinates, so this is instant and works offline.
    private func useNearestStation(quietly: Bool) {
        guard origin == nil || !quietly, let here = state.location.location?.coordinate else { return }
        if let station = MetroNetwork.nearestStation(to: here, within: quietly ? 1_000 : 3_000) {
            origin = station.name
            if destination == station.name { destination = nil }
        }
    }
}

/// Bus stops by name, searched; nearby stops first when there's no search yet.
private struct BusStopPicker: View {
    let title: String
    @Binding var selection: String?

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var names: [String] {
        guard let network = state.transit.busNetwork else { return [] }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let here = state.location.location?.coordinate else { return [] }
            var seen = Set<String>()
            return network.nearbyStops(to: here, within: 1_200).map(\.stop.name).filter { seen.insert($0).inserted }
        }
        return network.stopNames(matching: query)
    }

    var body: some View {
        List {
            Section {
                ForEach(names, id: \.self) { name in
                    Button {
                        selection = name
                        dismiss()
                    } label: {
                        HStack {
                            Text(name)
                                .foregroundStyle(.ice)
                            Spacer()
                            if selection == name {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.aurora)
                            }
                        }
                    }
                }
            } header: {
                InstrumentLabel(query.isEmpty ? "Near you" : "Stops")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.deepSurface)
        .searchable(text: $query, prompt: "Stop name")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Every station, searchable, grouped by line in running order.
private struct StationPicker: View {
    let title: String
    @Binding var selection: String?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List {
            ForEach(MetroNetwork.lines) { line in
                let stations = line.stations.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
                if !stations.isEmpty {
                    Section {
                        ForEach(stations, id: \.self) { station in
                            Button {
                                selection = station
                                dismiss()
                            } label: {
                                HStack {
                                    Text(station)
                                        .foregroundStyle(.ice)
                                    Spacer()
                                    if MetroNetwork.interchangeLines(for: station).count > 1 {
                                        Image(systemName: "arrow.triangle.swap")
                                            .foregroundStyle(.ion)
                                            .accessibilityLabel("Interchange")
                                    }
                                    if selection == station {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.aurora)
                                    }
                                }
                            }
                        }
                    } header: {
                        InstrumentLabel(line.name)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.deepSurface)
        .searchable(text: $query, prompt: "Station")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What you see while travelling: where you are, where to change, and when to get off.
struct ActiveJourneyCard: View {
    let journey: Journey
    let progress: JourneyProgress

    @Environment(AppState.self) private var state

    private var actNow: Bool { progress.isArrivingNext || progress.isChangingNext }

    var body: some View {
        ContentTile {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    SignalGlyph(symbol: progress.isChangingNext ? "arrow.triangle.swap" : journey.symbol, role: actNow ? .attention : .you, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        InstrumentLabel(journey.lineName, role: actNow ? .attention : .you)
                        Text(progress.hasArrived ? "You've arrived" : "To \(journey.destination)")
                            .font(.headline)
                            .foregroundStyle(.ice)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if !progress.hasArrived {
                        MetricText(value: "\(progress.stopsRemaining)", unit: progress.stopsRemaining == 1 ? "stop" : "stops", role: actNow ? .attention : .you)
                    }
                }
                .accessibilityElement(children: .combine)

                if progress.isArrivingNext {
                    Label("Get off at the next stop", systemImage: "figure.walk.departure")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.amber)
                } else if let index = progress.nextChangeIndex, let instruction = journey.stops[safe: index]?.changeInstruction {
                    Label("\(progress.isChangingNext ? "Next stop" : "At \(journey.stationName(at: index))"): \(instruction.prefix(1).lowercased() + instruction.dropFirst())",
                          systemImage: "arrow.triangle.swap")
                        .font(.subheadline.weight(progress.isChangingNext ? .semibold : .regular))
                        .foregroundStyle(progress.isChangingNext ? .amber : .ion)
                }

                HStack(spacing: 10) {
                    if let nextIndex = progress.nextStationIndex {
                        Label("Next: \(journey.stationName(at: nextIndex))", systemImage: "arrow.right")
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("End") {
                        state.endJourney()
                    }
                    .font(.subheadline.weight(.semibold))
                    .pathSecondaryAction()
                }
            }
        }
    }

    private var subtitle: String {
        if progress.hasArrived { return "\(journey.origin) → \(journey.destination)" }
        let source = progress.isTrackingByLocation ? "tracking your position" : "estimated from the clock"
        return "\(JourneyTracker.summary(progress)) · \(source)"
    }
}
