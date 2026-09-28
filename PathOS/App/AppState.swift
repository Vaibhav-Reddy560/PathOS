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
    /// Places and addresses anywhere, and your own saved ones.
    case search
}

/// Opens the event sheet, either empty or editing an existing event.
nonisolated struct EventSheetRequest: Identifiable, Hashable, Sendable {
    var id = UUID()
    var editing: UUID?
    /// Text to read into a draft (pasted or shared), if any.
    var text: String?
    /// A mail suggestion to start from, when you chose to edit it before adding.
    var mailSuggestion: UUID?
    /// The day it's being added to, when it was opened from one: no need to ask for it again.
    var day: Date?
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
    var carMinutes: Int?
    var transitMinutes: Int?
    var walkMinutes: Int?
    var updatedAt: Date

    /// The ways worth showing: a car and a two-wheeler first, on foot only if it's a walk.
    var options: [TravelTimes.Option] {
        TravelTimes.options(car: carMinutes, transit: transitMinutes, walk: walkMinutes)
    }

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
    let journeys: JourneyPlanner
    let backups: BackupService

    var selectedTab: AppTab = .now
    var deckStop: DeckStop = .collapsed
    /// The map signal whose details the deck is showing.
    var selectedSignalID: String?
    /// Set while something is being pointed out on the map, so selecting it doesn't open the deck
    /// over the map it's on.
    @ObservationIgnored var isPointingOut = false
    var isSettingsPresented = false
    var isAddingNote = false
    var isTimetablePresented = false
    var isJourneySheetPresented = false
    /// Read and cleared by the journey planner when it opens.
    var journeyPreset: JourneyPreset?
    var isTripsPresented = false
    /// Choosing Home or Work by moving the map under a pin.
    var placePicking: PlaceKind?
    /// Choosing Home or Work from Search's results.
    var searchSettingPlace: PlaceKind?
    /// A place found in Search, shown on the map.
    var searchPlace: PlaceSummary?
    var searchQuery = ""
    var searchResults: [PlaceSummary] = []
    /// A destination whose ways of getting there are being shown.
    var waysRequest: WaysRequest?
    /// The journey you're making, and how far along it you are.
    var trip: ActiveTrip?
    var tripStatus: TripGuide.Status?
    /// The road route for the leg being followed, and where you are along it.
    var tripNav: NavRoute?
    var tripStep: StepGuide.Position?
    /// Where you are on that route: what's behind you stops being drawn, and what's left is timed.
    var tripMatch: RouteProgress.Match?
    /// The last known position on the route, for drawing the line's head between fixes.
    var tripTrim: RouteTrim.Anchor?
    /// Off the route and fetching a new one.
    var isRerouting = false
    /// What the traffic is doing to this leg, from Apple Maps' live times.
    var tripTraffic: TripTraffic?
    /// Where along the route the traffic is, for colouring the line.
    var tripFlow: TripFlow?
    /// Where the map is centred, once it stops moving.
    @ObservationIgnored var mapCenter: CLLocationCoordinate2D?
    /// Presents the event sheet: nil id means a new event.
    var eventSheet: EventSheetRequest?
    /// A session of the weekly schedule being changed from the day it's on.
    var editingSession: ClassSession?
    var isScannerPresented = false
    var isPhotoPickerPresented = false
    private(set) var toast: Toast?
    /// False while the launch view covers the map on a cold start.
    private(set) var isLaunchComplete = false
    var mapLayers = AppState.savedMapLayers() {
        didSet { UserDefaults.standard.set(mapLayers.rawValue, forKey: "pathos.mapLayers") }
    }
    /// How much of Apple Maps' own map shows under PathOS's signals. Off by default: the map
    /// leads with what PathOS found for you, until you ask for the rest.
    var poiDisplay = AppState.savedPOIDisplay() {
        didSet {
            UserDefaults.standard.set(poiDisplay.showsEverything, forKey: "pathos.mapPOI.all")
            UserDefaults.standard.set(poiDisplay.groups.rawValue, forKey: "pathos.mapPOI.groups")
        }
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
                deckStop = .collapsed
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
    /// The next place you need to be today, and whether it's time to set off. See `refreshDeparture`.
    private(set) var departure: AlertSnapshot.Departure?
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
                Task { await resumeListening() }
            } else {
                sound.stop()
            }
        }
    }

    /// Whether an urgent alert is said a second time when the first may have been missed.
    var repeatsUrgentAlerts: Bool = UserDefaults.standard.object(forKey: "pathos.repeatsUrgentAlerts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(repeatsUrgentAlerts, forKey: "pathos.repeatsUrgentAlerts") }
    }

    /// Whether the turns are spoken while you're being led somewhere.
    var speaksDirections: Bool = UserDefaults.standard.object(forKey: "pathos.speaksDirections") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(speaksDirections, forKey: "pathos.speaksDirections")
            if !speaksDirections { speech.stop() }
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
    @ObservationIgnored private var departureETA: (id: String, from: CLLocation, at: Date, minutes: Int, byRoad: Bool)?
    /// The leg of the trip last announced, and how many five-minute slips have been mentioned.
    /// The leg the route on the map belongs to, so it's fetched once per leg.
    @ObservationIgnored var navLegID: UUID?
    /// Re-routing: one fetch at a time, not before the cooldown, and only once you've really left
    /// the route.
    @ObservationIgnored var isFetchingRoute = false
    @ObservationIgnored var lastRouteFetch = Date.distantPast
    @ObservationIgnored var offRouteSamples = 0
    /// The once-a-second loop that follows the leg you're on.
    @ObservationIgnored var navigationTask: Task<Void, Never>?
    /// When the trip last had its position worked out: fixes and the loop both ask, and between
    /// them they would otherwise do the same arithmetic twice in a row.
    @ObservationIgnored var lastNavigationUpdate = Date.distantPast
    /// When the traffic on the route was last asked about, and the Lock Screen last redrawn.
    @ObservationIgnored var lastTrafficCheck = Date.distantPast
    /// What's been measured of each piece of the route, for colouring it; which route that was;
    /// and when the last few pieces were asked about.
    @ObservationIgnored var trafficReadings: [Int: RouteTraffic.Reading] = [:]
    @ObservationIgnored var trafficRouteID: UUID?
    @ObservationIgnored var isMeasuringTraffic = false
    @ObservationIgnored var lastTrafficBatch = Date.distantPast
    @ObservationIgnored var lastTripActivityUpdate = Date.distantPast
    @ObservationIgnored var lastTripActivityStep: Int?
    /// Today's log, kept to hand: distance is added on every fix.
    @ObservationIgnored var cachedDayLog: DayLog?
    @ObservationIgnored var lastDayLogSave = Date.distantPast
    /// Turns already spoken on this trip, so each is said once.
    @ObservationIgnored var spokenMoments: Set<NavigationVoice.Moment> = []
    @ObservationIgnored var announcedTripLeg: Int?
    @ObservationIgnored var announcedTripDelay = 0
    /// The destination whose ways to get there have already been offered, so it's said once.
    @ObservationIgnored var offeredWaysFor: String?
    /// Where you were, for the next place, when you last moved a fair way: closer since means you're on your way.
    @ObservationIgnored private var departureCheckpoint: (id: String, meters: Double, isOnTheWay: Bool)?
    /// The leave-by the reminders are set for, so they're only rescheduled when it moves.
    @ObservationIgnored private var scheduledLeaveBy: (id: String, at: Date)?
    /// A note just brought back by arriving at its spot, which the pinned context shows for a while.
    @ObservationIgnored private var surfacedMemory: (memory: LockScreenContext.Memory, at: Date)?
    @ObservationIgnored private var lastDistanceLocation: CLLocation?
    @ObservationIgnored private(set) var isForeground = false
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
        journeys = JourneyPlanner(places: places, transit: transit)
        backups = BackupService(context: modelContext)

        haptics.isAdaptive = adaptiveSound
        notifications.onOpenURL = { [weak self] url in
            self?.handle(url: url)
        }
        // Before anything waits: a move that relaunched PathOS is reported as soon as it's running.
        location.onSignificantChange = { [weak self] here in
            Task { await self?.movedInBackground(to: here) }
        }
        location.onFix = { [weak self] fix in
            guard let self else { return }
            recordDistance(to: fix)
            // Following a way, the map moves with the fix rather than with a timer: a line trimmed
            // on the next tick of a one-second loop always trails the puck.
            if trip != nil {
                updateNavigationPosition()
            }
        }
        // Headphones went on, or a call ended: the noise sensor may be able to listen again.
        sound.onMayResume = { [weak self] in
            Task { await self?.resumeListening() }
        }
        Task { await bootstrap() }
    }

    private static func savedPOIDisplay() -> POIDisplay {
        POIDisplay(showsEverything: UserDefaults.standard.bool(forKey: "pathos.mapPOI.all"),
                   groups: POIGroups(rawValue: UserDefaults.standard.integer(forKey: "pathos.mapPOI.groups")))
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
        // Cheap enough to leave on: wakes PathOS as you move, so leaving on time and the pinned
        // context keep up with the phone in your pocket.
        location.setSignificantChangesActive(isContextPinned || location.hasAlwaysAccess)
        await notifications.refreshStatus()
        await vault.syncGeofences(userLocation: location.location)
        scheduleBackgroundRefresh()
        // A copy of everything, every couple of days, so the data outlives the app itself.
        backups.writeIfDue()
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
        await resumeListening()
    }

    /// The noise sensor, on again when nothing else needs the audio: not while PathOS is
    /// speaking or listening to you, and not while music or a video plays (it checks that itself).
    func resumeListening() async {
        guard adaptiveSound, isForeground, isLaunchComplete, !speech.isSpeaking, !voice.isListening,
              !sound.isRunning else { return }
        await sound.start()
    }

    /// Says something aloud. The noise sensor steps aside first: taking the microphone while
    /// speaking changes the audio setup under the voice.
    func say(_ text: String) {
        sound.stop()
        speech.speak(text)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            // Anything on screen counts as seen, so it won't buzz later — including any second
            // nudge that hasn't fired yet.
            announcedAlertIDs = AmbientAlerts.announcedIDs(ambientAlerts)
            notifications.cancelRepeats()
            location.startUpdates()
            barometer.start()
            ai.refreshStatus()
            // Not during the launch view: on a first run, the microphone prompt would land on top of it.
            Task { await resumeListening() }
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
            // Whatever has been counted since the last save, before the app is suspended.
            try? modelContainer.mainContext.save()
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
                // Back on once the music has stopped, or the voice has finished.
                await resumeListening()
                haptics.update(scene: sound.scene)
                if let here = location.location {
                    await transit.refreshNearby(location: here)
                    await context.refresh(location: here)
                    await refreshDeparture()
                    recordAttendance()
                    await refreshTrip()
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
        await refreshDeparture()
        recordAttendance()
        await refreshTrip()
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

    /// Adds real movement to today's log, on every fix, in the foreground or not. Measured from
    /// the last point that counted, which is kept across launches, so a ride made with PathOS
    /// closed still counts when it next runs.
    func recordDistance(to here: CLLocation) {
        let log: DayLog
        if let cached = cachedDayLog, Calendar.current.isDate(cached.dayStart, inSameDayAs: here.timestamp) {
            log = cached
        } else {
            log = todaysLog(for: here.timestamp)
            cachedDayLog = log
        }
        log.lastSeenAt = here.timestamp
        if log.firstSeenAt == nil {
            log.firstSeenAt = here.timestamp
        }
        // Nothing to measure from: no anchor, one from yesterday (whose journey would land on
        // today), or one so old that what happened in between is anyone's guess.
        guard let anchor = distanceAnchor,
              DayDistance.canMeasure(from: anchor.timestamp, to: here.timestamp) else {
            distanceAnchor = here
            return
        }
        switch DayDistance.step(distance: here.distance(from: anchor),
                                seconds: here.timestamp.timeIntervalSince(anchor.timestamp),
                                accuracy: here.horizontalAccuracy) {
        case .ignore:
            break
        case .skip:
            distanceAnchor = here
        case .count(let metres):
            log.distanceMeters += metres
            distanceAnchor = here
        }
        // Saved every half minute, not every second.
        if Date().timeIntervalSince(lastDayLogSave) > 30 {
            lastDayLogSave = Date()
            try? modelContainer.mainContext.save()
        }
    }

    /// The last point that counted towards today's distance.
    private var distanceAnchor: CLLocation? {
        get {
            if let lastDistanceLocation { return lastDistanceLocation }
            guard let stored = UserDefaults.standard.array(forKey: "pathos.distanceAnchor") as? [Double], stored.count == 4 else { return nil }
            return CLLocation(coordinate: CLLocationCoordinate2D(latitude: stored[0], longitude: stored[1]), altitude: 0,
                              horizontalAccuracy: stored[3], verticalAccuracy: -1,
                              timestamp: Date(timeIntervalSince1970: stored[2]))
        }
        set {
            lastDistanceLocation = newValue
            if let newValue {
                UserDefaults.standard.set([newValue.coordinate.latitude, newValue.coordinate.longitude,
                                           newValue.timestamp.timeIntervalSince1970, newValue.horizontalAccuracy],
                                          forKey: "pathos.distanceAnchor")
            }
        }
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
        try? modelContainer.mainContext.save()
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
                lane: .alert,
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
            shown = liveActivities.isRunning(.context)
        } else {
            shown = await liveActivities.show(
                .init(mode: .spatialNote, title: note.title, subtitle: note.body, symbol: "mappin.and.ellipse", deepLink: link),
                lane: .alert,
                staleAfter: 3_600,
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
        case "mail":
            // Day's own switch, which remembers its place.
            UserDefaults.standard.set(DayViewMode.mail.rawValue, forKey: "pathos.dayViewMode")
            showDeck(.day)
        case "radar": showDeck(.radar)
        case "scan": beginScan()
        case "vault": showDeck(.vault)
        case "search": showDeck(.search)
        case "settings": isSettingsPresented = true
        case "ways":
            if let departure {
                showWays(to: departure.placeName, at: CLLocationCoordinate2D(latitude: departure.latitude, longitude: departure.longitude),
                         id: "departure:\(departure.id)", arriveBy: departure.start)
            }
        case "departure":
            // From the "still going?" notification: its buttons, or a tap to decide in the app.
            if let id = value("id") {
                switch path.first {
                case "drop": Task { await dropDeparture(id) }
                case "keep": keepDeparture(id)
                default: showDeck(.day)
                }
            }
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

    /// Opens the whole-journey options for a place: what to take, in what order, and what it costs.
    func showWays(to name: String, at coordinate: CLLocationCoordinate2D, id: String? = nil, arriveBy: Date? = nil) {
        waysRequest = WaysRequest(
            id: id ?? "place:\(name)",
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            arriveBy: arriveBy
        )
    }

    /// After a backup is put back: everything on screen is rebuilt from the restored store, and
    /// the geofences and reminders that were set for the old data are set again for the new.
    func reloadAfterRestore() async {
        selectedSignalID = nil
        endTrip()
        await vault.syncGeofences(userLocation: location.location)
        timetable.refreshReminders()
        eventStore.refreshReminders()
        trips.refreshReminders()
        await refreshDeparture()
        await refreshPinnedContext()
        showToast("Your data is back", symbol: "checkmark.circle.fill")
    }

    /// Shows a signal on the map: the deck gets out of the way and the map centres on it,
    /// selected, so pulling the deck up opens its card.
    func pointOut(_ signalID: String) {
        isPointingOut = true
        deckStop = .collapsed
        selectedSignalID = signalID
    }

    /// Switches the deck to `tab` and opens it so its content is visible.
    func showDeck(_ tab: AppTab) {
        selectedTab = tab
        selectedSignalID = nil
        deckStop = .full
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

        // Only what's in your day: mail you haven't added, or a poster you scanned, is a
        // suggestion, and reminding you of it as if it were a plan is what made reminders
        // arrive for sessions you'd never heard of.
        let here = location.location
        let dropped = droppedDepartureIDs
        let nextEvent = events.events
            .filter { $0.source.isInYourDay && !dropped.contains($0.id) }
            .compactMap { event -> AlertSnapshot.Event? in
                // An all-day event doesn't start at a time, so it never "starts in 5 min".
                guard !event.isAllDay, let start = event.start, start >= now else { return nil }
                let distance: Double? = if let here, let latitude = event.latitude, let longitude = event.longitude {
                    here.distance(from: CLLocation(latitude: latitude, longitude: longitude))
                } else {
                    nil
                }
                return AlertSnapshot.Event(id: event.id, title: event.title, start: start, latitude: event.latitude,
                                           longitude: event.longitude, distanceMeters: distance)
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
            // On the way already: "leave by" is for before you set off.
            departure: isTravelling ? nil : departure,
            way: tripStatus.flatMap { status in
                trip.map { trip in
                    let leg = trip.option.legs[min(status.legIndex, trip.option.legs.count - 1)]
                    return AlertSnapshot.Way(
                        destination: trip.destinationName,
                        headline: status.headline,
                        detail: status.detail,
                        symbol: status.symbol,
                        minutesBehind: status.minutesBehind,
                        minutesRemaining: status.minutesRemaining,
                        // Nothing to point at once you're where this leg ends.
                        target: isAt(leg.endCoordinate, within: TripGuide.radius(for: leg)) ? nil
                            : CompassTarget(id: "way:\(leg.id)", name: leg.endName,
                                            latitude: leg.endLatitude, longitude: leg.endLongitude),
                        // Re-routing is the banner's to say; the island keeps to when you'll arrive.
                        trafficNote: tripTraffic?.note,
                        isTrafficSlow: tripTraffic?.isSlow == true
                    )
                }
            },
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
            // How hard to try depends on what it is and on the last thing PathOS heard: a buzz
            // in traffic is easily missed, so an urgent one in a loud place says itself twice.
            let plan = AlertEscalation.plan(
                role: alert.role,
                heardNoise: SoundClassifier.lastHeard,
                repeatsUrgent: repeatsUrgentAlerts,
                isSpeaking: speaksDirections && trip != nil
            )
            // A question is asked once, with its answers on the notification.
            let droppable = alert.buttons.compactMap { button -> String? in
                if case .dropDeparture(let id) = button.action { return id } else { return nil }
            }.first
            notifications.post(
                id: "pathos.alert.\(alert.id)",
                title: alert.headline,
                body: alert.detail,
                category: droppable == nil ? NotificationService.Category.ambient : NotificationService.Category.stillGoing,
                link: droppable.flatMap { URL(string: "pathos://departure?id=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)") }
                    ?? URL(string: "pathos://dashboard"),
                timeSensitive: plan.isTimeSensitive,
                sound: haptics.shouldPlaySound,
                repeatAfter: droppable == nil ? plan.repeatAfter : nil
            )
            if plan.speaks {
                say("\(alert.headline). \(alert.detail)")
            }
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
        case .waysTo(let target):
            showWays(to: target.name, at: target.coordinate, id: target.id)
        case .endGuidance:
            compassTarget = nil
        case .endJourney:
            endJourney()
        case .endTrip:
            Task { await stopLegTracking(declined: true) }
        case .endWay:
            endTrip()
        case .bookCab(let target):
            CabLauncher.open(preferredCab, drop: target.coordinate, pickup: location.location?.coordinate)
        case .dropDeparture(let id):
            Task { await dropDeparture(id) }
        case .keepDeparture(let id):
            keepDeparture(id)
        }
    }

    // MARK: Not going after all

    /// Things you said you're not going to today: no more "leave now" or "you're late" for them.
    var droppedDepartureIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "pathos.droppedDepartures") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(60)), forKey: "pathos.droppedDepartures") }
    }

    /// Things you said you are still going to, so "still going?" isn't asked twice.
    var keptDepartureIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "pathos.keptDepartures") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(60)), forKey: "pathos.keptDepartures") }
    }

    func dropDeparture(_ id: String) async {
        droppedDepartureIDs.insert(id)
        dismissedAlertIDs.insert("leave.drop.\(id)")
        let title = departure?.id == id ? departure?.title : nil
        await notifications.removePending(withPrefix: "pathos.leave.\(id)")
        await refreshDeparture()
        await refreshPinnedContext()
        showToast(title.map { "Dropped \($0) for today" } ?? "Dropped for today", role: .you, symbol: "xmark.circle.fill")
    }

    func keepDeparture(_ id: String) {
        keptDepartureIDs.insert(id)
        dismissedAlertIDs.insert("leave.drop.\(id)")
        if departure?.id == id {
            departure?.isAskingToDrop = false
        }
    }

    /// Close enough to be at it, so there's nothing to point at and no way there to plan. Events
    /// and sessions use the wider radius: a college or an office is a campus, not a door.
    func isAt(_ coordinate: CLLocationCoordinate2D, within radius: Double = AppState.atPlaceRadius) -> Bool {
        guard let here = location.location else { return false }
        return here.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) <= radius
    }

    static let atPlaceRadius = 100.0
    /// The pointer is for the last stretch: it points at a spot you could walk to and find, which
    /// is the one thing a map can't do for you. Further than this, what you want is directions.
    static let pointerRange = 500.0

    /// Whether pointing at a place would tell you anything a route wouldn't tell you better.
    func pointerIsUseful(to coordinate: CLLocationCoordinate2D) -> Bool {
        guard let away = metres(to: coordinate) else { return false }
        return away > WorldSignalBuilder.hereRadius && away <= Self.pointerRange
    }

    /// Whether there is a journey to plan at all: anywhere PathOS doesn't already call "Here".
    func routeIsWorthIt(to coordinate: CLLocationCoordinate2D) -> Bool {
        guard let away = metres(to: coordinate) else { return true }
        return away > DoorToDoor.tooCloseToRoute
    }

    private func metres(to coordinate: CLLocationCoordinate2D) -> Double? {
        location.location.map { $0.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) }
    }

    /// A way, a metro journey or a trip leg is being followed: you've set off.
    var isTravelling: Bool {
        trip != nil || transit.journey != nil || trackedLegID != nil
    }

    // MARK: Journeys

    func startJourney(_ journey: Journey) {
        transit.start(journey)
        location.startUpdates()
        refreshBackgroundSession()
        startTravelLoop()
        // Getting to the first station is part of the journey, and the part you can be late for.
        Task { await followAlong(journey) }
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
        pinnedCompassTarget != nil || transit.journey != nil || trackedLegID != nil || trip != nil
    }

    /// Also stops location entirely when nothing needs it and PathOS isn't on screen, so a trip
    /// that ends in your pocket doesn't leave GPS running until you next open the app.
    func refreshBackgroundSession() {
        location.setBackgroundSessionActive(needsBackgroundLocation)
        if !isForeground && !needsBackgroundLocation {
            location.stopUpdates()
        }
    }

    /// One loop for everything that moves with you. It keeps running with the app in the
    /// background, where the old foreground-only loop couldn't: that's what lets "get off next"
    /// and trip arrivals fire with the phone in your pocket.
    func startTravelLoop() {
        guard travelTask == nil else { return }
        travelTask = Task {
            // A journey, a tracked leg, or a whole way being followed — a metro leg inside a trip
            // used to fall outside this, so its stops never advanced.
            while !Task.isCancelled, transit.journey != nil || trackedLegID != nil || trip != nil {
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
            lane: .journey,
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
        await liveActivities.showIfChanged(state, lane: .journey, staleAfter: 3_600, relevance: 95)
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

    /// Home or Work at a place you chose, rather than where you're standing: found in Search, or
    /// picked on the map.
    func setPlace(_ kind: PlaceKind, name: String, at coordinate: CLLocationCoordinate2D) async {
        vault.setPlace(kind, name: name, at: coordinate)
        await vault.syncGeofences(userLocation: location.location)
        if let here = location.location {
            await context.refresh(location: here, force: true)
        }
        // Travel times were to the old place.
        lastCommuteCheck = nil
        timetable.refreshReminders()
        haptics.success()
        showToast("\(kind.label): \(name)", symbol: kind.symbol)
    }

    /// Moves the map to put a pin on Home or Work; the deck steps down out of the way.
    func startPickingPlace(_ kind: PlaceKind) {
        selectedSignalID = nil
        searchSettingPlace = nil
        deckStop = .collapsed
        placePicking = kind
    }

    /// Sets the place being picked where the map's pin is, named after what's there if Apple Maps
    /// knows a place right under it.
    func finishPickingPlace() async {
        guard let kind = placePicking, let center = mapCenter else {
            placePicking = nil
            return
        }
        placePicking = nil
        let spot = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let nearest = await places.nearbyPOIs(around: spot).filter { $0.distanceMeters <= 60 }.min { $0.distanceMeters < $1.distanceMeters }
        await setPlace(kind, name: nearest?.name ?? kind.label, at: center)
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
        let shown = await liveActivities.show(compassState(for: target), lane: .pointer, staleAfter: 1_800, relevance: 70)
        compassTask?.cancel()
        compassTask = Task {
            while !Task.isCancelled, let target = pinnedCompassTarget {
                await liveActivities.updateThrottled(compassState(for: target), lane: .pointer)
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

    /// Travel time to Work, or Home from work: for Now, and for the pinned context around when
    /// you usually leave. Apple Maps is only asked again once you've moved or
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
        var car: Int?
        var transit: Int?
        var walk: Int?
        if let destination {
            let distance = here.distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
            car = await places.eta(to: destination.coordinate, from: here, transport: .automobile)
            transit = await places.eta(to: destination.coordinate, from: here, transport: .transit)
            // Nobody walks across the city, so it isn't asked for unless it's close.
            if distance < 3_000 || car == nil {
                walk = await places.eta(to: destination.coordinate, from: here, transport: .walking)
            }
        }

        commute = CommuteInfo(
            destinationName: destination?.name,
            destinationLatitude: destination?.latitude,
            destinationLongitude: destination?.longitude,
            carMinutes: car,
            transitMinutes: transit,
            walkMinutes: walk,
            updatedAt: Date()
        )
    }

    // MARK: Leaving on time

    /// Works out the next place you need to be today and whether to set off: a session of your
    /// weekly schedule, at Work, or an event with a place. Travel time is Apple Maps' from where
    /// you are, asked again once you've moved or a few minutes have passed.
    func refreshDeparture(now: Date = Date()) async {
        let dropped = droppedDepartureIDs
        guard let here = location.location,
              let next = LeaveOnTime.next(in: destinations(on: now).filter { !dropped.contains($0.id) }, now: now) else {
            departure = nil
            return
        }
        let destination = CLLocation(latitude: next.latitude, longitude: next.longitude)
        let distance = here.distance(from: destination)

        var minutes = 0
        var byRoad = distance > LeaveOnTime.walkingDistance
        if distance > LeaveOnTime.arrivalRadius {
            if let eta = departureETA, eta.id == next.id, here.distance(from: eta.from) < 250, now.timeIntervalSince(eta.at) < 5 * 60 {
                minutes = eta.minutes
                byRoad = eta.byRoad
            } else {
                minutes = await places.eta(to: destination.coordinate, from: here, transport: byRoad ? .automobile : .walking)
                    ?? LeaveOnTime.roughTravelMinutes(distance: distance)
                departureETA = (next.id, here, now, minutes, byRoad)
            }
        }

        // On your way: a fair bit closer than when last checked, until you head away again.
        var checkpoint: (id: String, meters: Double, isOnTheWay: Bool) =
            departureCheckpoint?.id == next.id ? departureCheckpoint! : (next.id, distance, false)
        if distance < checkpoint.meters - 150 {
            checkpoint = (next.id, distance, true)
        } else if distance > checkpoint.meters + 150 {
            checkpoint = (next.id, distance, false)
        }
        departureCheckpoint = checkpoint

        let status = LeaveOnTime.status(start: next.start, travel: TimeInterval(minutes * 60), distance: distance, now: now)
        // Following a way there is being on your way, whatever the distance says so far.
        let isOnTheWay = checkpoint.isOnTheWay || isTravelling
        departure = AlertSnapshot.Departure(
            id: next.id, title: next.title, placeName: next.placeName, start: next.start,
            travelMinutes: minutes, byRoad: byRoad, status: status, isOnTheWay: isOnTheWay,
            latitude: next.latitude, longitude: next.longitude,
            isAskingToDrop: LeaveOnTime.asksToDrop(status, isOnTheWay: isOnTheWay) && !keptDepartureIDs.contains(next.id)
        )
        scheduleLeaveReminders(for: departure!, now: now)
        guard !isTravelling else { return }
        await offerWays(to: next, travelMinutes: minutes, status: status, from: here, now: now)
    }

    /// How long you have in hand beyond the travel time before something starts. Past this, the
    /// notification saying the ways are ready would be too early to act on.
    static let waysMarginMinutes = 15
    /// How far ahead Getting around works out the ways to the next thing, so the card is ready
    /// when you look rather than when you're already late.
    static let waysLeadMinutes = 90

    /// The ways to the next place you need to be, worked out ahead of being asked for. Cached by
    /// `JourneyPlanner`, so this is cheap to call again.
    func planWaysToNext(now: Date = Date()) async {
        guard let departure, departure.status != .there, !isTravelling, let here = location.location,
              departure.start.timeIntervalSince(now) <= Double(Self.waysLeadMinutes) * 60 else { return }
        await journeys.options(
            key: "departure:\(departure.id)",
            to: CLLocationCoordinate2D(latitude: departure.latitude, longitude: departure.longitude),
            named: departure.placeName, from: here, now: now
        )
    }

    /// Close to the time you'd have to set off, the ways of getting there are worked out ahead of
    /// being asked for, and said once. Getting around then has them ready.
    private func offerWays(to next: LeaveOnTime.Destination, travelMinutes: Int, status: LeaveOnTime.Status,
                           from here: CLLocation, now: Date) async {
        let spare = Int(next.start.timeIntervalSince(now) / 60) - travelMinutes
        let key = "departure:\(next.id)"
        guard status != .there, spare <= Self.waysMarginMinutes, next.start > now.addingTimeInterval(-LeaveOnTime.lateGrace) else {
            if offeredWaysFor == next.id, spare > Self.waysMarginMinutes { offeredWaysFor = nil }
            return
        }
        let options = await journeys.options(key: key, to: next.coordinate, named: next.placeName, from: here, now: now)
        guard offeredWaysFor != next.id, let quickest = options.first(where: \.isAvailableNow) else { return }
        offeredWaysFor = next.id
        guard !isForeground else { return }
        await notifications.schedule(
            id: "pathos.ways.\(next.id)",
            at: now.addingTimeInterval(1),
            title: "Ways to \(next.placeName) are ready",
            body: "\(quickest.headline) · about \(quickest.minutes) min · \(quickest.fareText). \(next.title) starts at \(next.start.formatted(date: .omitted, time: .shortened)).",
            category: NotificationService.Category.tripLeg,
            link: URL(string: "pathos://ways"),
            timeSensitive: spare <= 0
        )
    }

    /// Today's sessions and events that happen somewhere.
    private func destinations(on day: Date) -> [LeaveOnTime.Destination] {
        guard let interval = Calendar.current.dateInterval(of: .day, for: day) else { return [] }
        let sessions = timetable.sessions(on: day).compactMap { session -> LeaveOnTime.Destination? in
            guard let latitude = session.latitude, let longitude = session.longitude else { return nil }
            return .init(id: "class:\(session.id)", title: session.subject, placeName: session.placeName ?? "Work",
                         start: session.start, end: session.end, latitude: latitude, longitude: longitude)
        }
        let events = eventStore.events(on: day).filter { !$0.isAllDay }.compactMap { event -> LeaveOnTime.Destination? in
            guard let latitude = event.latitude, let longitude = event.longitude else { return nil }
            return .init(id: "event:\(event.id.uuidString)", title: event.title, placeName: event.placeName ?? event.title,
                         start: event.start, end: event.end, latitude: latitude, longitude: longitude)
        }
        let mirrored = Set(eventStore.all().compactMap(\.calendarEventID))
        let calendar = CalendarEventSource.items(from: interval.start, to: interval.end, excluding: mirrored)
            .filter { !$0.isAllDay }
            .compactMap { item -> LeaveOnTime.Destination? in
                guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
                let place = item.location?.split(separator: "\n").first.map(String.init) ?? item.title
                return .init(id: "calendar:\(item.id)", title: item.title, placeName: place,
                             start: item.start, end: item.end, latitude: latitude, longitude: longitude)
            }
        return sessions + events + calendar
    }

    /// Notifications ten minutes before you need to leave and when it's time, so they come with
    /// PathOS closed. Cleared once you're there or it's already time.
    private func scheduleLeaveReminders(for departure: AlertSnapshot.Departure, now: Date) {
        let prefix = "pathos.leave.\(departure.id)"
        // Already set off: "time to leave" would only arrive while you're in the auto.
        if isTravelling {
            if scheduledLeaveBy?.id == departure.id {
                scheduledLeaveBy = nil
                Task { await notifications.removePending(withPrefix: prefix) }
            }
            return
        }
        let leaveBy: Date
        switch departure.status {
        case .inGoodTime(let at), .leaveSoon(let at):
            leaveBy = at
        case .there, .leaveNow, .late:
            if scheduledLeaveBy?.id == departure.id {
                scheduledLeaveBy = nil
                Task { await notifications.removePending(withPrefix: prefix) }
            }
            return
        }
        if let scheduled = scheduledLeaveBy, scheduled.id == departure.id, abs(scheduled.at.timeIntervalSince(leaveBy)) < 60 {
            return
        }
        scheduledLeaveBy = (departure.id, leaveBy)
        let starts = departure.start.formatted(date: .omitted, time: .shortened)
        let soon = leaveBy.addingTimeInterval(-10 * 60)
        if soon > now {
            notifications.schedule(
                id: prefix + ".soon", at: soon,
                title: "Leave in 10 min for \(departure.title)",
                body: "\(departure.travelText). It starts at \(starts).",
                category: NotificationService.Category.event, link: URL(string: "pathos://day"), timeSensitive: true
            )
        }
        notifications.schedule(
            id: prefix + ".now", at: leaveBy,
            title: "Time to leave for \(departure.title)",
            body: "\(departure.travelText). It starts at \(starts).",
            category: NotificationService.Category.event, link: URL(string: "pathos://day"), timeSensitive: true
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
            location.setSignificantChangesActive(location.hasAlwaysAccess)
        }
        return shown
    }

    func unpinContext() async {
        isContextPinned = false
        surfacedMemory = nil
        location.setSignificantChangesActive(location.hasAlwaysAccess)
        // Directions stay until they're done; only the context comes off.
        await liveActivities.end(.context)
    }

    /// Redraws the pinned context on its own card. Directions have a card of their own, so this
    /// no longer has to wait for them to finish.
    @discardableResult
    func refreshPinnedContext(now: Date = Date()) async -> Bool {
        guard isContextPinned else { return false }
        if context.venue.kind == .home, routine.todaysDeparture(now: now) != nil {
            await refreshCommute()
        }
        let content = LockScreenContext.content(for: lockScreenInputs(now: now))
        return await liveActivities.showIfChanged(content.state, lane: .context, staleDate: content.staleDate, relevance: 60)
    }

    /// Directions are done with their card: it comes off, and the context is redrawn in case it
    /// was holding back anything while they ran.
    private func releaseLockScreen(from mode: PathOSActivityAttributes.Mode) async {
        await liveActivities.end(.journey, ifMode: mode)
        await refreshPinnedContext()
    }

    /// On opening PathOS: unpins if you swiped the context off the Lock Screen, and otherwise
    /// puts it back if iOS ended it after its eight hours, or starts it afresh before it would.
    private func reconcilePinnedContext() async {
        guard isContextPinned else { return }
        if liveActivities.wasRemovedByYou(.context) {
            await unpinContext()
            return
        }
        await liveActivities.renewIfOld()
        await refreshPinnedContext()
    }

    /// A few hundred metres moved with PathOS in the background: the place, the weather, when to
    /// leave and the pinned context catch up, and anything newly urgent, such as running late,
    /// becomes a notification. Open, the foreground loop already does all this.
    private func movedInBackground(to here: CLLocation) async {
        guard !isForeground else { return }
        await context.refresh(location: here)
        await refreshDeparture()
        recordAttendance()
        await refreshTrip()
        await refreshPinnedContext()
        notifyNewAlerts()
    }

    private func lockScreenInputs(now: Date) -> LockScreenContext.Inputs {
        if let surfaced = surfacedMemory, now.timeIntervalSince(surfaced.at) > 15 * 60 {
            surfacedMemory = nil
        }
        var commuteLine: LockScreenContext.Commute?
        if context.venue.kind == .home, let usual = routine.todaysDeparture(now: now),
           let commute, let name = commute.destinationName,
           let headline = TravelTimes.headline(car: commute.carMinutes, transit: commute.transitMinutes, walk: commute.walkMinutes) {
            commuteLine = .init(destination: name, minutes: headline.minutes, mode: headline.mode, usualDeparture: usual)
        }
        return LockScreenContext.Inputs(
            venueName: context.venue.name ?? context.venue.kind.label,
            venueSymbol: context.venue.kind.symbol,
            weather: weather.snapshot.map {
                AlertSnapshot.Weather(temperatureC: $0.temperatureC, summary: $0.summary, symbol: $0.symbol, rainChanceNext2h: $0.rainChanceNext2h)
            },
            exitAdvice: context.exitAdvice,
            agenda: agenda(on: now).filter { !droppedDepartureIDs.contains($0.id) },
            // The journey has its own card, which says how it's going.
            departure: isTravelling ? nil : departure,
            commute: commuteLine,
            memory: surfacedMemory?.memory,
            now: now
        )
    }

    // MARK: Who turned up

    /// Things seen to be somewhere else while they were on. Kept for the session; the verdict is
    /// written down once the thing has finished.
    @ObservationIgnored private var seenAwayFrom: Set<String> = []

    /// Notes where you were against what your day held, so the day's count is of the things you
    /// went to rather than the things that were scheduled. Silence counts as having gone: the app
    /// being closed is not evidence of absence.
    func recordAttendance(now: Date = Date()) {
        let items = destinations(on: now)
        guard !items.isEmpty else { return }
        let log = todaysLog(for: now)
        let here = location.location?.coordinate
        let dropped = droppedDepartureIDs
        var attended = Set(log.attendedIDs)
        var missed = Set(log.missedIDs)
        let before = (attended, missed)

        for item in items {
            if item.start <= now, item.end > now {
                switch Attendance.sighting(at: here, of: item.coordinate) {
                case .there: attended.insert(item.id)
                case .away: seenAwayFrom.insert(item.id)
                case .unknown: break
                }
            } else if item.end <= now, !attended.contains(item.id), !missed.contains(item.id) {
                let verdict = Attendance.verdict(sawThere: false,
                                                 sawAway: seenAwayFrom.contains(item.id),
                                                 wasDropped: dropped.contains(item.id))
                if verdict == .missed {
                    missed.insert(item.id)
                }
            }
        }
        guard (attended, missed) != before else { return }
        log.attendedIDs = attended.sorted()
        log.missedIDs = missed.sorted()
        try? modelContainer.mainContext.save()
    }

    /// Putting PathOS right by hand: you were there, or you weren't.
    func setAttendance(_ id: String, attended: Bool, on day: Date) {
        let log = todaysLog(for: day)
        var went = Set(log.attendedIDs)
        var skipped = Set(log.missedIDs)
        if attended {
            went.insert(id)
            skipped.remove(id)
        } else {
            skipped.insert(id)
            went.remove(id)
        }
        log.attendedIDs = went.sorted()
        log.missedIDs = skipped.sorted()
        try? modelContainer.mainContext.save()
    }

    /// Today's classes, events and calendar entries, as the Day shows them.
    private func agenda(on day: Date) -> [LockScreenContext.Entry] {
        guard let interval = Calendar.current.dateInterval(of: .day, for: day) else { return [] }
        // The room, which is what you need at college; the college itself only when there's none.
        let classes = timetable.sessions(on: day).map {
            LockScreenContext.Entry(id: "class:\($0.id)", title: $0.subject, place: $0.room ?? $0.placeName,
                                    start: $0.start, end: $0.end, symbol: "calendar.day.timeline.left", role: .you)
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
        // The sensor comes back on the foreground loop once the answer has been spoken, not
        // straight after asking, which cut into the answer.
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
        say(answer)
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
        say(reply)
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
