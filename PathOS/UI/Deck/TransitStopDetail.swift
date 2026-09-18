import SwiftUI

/// What runs from a stop on the map: metro lines with their hours and platforms, or the buses
/// that call here and roughly how often.
struct TransitStopDetail: View {
    let signal: WorldSignal

    @Environment(AppState.self) private var state
    @State private var services: [BusService] = []
    @State private var now = Date()

    private var isMetro: Bool { signal.id.hasPrefix("metro:") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isMetro {
                metro
            } else {
                bus
            }
            Button {
                state.planJourney(from: isMetro ? .metro(from: signal.title) : .bus(from: signal.title))
            } label: {
                Label(isMetro ? "Plan a journey from here" : "Plan a bus journey from here", systemImage: isMetro ? "tram.fill" : "bus.fill")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .pathSecondaryAction()
        }
        .task(id: signal.id) {
            guard !isMetro, let network = await state.transit.loadBusNetwork() else { return }
            services = network.stops(named: signal.title)
                .flatMap { network.services(at: $0.id, at: now) }
                .reduce(into: [BusService]()) { unique, service in
                    if !unique.contains(where: { $0.pattern.id == service.pattern.id }) { unique.append(service) }
                }
                .sorted { ($0.isRunningNow ? 0 : 1, $0.pattern.route.number) < ($1.isRunningNow ? 0 : 1, $1.pattern.route.number) }
        }
    }

    private var metro: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: "Metro")
            GroupedRows(MetroNetwork.interchangeLines(for: signal.title)) { line in
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.name)
                        .font(.headline)
                        .foregroundStyle(.ice)
                    Text(MetroSchedule.describe(MetroSchedule.status(for: line, at: now)))
                        .font(.subheadline)
                        .foregroundStyle(.mist)
                    if let index = line.stations.firstIndex(of: signal.title) {
                        Text(platforms(on: line, at: index))
                            .font(.footnote)
                            .foregroundStyle(.mist)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private var bus: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: "Buses from here", trailing: services.isEmpty ? nil : "\(Set(services.map(\.pattern.route.number)).count) routes")
            if services.isEmpty {
                EmptyState(symbol: "bus", title: "Loading routes…", message: "BMTC's stops and routes are bundled with PathOS.")
            } else {
                GroupedRows(Array(services.prefix(14))) { service in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(service.pattern.route.number)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(service.isRunningNow ? Color.ion : .mist)
                            .frame(minWidth: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Towards \(service.pattern.headsign)")
                                .font(.subheadline)
                                .foregroundStyle(.ice)
                                .lineLimit(2)
                            Text(BusNetwork.describe(service))
                                .font(.footnote)
                                .foregroundStyle(.mist)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                Text("Timings are approximate: they come from the Namma BMTC app's timetables, which are often wrong. There are no live bus positions.")
                    .font(.footnote)
                    .foregroundStyle(.mist)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func platforms(on line: MetroLine, at index: Int) -> String {
        let ends = [index > 0 ? line.stations.first : nil, index < line.stations.count - 1 ? line.stations.last : nil].compactMap { $0 }
        return "Platforms: towards " + ends.joined(separator: " · towards ")
    }
}
