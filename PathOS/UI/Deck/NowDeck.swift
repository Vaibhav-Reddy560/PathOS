import SwiftData
import SwiftUI

/// Now: where you are, the environment around you, and getting around.
struct NowDeck: View {
    @Environment(AppState.self) private var state
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var savedPlaces: [SavedPlace]

    @State private var isTogglingPin = false

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
        .deckScroll()
        .task {
            await state.refreshCommute()
        }
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
                    if state.isContextPinned {
                        Label("On your Lock Screen", systemImage: "lock.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.aurora)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                pinButton
            }
        }
    }

    /// Pins the context to the Lock Screen, and unpins it again. Green while it's pinned.
    @ViewBuilder
    private var pinButton: some View {
        let isPinned = state.isContextPinned
        let button = Button {
            Task { await togglePin() }
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonBorderShape(.circle)
        .disabled(isTogglingPin)
        .accessibilityLabel(isPinned ? "Unpin from Lock Screen" : "Pin to Lock Screen")
        .accessibilityHint(isPinned ? "Takes PathOS off the Lock Screen" : "Keeps rain warnings, your next class or event, and directions on the Lock Screen")

        if isPinned {
            button.pathPrimaryAction()
        } else {
            button.pathSecondaryAction()
        }
    }

    private func togglePin() async {
        isTogglingPin = true
        defer { isTogglingPin = false }
        if state.isContextPinned {
            await state.unpinContext()
            state.showToast("Unpinned from your Lock Screen", symbol: "pin.slash.fill")
        } else if await state.pinContext() {
            state.showToast("Pinned to your Lock Screen", symbol: "pin.fill")
        } else {
            state.showToast("Live Activities are off for PathOS", role: .attention, symbol: "exclamationmark.circle.fill")
        }
    }

    private var environmentSection: some View {
        let snapshot = state.weather.snapshot
        let barometer = state.barometer

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
                    value: snapshot.map { "\($0.rainChanceNext2h)" } ?? "—",
                    unit: "%",
                    detail: snapshot.map(rainVerdict) ?? "Loading…",
                    role: snapshot?.isRainLikely == true ? .attention : .world
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
            if let snapshot {
                Text(weatherSources(snapshot))
                    .font(.caption)
                    .foregroundStyle(.mist)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Travel times and the nearest metro, one way to plan a ride, and cabs. There used to be a
    /// Start commute button beside the planner: it put these same times on the Lock Screen, read as
    /// a second way to travel, and had no end. Pinning the context does its job now.
    private var commuteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(
                title: "Getting around",
                trailing: state.routine.todaysDeparture().map { "You usually leave \(RoutineLearner.format(minutes: $0))" }
            )
            ContentTile {
                VStack(alignment: .leading, spacing: 14) {
                    travelTimes

                    if state.transit.journey == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                state.planJourney(from: nil)
                            } label: {
                                Label("Plan a metro or bus journey", systemImage: "tram.fill")
                                    .font(.headline)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .pathPrimaryAction()
                            Text("Stop by stop on your Lock Screen, with a nudge before you change or get off.")
                                .font(.caption)
                                .foregroundStyle(.mist)
                        }
                    }

                    HStack(spacing: 8) {
                        ForEach(CabProvider.allCases) { provider in
                            Button {
                                CabLauncher.open(provider, drop: state.commute?.destination, pickup: state.location.location?.coordinate)
                            } label: {
                                Label(provider.name, systemImage: provider.symbol)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, minHeight: 28)
                            }
                            .pathSecondaryAction()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var travelTimes: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let commute = state.commute, let name = commute.destinationName {
                VStack(alignment: .leading, spacing: 10) {
                    Text("To \(name)")
                        .font(.headline)
                        .foregroundStyle(.ice)
                    if let transit = commute.transitMinutes {
                        CommuteLine(symbol: "tram.fill", value: "\(transit)", unit: "min", text: "by transit")
                    }
                    if let walk = commute.walkMinutes {
                        CommuteLine(symbol: "figure.walk", value: "\(walk)", unit: "min", text: "walk")
                    }
                }
            } else if !hasHomeAndWork {
                Text("Set Home and Work below for travel times between them.")
                    .font(.subheadline)
                    .foregroundStyle(.mist)
            }
            nearestMetro
        }
    }

    /// From wherever you are right now, not from home: it moves with you.
    @ViewBuilder
    private var nearestMetro: some View {
        if let here = state.location.location?.coordinate,
           let nearest = MetroNetwork.nearbyStations(to: here, atLeast: 1).first {
            VStack(alignment: .leading, spacing: 8) {
                InstrumentLabel("Nearest metro to you")
                // Past a couple of kilometres nobody walks it, so it's the distance that helps.
                if nearest.distance > 2_000 {
                    CommuteLine(symbol: "tram.circle", value: String(format: "%.1f", nearest.distance / 1_000), unit: "km", text: "to \(nearest.station.name)")
                } else {
                    CommuteLine(symbol: "tram.circle", value: "\(GeoMath.walkingMinutes(forDistance: nearest.distance))", unit: "min", text: "walk to \(nearest.station.name)")
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

    private func rainVerdict(_ snapshot: WeatherSnapshot) -> String {
        if snapshot.isRainingNearby { return "Raining nearby" }
        if snapshot.isRainLikely { return "Take an umbrella" }
        if snapshot.rainChanceNext2h >= ExitCheckEvaluator.rainChanceThreshold { return "A few drops at most" }
        return "Unlikely"
    }

    /// Where the numbers come from, so you can judge them: a station's report, or forecasts.
    private func weatherSources(_ snapshot: WeatherSnapshot) -> String {
        let now: String = if let station = snapshot.observation {
            "Now: reported at \(station.station), \(GeoMath.formatDistance(station.distanceMeters)) away, at \(station.observedAt.formatted(date: .omitted, time: .shortened))."
        } else {
            "Now: forecast, as no weather station is near enough."
        }
        let rain = snapshot.modelCount > 1
            ? " Rain: the middle of \(snapshot.modelCount) forecasts, \(snapshot.modelsExpectingRain) of which expect rain."
            : ""
        return now + rain
    }

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
            // Station names run long ("Dr. B.R. Ambedkar Station, Vidhana Soudha").
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.mist)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}
