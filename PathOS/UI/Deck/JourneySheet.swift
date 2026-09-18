import SwiftUI

/// Start a metro journey: a line, where you're getting on, and where you're getting off.
/// PathOS pre-fills the station you're standing at when it can.
struct JourneySheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var lineID = MetroNetwork.purple.id
    @State private var fromIndex = 0
    @State private var toIndex = 1
    @State private var isLocating = false

    private var line: MetroLine {
        MetroNetwork.line(id: lineID) ?? MetroNetwork.purple
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Line", selection: $lineID) {
                        ForEach(MetroNetwork.lines) { line in
                            Text(line.name).tag(line.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(line.termini)
                        .font(.footnote)
                        .foregroundStyle(.mist)
                } header: {
                    InstrumentLabel("Line")
                }

                Section {
                    Picker("From", selection: $fromIndex) {
                        ForEach(Array(line.stations.enumerated()), id: \.offset) { index, station in
                            Text(station).tag(index)
                        }
                    }
                    Picker("To", selection: $toIndex) {
                        ForEach(Array(line.stations.enumerated()), id: \.offset) { index, station in
                            Text(station).tag(index)
                        }
                    }
                    Button {
                        Task { await useNearestStation() }
                    } label: {
                        Label(isLocating ? "Finding…" : "Start from the station I'm at", systemImage: "location.fill")
                    }
                    .disabled(isLocating)
                } header: {
                    InstrumentLabel("Stations")
                } footer: {
                    if fromIndex != toIndex {
                        Text("\(abs(toIndex - fromIndex)) stops · about \(Int((Double(abs(toIndex - fromIndex)) * JourneyTracker.minutesPerStop).rounded())) min, estimated.")
                    }
                }

                if !interchangeNote.isEmpty {
                    Section {
                        Label(interchangeNote, systemImage: "arrow.triangle.swap")
                            .font(.footnote)
                            .foregroundStyle(.ion)
                    }
                }

                Section {
                    Text("BMRCL doesn't publish live train positions, so PathOS tracks **you**: your position along the line, with the clock carrying the estimate underground. Times are estimates, not timetables.")
                        .font(.footnote)
                        .foregroundStyle(.mist)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle("Start a journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        state.startJourney(lineID: lineID, fromIndex: fromIndex, toIndex: toIndex)
                        state.haptics.success()
                        dismiss()
                    }
                    .disabled(fromIndex == toIndex)
                }
            }
            .task { await state.transit.resolveStations(for: lineID) }
            .onChange(of: lineID) { _, newValue in
                fromIndex = 0
                toIndex = min(1, line.stations.count - 1)
                Task { await state.transit.resolveStations(for: newValue) }
            }
        }
    }

    private var interchangeNote: String {
        let destination = line.stations[safe: toIndex] ?? ""
        let others = MetroNetwork.interchangeLines(for: destination).filter { $0.id != lineID }
        guard !others.isEmpty else { return "" }
        return "\(destination) connects to the \(others.map(\.name).joined(separator: " and "))."
    }

    private func useNearestStation() async {
        isLocating = true
        defer { isLocating = false }
        await state.transit.resolveStations(for: lineID)
        guard let here = await state.location.currentLocation(),
              let index = state.transit.nearestStation(to: here, on: line) else { return }
        fromIndex = index
        if toIndex == index {
            toIndex = min(index + 1, line.stations.count - 1)
        }
    }
}

/// What you see while travelling: where you are on the line and when to get off.
struct ActiveJourneyCard: View {
    let journey: Journey
    let progress: JourneyProgress

    @Environment(AppState.self) private var state

    var body: some View {
        ContentTile {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    SignalGlyph(symbol: "tram.fill", role: progress.isArrivingNext ? .attention : .you, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        InstrumentLabel(journey.lineName, role: progress.isArrivingNext ? .attention : .you)
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
                        MetricText(value: "\(progress.stopsRemaining)", unit: progress.stopsRemaining == 1 ? "stop" : "stops", role: progress.isArrivingNext ? .attention : .you)
                    }
                }
                .accessibilityElement(children: .combine)

                if progress.isArrivingNext {
                    Label("Get off at the next stop", systemImage: "figure.walk.departure")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.amber)
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
