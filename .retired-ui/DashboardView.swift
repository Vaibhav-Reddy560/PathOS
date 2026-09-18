import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var state
    @Query(sort: \SpatialNote.createdAt, order: .reverse) private var notes: [SpatialNote]
    @Query private var savedPlaces: [SavedPlace]

    @State private var isAddingNote = false
    @State private var isSettingsPresented = false
    @State private var isStartingCommute = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if state.location.authorization != .authorizedAlways {
                    permissionCard
                }
                if let advice = state.context.exitAdvice {
                    SpatialCardView(symbol: advice.symbol, tint: .orange, title: advice.headline, subtitle: advice.detail)
                }
                environmentCard
                commuteCard
                if !hasHomeAndWork {
                    placesSetupCard
                }
                quickActions
                statusRow
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(AmbientBackground())
        .navigationTitle("PathOS")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $isAddingNote) { AddNoteSheet() }
        .sheet(isPresented: $isSettingsPresented) { SettingsView() }
    }

    // MARK: Sections

    private var header: some View {
        let venue = state.context.venue
        return HStack(spacing: 12) {
            Image(systemName: venue.kind.symbol)
                .font(.title2)
                .foregroundStyle(.mint)
                .frame(width: 52, height: 52)
                .glassEffect(.regular, in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(venue.name ?? venue.kind.label)
                    .font(.title2.bold())
                    .lineLimit(1)
            }

            Spacer()

            Button {
                Task {
                    let shown = await state.liveActivities.show(state.context.venueActivityState())
                    message = shown ? "Context pinned to your Lock Screen." : "Live Activities are turned off for PathOS."
                }
            } label: {
                Image(systemName: "rectangle.badge.plus")
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Show context on Lock Screen")
        }
    }

    private var permissionCard: some View {
        let status = state.location.authorization
        let (title, subtitle): (String, String) = switch status {
        case .notDetermined:
            ("Allow location", "PathOS needs your location for context, geofences and the pointer.")
        case .authorizedWhenInUse:
            ("Allow “Always” location", "Exit checks and spatial notes only work in the background with Always access.")
        default:
            ("Location is off", "Turn it on in Settings → PathOS → Location.")
        }
        return SpatialCardView(symbol: "location.slash.fill", tint: .yellow, title: title, subtitle: subtitle) {
            Button("Allow") {
                if status == .denied || status == .restricted {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } else {
                    Task { await state.requestCorePermissions() }
                }
            }
            .buttonStyle(.glassProminent)
        }
    }

    private var environmentCard: some View {
        let snapshot = state.weather.snapshot
        let title = snapshot.map { "\($0.summary), \(Int($0.temperatureC.rounded()))°C" } ?? "Weather loading…"
        let rain = snapshot.map { "Rain chance next 2 h: \($0.rainChanceNext2h)%" }
        var pressure = state.barometer.isAvailable ? state.barometer.trend.label : "Barometer unavailable"
        if let hPa = state.barometer.seaLevelPressureHPa {
            pressure += String(format: " · %.1f hPa", hPa)
        }
        return SpatialCardView(symbol: snapshot?.symbol ?? "cloud.fill", tint: .cyan, title: title, subtitle: rain, detail: pressure)
    }

    private var commuteCard: some View {
        GlassSection(title: "Commute", symbol: "figure.walk") {
            if let departure = state.routine.todaysDeparture() {
                Text("You usually leave around \(RoutineLearner.format(minutes: departure)).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let commute = state.commute {
                VStack(alignment: .leading, spacing: 6) {
                    if let name = commute.destinationName {
                        Text("To \(name)").font(.subheadline.weight(.semibold))
                    }
                    if let transit = commute.transitMinutes {
                        Label("\(transit) min by transit", systemImage: "tram.fill")
                    }
                    if let walk = commute.walkMinutes {
                        Label("\(walk) min walk", systemImage: "figure.walk")
                    }
                    if let station = commute.stationName {
                        Label("\(station) · \(commute.stationWalkMinutes ?? 0) min", systemImage: "tram.circle")
                    }
                }
                .font(.subheadline)
            } else if state.routine.loggedDepartures < RoutineModel.minimumSamples {
                Text("PathOS learns when you leave home. Reminders start after a few departures.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    isStartingCommute = true
                    let shown = await state.startCommute()
                    isStartingCommute = false
                    message = shown ? nil : "Couldn't start the commute view. Check location and Live Activities."
                }
            } label: {
                Label(isStartingCommute ? "Working…" : "Start commute", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(isStartingCommute)

            HStack(spacing: 8) {
                ForEach(CabProvider.allCases) { provider in
                    Button {
                        CabLauncher.open(provider, drop: state.commute?.destination, pickup: state.location.location?.coordinate)
                    } label: {
                        Label(provider.name, systemImage: provider.symbol)
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private var placesSetupCard: some View {
        GlassSection(title: "Teach PathOS your places", symbol: "house.and.flag.fill") {
            Text("Stand at home or work and tap below. Exit checks and commute learning use these.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                ForEach([PlaceKind.home, .work]) { kind in
                    let isSet = savedPlaces.contains { $0.kind == kind }
                    Button {
                        Task {
                            let saved = await state.setPlaceHere(kind)
                            message = saved ? "\(kind.label) saved." : "Couldn't get your location."
                        }
                    } label: {
                        Label(isSet ? "\(kind.label) ✓" : "I'm at \(kind.label)", systemImage: kind.symbol)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            QuickActionButton(title: "Ask", symbol: "waveform", tint: .purple) {
                state.voiceAutoListen = true
                state.isVoicePresented = true
            }
            QuickActionButton(title: "Save spot", symbol: "mappin.and.ellipse", tint: .yellow) {
                isAddingNote = true
            }
            QuickActionButton(title: "Scan", symbol: "text.viewfinder", tint: .orange) {
                state.selectedTab = .scan
            }
            QuickActionButton(title: "Find my spot", symbol: "location.north.line.fill", tint: .mint) {
                if let note = notes.first {
                    state.startCompass(to: CompassTarget(id: note.geofenceID, name: note.title, latitude: note.latitude, longitude: note.longitude))
                } else {
                    message = "Save a spot first."
                }
            }
        }
    }

    private var statusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                StatusChip(symbol: state.sound.scene.symbol, text: state.sound.scene.label)
                switch state.ai.status {
                case .available:
                    StatusChip(symbol: "apple.intelligence", text: "On-device AI ready", tint: .mint)
                case .unavailable:
                    StatusChip(symbol: "exclamationmark.circle", text: "AI unavailable", tint: .orange)
                }
                StatusChip(symbol: "record.circle", text: "\(state.geofences.monitoredIDs.count) geofences")
            }
        }
    }

    // MARK: Helpers

    private var hasHomeAndWork: Bool {
        savedPlaces.contains { $0.kind == .home } && savedPlaces.contains { $0.kind == .work }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Hello"
        }
    }
}

private struct QuickActionButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
    }
}
