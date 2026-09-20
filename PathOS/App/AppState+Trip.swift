import CoreLocation
import Foundation

/// A journey you said you'd make, and when you set off.
nonisolated struct ActiveTrip: Sendable {
    var option: DoorToDoor.Option
    var destinationName: String
    var startedAt: Date
    /// What you're heading for, when the journey was planned to reach somewhere by a time.
    var arriveBy: Date?

    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension AppState {

    // MARK: Making a journey

    /// Starts following a way to get somewhere: the Lock Screen carries the leg you're on, and
    /// PathOS says so when you fall behind it.
    func startTrip(_ option: DoorToDoor.Option, to name: String, at destination: CLLocationCoordinate2D, arriveBy: Date? = nil) {
        trip = ActiveTrip(option: option, destinationName: name, startedAt: Date(), arriveBy: arriveBy,
                          latitude: destination.latitude, longitude: destination.longitude)
        announcedTripLeg = nil
        announcedTripDelay = 0
        spokenMoments = []
        location.startUpdates()
        location.beginHeadingUpdates()
        refreshBackgroundSession()
        startNavigationLoop()
        // A metro leg inside the journey needs the travel loop too, or its stops never advance.
        startTravelLoop()
        Task { await refreshTrip() }
        showToast("Following your way to \(name)", symbol: option.legs.first?.mode.symbol ?? "point.topleft.down.to.point.bottomright.curvepath")
    }

    /// A metro or bus journey planned station to station is only part of getting there: if you
    /// aren't at the first station yet, reaching it is a leg of its own, and PathOS follows the
    /// whole thing so it can say you're behind before you've even boarded.
    func followAlong(_ journey: Journey) async {
        guard trip == nil, let here = location.location,
              let first = journey.stops.first, let last = journey.stops.last else { return }
        let toStation = here.distance(from: CLLocation(latitude: first.latitude, longitude: first.longitude))
        // Already at the station: the journey tracker follows the ride stop by stop on its own.
        guard toStation > TripGuide.stationRadius else { return }

        let byRoad = toStation > DoorToDoor.walkToStation
        let measured = await places.hop(to: first.coordinate, from: here, transport: byRoad ? .automobile : .walking)
        let hop = DoorToDoor.RoadHop(
            minutes: measured?.minutes ?? (byRoad ? LeaveOnTime.roughTravelMinutes(distance: toStation)
                                                  : GeoMath.walkingMinutes(forDistance: toStation)),
            distanceMeters: measured?.distanceMeters ?? toStation * 1.3
        )
        let access = byRoad
            ? DoorToDoor.roadLeg(hop, to: first.coordinate, name: first.name, now: Date(), title: "Auto to \(first.name)")
            : DoorToDoor.Leg(mode: .walk, title: "Walk to \(first.name)", detail: GeoMath.formatDistance(hop.distanceMeters),
                             minutes: hop.minutes, distanceMeters: hop.distanceMeters,
                             endName: first.name, endLatitude: first.latitude, endLongitude: first.longitude)
        let ride = DoorToDoor.Leg(
            mode: journey.kind == .metro ? .metro : .bus,
            title: "\(journey.lineName) to \(last.name)",
            detail: "\(journey.stops.count - 1) stops",
            minutes: max(1, Int(last.minutesFromStart.rounded())),
            distanceMeters: 0,
            endName: last.name,
            endLatitude: last.latitude,
            endLongitude: last.longitude
        )
        let option = DoorToDoor.Option(
            headline: "\(journey.lineName) from \(first.name)",
            legs: [access, ride],
            minutes: access.minutes + DoorToDoor.stationEntryMinutes + ride.minutes,
            fareLow: access.headlineFare?.estimate.low ?? 0,
            fareHigh: access.headlineFare?.estimate.high ?? 0
        )
        trip = ActiveTrip(option: option, destinationName: last.name, startedAt: Date(), arriveBy: nil,
                          latitude: last.latitude, longitude: last.longitude)
        announcedTripLeg = 0
        announcedTripDelay = 0
        await refreshTrip()
    }

    /// The stations of the ride you're on, for the map. Nil unless you're actually on it.
    var rideBeingFollowed: [JourneyStop]? {
        guard let trip, let status = tripStatus, !status.hasArrived else { return nil }
        let leg = trip.option.legs[min(status.legIndex, trip.option.legs.count - 1)]
        guard leg.mode == .metro || leg.mode == .bus else { return nil }
        if let journey = transit.journey { return journey.stops }
        guard let route = leg.metro else { return nil }
        return Journey.metro(route).stops
    }

    func endTrip() {
        let name = trip?.destinationName
        trip = nil
        tripStatus = nil
        tripNav = nil
        tripStep = nil
        navLegID = nil
        navigationTask?.cancel()
        navigationTask = nil
        offRouteSamples = 0
        spokenMoments = []
        speech.stop()
        location.setNavigating(false)
        announcedTripLeg = nil
        announcedTripDelay = 0
        if transit.journey != nil {
            transit.end()
        }
        location.endHeadingUpdates()
        refreshBackgroundSession()
        Task {
            await notifications.removePending(withPrefix: tripNotificationPrefix)
            await liveActivities.end(.journey)
            await refreshPinnedContext()
        }
        if let name {
            showToast("Stopped following the way to \(name)", symbol: "xmark.circle.fill")
        }
    }

    // MARK: Following it on the map

    /// Where you are along the leg you're on, worked out afresh from your latest position.
    ///
    /// Cheap on purpose: arithmetic over the route you already have, no network, so it can run on
    /// every fix. The turn on the map used to be recomputed on the twenty-second loop, which at
    /// city speeds meant "In 50 m, turn right" still on screen a street after the turn.
    func updateNavigationPosition(now: Date = Date()) {
        guard let trip, let here = location.location else { return }
        let status = TripGuide.status(for: trip.option, startedAt: trip.startedAt, now: now,
                                      location: here.coordinate)
        tripStatus = status
        guard let status, !status.hasArrived else { return }

        let leg = trip.option.legs[min(status.legIndex, trip.option.legs.count - 1)]
        // A ride is followed by its stations, not by turns.
        guard leg.mode != .metro, leg.mode != .bus else {
            tripStep = nil
            return
        }
        let position = tripNav.flatMap { StepGuide.position(in: $0.steps, at: here.coordinate) }
        tripStep = position

        // Noticing a wrong turn is part of following, so it's counted here on every fix rather
        // than on the slow loop, where three samples would have meant a minute of wrong turns.
        if tripNav == nil {
            offRouteSamples = 0
        } else {
            offRouteSamples = position?.isOffRoute == true ? offRouteSamples + 1 : 0
        }
        if offRouteSamples >= Self.offRouteSamplesBeforeReroute || tripNav == nil,
           now.timeIntervalSince(lastRouteFetch) >= Self.rerouteCooldown, !isFetchingRoute {
            Task { await refreshRoute(force: true) }
        }
        speakNextTurn(status: status, leg: leg)
    }

    /// The road route for the leg you're on, with its turns. One fetch per leg, and a fresh one
    /// only once you've really left the route — a wrong turn, not a wobble in the fix.
    func refreshRoute(force: Bool = false, now: Date = Date()) async {
        guard let trip, let status = tripStatus, let here = location.location else {
            tripNav = nil
            tripStep = nil
            return
        }
        let leg = trip.option.legs[min(status.legIndex, trip.option.legs.count - 1)]
        guard leg.mode != .metro, leg.mode != .bus else {
            tripNav = nil
            tripStep = nil
            navLegID = nil
            offRouteSamples = 0
            return
        }

        // A new leg is always routed; anything else waits for the fast loop to have seen you off
        // the road for several fixes running, and for the cooldown to have passed.
        let isNewLeg = navLegID != leg.id || tripNav == nil
        if !isNewLeg, !force { return }
        guard !isFetchingRoute, isNewLeg || now.timeIntervalSince(lastRouteFetch) >= Self.rerouteCooldown else { return }

        isFetchingRoute = true
        defer { isFetchingRoute = false }
        navLegID = leg.id
        lastRouteFetch = now
        offRouteSamples = 0
        tripNav = await places.directions(to: leg.endCoordinate, from: here, byRoad: leg.mode != .walk)
        tripStep = tripNav.flatMap { StepGuide.position(in: $0.steps, at: here.coordinate) }
    }

    /// Long enough that a wrong turn is re-routed once, not once a second.
    static let rerouteCooldown: TimeInterval = 10
    static let offRouteSamplesBeforeReroute = 3

    /// Where you've got to, what to do next, and whether the plan is slipping. Called on the
    /// foreground loop and on every background wake, so it keeps working in your pocket.
    func refreshTrip(now: Date = Date()) async {
        guard let trip else { return }
        let status = TripGuide.status(for: trip.option, startedAt: trip.startedAt, now: now,
                                      location: location.location?.coordinate)
        tripStatus = status
        guard let status else { return }

        if status.hasArrived {
            await announceTrip(title: "You've arrived", body: "\(trip.destinationName) · \(Int(now.timeIntervalSince(trip.startedAt) / 60)) min door to door", id: "arrived")
            endTrip()
            return
        }

        // The metro leg is followed stop by stop by the journey tracker, which knows about
        // changes and getting off; the trip hands over to it and takes back afterwards.
        let leg = trip.option.legs[status.legIndex]
        if leg.mode == .metro, let route = leg.metro {
            if transit.journey == nil {
                transit.start(Journey.metro(route, startedAt: now))
            }
        } else if transit.journey != nil {
            transit.end()
        }

        if announcedTripLeg != status.legIndex {
            announcedTripLeg = status.legIndex
            if status.legIndex > 0 {
                await announceTrip(title: status.headline, body: status.detail, id: "leg\(status.legIndex)")
            }
        }
        // Said once for each further five minutes lost, not every time it's noticed.
        let slipped = status.minutesBehind / 5
        if status.isBehind, slipped > announcedTripDelay {
            announcedTripDelay = slipped
            await announceTrip(
                title: "Running \(status.minutesBehind) min behind",
                body: lateBody(trip: trip, status: status),
                id: "late\(slipped)"
            )
        }
        await refreshRoute()
        await updateTripActivity()
    }

    /// The fast loop: where you are along the leg, once a second while you're looking at it, and
    /// every few seconds with the phone in your pocket. Everything costly — re-routing, alerts,
    /// the Lock Screen — stays on the slower loop or on a change worth reporting.
    func startNavigationLoop() {
        guard navigationTask == nil else { return }
        navigationTask = Task { [weak self] in
            while !Task.isCancelled, self?.trip != nil {
                guard let self else { return }
                updateNavigationPosition()
                location.setNavigating(isNavigatingByRoad)
                try? await Task.sleep(for: .seconds(isForeground ? 1 : 5))
            }
            self?.navigationTask = nil
            self?.location.setNavigating(false)
        }
    }

    /// The map is leading you somewhere: a way is being followed and you haven't arrived.
    /// The banner, the control rail and the camera all read this, so they can't disagree.
    var isLeadingTheWay: Bool {
        trip != nil && tripStatus?.hasArrived == false
    }

    /// Following a leg you travel along a road for, as against waiting on a platform.
    var isNavigatingByRoad: Bool {
        guard let trip, let status = tripStatus, !status.hasArrived else { return false }
        let leg = trip.option.legs[min(status.legIndex, trip.option.legs.count - 1)]
        return leg.mode != .metro && leg.mode != .bus
    }

    /// Says the turn coming up, once, and the handover to the next leg. Silent when muted.
    private func speakNextTurn(status: TripGuide.Status, leg: DoorToDoor.Leg) {
        guard speaksDirections, let position = tripStep, let nav = tripNav else { return }
        let step = nav.steps[safe: position.stepIndex]
        let announcement = NavigationVoice.announcement(
            step: step,
            stepIndex: position.stepIndex,
            metresToStep: position.metresToStep,
            legIndex: status.legIndex,
            legInstruction: TripGuide.instruction(for: leg),
            isBehind: status.isBehind,
            minutesBehind: status.minutesBehind,
            hasSaidLeg: spokenMoments.contains(.handover(leg: status.legIndex)),
            said: spokenMoments
        )
        guard let announcement else { return }
        spokenMoments.insert(announcement.moment)
        speech.speak(announcement.text)
    }

    /// "You should be at Jayadeva Hospital by now. Next: ride to BTM Layout." Where the journey
    /// was for something with a start time, it says what that now means for it.
    private func lateBody(trip: ActiveTrip, status: TripGuide.Status) -> String {
        var parts = [status.detail]
        if let arriveBy = trip.arriveBy {
            let arrival = Date().addingTimeInterval(TimeInterval(status.minutesRemaining * 60))
            if arrival > arriveBy {
                let late = Int(arrival.timeIntervalSince(arriveBy) / 60)
                parts.append("You'd reach \(trip.destinationName) about \(late) min after it starts.")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func announceTrip(title: String, body: String, id: String) async {
        guard !isForeground else {
            haptics.alert()
            return
        }
        await notifications.schedule(
            id: "\(tripNotificationPrefix)\(id)",
            at: Date().addingTimeInterval(1),
            title: title,
            body: body,
            category: NotificationService.Category.tripLeg,
            link: URL(string: "pathos://dashboard"),
            timeSensitive: true
        )
    }

    /// The leg you're on, on the Lock Screen. The metro's own stop-by-stop activity takes over
    /// while you're on the train.
    func updateTripActivity() async {
        guard let trip, let status = tripStatus, transit.journey == nil else { return }
        await liveActivities.showIfChanged(
            .init(
                mode: .journey,
                title: status.headline,
                subtitle: status.detail,
                symbol: status.symbol,
                etaMinutes: status.minutesRemaining,
                deepLink: URL(string: "pathos://dashboard"),
                notes: [.init(symbol: "flag.checkered", text: "To \(trip.destinationName)", role: .you)],
                role: status.isBehind ? .attention : .you
            ),
            lane: .journey,
            staleAfter: 1_800,
            relevance: status.isBehind ? 96 : 94
        )
    }

    var tripNotificationPrefix: String { "pathos.trip." }
}
