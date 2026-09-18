import SwiftData
import SwiftUI

/// Now: where you are, the environment around you, and your commute.
struct NowDeck: View {
    @Environment(AppState.self) private var state
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var savedPlaces: [SavedPlace]

    @State private var isStartingCommute = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if state.location.authorization != .authorizedAlways {
                    permissionTile
                }
                contextTile
                if let journey = state.transit.journey, let progress = state.transit.progress {
                    ActiveJourneyCard(journey: journey, progress: progress)
                }
                environmentSection
                commuteSection
                if !hasHomeAndWork {
                    placesSetupSection
                }
                if !state.assistantTurns.isEmpty {
                    answersSection
                }
                statusRow
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Sections

    private var permissionTile: some View {
        let status = state.location.authorization
        let isBlocked = status == .denied || status == .restricted
        let (title, subtitle): (String, String) = switch status {
        case .notDetermined:
            ("Allow location", "PathOS needs your location for context, geofences and the pointer.")
        case .authorizedWhenInUse:
            ("Allow “Always” location", "Exit checks and spatial notes only work in the background with Always access.")
        default:
            ("Location is off", "Turn it on in Settings → PathOS → Location. PathOS can't guide you without it.")
        }

        return ContentTile {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    SignalGlyph(symbol: "location.slash.fill", role: isBlocked ? .critical : .attention)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.ice)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                    }
                }
                Button {
                    if isBlocked {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } else {
                        Task { await state.requestCorePermissions() }
                    }
                } label: {
                    Text(isBlocked ? "Open Settings" : "Allow")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .pathSecondaryAction()
            }
        }
    }

    private var contextTile: some View {
        let venue = state.context.venue
        return ContentTile {
            HStack(spacing: 14) {
                SignalGlyph(symbol: venue.kind.symbol, role: .world, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    InstrumentLabel(greeting)
                    Text(venue.name ?? venue.kind.label)
                        .font(.pathTitle)
                        .foregroundStyle(.ice)
                        .lineLimit(2)
                    if venue.name != nil {
                        Text(venue.kind.label)
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    Task {
                        let shown = await state.liveActivities.show(state.context.venueActivityState())
                        if shown {
                            state.showToast("Context pinned to your Lock Screen")
                        } else {
                            state.showToast("Live Activities are off for PathOS", role: .attention, symbol: "exclamationmark.circle.fill")
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.badge.plus")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .pathSecondaryAction()
                .buttonBorderShape(.circle)
                .accessibilityLabel("Show context on Lock Screen")
            }
        }
    }

    private var environmentSection: some View {
        let snapshot = state.weather.snapshot
        let barometer = state.barometer
        let rainChance = snapshot?.rainChanceNext2h

        return VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: "Environment", trailing: snapshot.map { "Updated \($0.fetchedAt.formatted(date: .omitted, time: .shortened))" })
            LazyVGrid(columns: environmentColumns, spacing: 10) {
                EnvironmentTile(
                    symbol: snapshot?.symbol ?? "cloud.fill",
                    label: "Weather",
                    value: snapshot.map { "\(Int($0.temperatureC.rounded()))" } ?? "—",
                    unit: "°C",
                    detail: snapshot?.summary ?? "Loading…"
                )
                EnvironmentTile(
                    symbol: "cloud.rain.fill",
                    label: "Rain · 2 h",
                    value: rainChance.map { "\($0)" } ?? "—",
                    unit: "%",
                    detail: (rainChance ?? 0) >= ExitCheckEvaluator.rainChanceThreshold ? "Take an umbrella" : "Unlikely",
                    role: (rainChance ?? 0) >= ExitCheckEvaluator.rainChanceThreshold ? .attention : .world
                )
                if barometer.isAvailable {
                    EnvironmentTile(
                        symbol: barometer.trend.symbol,
                        label: "Pressure",
                        value: barometer.seaLevelPressureHPa.map { String(format: "%.0f", $0) } ?? "—",
                        unit: "hPa",
                        detail: barometer.trend.label,
                        role: barometer.trend.isRapidDrop ? .attention : .world
                    )
                    EnvironmentTile(
                        symbol: "mountain.2.fill",
                        label: "Altitude",
                        value: barometer.absoluteAltitudeMeters.map { "\(Int($0.rounded()))" } ?? "—",
                        unit: "m",
                        detail: "Above sea level"
                    )
                }
                EnvironmentTile(
                    symbol: state.sound.scene.symbol,
                    label: "Sound",
                    value: state.sound.levelDB.map { "\(Int($0.rounded()))" } ?? "—",
                    unit: "dB",
                    detail: state.sound.scene.label
                )
            }
        }
    }

    private var commuteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(
                title: "Commute",
                trailing: state.routine.todaysDeparture().map { "Usually \(RoutineLearner.format(minutes: $0))" }
            )
            ContentTile {
                VStack(alignment: .leading, spacing: 14) {
                    if let commute = state.commute {
                        if let name = commute.destinationName {
                            Text("To \(name)")
                                .font(.headline)
                                .foregroundStyle(.ice)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            if let transit = commute.transitMinutes {
                                CommuteLine(symbol: "tram.fill", value: "\(transit)", unit: "min", text: "by transit")
                            }
                            if let walk = commute.walkMinutes {
                                CommuteLine(symbol: "figure.walk", value: "\(walk)", unit: "min", text: "walk")
                            }
                            if let station = commute.stationName {
                                CommuteLine(symbol: "tram.circle", value: "\(commute.stationWalkMinutes ?? 0)", unit: "min", text: "to \(station)")
                            }
                        }
                    } else {
                        Text(state.routine.loggedDepartures < RoutineModel.minimumSamples
                             ? "PathOS learns when you leave home. Reminders start after a few departures."
                             : "Start your commute for live ETAs, the nearest metro and cabs on your Lock Screen.")
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                    }

                    Button {
                        Task {
                            isStartingCommute = true
                            let shown = await state.startCommute()
                            isStartingCommute = false
                            if !shown {
                                state.showToast("Couldn't start the commute. Check location and Live Activities.", role: .attention, symbol: "exclamationmark.circle.fill")
                            }
                        }
                    } label: {
                        Label(isStartingCommute ? "Working…" : "Start commute", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .pathPrimaryAction()
                    .disabled(isStartingCommute)

                    if state.transit.journey == nil {
                        Button {
                            state.planJourney(from: nil)
                        } label: {
                            Label("Plan a metro or bus journey", systemImage: "tram.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .pathSecondaryAction()
                    }

                    HStack(spacing: 8) {
                        ForEach(CabProvider.allCases) { provider in
                            Button {
                                CabLauncher.open(provider, drop: state.commute?.destination, pickup: state.location.location?.coordinate)
                            } label: {
                                Label(provider.name, systemImage: provider.symbol)
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 28)
                            }
                            .pathSecondaryAction()
                        }
                    }
                }
            }
        }
    }

    private var placesSetupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: "Teach PathOS your places")
            ContentTile {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Stand at home or work and tap below. Exit checks and commute learning use these.")
                        .font(.subheadline)
                        .foregroundStyle(.mist)
                    HStack(spacing: 10) {
                        ForEach([PlaceKind.home, .work]) { kind in
                            let isSet = savedPlaces.contains { $0.kind == kind }
                            Button {
                                Task {
                                    let saved = await state.setPlaceHere(kind)
                                    if saved {
                                        state.showToast("\(kind.label) saved")
                                    } else {
                                        state.showToast("Couldn't get your location", role: .attention, symbol: "location.slash.fill")
                                    }
                                }
                            } label: {
                                Label(isSet ? "\(kind.label) set" : "I'm at \(kind.label)", systemImage: isSet ? "checkmark" : kind.symbol)
                                    .frame(maxWidth: .infinity, minHeight: 32)
                            }
                            .pathSecondaryAction()
                        }
                    }
                }
            }
        }
    }

    private var answersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: "Asked PathOS")
            ForEach(state.assistantTurns.prefix(3)) { turn in
                ContentTile {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(turn.question)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.mist)
                        Text(turn.answer)
                            .font(.body)
                            .foregroundStyle(.ice)
                            .lineLimit(4)
                        if !turn.places.isEmpty {
                            InstrumentLabel("\(turn.places.count) places on the map", role: .world)
                        }
                    }
                }
            }
        }
    }

    private var statusRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                switch state.ai.status {
                case .available:
                    SignalChip(symbol: "apple.intelligence", text: "On-device AI ready", role: .world)
                case .unavailable:
                    SignalChip(symbol: "exclamationmark.circle", text: "AI unavailable", role: .attention)
                }
                SignalChip(symbol: "record.circle", text: "\(state.geofences.monitoredIDs.count) geofences")
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Helpers

    /// Two tiles side by side, or one column at accessibility sizes so captions never break mid-word.
    private var environmentColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    private var hasHomeAndWork: Bool {
        savedPlaces.contains { $0.kind == .home } && savedPlaces.contains { $0.kind == .work }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "You are here"
        }
    }
}

private struct EnvironmentTile: View {
    let symbol: String
    let label: String
    let value: String
    var unit: String?
    var detail: String?
    var role: SignalRole = .world

    var body: some View {
        ContentTile(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(role.color)
                    InstrumentLabel(label)
                }
                MetricText(value: value, unit: unit, role: role)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.mist)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CommuteLine: View {
    let symbol: String
    let value: String
    let unit: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ion)
                .frame(width: 22)
            MetricText(value: value, unit: unit, role: .world)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.mist)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
