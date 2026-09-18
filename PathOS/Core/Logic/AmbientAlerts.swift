import Foundation

/// One thing the island can say. The first alert in priority order is what the island shows.
nonisolated struct AmbientAlert: Identifiable, Equatable, Sendable {
    nonisolated enum Action: Hashable, Sendable {
        case requestLocation
        case openSettings
        case startCommute
        case showNow
        case showRadar
        case pointTo(CompassTarget)
        case endGuidance
        case endJourney
        case endTrip
    }

    nonisolated struct Button: Hashable, Sendable {
        var title: String
        var symbol: String
        var action: Action
        /// The one green action; others are plain glass.
        var isPrimary = false
    }

    var id: String
    var role: SignalRole
    /// Lower comes first.
    var priority: Int
    var symbol: String
    /// A few words for the compact capsule.
    var compactText: String
    /// Monospaced readout on the capsule's trailing edge.
    var metric: String?
    var headline: String
    var detail: String
    var buttons: [Button] = []
    var isDismissible = true
}

/// Plain values the alert rules read, so they can be tested without the app running.
nonisolated struct AlertSnapshot: Sendable {
    nonisolated enum LocationAccess: Sendable {
        case notDetermined
        case whenInUse
        case always
        case denied
    }

    nonisolated struct Guidance: Sendable {
        var target: CompassTarget
        var distanceMeters: Double?
        var needsCalibration: Bool
    }

    nonisolated struct Journey: Sendable {
        var destination: String
        var lineName: String
        var stopsRemaining: Int
        var minutesRemaining: Int
        var isArrivingNext: Bool
        var symbol = "tram.fill"
        /// Where the next change is and what to do there, when it's the next stop.
        var changeStation: String? = nil
        var changeInstruction: String? = nil
    }

    nonisolated struct Trip: Sendable {
        var title: String
        var destination: String
        var symbol: String
        var summary: String
        var minutesRemaining: Int?
        var isLate: Bool
    }

    nonisolated struct Commute: Sendable {
        var destinationName: String?
        var minutes: Int?
    }

    nonisolated struct Event: Sendable {
        var id: String
        var title: String
        var start: Date
        var latitude: Double?
        var longitude: Double?
    }

    nonisolated struct Weather: Sendable {
        var temperatureC: Double
        var summary: String
        var symbol: String
        var rainChanceNext2h: Int
    }

    var location: LocationAccess
    var exitAdvice: ExitAdvice?
    var pressureTrend: PressureTrend
    var guidance: Guidance?
    var journey: Journey?
    var trip: Trip? = nil
    var commute: Commute?
    var nextEvent: Event?
    var weather: Weather?
    var venueName: String
    var venueSymbol: String
    var now: Date
}

nonisolated enum AmbientAlerts {
    /// Events starting this soon get an amber alert.
    static let eventSoonWindow: TimeInterval = 30 * 60

    static func prioritized(_ snapshot: AlertSnapshot, dismissed: Set<String> = []) -> [AmbientAlert] {
        var alerts: [AmbientAlert] = []

        // Critical: PathOS can't work.
        if snapshot.location == .denied {
            alerts.append(AmbientAlert(
                id: "location.denied",
                role: .critical,
                priority: 0,
                symbol: "location.slash.fill",
                compactText: "Location is off",
                headline: "PathOS can't see where you are",
                detail: "Turn on location in Settings → PathOS → Location. The map, geofences and guidance need it.",
                buttons: [AmbientAlert.Button(title: "Open Settings", symbol: "gear", action: .openSettings)],
                isDismissible: false
            ))
        }

        // Attention.
        if let advice = snapshot.exitAdvice {
            alerts.append(AmbientAlert(
                id: "exit.advice",
                role: .attention,
                priority: 10,
                symbol: advice.symbol,
                compactText: shortHeadline(advice.headline),
                metric: snapshot.weather.map { "\($0.rainChanceNext2h)%" },
                headline: advice.headline,
                detail: advice.detail
            ))
        } else if snapshot.pressureTrend.isRapidDrop {
            alerts.append(AmbientAlert(
                id: "pressure.drop",
                role: .attention,
                priority: 11,
                symbol: "barometer",
                compactText: "Pressure dropping fast",
                headline: "Pressure dropping fast",
                detail: "\(snapshot.pressureTrend.label). The weather may turn soon."
            ))
        }

        if let event = snapshot.nextEvent {
            let untilStart = event.start.timeIntervalSince(snapshot.now)
            let minutes = Int((untilStart / 60).rounded(.up))
            if untilStart >= 0 && untilStart <= eventSoonWindow {
                var buttons: [AmbientAlert.Button] = []
                if let target = target(for: event) {
                    buttons.append(AmbientAlert.Button(title: "Point me there", symbol: "location.north.line.fill", action: .pointTo(target), isPrimary: true))
                }
                alerts.append(AmbientAlert(
                    id: "event.soon.\(event.id)",
                    role: .attention,
                    priority: 12,
                    symbol: "ticket.fill",
                    compactText: event.title,
                    metric: "\(minutes) min",
                    headline: "\(event.title) starts in \(minutes) min",
                    detail: "Starts at \(event.start.formatted(date: .omitted, time: .shortened)).",
                    buttons: buttons
                ))
            } else if untilStart > eventSoonWindow, Calendar.current.isDate(event.start, inSameDayAs: snapshot.now) {
                alerts.append(AmbientAlert(
                    id: "event.today.\(event.id)",
                    role: .world,
                    priority: 30,
                    symbol: "ticket.fill",
                    compactText: event.title,
                    metric: event.start.formatted(date: .omitted, time: .shortened),
                    headline: event.title,
                    detail: "Today at \(event.start.formatted(date: .omitted, time: .shortened)).",
                    buttons: [AmbientAlert.Button(title: "Show Radar", symbol: "dot.radiowaves.left.and.right", action: .showRadar)]
                ))
            }
        }

        if let guidance = snapshot.guidance, guidance.needsCalibration {
            alerts.append(AmbientAlert(
                id: "guidance.calibrate",
                role: .attention,
                priority: 13,
                symbol: "gyroscope",
                compactText: "Calibrate compass",
                headline: "Compass needs calibrating",
                detail: "Wave your iPhone in a figure-8 until the arrow settles."
            ))
        }

        if snapshot.location == .notDetermined {
            alerts.append(AmbientAlert(
                id: "location.ask",
                role: .attention,
                priority: 14,
                symbol: "location.fill",
                compactText: "Allow location",
                headline: "Let PathOS see where you are",
                detail: "Your location stays on this iPhone. It powers the map, geofences and guidance.",
                buttons: [AmbientAlert.Button(title: "Allow", symbol: "location.fill", action: .requestLocation, isPrimary: true)],
                isDismissible: false
            ))
        }

        if let journey = snapshot.journey {
            let changingNext = journey.changeStation != nil
            let actNow = journey.isArrivingNext || changingNext
            alerts.append(AmbientAlert(
                id: "journey",
                role: actNow ? .attention : .you,
                // Getting off or changing at the right stop matters more than anything else en route.
                priority: actNow ? 9 : 19,
                symbol: changingNext ? "arrow.triangle.swap" : journey.symbol,
                compactText: journey.isArrivingNext ? "Get off next" : (changingNext ? "Change next" : "To \(journey.destination)"),
                metric: actNow ? nil : "\(journey.stopsRemaining) stops",
                headline: journey.isArrivingNext
                    ? "Get off next: \(journey.destination)"
                    : (journey.changeStation.map { "Change next: \($0)" } ?? "\(journey.lineName) to \(journey.destination)"),
                detail: journey.isArrivingNext
                    ? "About \(journey.minutesRemaining) min to go."
                    : (journey.changeInstruction.map { "\($0)." } ?? "\(journey.stopsRemaining) stops · about \(journey.minutesRemaining) min (estimated)."),
                buttons: [AmbientAlert.Button(title: "End", symbol: "xmark", action: .endJourney)],
                isDismissible: false
            ))
        }

        if let trip = snapshot.trip {
            alerts.append(AmbientAlert(
                id: "trip",
                role: trip.isLate ? .attention : .you,
                priority: trip.isLate ? 12 : 19,
                symbol: trip.symbol,
                compactText: "To \(trip.destination)",
                metric: trip.minutesRemaining.map { "\($0) min" },
                headline: trip.title,
                detail: trip.summary,
                buttons: [AmbientAlert.Button(title: "End", symbol: "xmark", action: .endTrip)],
                isDismissible: false
            ))
        }

        // You: what you're doing right now.
        if let guidance = snapshot.guidance {
            alerts.append(AmbientAlert(
                id: "guidance",
                role: .you,
                priority: 20,
                symbol: "location.north.line.fill",
                compactText: guidance.target.name,
                metric: guidance.distanceMeters.map(GeoMath.formatDistance),
                headline: "Guiding you to \(guidance.target.name)",
                detail: guidance.distanceMeters.map { "\(GeoMath.formatDistance($0)) away · about \(GeoMath.walkingMinutes(forDistance: $0)) min walk." } ?? "Finding your location…",
                buttons: [AmbientAlert.Button(title: "End", symbol: "xmark", action: .endGuidance)],
                isDismissible: false
            ))
        }

        if let commute = snapshot.commute {
            alerts.append(AmbientAlert(
                id: "commute",
                role: .you,
                priority: 21,
                symbol: "tram.fill",
                compactText: commute.destinationName.map { "To \($0)" } ?? "Commute",
                metric: commute.minutes.map { "\($0) min" },
                headline: commute.destinationName.map { "Commute to \($0)" } ?? "Commute",
                detail: commute.minutes.map { "About \($0) min door to door." } ?? "Route unavailable · cabs one tap away.",
                buttons: [AmbientAlert.Button(title: "Details", symbol: "list.bullet", action: .showNow)]
            ))
        }

        // World: the ambient default.
        if let weather = snapshot.weather {
            alerts.append(AmbientAlert(
                id: "weather",
                role: .world,
                priority: 31,
                symbol: weather.symbol,
                compactText: weather.summary,
                metric: "\(Int(weather.temperatureC.rounded()))°",
                headline: "\(weather.summary), \(Int(weather.temperatureC.rounded()))°C",
                detail: "\(weather.rainChanceNext2h)% chance of rain in the next 2 hours.",
                buttons: [AmbientAlert.Button(title: "Environment", symbol: "cloud.sun", action: .showNow)]
            ))
        }

        alerts.append(AmbientAlert(
            id: "idle",
            role: .world,
            priority: 40,
            symbol: snapshot.venueSymbol,
            compactText: snapshot.venueName,
            headline: snapshot.venueName,
            detail: "PathOS is watching the way.",
            isDismissible: false
        ))

        return alerts
            .filter { !$0.isDismissible || !dismissed.contains($0.id) }
            .sorted { $0.priority < $1.priority }
    }

    /// Alerts worth interrupting for that weren't already announced. Anything still present
    /// from the last check stays quiet, so a rainy afternoon doesn't buzz every half hour.
    static func notifiable(previous: Set<String>, current: [AmbientAlert]) -> [AmbientAlert] {
        current.filter { interrupts($0) && !previous.contains($0.id) }
    }

    /// What to remember as "already announced" after a check.
    static func announcedIDs(_ alerts: [AmbientAlert]) -> Set<String> {
        Set(alerts.filter(interrupts).map(\.id))
    }

    private static func interrupts(_ alert: AmbientAlert) -> Bool {
        alert.role == .attention || alert.role == .critical
    }

    /// "Rain likely — take an umbrella" → "Rain likely".
    static func shortHeadline(_ headline: String) -> String {
        headline.components(separatedBy: " — ").first ?? headline
    }

    private static func target(for event: AlertSnapshot.Event) -> CompassTarget? {
        guard let latitude = event.latitude, let longitude = event.longitude else { return nil }
        return CompassTarget(id: event.id, name: event.title, latitude: latitude, longitude: longitude)
    }
}
