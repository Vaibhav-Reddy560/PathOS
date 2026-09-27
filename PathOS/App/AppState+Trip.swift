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

/// What live traffic is doing to the leg you're on.
nonisolated struct TripTraffic: Equatable, Sendable {
    /// Minutes more than the plan allowed for this leg; negative when it's clearer than expected.
    var delayMinutes: Int
    /// "Heavy traffic · +7 min", "Faster route · saves 4 min", or nil when there's nothing to say.
    var note: String?
    /// When it was worked out.
    var at: Date

    var isSlow: Bool { delayMinutes >= TripTraffic.worthSaying }

    /// Less than this either way is ordinary.
    static let worthSaying = 4
}

/// How the traffic runs along the route you're on, in stretches of it.
nonisolated struct TripFlow: Equatable, Sendable {
    /// The route these stretches were measured on.
    var routeID: UUID
    var bands: [RouteTraffic.Band]
    var at: Date

    /// The stretches, but only while they still belong to the route on screen. A re-route brings
    /// a new route with a new id, so old colours can't survive it.
    func shown(on route: NavRoute?) -> [RouteTraffic.Band] {
        route?.id == routeID ? bands : []
    }
}

extension AppState {

    // MARK: Making a journey

    /// Starts following a way to get somewhere: the Lock Screen carries the leg you're on, and
    /// PathOS says so when you fall behind it.
    func startTrip(_ option: DoorToDoor.Option, to name: String, at destination: CLLocationCoordinate2D, arriveBy: Date? = nil) {
        let startedAt = Date()
        trip = ActiveTrip(option: option, destinationName: name, startedAt: startedAt, arriveBy: arriveBy,
                          latitude: destination.latitude, longitude: destination.longitude)
        // The map that leads you needs both of these, and both used to arrive a frame or two later:
        // the browsing map showed instead, with its own marker and rings, and then vanished.
        tripStatus = TripGuide.status(for: option, startedAt: startedAt, now: startedAt,
                                      location: location.location?.coordinate)
        deckStop = .collapsed
        announcedTripLeg = nil
        announcedTripDelay = 0
        spokenMoments = []
        // Set off: any "time to leave" still waiting would only arrive on the way.
        Task { await notifications.removePending(withPrefix: "pathos.leave.") }
        location.startUpdates()
        location.beginHeadingUpdates()
        // A road can't be drawn from a position given to the nearest few kilometres.
        Task { await location.requestFullAccuracy() }
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
        tripMatch = nil
        tripTrim = nil
        tripTraffic = nil
        tripFlow = nil
        isRerouting = false
        navLegID = nil
        lastTripActivityStep = nil
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
    /// Cheap on purpose: arithmetic over the route you already have, no network, so it runs on
    /// every fix — once a second on screen, every few seconds in your pocket. Everything that has
    /// to happen *when* something changes happens here too, the moment it's seen: reaching the
    /// end of a leg, arriving, leaving the route. Those used to wait for a twenty-second loop, or
    /// in your pocket for a wake that came minutes later.
    func updateNavigationPosition(now: Date = Date()) {
        guard let trip, let here = location.location else { return }
        // Fixes and the loop both ask. Coalesced, so a fix landing just after a tick doesn't repeat
        // the work, and the background keeps its slower pace.
        guard now.timeIntervalSince(lastNavigationUpdate) >= (isForeground ? 0.2 : 5) else { return }
        lastNavigationUpdate = now
        guard var status = TripGuide.status(for: trip.option, startedAt: trip.startedAt, now: now,
                                            location: here.coordinate) else { return }
        let leg = trip.option.legs[min(status.legIndex, trip.option.legs.count - 1)]
        let isRoad = leg.mode != .metro && leg.mode != .bus

        // Where you are on the route, and what's left of it at the traffic's pace.
        if isRoad, !status.hasArrived, let nav = tripNav, navLegID == leg.id {
            let match = RouteProgress.match(nav.coordinates, at: here.coordinate, after: tripMatch)
            tripMatch = match
            tripTrim = match.map { RouteTrim.Anchor(fraction: $0.fraction, at: here.timestamp,
                                                    metresPerSecond: max(0, here.speed), routeMetres: $0.total) }
            tripStep = StepGuide.position(in: nav.steps, at: here.coordinate, near: tripStep?.stepIndex)
            if let match {
                status = liveAdjusted(status, trip: trip, now: now)
                // A wrong turn, or heading the wrong way down the route: seen within a couple of
                // fixes, not after a minute.
                let isOff = match.offset > RouteProgress.offRouteMetres(accuracy: here.horizontalAccuracy)
                    || RouteProgress.isHeadingAway(course: location.courseDegrees, speed: here.speed, along: nav.coordinates, at: match)
                offRouteSamples = isOff ? offRouteSamples + 1 : 0
            }
        } else if !isRoad {
            tripStep = nil
            tripMatch = nil
            tripTrim = nil
        }

        let previous = tripStatus
        tripStatus = status

        // A leg finished, or the whole way: handled now, not on the next slow pass.
        let justArrived = status.hasArrived && previous?.hasArrived != true
        if justArrived || (!status.hasArrived && previous.map({ $0.legIndex != status.legIndex }) == true) {
            Task { await refreshTrip(now: now) }
            return
        }
        guard isRoad, !status.hasArrived else { return }

        if tripNav == nil || navLegID != leg.id || offRouteSamples >= Self.offRouteSamplesBeforeReroute {
            if offRouteSamples >= Self.offRouteSamplesBeforeReroute { isRerouting = true }
            if !isFetchingRoute, now.timeIntervalSince(lastRouteFetch) >= Self.rerouteCooldown || navLegID != leg.id {
                Task { await refreshRoute(force: true) }
            }
        } else if now.timeIntervalSince(lastTrafficCheck) >= Self.trafficCheckInterval, !isFetchingRoute, leg.mode != .walk {
            lastTrafficCheck = now
            Task { await checkTraffic(for: leg) }
        }

        speakNextTurn(status: status, leg: leg)

        // The Lock Screen, kept as current as the map: at once when the turn changes, and every
        // few seconds otherwise.
        let stepChanged = tripStep?.stepIndex != lastTripActivityStep
        if stepChanged || now.timeIntervalSince(lastTripActivityUpdate) >= (isForeground ? 5 : 10) {
            lastTripActivityUpdate = now
            lastTripActivityStep = tripStep?.stepIndex
            Task { await updateTripActivity() }
        }
    }

    /// The road route for the leg you're on, with its turns: fetched for each new leg, and again
    /// as soon as you've left it.
    func refreshRoute(force: Bool = false, now: Date = Date()) async {
        guard let trip, let status = tripStatus, let here = location.location else {
            tripNav = nil
            tripStep = nil
            tripMatch = nil
            return
        }
        let leg = trip.option.legs[min(status.legIndex, trip.option.legs.count - 1)]
        guard leg.mode != .metro, leg.mode != .bus else {
            tripNav = nil
            tripStep = nil
            tripMatch = nil
            navLegID = nil
            offRouteSamples = 0
            isRerouting = false
            return
        }

        let isNewLeg = navLegID != leg.id || tripNav == nil
        if !isNewLeg, !force { return }
        guard !isFetchingRoute, isNewLeg || now.timeIntervalSince(lastRouteFetch) >= Self.rerouteCooldown else { return }

        isFetchingRoute = true
        defer { isFetchingRoute = false }
        lastRouteFetch = now
        let found = await places.directions(to: leg.endCoordinate, from: here, byRoad: leg.mode != .walk)
        // Still on the same leg of the same way when it comes back.
        guard self.trip?.option.id == trip.option.id, tripStatus?.legIndex == status.legIndex else { return }
        // Where you are *now*, not where you were when the request left: at road speed a couple of
        // seconds of fetching is tens of metres, and the new line would start that far behind you.
        let arrived = location.location ?? here
        if let found {
            tripNav = found
            navLegID = leg.id
            place(on: found, at: arrived)
            if isRerouting, !isNewLeg {
                // The next turn is a different one now.
                spokenMoments = spokenMoments.filter { if case .handover = $0 { true } else { false } }
            }
        }
        offRouteSamples = 0
        isRerouting = false
        // A fresh leg is asked about at once; a re-route waits ten seconds so the two fetches
        // don't land together.
        lastTrafficCheck = isNewLeg ? .distantPast : now.addingTimeInterval(-Self.trafficCheckInterval + 10)
    }

    /// Asks Apple Maps again, every minute or so, how long the rest of the leg takes in the
    /// traffic now, and whether another way is quicker. A clearly quicker way is taken, and said,
    /// as navigation apps do; otherwise the times on screen follow the traffic.
    private func checkTraffic(for leg: DoorToDoor.Leg, now: Date = Date()) async {
        guard let trip, let nav = tripNav, let match = tripMatch, let here = location.location else { return }
        // Where the next stretch of road ends, worked out before anything is awaited.
        let ahead = RouteProgress.point(nav.coordinates, from: match, after: RouteTraffic.probeMetres)
        isFetchingRoute = true
        // One round trip for all of it: the whole of what's left, the stretch right in front of
        // you, and what that whole stretch takes with nothing in the way, which is what says
        // whether the road is held up or simply narrow.
        async let whole = places.routes(to: leg.endCoordinate, from: here, byRoad: true)
        async let stretch = probe(ahead, from: here, now: now)
        async let quiet = places.roadTime(to: leg.endCoordinate, from: here,
                                          departingAt: RouteTraffic.quietHour(after: now))
        let (routes, probe, wholeFreeFlow) = await (whole, stretch, quiet)
        isFetchingRoute = false
        guard self.trip?.option.id == trip.option.id, navLegID == leg.id, let fastest = routes.first else { return }

        let current = nav.secondsRemaining(from: match)
        // The route you're on, as it's timed now: the one of those offered that is the same road,
        // judged by its name and length.
        let same = routes.first { route in
            route.name == nav.name && abs(route.distanceMeters - match.remaining) < max(300, match.remaining * 0.15)
        }
        let yours = same?.seconds ?? current
        let saving = yours - fastest.seconds

        if same?.name != fastest.name, saving >= max(180, yours * 0.1) {
            // Quicker by enough to be worth a different road.
            tripNav = fastest
            place(on: fastest, at: location.location ?? here)
            let minutes = Int((saving / 60).rounded())
            tripTraffic = TripTraffic(delayMinutes: tripTraffic?.delayMinutes ?? 0,
                                      note: "Faster route · saves \(minutes) min", at: now)
            if speaksDirections {
                say("Found a faster route\(fastest.name.isEmpty ? "" : " via \(fastest.name)"). It saves \(minutes) minutes.")
            }
            await updateTripActivity()
            return
        }
        if let same {
            // Keep the route, but time the rest of it by the traffic now.
            var updated = nav
            updated.seconds = same.seconds / max(0.05, 1 - match.fraction)
            updated.fetchedAt = now
            tripNav = updated
        }
        // Against what the plan allowed for this leg: the part already done, and the rest now.
        let elapsedOnLeg = max(0, now.timeIntervalSince(trip.startedAt) / 60
                               - (TripGuide.schedule(trip.option)[safe: (tripStatus?.legIndex ?? 0) - 1] ?? 0))
        let delay = Int((elapsedOnLeg + yours / 60 - Double(leg.minutes)).rounded())
        let wasSlow = tripTraffic?.isSlow == true
        tripTraffic = TripTraffic(
            delayMinutes: delay,
            note: delay >= TripTraffic.worthSaying ? "Heavy traffic · +\(delay) min"
                : delay <= -TripTraffic.worthSaying ? "Clear roads · \(-delay) min quicker" : nil,
            at: now
        )
        if tripTraffic?.isSlow == true, !wasSlow, speaksDirections {
            say("Heavy traffic ahead. About \(delay) minutes longer than planned.")
        }

        // Where the traffic is, as stretches of the line: the kilometre in front of you, and what
        // comes after it. A probe that came back down a different road than the one being followed
        // is thrown away rather than used to colour it.
        let measured = ahead.flatMap { target -> RouteTraffic.Measure? in
            guard let probe, abs(probe.metres - target.metres) < max(200, target.metres * 0.25) else { return nil }
            return probe
        }
        let remainingMetres = same?.distanceMeters ?? match.remaining
        // The whole of what's left, without the traffic: same guard, since a quiet-hour route
        // that took a different road can't be subtracted from this one.
        let remainingFreeFlow = wholeFreeFlow.flatMap { quiet -> TimeInterval? in
            abs(quiet.metres - remainingMetres) < max(200, remainingMetres * 0.15) ? quiet.seconds : nil
        }
        tripFlow = TripFlow(
            routeID: nav.id,
            bands: RouteTraffic.bands(
                routeMetres: match.total, travelledMetres: match.travelled, probe: measured,
                remaining: RouteTraffic.Measure(metres: remainingMetres, seconds: yours,
                                                freeFlowSeconds: remainingFreeFlow)
            ),
            at: now
        )
    }

    /// Puts you on a route just fetched: where you are along it, which turn that makes next, and
    /// the anchor the line's head is drawn from.
    private func place(on route: NavRoute, at here: CLLocation) {
        let match = RouteProgress.match(route.coordinates, at: here.coordinate)
        tripMatch = match
        tripTrim = match.map { RouteTrim.Anchor(fraction: $0.fraction, at: here.timestamp,
                                                metresPerSecond: max(0, here.speed), routeMetres: $0.total) }
        tripStep = StepGuide.position(in: route.steps, at: here.coordinate)
    }

    /// How long the stretch in front of you takes, when there is one to ask about.
    private func probe(_ target: (coordinate: CLLocationCoordinate2D, metres: Double)?,
                       from here: CLLocation, now: Date) async -> RouteTraffic.Measure? {
        guard let target else { return nil }
        return await places.roadProbe(to: target.coordinate, from: here, now: now)
    }

    /// The plan's status, timed instead by what's left of the route you're on in today's traffic,
    /// once there's a route and a place on it to measure from.
    func liveAdjusted(_ status: TripGuide.Status, trip: ActiveTrip, now: Date) -> TripGuide.Status {
        guard !status.hasArrived, let nav = tripNav, let match = tripMatch,
              navLegID == trip.option.legs[safe: status.legIndex]?.id else { return status }
        return TripGuide.adjusting(status, in: trip.option, startedAt: trip.startedAt, now: now,
                                   legMinutesLeft: nav.secondsRemaining(from: match) / 60)
    }

    /// Two fixes off the route, a second apart, and it re-routes: a wrong turn, not a wobble.
    static let rerouteCooldown: TimeInterval = 6
    static let offRouteSamplesBeforeReroute = 2
    /// How often the traffic on the route is asked about.
    static let trafficCheckInterval: TimeInterval = 60

    /// Where you've got to, what to do next, and whether the plan is slipping. Called on the
    /// foreground loop and on every background wake, so it keeps working in your pocket.
    func refreshTrip(now: Date = Date()) async {
        guard let trip else { return }
        guard let planned = TripGuide.status(for: trip.option, startedAt: trip.startedAt, now: now,
                                             location: location.location?.coordinate) else { return }
        let status = liveAdjusted(planned, trip: trip, now: now)
        tripStatus = status

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
        say(announcement.text)
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
    ///
    /// Said once each: the instruction as the title, the turn coming up or the leg's detail under
    /// it, the next leg as the one note, and when you'll arrive, which the Lock Screen counts down
    /// to by itself so it's right whenever you look.
    func updateTripActivity() async {
        guard let trip, let status = tripStatus, transit.journey == nil else { return }
        let leg = trip.option.legs[min(status.legIndex, trip.option.legs.count - 1)]
        let turn: String? = if isRerouting {
            "Finding a new route…"
        } else if let position = tripStep, let step = tripNav?.steps[safe: position.stepIndex] {
            StepGuide.sentence(for: step, metresToStep: position.metresToStep)
        } else {
            nil
        }
        var notes: [PathOSActivityAttributes.Note] = []
        if let note = tripTraffic?.note {
            notes.append(.init(symbol: tripTraffic?.isSlow == true ? "car.rear.and.tire.marks" : "arrow.triangle.branch",
                               text: note, role: tripTraffic?.isSlow == true ? .attention : .you))
        } else if status.isBehind {
            notes.append(.init(symbol: "clock.badge.exclamationmark", text: "\(status.minutesBehind) min behind plan", role: .attention))
        } else if let next = trip.option.legs[safe: status.legIndex + 1] {
            notes.append(.init(symbol: next.mode.symbol, text: "Then \(TripGuide.instruction(for: next).prefix(1).lowercased() + TripGuide.instruction(for: next).dropFirst())", role: .you))
        } else if !status.headline.contains(trip.destinationName) {
            notes.append(.init(symbol: "flag.checkered", text: trip.destinationName, role: .you))
        }
        let arrival = Date().addingTimeInterval(TimeInterval(status.minutesRemaining * 60))
        await liveActivities.showIfChanged(
            .init(
                mode: .journey,
                title: status.headline,
                subtitle: turn ?? leg.detail ?? "About \(status.minutesRemaining) min to go",
                symbol: status.symbol,
                etaMinutes: status.minutesRemaining,
                deepLink: URL(string: "pathos://dashboard"),
                notes: notes,
                role: status.isBehind || tripTraffic?.isSlow == true ? .attention : .you,
                // A minute's precision: redrawn when the time left moves, not every second.
                arrivalDate: Date(timeIntervalSinceReferenceDate: (arrival.timeIntervalSinceReferenceDate / 60).rounded() * 60)
            ),
            lane: .journey,
            staleAfter: 600,
            relevance: status.isBehind ? 96 : 94
        )
    }

    var tripNotificationPrefix: String { "pathos.trip." }
}
