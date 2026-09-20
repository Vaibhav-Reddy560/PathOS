import CoreLocation
import SwiftData
import SwiftUI

/// Trips: a name, the days it covers, and the legs that get you around.
struct TripSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Trip.startDate, order: .reverse) private var trips: [Trip]

    @State private var editingTrip: Trip?
    @State private var legTrip: Trip?

    var body: some View {
        NavigationStack {
            Form {
                if trips.isEmpty {
                    Section {
                        Text("A trip holds the days you're away and every leg that moves you: walk, scooter, car, cab, bus, metro, train, flight or ferry. Each leg reminds you \(TripStore.reminderMinutesBefore) minutes before it leaves.")
                            .font(.footnote)
                            .foregroundStyle(.mist)
                    }
                }

                ForEach(trips) { trip in
                    Section {
                        Button {
                            editingTrip = trip
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(trip.name)
                                    .font(.headline)
                                    .foregroundStyle(.ice)
                                Text(String.range(trip.startDate.formatted(date: .abbreviated, time: .omitted), trip.endDate.formatted(date: .abbreviated, time: .omitted), separator: " – ") + " · \(trip.dayCount) days")
                                    .font(.footnote)
                                    .foregroundStyle(.mist)
                                if !trip.legs.isEmpty {
                                    Text(TripPlan.modeSummary(trip.legs.map(TripStore.plannedLeg)))
                                        .font(.pathInstrument)
                                        .foregroundStyle(.ion)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        ForEach(trip.legs.sorted { $0.departure < $1.departure }) { leg in
                            LegRow(leg: leg)
                        }
                        .onDelete { offsets in
                            let sorted = trip.legs.sorted { $0.departure < $1.departure }
                            for index in offsets {
                                state.trips.delete(sorted[index])
                            }
                        }

                        Button {
                            legTrip = trip
                        } label: {
                            Label("Add a leg", systemImage: "plus")
                        }

                        Button(role: .destructive) {
                            state.trips.delete(trip)
                        } label: {
                            Label("Delete trip", systemImage: "trash")
                        }
                        .foregroundStyle(.coral)
                    } header: {
                        InstrumentLabel(trip.covers(Date()) ? "Happening now" : trip.startDate > Date() ? "Coming up" : "Past")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle("Trips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("New trip") {
                        editingTrip = Trip(name: "", startDate: Date(), endDate: Date().addingTimeInterval(2 * 86_400))
                    }
                }
            }
            .sheet(item: $editingTrip) { trip in
                TripEditor(trip: trip)
            }
            .sheet(item: $legTrip) { trip in
                LegEditor(trip: trip)
            }
        }
    }
}

private struct LegRow: View {
    let leg: TripLeg

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: leg.mode.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ion)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(leg.origin) → \(leg.destination)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ice)
                    .lineLimit(1)
                Text(leg.arrival.map { String.range(leg.departure.formatted(date: .abbreviated, time: .shortened), $0.formatted(date: .omitted, time: .shortened), separator: " – ") } ?? leg.departure.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(.mist)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TripEditor: View {
    @Bindable var trip: Trip

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Where to?", text: $trip.name)
                    DatePicker("Leaves", selection: $trip.startDate, displayedComponents: .date)
                    DatePicker("Back", selection: $trip.endDate, in: trip.startDate..., displayedComponents: .date)
                    TextField("Notes", text: $trip.notes, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    InstrumentLabel("Trip")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle(trip.name.isEmpty ? "New trip" : trip.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        state.trips.save(trip)
                        state.showToast("Trip saved")
                        dismiss()
                    }
                    .disabled(trip.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

private struct LegEditor: View {
    let trip: Trip

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var mode: TravelMode = .train
    @State private var origin = ""
    @State private var destination = ""
    @State private var departure = Date()
    @State private var hasArrival = false
    @State private var arrival = Date().addingTimeInterval(3_600)
    @State private var notes = ""
    @State private var isLocating = false
    @State private var destinationCoordinate: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("How", selection: $mode) {
                        ForEach(TravelMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    TextField("From", text: $origin)
                    TextField("To", text: $destination)
                } header: {
                    InstrumentLabel("Leg")
                }

                Section {
                    DatePicker("Leaves", selection: $departure)
                    Toggle("I know when it arrives", isOn: $hasArrival)
                    if hasArrival {
                        DatePicker("Arrives", selection: $arrival, in: departure...)
                    }
                } header: {
                    InstrumentLabel("When")
                } footer: {
                    Text(hasArrival
                         ? "You'll be reminded \(TripStore.reminderMinutesBefore) minutes before it leaves."
                         : "Without an arrival time, PathOS estimates one from the distance and how you're travelling.")
                }

                Section {
                    TextField("Notes, seat, booking reference…", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                    Button {
                        Task { await pinDestination() }
                    } label: {
                        Label(isLocating ? "Finding…" : "Find the destination on the map", systemImage: "map")
                    }
                    .disabled(destination.trimmingCharacters(in: .whitespaces).isEmpty || isLocating)
                } header: {
                    InstrumentLabel("Details")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle("Add a leg")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save)
                        .disabled(origin.trimmingCharacters(in: .whitespaces).isEmpty || destination.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task { departure = max(Date(), trip.startDate) }
        }
    }

    private func pinDestination() async {
        isLocating = true
        defer { isLocating = false }
        guard let here = await state.location.currentLocation(),
              let match = (try? await state.places.search(destination, near: here, radius: 200_000))?.first else { return }
        destinationCoordinate = match.coordinate
        destination = match.name
    }

    private func save() {
        let leg = TripLeg(
            mode: mode,
            origin: origin.trimmingCharacters(in: .whitespaces),
            destination: destination.trimmingCharacters(in: .whitespaces),
            departure: departure,
            arrival: hasArrival ? arrival : nil,
            notes: notes
        )
        leg.destinationLatitude = destinationCoordinate?.latitude
        leg.destinationLongitude = destinationCoordinate?.longitude
        state.trips.add(leg, to: trip)
        // Where it starts matters for the map pin before you leave, so look it up by name rather
        // than assuming it starts wherever you're planning it from.
        Task { await state.trips.pinEnds(of: leg, places: state.places, vault: state.vault, near: state.location.location) }
        state.haptics.success()
        dismiss()
    }
}
