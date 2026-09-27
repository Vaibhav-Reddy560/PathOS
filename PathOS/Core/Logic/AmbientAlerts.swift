import Foundation

/// One thing the island can say. The first alert in priority order is what the island shows.
nonisolated struct AmbientAlert: Identifiable, Equatable, Sendable {
    nonisolated enum Action: Hashable, Sendable {
        case requestLocation
        case openSettings
        case pointTo(CompassTarget)
        /// The ways of actually getting there, which is what a place you aren't at needs.
        case waysTo(CompassTarget)
        case endGuidance
        case endJourney
        case endTrip
        /// Stop following a whole way to somewhere.
        case endWay
        /// Your preferred cab, to there.
        case bookCab(CompassTarget)
        /// You're not going after all: stop reminding you about it today.
        case dropDeparture(String)
        /// You are still going: stop asking.
        case keepDeparture(String)
    }

    /// Only things the alert itself can do. A button that just opened a deck screen read as an
    /// action and did nothing of the kind, so alerts don't carry them.
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

    /// The weather and where you are: always true, so never news. The deck shows both too.
    var isBackground: Bool { id == "weather" || id == "idle" }
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

    /// The whole way you're making to somewhere, of which a metro ride may be one leg.
    nonisolated struct Way: Sendable {
        var destination: String
        var headline: String
        var detail: String
        var symbol: String
        var minutesBehind: Int
        var minutesRemaining: Int
        /// Where the leg you're on ends, so the island can point you at it.
        var target: CompassTarget?
        /// What the traffic is doing, from Apple Maps' live times: "Heavy traffic · +7 min".
        var trafficNote: String? = nil
        var isTrafficSlow = false
    }

    nonisolated struct Event: Sendable {
        var id: String
        var title: String
        var start: Date
        var latitude: Double?
        var longitude: Double?
        /// How far you are from it now, when both are known.
        var distanceMeters: Double? = nil
    }

    /// The next place you need to be, and whether to set off. See `LeaveOnTime`.
    nonisolated struct Departure: Sendable {
        var id: String
        var title: String
        var placeName: String
        var start: Date
        var travelMinutes: Int
        /// By road; on foot otherwise.
        var byRoad: Bool
        var status: LeaveOnTime.Status
        /// Getting closer since the last checks: in good time, there's nothing to say.
        var isOnTheWay: Bool
        var latitude: Double
        var longitude: Double
        /// Far too late to make it and not setting off: time to ask whether you're still going,
        /// rather than remind you again.
        var isAskingToDrop = false

        /// "25 min by road to BMS College".
        var travelText: String {
            "\(travelMinutes) min \(byRoad ? "by road" : "on foot") to \(placeName)"
        }
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
    var nextEvent: Event?
    var departure: Departure? = nil
    var way: Way? = nil
    var weather: Weather?
    var venueName: String
    var venueSymbol: String
    var now: Date
}

nonisolated enum AmbientAlerts {
    /// Events starting this soon get an amber alert.
    static let eventSoonWindow: TimeInterval = 30 * 60

    /// Nothing worth a glance: the island rests on PathOS's name, and the background alerts wait
    /// in its expanded list until something takes the name's place.
    static func isQuiet(_ alerts: [AmbientAlert]) -> Bool {
        alerts.first?.isBackground ?? true
    }

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

        let leaving = snapshot.departure.flatMap(departureAlert)
        if let leaving {
            alerts.append(leaving)
        }

        // When to leave for it says more than that it starts soon; the one alert does.
        if let event = snapshot.nextEvent,
           leaving == nil || !(snapshot.departure?.title == event.title && snapshot.departure?.start == event.start) {
            let untilStart = event.start.timeIntervalSince(snapshot.now)
            let minutes = Int((untilStart / 60).rounded(.up))
            if untilStart >= 0 && untilStart <= eventSoonWindow {
                var buttons: [AmbientAlert.Button] = []
                if let target = target(for: event) {
                    buttons.append(AmbientAlert.Button(title: "Take me there", symbol: "arrow.triangle.turn.up.right.diamond.fill",
                                                       action: .waysTo(target), isPrimary: true))
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
                    detail: "Today at \(event.start.formatted(date: .omitted, time: .shortened))."
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
        if let way = snapshot.way, snapshot.journey == nil {
            let behind = way.minutesBehind >= TripGuide.lateAfterMinutes
            let arrival = snapshot.now.addingTimeInterval(Double(way.minutesRemaining) * 60)
                .formatted(date: .omitted, time: .shortened)
            // The island says what the turn banner doesn't: when you'll be there, and what the
            // traffic is doing to that, as it changes.
            alerts.append(AmbientAlert(
                id: "way",
                role: behind || way.isTrafficSlow ? .attention : .you,
                priority: behind || way.isTrafficSlow ? 9 : 19,
                symbol: way.isTrafficSlow ? "car.rear.and.tire.marks" : way.symbol,
                compactText: way.trafficNote ?? "Arrive \(arrival)",
                // The minutes are on the turn banner under it; the island adds when, not how long.
                metric: nil,
                headline: way.headline,
                detail: ([way.trafficNote].compactMap { $0 } + ["\(way.detail). To \(way.destination)."]).joined(separator: " · "),
                buttons: [
                    way.target.map { AmbientAlert.Button(title: "Point me there", symbol: "location.north.line.fill", action: .pointTo($0)) },
                    AmbientAlert.Button(title: "Stop", symbol: "xmark", action: .endWay),
                ].compactMap { $0 },
                isDismissible: false
            ))
        }

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
                detail: "\(weather.rainChanceNext2h)% chance of rain in the next 2 hours."
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

    /// Leave by, leave now, or running late; nothing once you're there, or on your way in good time.
    static func departureAlert(_ departure: AlertSnapshot.Departure) -> AmbientAlert? {
        let starts = departure.start.formatted(date: .omitted, time: .shortened)
        let target = CompassTarget(id: "leave:\(departure.id)", name: departure.placeName,
                                   latitude: departure.latitude, longitude: departure.longitude)
        let ways = [
            AmbientAlert.Button(title: "Take me there", symbol: "arrow.triangle.turn.up.right.diamond.fill",
                                action: .waysTo(target), isPrimary: true),
            AmbientAlert.Button(title: "Book a cab", symbol: "car.fill", action: .bookCab(target)),
        ]
        switch departure.status {
        case .there, .inGoodTime:
            return nil
        case .leaveSoon(let leaveBy):
            guard !departure.isOnTheWay else { return nil }
            let time = leaveBy.formatted(date: .omitted, time: .shortened)
            return AmbientAlert(
                id: "leave.soon.\(departure.id)",
                role: .you,
                priority: 18,
                symbol: "figure.walk.departure",
                compactText: "Leave by \(time)",
                metric: "\(departure.travelMinutes) min",
                headline: "Leave by \(time) for \(departure.title)",
                detail: "\(departure.travelText). It starts at \(starts)."
            )
        case .leaveNow:
            guard !departure.isOnTheWay else { return nil }
            return AmbientAlert(
                id: "leave.now.\(departure.id)",
                role: .attention,
                priority: 8,
                symbol: "figure.walk.departure",
                compactText: "Leave now for \(departure.title)",
                metric: "\(departure.travelMinutes) min",
                headline: "Leave now for \(departure.title)",
                detail: "\(departure.travelText). It starts at \(starts).",
                buttons: ways
            )
        case .late(_, let minutes) where departure.isAskingToDrop:
            // Reminding again won't help: you're this late and haven't set off. Asked once.
            return AmbientAlert(
                id: "leave.drop.\(departure.id)",
                role: .attention,
                priority: 7,
                symbol: "questionmark.circle.fill",
                compactText: "Still going to \(departure.title)?",
                metric: "+\(minutes) min",
                headline: "Still going to \(departure.title)?",
                detail: "You'd be about \(minutes) min late and haven't set off. Drop it and PathOS stops reminding you today.",
                buttons: [
                    AmbientAlert.Button(title: "Drop it", symbol: "xmark.circle", action: .dropDeparture(departure.id), isPrimary: true),
                    AmbientAlert.Button(title: "I'm going", symbol: "figure.walk.departure", action: .keepDeparture(departure.id)),
                ]
            )
        case .late(_, let minutes):
            return AmbientAlert(
                id: "leave.late.\(departure.id)",
                role: .attention,
                priority: 7,
                symbol: "clock.badge.exclamationmark",
                compactText: "Running late",
                metric: "+\(minutes) min",
                headline: "You'll be about \(minutes) min late for \(departure.title)",
                detail: "\(departure.travelText) from here, and it starts at \(starts).",
                buttons: ways
            )
        }
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
        // Already there: nothing to point at.
        if let distance = event.distanceMeters, distance <= LeaveOnTime.arrivalRadius { return nil }
        return CompassTarget(id: event.id, name: event.title, latitude: latitude, longitude: longitude)
    }
}
