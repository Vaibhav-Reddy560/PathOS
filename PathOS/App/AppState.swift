import BackgroundTasks
import CoreLocation
import Observation
import SwiftData
import SwiftUI

/// The deck's modes. Scanning is an action on the map, not a mode.
nonisolated enum AppTab: String, Hashable, Sendable {
    case now
    case day
    case radar
    case vault
}

/// Opens the event sheet, either empty or editing an existing event.
nonisolated struct EventSheetRequest: Identifiable, Hashable, Sendable {
    var id = UUID()
    var editing: UUID?
    /// Text to read into a draft (pasted or shared), if any.
    var text: String?
}

/// A short confirmation shown at the top of the deck.
nonisolated struct Toast: Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var role: SignalRole
    var symbol: String
}

nonisolated struct CompassTarget: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

nonisolated struct CommuteInfo: Sendable {
    var destinationName: String?
    var destinationLatitude: Double?
    var destinationLongitude: Double?
    var walkMinutes: Int?
    var transitMinutes: Int?
    var stationName: String?
    var stationWalkMinutes: Int?
    var updatedAt: Date

    var destination: CLLocationCoordinate2D? {
        guard let destinationLatitude, let destinationLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: destinationLatitude, longitude: destinationLongitude)
    }
}

nonisolated struct AssistantTurn: Identifiable, Sendable {
    var id = UUID()
    var question: String
    var answer: String
    var places: [PlaceSummary]
}

/// Root state: owns every manager and reacts to geofences, deep links and lifecycle.
@Observable
final class AppState {
    static let shared = AppState()
    nonisolated static let refreshTaskID = "com.vaibhavreddy.pathos.refresh"

    let modelContainer: ModelContainer
    let location: LocationManager
    let geofences: GeofenceMonitor
    let barometer: BarometerManager
    let weather: WeatherService
    let sound: SoundClassifier
    let voice: VoiceInput
    let speech: SpeechOutput
    let places: PlacesService
    let ai: AIClient
    let liveActivities: LiveActivityController
    let notifications: NotificationService
    let haptics: HapticsService
    let vault: SpatialVaultService
    let routine: RoutineLearner
    let context: ContextEngine
    let events: EventsService
    let eventStore: EventStore
    let timetable: TimetableService
    let transit: TransitService
    let trips: TripStore
    let snap: SnapToActionService

    var selectedTab: AppTab = .now
    var deckDetent: PresentationDetent = .deckPeek
    /// The map signal whose details the deck is showing.
    var selectedSignalID: String?
    var isSettingsPresented = false
    var isAddingNote = false
    var isTimetablePresented = false
    var isJourneySheetPresented = false
    var isTripsPresented = false
    /// Presents the event sheet: nil id means a new event.
    var eventSheet: EventSheetRequest?
    var isScannerPresented = false
    var isPhotoPickerPresented = false
    private(set) var toast: Toast?
    var mapLayers = MapLayers(rawValue: UserDefaults.standard.object(forKey: "pathos.mapLayers") as? Int ?? MapLayers.all.rawValue) {
        didSet { UserDefaults.standard.set(mapLayers.rawValue, forKey: "pathos.mapLayers") }
    }
    /// Where guidance is pointing. Setting it hides the deck and shows the guidance HUD over the map.
    var compassTarget: CompassTarget? {
        didSet {
            guard compassTarget?.id != oldValue?.id else { return }
            guidanceRoute = nil
            if compassTarget == nil {
                isHeadsUp = false
            }
        }
    }
    private(set) var guidanceRoute: WalkingRoute?
    /// Guidance with the map dimmed away, leaving just the arrow.
    var isHeadsUp = false
    /// The island has grown into the assistant.
    var isAssistantActive = false {
        didSet {
            // Keep the island visible above the deck while you talk to it.
            if isAssistantActive {
                deckDetent = .deckPeek
            }
        }
    }
    var voiceAutoListen = false
    /// Island alerts you've dismissed this session.
    var dismissedAlertIDs: Set<String> = []
    var focusedNoteID: UUID?
    /// Target of the Lock Screen pointer; outlives the in-app compass screen.
    private(set) var pinnedCompassTarget: CompassTarget?
    private(set) var commute: CommuteInfo?
    private(set) var assistantTurns: [AssistantTurn] = []
    private(set) var isAnswering = false

    var preferredCab: CabProvider = CabProvider(rawValue: UserDefaults.standard.string(forKey: "pathos.preferredCab") ?? "") ?? .uber {
        didSet { UserDefaults.standard.set(preferredCab.rawValue, forKey: "pathos.preferredCab") }
    }

    var adaptiveSound: Bool = UserDefaults.standard.object(forKey: "pathos.adaptiveSound") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(adaptiveSound, forKey: "pathos.adaptiveSound")
            haptics.isAdaptive = adaptiveSound
            if adaptiveSound {
                Task { await sound.start() }
            } else {
                sound.stop()
            }
        }
    }

    @ObservationIgnored private var assistantPlaces: [PlaceSummary] = []
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var compassTask: Task<Void, Never>?
    @ObservationIgnored private var lastGeofenceSyncLocation: CLLocation?
    @ObservationIgnored private var lastDistanceLocation: CLLocation?
    @ObservationIgnored private var isForeground = false
    /// Alerts already announced, kept across background relaunches so nothing repeats.
    @ObservationIgnored private var announcedAlertIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "pathos.announcedAlerts") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "pathos.announcedAlerts") }
    }

    private init() {
        do {
            modelContainer = try ModelContainer(
                for: SavedPlace.self, SpatialNote.self, ScanRecord.self, Expense.self, DepartureLog.self,
                PathEvent.self, DayLog.self, NotePhoto.self, TimetableEntry.self, TimetableException.self,
                Trip.self, TripLeg.self
            )
        } catch {
            fatalError("PathOS couldn't open its storage: \(error)")
        }
        let modelContext = modelContainer.mainContext

        let location = LocationManager()
        let geofences = GeofenceMonitor()
        let barometer = BarometerManager()
        let weather = WeatherService()
        let places = PlacesService()
        let ai = AIClient()
        let notifications = NotificationService()
        let vault = SpatialVaultService(context: modelContext, geofences: geofences)

        self.location = location
        self.geofences = geofences
        self.barometer = barometer
        self.weather = weather
        self.places = places
        self.ai = ai
        self.notifications = notifications
        self.vault = vault
        sound = SoundClassifier()
        voice = VoiceInput()
        speech = SpeechOutput()
        liveActivities = LiveActivityController()
        haptics = HapticsService()
        routine = RoutineLearner(context: modelContext, notifications: notifications)
        context = ContextEngine(places: places, vault: vault, barometer: barometer, weather: weather)
        let eventStore = EventStore(context: modelContext, notifications: notifications)
        self.eventStore = eventStore
        let timetable = TimetableService(context: modelContext, ai: ai, notifications: notifications)
        self.timetable = timetable
        transit = TransitService(places: places, notifications: notifications)
        trips = TripStore(context: modelContext, notifications: notifications)
        events = EventsService(sources: [
            PathOSEventSource(store: eventStore),
            TimetableEventSource(service: timetable),
            ScannedEventSource(context: modelContext),
            VenueEventSource(places: places),
        ])
        snap = SnapToActionService(ai: ai, context: modelContext)

        haptics.isAdaptive = adaptiveSound
        notifications.onOpenURL = { [weak self] url in
            self?.handle(url: url)
        }
        Task { await bootstrap() }
    }

    // MARK: Lifecycle

    /// Runs on every launch, including background relaunches for geofence events.
    private func bootstrap() async {
        #if DEBUG
        seedDemoDataIfRequested()
        applyDebugLaunchArguments()
        #endif
        await geofences.start { [weak self] event in
            self?.handleGeofence(event)
        }
        await notifications.refreshStatus()
        await vault.syncGeofences(userLocation: location.location)
        scheduleBackgroundRefresh()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            // Anything on screen counts as seen, so it won't buzz later.
            announcedAlertIDs = AmbientAlerts.announcedIDs(ambientAlerts)
            location.startUpdates()
            barometer.start()
            ai.refreshStatus()
            if adaptiveSound {
                Task { await sound.start() }
            }
            startForegroundLoop()
        case .background:
            isForeground = false
            loopTask?.cancel()
            loopTask = nil
            sound.stop()
            barometer.stop()
            if pinnedCompassTarget == nil && liveActivities.currentMode != .commute {
                location.stopUpdates()
            }
            scheduleBackgroundRefresh()
        default:
            break
        }
    }

    private func startForegroundLoop() {
        loopTask?.cancel()
        loopTask = Task {
            while !Task.isCancelled {
                haptics.update(scene: sound.scene)
                transit.update(location: location.location)
                if let here = location.location {
                    recordDistance(to: here)
                    await context.refresh(location: here)
                    if lastGeofenceSyncLocation.map({ here.distance(from: $0) > 1_000 }) ?? true {
                        lastGeofenceSyncLocation = here
                        await vault.syncGeofences(userLocation: here)
                    }
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func performBackgroundRefresh() async {
        scheduleBackgroundRefresh()
        await barometer.sampleBriefly()
        var here = location.location
        if here == nil, location.hasAlwaysAccess {
            here = await location.currentLocation()
        }
        if let here {
            await context.refresh(location: here, force: true)
        }
        await routine.rescheduleReminders()
        eventStore.refreshReminders()
        timetable.refreshReminders()
        trips.refreshReminders()
        notifyNewAlerts()
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func requestCorePermissions() async {
        if location.authorization == .notDetermined {
            location.requestWhenInUse()
        } else if location.authorization == .authorizedWhenInUse {
            location.requestAlways()
        }
        await notifications.requestAuthorization()
    }

    // MARK: Day log

    /// Adds real movement to today's log, ignoring GPS wobble and impossible jumps.
    func recordDistance(to here: CLLocation) {
        defer { lastDistanceLocation = here }
        let log = todaysLog()
        log.lastSeenAt = Date()
        if log.firstSeenAt == nil {
            log.firstSeenAt = Date()
        }
        guard let previous = lastDistanceLocation else { return }
        log.distanceMeters += DayDistance.step(fromDistance: here.distance(from: previous))
        try? modelContainer.mainContext.save()
    }

    @discardableResult
    func todaysLog(for day: Date = Date()) -> DayLog {
        let dayStart = Calendar.current.startOfDay(for: day)
        let descriptor = FetchDescriptor<DayLog>(predicate: #Predicate { $0.dayStart == dayStart })
        if let existing = try? modelContainer.mainContext.fetch(descriptor).first {
            return existing
        }
        let log = DayLog(dayStart: dayStart)
        modelContainer.mainContext.insert(log)
        return log
    }

    // MARK: Geofences

    private func handleGeofence(_ event: GeofenceEvent) {
        Task {
            if let place = vault.place(forGeofenceID: event.id) {
                switch event.transition {
                case .exited:
                    await didLeave(place)
                case .entered:
                    if place.kind == .home || place.kind == .work {
                        await liveActivities.end(ifMode: .commute)
                        await liveActivities.end(ifMode: .exitCheck)
                    }
                }
            } else if event.transition == .entered, let note = vault.note(forGeofenceID: event.id) {
                await surface(note)
            }
        }
    }

    private func didLeave(_ place: SavedPlace) async {
        if place.kind == .home {
            routine.logDeparture(from: .home)
            await routine.rescheduleReminders()
        }

        let here = await location.currentLocation() ?? CLLocation(latitude: place.latitude, longitude: place.longitude)
        guard let advice = await context.evaluateExit(at: here) else { return }

        haptics.alert()
        let link = URL(string: "pathos://dashboard")
        await liveActivities.show(
            .init(mode: .exitCheck, title: advice.headline, subtitle: advice.detail, symbol: advice.symbol, deepLink: link),
            staleAfter: 2 * 3600,
            relevance: 90
        )
        announcedAlertIDs.insert("exit.advice")
        notifications.post(
            id: "pathos.exit.\(place.id.uuidString)",
            title: advice.headline,
            body: advice.detail,
            category: NotificationService.Category.exitCheck,
            link: link,
            timeSensitive: true,
            sound: haptics.shouldPlaySound
        )
    }

    private func surface(_ note: SpatialNote) async {
        guard vault.shouldSurface(note) else { return }
        vault.markSurfaced(note)
        haptics.alert()

        let link = URL(string: "pathos://note/\(note.id.uuidString)")
        let shown = await liveActivities.show(
            .init(mode: .spatialNote, title: note.title, subtitle: note.body, symbol: "mappin.and.ellipse", deepLink: link),
            staleAfter: 3600,
            relevance: 80
        )
        if !shown {
            notifications.post(
                id: "pathos.note.\(note.id.uuidString)",
                title: note.title,
                body: note.body.isEmpty ? "You left a note here." : note.body,
                category: NotificationService.Category.spatialNote,
                link: link,
                timeSensitive: true,
                sound: haptics.shouldPlaySound
            )
        }
    }

    // MARK: Deep links

    func handle(url: URL) {
        guard url.scheme == "pathos" else { return }
        let path = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        switch url.host() {
        case "dashboard": showDeck(.now)
        case "day": showDeck(.day)
        case "radar": showDeck(.radar)
        case "scan": beginScan()
        case "vault": showDeck(.vault)
        case "voice":
            activateAssistant(listen: true)
        case "compass":
            if compassTarget == nil {
                if let pinned = pinnedCompassTarget {
                    startCompass(to: pinned)
                } else if let note = vault.activeNotes().first {
                    startCompass(to: CompassTarget(id: note.geofenceID, name: note.title, latitude: note.latitude, longitude: note.longitude))
                }
            }
        case "note":
            if let id = path.first.flatMap(UUID.init(uuidString:)) {
                showDeck(.vault)
                focusedNoteID = id
            }
        case "commute":
            showDeck(.now)
            if path.first == "start" {
                Task { await startCommute() }
            }
        case "cab":
            let provider = value("provider").flatMap(CabProvider.init(rawValue:)) ?? preferredCab
            let drop: CLLocationCoordinate2D? = if let lat = value("lat").flatMap(Double.init), let lng = value("lng").flatMap(Double.init) {
                CLLocationCoordinate2D(latitude: lat, longitude: lng)
            } else {
                commute?.destination
            }
            CabLauncher.open(provider, drop: drop, pickup: location.location?.coordinate)
        default:
            break
        }
    }

    /// Switches the deck to `tab` and lifts it out of the peek position so its content is visible.
    func showDeck(_ tab: AppTab) {
        selectedTab = tab
        selectedSignalID = nil
        if deckDetent == .deckPeek {
            deckDetent = .medium
        }
    }

    func activateAssistant(listen: Bool) {
        voiceAutoListen = listen
        isAssistantActive = true
    }

    // MARK: Island

    /// Everything the island could say right now, most important first.
    var ambientAlerts: [AmbientAlert] {
        AmbientAlerts.prioritized(alertSnapshot(), dismissed: dismissedAlertIDs)
    }

    func alertSnapshot(now: Date = Date()) -> AlertSnapshot {
        let access: AlertSnapshot.LocationAccess = switch location.authorization {
        case .authorizedAlways: .always
        case .authorizedWhenInUse: .whenInUse
        case .notDetermined: .notDetermined
        default: .denied
        }

        let guidance = compassTarget.map { target in
            AlertSnapshot.Guidance(
                target: target,
                distanceMeters: location.location?.distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude)),
                needsCalibration: CLLocationManager.headingAvailable() && location.headingDegrees != nil
                    && (location.headingAccuracy < 0 || location.headingAccuracy > 30)
            )
        }

        let activeCommute = liveActivities.currentMode == .commute ? commute : nil
        let nextEvent = events.events
            .compactMap { event -> AlertSnapshot.Event? in
                guard let start = event.start, start >= now else { return nil }
                return AlertSnapshot.Event(id: event.id, title: event.title, start: start, latitude: event.latitude, longitude: event.longitude)
            }
            .min { $0.start < $1.start }

        return AlertSnapshot(
            location: access,
            exitAdvice: context.exitAdvice,
            pressureTrend: barometer.trend,
            guidance: guidance,
            journey: transit.journey.flatMap { journey in
                transit.progress.map { progress in
                    AlertSnapshot.Journey(
                        destination: journey.destination,
                        lineName: journey.lineName,
                        stopsRemaining: progress.stopsRemaining,
                        minutesRemaining: progress.estimatedMinutesRemaining,
                        isArrivingNext: progress.isArrivingNext
                    )
                }
            },
            commute: activeCommute.map { AlertSnapshot.Commute(destinationName: $0.destinationName, minutes: $0.transitMinutes ?? $0.walkMinutes) },
            nextEvent: nextEvent,
            weather: weather.snapshot.map {
                AlertSnapshot.Weather(temperatureC: $0.temperatureC, summary: $0.summary, symbol: $0.symbol, rainChanceNext2h: $0.rainChanceNext2h)
            },
            venueName: context.venue.name ?? context.venue.kind.label,
            venueSymbol: context.venue.kind.symbol,
            now: now
        )
    }

    /// Sends a notification for anything that has *newly* become worth interrupting for.
    /// Silent while the app is open, because the island is already showing it.
    func notifyNewAlerts() {
        guard !isForeground, notifications.isAuthorized else { return }
        let alerts = ambientAlerts
        for alert in AmbientAlerts.notifiable(previous: announcedAlertIDs, current: alerts) {
            notifications.post(
                id: "pathos.alert.\(alert.id)",
                title: alert.headline,
                body: alert.detail,
                category: NotificationService.Category.ambient,
                link: URL(string: "pathos://dashboard"),
                timeSensitive: alert.role == .critical,
                sound: haptics.shouldPlaySound
            )
        }
        announcedAlertIDs = AmbientAlerts.announcedIDs(alerts)
    }

    func perform(_ action: AmbientAlert.Action) {
        switch action {
        case .requestLocation:
            Task { await requestCorePermissions() }
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .startCommute:
            Task { await startCommute() }
        case .showNow:
            showDeck(.now)
        case .showRadar:
            showDeck(.radar)
        case .pointTo(let target):
            startCompass(to: target)
        case .endGuidance:
            compassTarget = nil
        case .endJourney:
            endJourney()
        }
    }

    // MARK: Journeys

    func startJourney(lineID: String, fromIndex: Int, toIndex: Int) {
        transit.start(lineID: lineID, fromIndex: fromIndex, toIndex: toIndex)
        location.startUpdates()
        location.setBackgroundSessionActive(true)
        Task { await updateJourneyActivity() }
    }

    func endJourney() {
        transit.end()
        location.setBackgroundSessionActive(pinnedCompassTarget != nil)
        Task { await liveActivities.end(ifMode: .journey) }
    }

    /// Mirrors journey progress onto the Lock Screen and Dynamic Island.
    func updateJourneyActivity() async {
        guard let journey = transit.journey, let progress = transit.progress else { return }
        let state = PathOSActivityAttributes.ContentState(
            mode: .journey,
            title: "To \(journey.destination)",
            subtitle: progress.hasArrived
                ? "You've arrived"
                : "\(journey.lineName) · \(JourneyTracker.summary(progress)) (estimated)",
            symbol: "tram.fill",
            etaMinutes: progress.estimatedMinutesRemaining,
            deepLink: URL(string: "pathos://dashboard")
        )
        await liveActivities.show(state, staleAfter: 3_600, relevance: 95)
    }

    /// Live Text camera where supported; the photo picker otherwise (e.g. the simulator).
    func beginScan() {
        if ScannerController.isSupported {
            isScannerPresented = true
        } else {
            isPhotoPickerPresented = true
        }
    }

    func showToast(_ text: String, role: SignalRole = .you, symbol: String = "checkmark.circle.fill") {
        let toast = Toast(text: text, role: role, symbol: symbol)
        self.toast = toast
        AccessibilityNotification.Announcement(text).post()
        Task {
            try? await Task.sleep(for: .seconds(3))
            if self.toast?.id == toast.id {
                self.toast = nil
            }
        }
    }

    // MARK: Home / Work

    @discardableResult
    func setPlaceHere(_ kind: PlaceKind) async -> Bool {
        guard let here = await location.currentLocation() else { return false }
        vault.setPlace(kind, name: kind.label, at: here.coordinate)
        await vault.syncGeofences(userLocation: here)
        await context.refresh(location: here, force: true)
        haptics.success()
        return true
    }

    // MARK: Compass

    func startCompass(to target: CompassTarget) {
        selectedSignalID = nil
        isAssistantActive = false
        compassTarget = target
        location.startUpdates()
        Task {
            guard let here = await location.currentLocation() else { return }
            let route = await places.walkingRoute(to: target.coordinate, from: here)
            if compassTarget?.id == target.id {
                guidanceRoute = route
            }
        }
    }

    /// Stops the Lock Screen pointer. The in-app compass screen closes independently.
    func unpinCompass() async {
        guard pinnedCompassTarget != nil else { return }
        pinnedCompassTarget = nil
        compassTask?.cancel()
        compassTask = nil
        location.endHeadingUpdates()
        location.setBackgroundSessionActive(false)
        await liveActivities.end(ifMode: .compass)
    }

    /// Mirrors the pointer onto the Lock Screen, Dynamic Island and StandBy.
    @discardableResult
    func pinCompassToLockScreen() async -> Bool {
        guard let target = compassTarget else { return false }
        if pinnedCompassTarget == nil {
            location.beginHeadingUpdates()
            location.setBackgroundSessionActive(true)
        }
        pinnedCompassTarget = target
        let shown = await liveActivities.show(compassState(for: target), staleAfter: 1_800, relevance: 70)
        compassTask?.cancel()
        compassTask = Task {
            while !Task.isCancelled, let target = pinnedCompassTarget {
                await liveActivities.updateThrottled(compassState(for: target))
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return shown
    }

    func compassState(for target: CompassTarget) -> PathOSActivityAttributes.ContentState {
        let link = URL(string: "pathos://compass")
        guard let here = location.location else {
            return .init(mode: .compass, title: target.name, subtitle: "Finding your location…", symbol: "location.north.line.fill", deepLink: link)
        }
        let bearing = GeoMath.bearing(from: here.coordinate, to: target.coordinate)
        let relative = location.headingDegrees.map { GeoMath.relativeBearing(target: bearing, heading: $0) }
        let distance = here.distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
        let walk = GeoMath.walkingMinutes(forDistance: distance)
        return .init(
            mode: .compass,
            title: target.name,
            subtitle: "\(GeoMath.formatDistance(distance)) · \(walk) min walk",
            symbol: "location.north.fill",
            relativeBearing: relative,
            distanceMeters: distance,
            etaMinutes: walk,
            deepLink: link
        )
    }

    // MARK: Commute

    /// Walking/transit ETA to Work (or Home when at work), nearest metro, and cab shortcuts.
    @discardableResult
    func startCommute() async -> Bool {
        guard let here = await location.currentLocation() else { return false }
        let destination = context.venue.kind == .work
            ? vault.place(ofKind: .home)
            : (vault.place(ofKind: .work) ?? vault.place(ofKind: .home))

        let station = await places.nearestTransitStation(to: here)
        var walk: Int?
        var transit: Int?
        if let destination {
            walk = await places.eta(to: destination.coordinate, from: here, transport: .walking)
            transit = await places.eta(to: destination.coordinate, from: here, transport: .transit)
        }

        let info = CommuteInfo(
            destinationName: destination?.name,
            destinationLatitude: destination?.latitude,
            destinationLongitude: destination?.longitude,
            walkMinutes: walk,
            transitMinutes: transit,
            stationName: station?.name,
            stationWalkMinutes: station?.walkMinutes,
            updatedAt: Date()
        )
        commute = info

        let parts = [
            transit.map { "\($0) min by transit" },
            walk.map { "\($0) min walk" },
            station.map { "Metro: \($0.name) (\($0.walkMinutes) min)" },
        ].compactMap { $0 }
        let subtitle = parts.isEmpty
            ? (destination == nil ? "Set Work in the Vault for ETAs" : "Route unavailable · cabs one tap away")
            : parts.joined(separator: " · ")

        return await liveActivities.show(
            .init(
                mode: .commute,
                title: destination.map { "To \($0.name)" } ?? "Commute",
                subtitle: subtitle,
                symbol: transit != nil ? "tram.fill" : "figure.walk",
                etaMinutes: transit ?? walk,
                deepLink: URL(string: "pathos://dashboard")
            ),
            staleAfter: 3_600,
            relevance: 85
        )
    }

    // MARK: Assistant

    func listenAndAnswer() async {
        speech.stop()
        sound.stop()
        defer {
            if adaptiveSound {
                Task { await sound.start() }
            }
        }
        guard let question = await voice.listen() else { return }
        await ask(question)
    }

    func ask(_ question: String) async {
        isAnswering = true
        defer { isAnswering = false }
        assistantPlaces = []

        let answer: String
        if ai.isAvailable {
            do {
                answer = try await ai.answer(question, situation: situationSummary())
            } catch {
                answer = "Sorry, I couldn't work that out right now."
            }
        } else {
            let found = await searchPlacesForAssistant(query: question, maxWalkMinutes: 15)
            answer = found.isEmpty
                ? "Apple Intelligence is off, and I couldn't find a matching place nearby."
                : "Closest matches: " + found.prefix(3).map { "\($0.name), \($0.walkMinutes) minutes' walk" }.joined(separator: "; ")
        }

        assistantTurns.insert(AssistantTurn(question: question, answer: answer, places: assistantPlaces), at: 0)
        speech.speak(answer)
    }

    func searchPlacesForAssistant(query: String, maxWalkMinutes: Int) async -> [PlaceSummary] {
        guard let here = await location.currentLocation() else { return [] }
        let radius = max(300, Double(maxWalkMinutes) * 80 / 1.3)
        let found = (try? await places.search(query, near: here, radius: radius)) ?? []
        let reachable = found.filter { $0.walkMinutes <= maxWalkMinutes }
        assistantPlaces = Array(reachable.prefix(6))
        return reachable
    }

    func notesForAssistant(keyword: String) async -> [String] {
        let here = location.location
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        return vault.activeNotes()
            .filter { trimmed.isEmpty || "\($0.title) \($0.body)".localizedCaseInsensitiveContains(trimmed) }
            .prefix(5)
            .map { note in
                let away = here.map { " (\(GeoMath.formatDistance($0.distance(from: CLLocation(latitude: note.latitude, longitude: note.longitude)))) away)" } ?? ""
                return "\(note.title): \(note.body)\(away)"
            }
    }

    func weatherForAssistant() async -> String {
        guard let here = await location.currentLocation(), let snapshot = await weather.refresh(for: here) else {
            return "Weather is unavailable right now. Barometer: \(barometer.trend.label)."
        }
        return "\(snapshot.summary), \(Int(snapshot.temperatureC.rounded()))°C, \(snapshot.rainChanceNext2h)% chance of rain in the next 2 hours. Barometer: \(barometer.trend.label)."
    }

    func situationSummary() -> String {
        var parts = ["Local time \(Date().formatted(date: .abbreviated, time: .shortened))"]
        parts.append("At: \(context.venue.name ?? context.venue.kind.label)")
        if let snapshot = weather.snapshot {
            parts.append("Weather: \(snapshot.summary), \(Int(snapshot.temperatureC.rounded()))°C, \(snapshot.rainChanceNext2h)% rain soon")
        }
        parts.append("Sound: \(sound.scene.label)")
        return parts.joined(separator: ". ")
    }
}
