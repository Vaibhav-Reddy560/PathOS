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
    /// A mail suggestion to start from, when you chose to edit it before adding.
    var mailSuggestion: UUID?
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
    var stationDistanceMeters: Double?
    var updatedAt: Date

    var destination: CLLocationCoordinate2D? {
        guard let destinationLatitude, let destinationLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: destinationLatitude, longitude: destinationLongitude)
    }
}

/// Where the journey planner should start, when it's opened from a stop on the map.
nonisolated enum JourneyPreset: Hashable, Sendable {
    case metro(from: String, to: String? = nil)
    case bus(from: String, to: String? = nil)
}

/// A change waiting on the assistant card for you to approve, edit or drop.
nonisolated struct PendingChange: Identifiable, Sendable {
    var id = UUID()
    /// What you said, kept for the assistant's history.
    var request: String
    var change: ProposedChange
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
    let mail: MailService
    let changes: ChangeService

    var selectedTab: AppTab = .now
    var deckDetent: PresentationDetent = .deckPeek
    /// The map signal whose details the deck is showing.
    var selectedSignalID: String?
    var isSettingsPresented = false
    var isAddingNote = false
    var isTimetablePresented = false
    var isJourneySheetPresented = false
    /// Read and cleared by the journey planner when it opens.
    var journeyPreset: JourneyPreset?
    var isTripsPresented = false
    /// Presents the event sheet: nil id means a new event.
    var eventSheet: EventSheetRequest?
    var isScannerPresented = false
    var isPhotoPickerPresented = false
    private(set) var toast: Toast?
    /// False while the launch view covers the map on a cold start.
    private(set) var isLaunchComplete = false
    var mapLayers = AppState.savedMapLayers() {
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
    /// Travel time to where you usually go next, and the nearest metro. See `refreshCommute`.
    private(set) var commute: CommuteInfo?
    /// The context stays on the Lock Screen, kept up to date, until you unpin it; across launches too.
    private(set) var isContextPinned = UserDefaults.standard.bool(forKey: "pathos.contextPinned") {
        didSet { UserDefaults.standard.set(isContextPinned, forKey: "pathos.contextPinned") }
    }
    /// The trip leg being followed on the Lock Screen, and how it's going.
    private(set) var trackedLegID: UUID?
    private(set) var legProgress: LegProgress?
    private(set) var assistantTurns: [AssistantTurn] = []
    private(set) var isAnswering = false
    /// A change the assistant has proposed and is waiting on you for.
    var pendingChange: PendingChange?
    private(set) var isApplyingChange = false

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
    /// Runs while a metro journey or a trip leg is being followed, in the foreground or not.
    @ObservationIgnored private var travelTask: Task<Void, Never>?
    /// Legs you ended by hand, so opening the app doesn't start following them again.
    @ObservationIgnored private var declinedLegIDs: Set<UUID> = []
    @ObservationIgnored private var lastGeofenceSyncLocation: CLLocation?
    @ObservationIgnored private var lastCommuteCheck: (location: CLLocation, at: Date)?
    /// A note just brought back by arriving at its spot, which the pinned context shows for a while.
    @ObservationIgnored private var surfacedMemory: (memory: LockScreenContext.Memory, at: Date)?
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
                Trip.self, TripLeg.self, MailSuggestion.self
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
        transit = TransitService(notifications: notifications)
        trips = TripStore(context: modelContext, notifications: notifications)
        let geocoder = PlaceGeocoder(places: places)
        events = EventsService(sources: [
            PathOSEventSource(store: eventStore),
            TimetableEventSource(service: timetable),
            TripEventSource(store: trips),
            CalendarEventSource(store: eventStore, geocoder: geocoder),
            MailEventSource(context: modelContext, geocoder: geocoder),
            ScannedEventSource(context: modelContext),
        ])
        snap = SnapToActionService(ai: ai, context: modelContext)
        mail = MailService(context: modelContext, ai: ai, eventStore: eventStore, places: places, notifications: notifications)
        changes = ChangeService(ai: ai, timetable: timetable, eventStore: eventStore, trips: trips, places: places)

        haptics.isAdaptive = adaptiveSound
        notifications.onOpenURL = { [weak self] url in
            self?.handle(url: url)
        }
        // Before anything waits: a move that relaunched PathOS is reported as soon as it's running.
        location.onSignificantChange = { [weak self] here in
            Task { await self?.movedWhilePinned(to: here) }
        }
        Task { await bootstrap() }
    }

    /// Layers saved before the transit layer existed get it switched on, once.
    private static func savedMapLayers() -> MapLayers {
        let defaults = UserDefaults.standard
        guard let raw = defaults.object(forKey: "pathos.mapLayers") as? Int else { return .all }
        var layers = MapLayers(rawValue: raw)
        if !defaults.bool(forKey: "pathos.mapLayers.transitAdded") {
            layers.insert(.transit)
            defaults.set(true, forKey: "pathos.mapLayers.transitAdded")
        }
        return layers
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
        if isContextPinned {
            location.setSignificantChangesActive(true)
        }
        await notifications.refreshStatus()
        await vault.syncGeofences(userLocation: location.location)
        scheduleBackgroundRefresh()
    }

    /// Lifts the launch view once the map has something to centre on: your location, or the
    /// knowledge that there won't be one. Always on screen long enough for the route to draw, and
    /// never more than a few seconds, so a slow GPS fix can't hold the app back.
    func finishLaunch(minimum: TimeInterval = 1.7, maximum: TimeInterval = 3.5) async {
        guard !isLaunchComplete else { return }
        let started = Date()
        while Date().timeIntervalSince(started) < maximum {
            let willNotLocate = [.denied, .restricted, .notDetermined].contains(location.authorization)
            if location.location != nil || willNotLocate { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let remaining = minimum - Date().timeIntervalSince(started)
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
        }
        #if DEBUG
        // `-PathOSHoldLaunch YES` keeps the launch view up, for screenshots of it.
        if UserDefaults.standard.bool(forKey: "PathOSHoldLaunch") { return }
        #endif
        isLaunchComplete = true
        if adaptiveSound {
            await sound.start()
        }
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
            // Not during the launch view: on a first run, the microphone prompt would land on top of it.
            if adaptiveSound && isLaunchComplete {
                Task { await sound.start() }
            }
            startForegroundLoop()
            followCurrentLegIfAny()
            Task {
                let found = await mail.checkIfDue(every: 10 * 60)
                if found > 0 {
                    showToast(found == 1 ? "1 new thing from your mail" : "\(found) new things from your mail", role: .world, symbol: "envelope.fill")
                }
            }
        case .background:
            isForeground = false
            loopTask?.cancel()
            loopTask = nil
            sound.stop()
            barometer.stop()
            if !needsBackgroundLocation {
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
            await reconcilePinnedContext()
            while !Task.isCancelled {
                haptics.update(scene: sound.scene)
                if let here = location.location {
                    recordDistance(to: here)
                    await transit.refreshNearby(location: here)
                    await context.refresh(location: here)
                    if lastGeofenceSyncLocation.map({ here.distance(from: $0) > 1_000 }) ?? true {
                        lastGeofenceSyncLocation = here
                        await vault.syncGeofences(userLocation: here)
                    }
                }
                await refreshPinnedContext()
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
        await refreshPinnedContext()
        await routine.rescheduleReminders()
        eventStore.refreshReminders()
        timetable.refreshReminders()
        trips.refreshReminders()
        notifyNewAlerts()
        // Few messages, so the check fits in the half-minute or so iOS allows.
        await mail.checkIfDue(every: 20 * 60, limit: 6, notify: true)
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
                        await releaseLockScreen(from: .exitCheck)
                    }
                }
                // Arriving or leaving changes where you are, which the pinned context leads with.
                if isContextPinned, let here = await location.currentLocation() {
                    await context.refresh(location: here, force: true)
                    await refreshPinnedContext()
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
        // Pinned, the context leads with the umbrella itself.
        if !isContextPinned {
            await liveActivities.show(
                .init(mode: .exitCheck, title: advice.headline, subtitle: advice.detail, symbol: advice.symbol, deepLink: link),
                staleAfter: 2 * 3600,
                relevance: 90
            )
        }
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
        let shown: Bool
        if isContextPinned {
            surfacedMemory = (LockScreenContext.Memory(title: note.title, body: note.body), Date())
            await refreshPinnedContext()
            // Directions keep the Lock Screen during a journey, so the note comes as a notification.
            shown = liveActivities.isRunning && liveActivities.currentMode == .venue
        } else {
            shown = await liveActivities.show(
                .init(mode: .spatialNote, title: note.title, subtitle: note.body, symbol: "mappin.and.ellipse", deepLink: link),
                staleAfter: 3600,
                relevance: 80
            )
        }
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
        case "settings": isSettingsPresented = true
        case "timetable": isTimetablePresented = true
        case "event": eventSheet = EventSheetRequest(editing: nil, text: value("text"))
        case "journey":
            // pathos://journey?from=Indiranagar&to=Majestic, or &by=bus with stop names.
            let from = value("from").flatMap { MetroNetwork.station(matching: $0) ?? $0 } ?? ""
            let to = value("to").flatMap { MetroNetwork.station(matching: $0) ?? $0 }
            planJourney(from: value("by") == "bus" ? .bus(from: value("from") ?? "", to: value("to")) : .metro(from: from, to: to))
        case "leg":
            if let id = path.first.flatMap(UUID.init(uuidString:)) {
                showDeck(.day)
                if path.dropFirst().first == "track" {
                    Task { await startLegTracking(id) }
                }
            }
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
            // Reminders scheduled before the context could be pinned still say "start".
            if path.first == "start" {
                Task { await pinContext() }
            }
        case "context":
            showDeck(.now)
            if path.first == "pin" {
                Task { await pinContext() }
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
                        isArrivingNext: progress.isArrivingNext,
                        symbol: journey.symbol,
                        changeStation: progress.isChangingNext ? progress.nextStationIndex.map(journey.stationName(at:)) : nil,
                        changeInstruction: progress.isChangingNext ? progress.nextStationIndex.flatMap { journey.stops[safe: $0]?.changeInstruction } : nil
                    )
                }
            },
            trip: trackedLeg.flatMap { leg in
                legProgress.map { progress in
                    AlertSnapshot.Trip(
                        title: "\(leg.mode.label) to \(leg.destination)",
                        destination: leg.destination,
                        symbol: leg.mode.symbol,
                        summary: TripTracker.summary(progress),
                        minutesRemaining: progress.minutesRemaining,
                        isLate: progress.isLate
                    )
                }
            },
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
        case .pointTo(let target):
            startCompass(to: target)
        case .endGuidance:
            compassTarget = nil
        case .endJourney:
            endJourney()
        case .endTrip:
            Task { await stopLegTracking(declined: true) }
        }
    }

    // MARK: Journeys

    func startJourney(_ journey: Journey) {
        transit.start(journey)
        location.startUpdates()
        refreshBackgroundSession()
        startTravelLoop()
    }

    func endJourney() {
        transit.end()
        refreshBackgroundSession()
        Task {
            await releaseLockScreen(from: .journey)
            // A trip leg that was waiting behind the journey gets the Lock Screen back.
            await updateLegActivity()
        }
    }

    func planJourney(from preset: JourneyPreset?) {
        journeyPreset = preset
        selectedSignalID = nil
        isJourneySheetPresented = true
    }

    /// Location keeps flowing in the background while anything is being followed.
    private var needsBackgroundLocation: Bool {
        pinnedCompassTarget != nil || transit.journey != nil || trackedLegID != nil
    }

    /// Also stops location entirely when nothing needs it and PathOS isn't on screen, so a trip
    /// that ends in your pocket doesn't leave GPS running until you next open the app.
    private func refreshBackgroundSession() {
        location.setBackgroundSessionActive(needsBackgroundLocation)
        if !isForeground && !needsBackgroundLocation {
            location.stopUpdates()
        }
    }

    /// One loop for everything that moves with you. It keeps running with the app in the
    /// background, where the old foreground-only loop couldn't: that's what lets "get off next"
    /// and trip arrivals fire with the phone in your pocket.
    private func startTravelLoop() {
        guard travelTask == nil else { return }
        travelTask = Task {
            while !Task.isCancelled, transit.journey != nil || trackedLegID != nil {
                if transit.journey != nil {
                    transit.update(location: location.location)
                    await updateJourneyActivity()
                }
                if trackedLegID != nil {
                    await updateLegProgress()
                }
                try? await Task.sleep(for: .seconds(10))
            }
            travelTask = nil
        }
    }

    // MARK: Trip legs

    var trackedLeg: TripLeg? {
        trackedLegID.flatMap { trips.leg(id: $0) }
    }

    /// Follows a trip leg on the Lock Screen until you arrive. iOS only lets this start while
    /// PathOS is open, which is why the departure reminder has a Start tracking button.
    func startLegTracking(_ id: UUID) async {
        guard let leg = trips.leg(id: id) else { return }
        // A metro leg between two stations is better followed stop by stop.
        if leg.mode == .metro, transit.journey == nil,
           let from = MetroNetwork.station(matching: leg.origin),
           let to = MetroNetwork.station(matching: leg.destination),
           let route = MetroRouter.route(from: from, to: to) {
            startJourney(.metro(route))
            return
        }
        trackedLegID = id
        declinedLegIDs.remove(id)
        location.startUpdates()
        refreshBackgroundSession()
        await updateLegProgress()
        startTravelLoop()
    }

    func stopLegTracking(declined: Bool = false) async {
        if declined, let trackedLegID {
            declinedLegIDs.insert(trackedLegID)
        }
        trackedLegID = nil
        legProgress = nil
        refreshBackgroundSession()
        await releaseLockScreen(from: .trip)
    }

    /// Opening PathOS during a leg starts following it, unless you already ended it.
    private func followCurrentLegIfAny(now: Date = Date()) {
        guard trackedLegID == nil, transit.journey == nil else { return }
        let legs = trips.all().flatMap(\.legs).filter { !declinedLegIDs.contains($0.id) }
        let planned = legs.map(TripStore.plannedLeg)
        // Underway, or leaving within a quarter of an hour.
        let current = TripPlan.current(in: planned, now: now)
            ?? planned.first { $0.departure > now && $0.departure.timeIntervalSince(now) <= 15 * 60 }
        guard let current else { return }
        Task { await startLegTracking(current.id) }
    }

    private func updateLegProgress(now: Date = Date()) async {
        guard let leg = trackedLeg else {
            await stopLegTracking()
            return
        }
        let planned = TripStore.plannedLeg(leg)
        let progress = TripTracker.progress(
            leg: planned,
            origin: leg.originCoordinate,
            destination: leg.destinationCoordinate,
            location: location.location?.coordinate,
            now: now
        )
        legProgress = progress

        if progress.hasArrived {
            if !isForeground {
                notifications.post(
                    id: "pathos.leg.\(leg.id.uuidString).arrived",
                    title: "You've arrived: \(leg.destination)",
                    body: "\(leg.mode.label) from \(leg.origin).",
                    category: NotificationService.Category.tripLeg,
                    link: URL(string: "pathos://day")
                )
            }
            await stopLegTracking()
            return
        }
        // Give up a while after the planned arrival if there's no location to prove otherwise.
        let giveUp = (planned.arrivalEstimate() ?? leg.departure.addingTimeInterval(12 * 3_600)).addingTimeInterval(2 * 3_600)
        if now > giveUp {
            await stopLegTracking()
            return
        }
        await updateLegActivity()
    }

    /// The metro journey has the Lock Screen while it runs; a leg shows otherwise.
    private func updateLegActivity() async {
        guard transit.journey == nil, let leg = trackedLeg, let progress = legProgress else { return }
        await liveActivities.showIfChanged(
            .init(
                mode: .trip,
                title: "\(leg.mode.label) to \(leg.destination)",
                subtitle: TripTracker.summary(progress),
                symbol: leg.mode.symbol,
                distanceMeters: progress.distanceRemaining.map { ($0 / 100).rounded() * 100 },
                etaMinutes: progress.minutesRemaining,
                deepLink: URL(string: "pathos://day")
            ),
            staleAfter: 3_600,
            relevance: progress.isLate ? 92 : 88
        )
    }

    /// Mirrors journey progress onto the Lock Screen and Dynamic Island.
    func updateJourneyActivity() async {
        guard let journey = transit.journey, let progress = transit.progress else { return }
        let changeHere = progress.isChangingNext ? progress.nextStationIndex.flatMap { journey.stops[safe: $0]?.changeInstruction } : nil
        let state = PathOSActivityAttributes.ContentState(
            mode: .journey,
            title: "To \(journey.destination)",
            subtitle: progress.hasArrived
                ? "You've arrived"
                : changeHere.map { "Next stop \(journey.stationName(at: progress.nextStationIndex ?? 0)): \($0.prefix(1).lowercased() + $0.dropFirst())" }
                    ?? "\(journey.lineName) · \(JourneyTracker.summary(progress)) (estimated)",
            symbol: changeHere == nil ? journey.symbol : "arrow.triangle.swap",
            etaMinutes: progress.estimatedMinutesRemaining,
            deepLink: URL(string: "pathos://dashboard")
        )
        await liveActivities.showIfChanged(state, staleAfter: 3_600, relevance: 95)
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
        refreshBackgroundSession()
        await releaseLockScreen(from: .compass)
    }

    /// Mirrors the pointer onto the Lock Screen, Dynamic Island and StandBy.
    @discardableResult
    func pinCompassToLockScreen() async -> Bool {
        guard let target = compassTarget else { return false }
        if pinnedCompassTarget == nil {
            location.beginHeadingUpdates()
        }
        pinnedCompassTarget = target
        refreshBackgroundSession()
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

    /// Travel time to Work, or Home from work, and the nearest metro: for Now, and for the pinned
    /// context around when you usually leave. Apple Maps is only asked again once you've moved or
    /// a while has passed.
    func refreshCommute(force: Bool = false) async {
        guard let here = location.location else { return }
        if !force, let last = lastCommuteCheck,
           here.distance(from: last.location) < 300, Date().timeIntervalSince(last.at) < 10 * 60 {
            return
        }
        lastCommuteCheck = (here, Date())

        let destination: SavedPlace? = switch context.venue.kind {
        case .home: vault.place(ofKind: .work)
        case .work: vault.place(ofKind: .home)
        default: vault.place(ofKind: .work) ?? vault.place(ofKind: .home)
        }
        var walk: Int?
        var transit: Int?
        if let destination {
            walk = await places.eta(to: destination.coordinate, from: here, transport: .walking)
            transit = await places.eta(to: destination.coordinate, from: here, transport: .transit)
        }
        let station = MetroNetwork.nearbyStations(to: here.coordinate, atLeast: 1).first

        commute = CommuteInfo(
            destinationName: destination?.name,
            destinationLatitude: destination?.latitude,
            destinationLongitude: destination?.longitude,
            walkMinutes: walk,
            transitMinutes: transit,
            stationName: station?.station.name,
            stationWalkMinutes: station.map { GeoMath.walkingMinutes(forDistance: $0.distance) },
            stationDistanceMeters: station?.distance,
            updatedAt: Date()
        )
    }

    // MARK: Pinned context

    /// Directions have the Lock Screen while they run; the pinned context takes it back after.
    private static let directionModes: Set<PathOSActivityAttributes.Mode> = [.journey, .trip, .compass]

    /// Keeps what's around you on the Lock Screen: whether to take an umbrella, the class or event
    /// starting or under way, when to leave. Returns false when Live Activities are off.
    @discardableResult
    func pinContext() async -> Bool {
        isContextPinned = true
        location.setSignificantChangesActive(true)
        let shown = await refreshPinnedContext()
        if !shown {
            isContextPinned = false
            location.setSignificantChangesActive(false)
        }
        return shown
    }

    func unpinContext() async {
        isContextPinned = false
        surfacedMemory = nil
        location.setSignificantChangesActive(false)
        // Directions stay until they're done; only the context comes off.
        if liveActivities.currentMode == .venue {
            await liveActivities.end()
        }
    }

    /// Redraws the pinned context, unless directions have the Lock Screen.
    @discardableResult
    func refreshPinnedContext(now: Date = Date()) async -> Bool {
        guard isContextPinned else { return false }
        if liveActivities.isRunning, let mode = liveActivities.currentMode, Self.directionModes.contains(mode) {
            return true
        }
        if context.venue.kind == .home, routine.todaysDeparture(now: now) != nil {
            await refreshCommute()
        }
        let content = LockScreenContext.content(for: lockScreenInputs(now: now))
        return await liveActivities.showIfChanged(content.state, staleDate: content.staleDate, relevance: 60)
    }

    /// Something that had the Lock Screen is done with it: the pinned context takes it back, or
    /// it comes off.
    private func releaseLockScreen(from mode: PathOSActivityAttributes.Mode) async {
        guard liveActivities.currentMode == mode else { return }
        if isContextPinned {
            // Past the directions guard, which would otherwise see them still up.
            let content = LockScreenContext.content(for: lockScreenInputs(now: Date()))
            await liveActivities.show(content.state, staleDate: content.staleDate, relevance: 60)
        } else {
            await liveActivities.end()
        }
    }

    /// On opening PathOS: unpins if you swiped the context off the Lock Screen, and otherwise
    /// puts it back if iOS ended it after its eight hours, or starts it afresh before it would.
    private func reconcilePinnedContext() async {
        guard isContextPinned else { return }
        if liveActivities.wasRemovedByYou {
            await unpinContext()
            return
        }
        await liveActivities.renewIfOld()
        await refreshPinnedContext()
    }

    /// A few hundred metres moved with PathOS in the background: the place, the weather and the
    /// context catch up. Open, the foreground loop already does.
    private func movedWhilePinned(to here: CLLocation) async {
        guard isContextPinned, !isForeground else { return }
        await context.refresh(location: here)
        await refreshPinnedContext()
    }

    private func lockScreenInputs(now: Date) -> LockScreenContext.Inputs {
        if let surfaced = surfacedMemory, now.timeIntervalSince(surfaced.at) > 15 * 60 {
            surfacedMemory = nil
        }
        var commuteLine: LockScreenContext.Commute?
        if context.venue.kind == .home, let usual = routine.todaysDeparture(now: now),
           let commute, let name = commute.destinationName,
           let minutes = commute.transitMinutes ?? commute.walkMinutes {
            commuteLine = .init(destination: name, minutes: minutes, byTransit: commute.transitMinutes != nil, usualDeparture: usual)
        }
        return LockScreenContext.Inputs(
            venueName: context.venue.name ?? context.venue.kind.label,
            venueSymbol: context.venue.kind.symbol,
            weather: weather.snapshot.map {
                AlertSnapshot.Weather(temperatureC: $0.temperatureC, summary: $0.summary, symbol: $0.symbol, rainChanceNext2h: $0.rainChanceNext2h)
            },
            exitAdvice: context.exitAdvice,
            agenda: agenda(on: now),
            commute: commuteLine,
            memory: surfacedMemory?.memory,
            now: now
        )
    }

    /// Today's classes, events and calendar entries, as the Day shows them.
    private func agenda(on day: Date) -> [LockScreenContext.Entry] {
        guard let interval = Calendar.current.dateInterval(of: .day, for: day) else { return [] }
        let classes = timetable.sessions(on: day).map {
            LockScreenContext.Entry(id: "class:\($0.id)", title: $0.subject, place: $0.room,
                                    start: $0.start, end: $0.end, symbol: "graduationcap.fill", role: .you)
        }
        let own = eventStore.events(on: day).filter { !$0.isAllDay }.map {
            LockScreenContext.Entry(id: "event:\($0.id.uuidString)", title: $0.title, place: $0.placeName,
                                    start: $0.start, end: $0.end, symbol: "calendar", role: .world)
        }
        let mirrored = Set(eventStore.all().compactMap(\.calendarEventID))
        let calendar = CalendarEventSource.items(from: interval.start, to: interval.end, excluding: mirrored)
            .filter { !$0.isAllDay }
            .map { item in
                let place = item.location?.split(separator: "\n").first.map(String.init)
                return LockScreenContext.Entry(id: "calendar:\(item.id)", title: item.title, place: place,
                                               start: item.start, end: item.end,
                                               symbol: place.map(MailTriage.isOnline) == true ? "video.fill" : "calendar",
                                               role: .world)
            }
        return classes + own + calendar
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
        pendingChange = nil

        if ChangeIntent.looksLikeChange(question), await proposeChange(question) {
            return
        }

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

    /// Reads a change and puts it on the assistant card. Returns false when it wasn't a change
    /// after all, so the text is answered as a question instead.
    private func proposeChange(_ request: String) async -> Bool {
        let reply: String
        if !ai.isAvailable {
            reply = "Apple Intelligence is off, so I can't make changes from what you say. You can edit from the Day tab."
        } else {
            switch await changes.propose(request) {
            case .proposal(let change):
                pendingChange = PendingChange(request: request, change: change)
                reply = "Here's the change. Approve it and I'll update your day."
            case .needs(let message):
                reply = message
            case .notAChange:
                return false
            }
        }
        assistantTurns.insert(AssistantTurn(question: request, answer: reply, places: []), at: 0)
        speech.speak(reply)
        return true
    }

    func approvePendingChange() async {
        guard let pending = pendingChange, !isApplyingChange else { return }
        isApplyingChange = true
        defer { isApplyingChange = false }
        let summary = await changes.apply(pending.change, near: location.location)
        pendingChange = nil
        haptics.success()
        showToast(summary)
        assistantTurns.insert(AssistantTurn(question: pending.request, answer: summary, places: []), at: 0)
    }

    /// Opens the change in its usual editor instead of applying it as proposed.
    func editPendingChange() {
        guard let pending = pendingChange else { return }
        pendingChange = nil
        isAssistantActive = false
        switch pending.change {
        case .moveClass, .cancelClass, .dayOff, .classesOn:
            isTimetablePresented = true
        case .moveEvent(let id, _, _, _), .cancelEvent(let id, _, _), .renameEvent(let id, _, _):
            eventSheet = EventSheetRequest(editing: id, text: nil)
        case .addEvent:
            eventSheet = EventSheetRequest(editing: nil, text: pending.request)
        case .moveLeg, .cancelLeg:
            isTripsPresented = true
        }
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
