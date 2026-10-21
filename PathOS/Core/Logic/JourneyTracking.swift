import CoreLocation
import Foundation

/// One stop along a journey, in riding order.
nonisolated struct JourneyStop: Hashable, Codable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
    /// Estimated minutes from setting off to reaching this stop.
    var minutesFromStart: Double
    /// Set where you change: "Change to the Green Line towards Silk Institute".
    var changeInstruction: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A metro or bus journey you're on.
nonisolated struct Journey: Identifiable, Codable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case metro
        case bus
    }

    /// One train between changes: where it's boarded and left on `stops`, and how often it runs.
    nonisolated struct Part: Hashable, Codable, Sendable {
        var firstStop: Int
        var lastStop: Int
        /// "Yellow Line towards Delta Electronics Bommasandra", as the platform signs it.
        var train: String
        /// Minutes between trains, when the operator says.
        var everyMinutes: Int?
        /// Minutes to walk to this train's platform, on a change.
        var changeWalk: Int = 0
    }

    var id = UUID()
    var kind: Kind
    /// "Purple Line", "Purple → Green Line", "Bus 500D".
    var lineName: String
    var stops: [JourneyStop]
    var startedAt: Date
    /// The first train, as the platform signs it: "Yellow Line towards Delta Electronics Bommasandra".
    var boarding: String? = nil
    var parts: [Part] = []

    var origin: String { stops.first?.name ?? "" }
    var destination: String { stops.last?.name ?? "" }
    var symbol: String { kind == .metro ? "tram.fill" : "bus.fill" }

    /// The trains, or one covering the whole ride where none were recorded, as on a bus.
    var rideParts: [Part] {
        parts.isEmpty ? [Part(firstStop: 0, lastStop: max(0, stops.count - 1), train: boarding ?? lineName)] : parts
    }

    func stationName(at index: Int) -> String {
        stops[safe: index]?.name ?? ""
    }

    static func metro(_ route: MetroRoute, startedAt: Date = Date(), calendar: Calendar = .current) -> Journey {
        let changes = Dictionary(uniqueKeysWithValues: route.rides.dropFirst().map {
            ($0.boardAt, "Change to the \($0.lineName) towards \($0.towards)")
        })
        let stops = zip(route.path, route.arrivalMinutes).map { station, minutes in
            JourneyStop(name: station.name, latitude: station.lat, longitude: station.lon,
                        minutesFromStart: minutes, changeInstruction: changes[station.name])
        }
        // Each ride takes up from the station the one before left off at.
        var first = 0
        var parts: [Part] = []
        for (index, ride) in route.rides.enumerated() {
            let every: Int? = ride.line.flatMap { line in
                if case .running(let minutes, _) = MetroSchedule.status(for: line, at: startedAt, calendar: calendar) {
                    return minutes
                }
                return nil
            }
            parts.append(Part(firstStop: first, lastStop: first + ride.stops, train: "\(ride.lineName) towards \(ride.towards)",
                              everyMinutes: every,
                              changeWalk: index == 0 ? 0 : MetroNetwork.interchangeWalkMinutes(at: ride.boardAt)))
            first += ride.stops
        }
        return Journey(kind: .metro, lineName: route.lineSummary, stops: stops, startedAt: startedAt,
                       boarding: route.rides.first.map { "\($0.lineName) towards \($0.towards)" }, parts: parts)
    }
}

/// Where you are along a journey. No Indian metro or bus service publishes live vehicle positions,
/// so PathOS measures *you* — on the line, by GPS — and estimates the minutes from that.
nonisolated struct JourneyProgress: Equatable, Sendable {
    /// The last station you've reached.
    var currentIndex: Int
    var nextStationIndex: Int?
    var stopsRemaining: Int
    var estimatedMinutesRemaining: Int
    /// The next stop is where you get off.
    var isArrivingNext: Bool
    var hasArrived: Bool
    /// GPS has put you on the line within the last minute.
    var isTrackingByLocation: Bool
    /// The next stop is where you change lines.
    var isChangingNext = false
    /// The next change still ahead, if any.
    var nextChangeIndex: Int?
    /// How far the next station is, while GPS can say.
    var metresToNext: Double? = nil
    /// On the platform, not yet on the train: at the start, or at a change.
    var isWaiting = false
    /// Waiting at a change rather than at the start.
    var isChanging = false
    /// The train you're on or waiting for: "Green Line towards Silk Institute".
    var train: String? = nil
    /// Minutes between its trains, when known.
    var everyMinutes: Int? = nil
    /// You, on the line, where the map draws you.
    var latitude: Double? = nil
    var longitude: Double? = nil

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// What's known of you on a ride, kept from one fix to the next. Only ever forward: a station once
/// passed stays passed, whatever the next fix from under a concrete roof says.
nonisolated struct RideTrack: Codable, Equatable, Sendable {
    /// The furthest along the line a good fix has put you, in metres from the first stop.
    var along: Double = 0
    /// When a good fix last put you on the line.
    var seenAt: Date?
    /// The train you're on or waiting for: an index into the journey's parts.
    var part = 0
    /// On that train, rather than on its platform.
    var isOnBoard = false
    /// When you got on, or reached the platform.
    var since: Date?
    /// GPS has put you at the last station.
    var hasArrived = false
    /// Platforms you've been asked about already, so each is asked once.
    var askedOnBoard: [Int] = []
}

/// A position from GPS, as a ride reads it.
nonisolated struct RideFix: Sendable {
    var coordinate: CLLocationCoordinate2D
    /// Metres either way; negative when unknown.
    var accuracy: Double
    var at: Date
}

/// The ride's line, as it's drawn: straight from each station to the next.
nonisolated enum RideLine {
    /// Metres along the line to each stop.
    static func distances(_ stops: [JourneyStop]) -> [Double] {
        var total = 0.0
        return stops.enumerated().map { index, stop in
            if index > 0 { total += GeoMath.distance(from: stops[index - 1].coordinate, to: stop.coordinate) }
            return total
        }
    }

    /// Where a point falls on the line: metres along it, and how far off it.
    static func locate(_ point: CLLocationCoordinate2D, on stops: [JourneyStop],
                       distances: [Double]) -> (along: Double, offset: Double)? {
        guard stops.count > 1 else {
            return stops.first.map { (0, GeoMath.distance(from: point, to: $0.coordinate)) }
        }
        var best: (along: Double, offset: Double)?
        for index in 0..<(stops.count - 1) {
            let a = stops[index].coordinate, b = stops[index + 1].coordinate
            // Flat metres around the segment's start: plenty for a kilometre or two of track.
            let scale = cos(a.latitude * .pi / 180) * 111_320.0
            let bx = (b.longitude - a.longitude) * scale, by = (b.latitude - a.latitude) * 111_320.0
            let px = (point.longitude - a.longitude) * scale, py = (point.latitude - a.latitude) * 111_320.0
            let length = max(1, (bx * bx + by * by).squareRoot())
            let t = min(max((px * bx + py * by) / (length * length), 0), 1)
            let dx = px - bx * t, dy = py - by * t
            let offset = (dx * dx + dy * dy).squareRoot()
            if best == nil || offset < best!.offset {
                best = (distances[index] + (distances[index + 1] - distances[index]) * t, offset)
            }
        }
        return best
    }

    /// The point a distance along the line, to draw you on it.
    static func point(at along: Double, on stops: [JourneyStop], distances: [Double]) -> CLLocationCoordinate2D? {
        guard let first = stops.first else { return nil }
        guard along > 0 else { return first.coordinate }
        for index in 0..<max(0, stops.count - 1) where along <= distances[index + 1] {
            let span = max(1, distances[index + 1] - distances[index])
            let t = (along - distances[index]) / span
            let a = stops[index].coordinate, b = stops[index + 1].coordinate
            return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                          longitude: a.longitude + (b.longitude - a.longitude) * t)
        }
        return stops.last?.coordinate
    }
}

nonisolated enum JourneyTracker {
    /// A fix this sure of itself, or surer, can move you along.
    static let goodFix = 100.0
    /// Within this of the line, a fix is on it. Track curves away from the straight line between
    /// stations, and a station's entrances sit off it.
    static let onLine = 250.0
    /// Within this of a station, along the line, is being at it.
    static let atStation = 120.0
    /// Moved this far along from the platform, and you're on the train: well past the end of it,
    /// and past where GPS wanders while you wait.
    static let boardedAfter = 300.0
    /// Nothing on rails here goes faster than this; a fix further on than it allows is a jump.
    static let fastest = 25.0
    /// Average speed along the line, stops included: BMRCL's end-to-end running times, over the
    /// straight lines between stations the line is measured by.
    static let cruise = MetroRouter.averageSpeedKmh / 3.6 / MetroRouter.trackFactor
    /// Minutes to wait for a train when how often they run isn't known.
    static let unknownWait = 8

    /// Moves you along the ride by one fix: forward only, never faster than a train, and only when
    /// the fix is good and on the line. A fix that jumps back — to the station you left, as GPS
    /// does under a platform roof — or kilometres ahead is left out rather than believed.
    static func advance(_ track: RideTrack, in journey: Journey, fix: RideFix?, now: Date) -> RideTrack {
        var track = track
        if track.since == nil { track.since = now }
        let stops = journey.stops
        let distances = RideLine.distances(stops)
        let parts = journey.rideParts
        guard let fix, fix.accuracy > 0, fix.accuracy <= goodFix,
              let spot = RideLine.locate(fix.coordinate, on: stops, distances: distances),
              spot.offset <= max(onLine, fix.accuracy * 2) else { return track }

        let reach = track.seenAt.map { track.along + max(500, fix.at.timeIntervalSince($0) * fastest) } ?? .infinity
        if spot.along <= reach {
            track.along = max(track.along, spot.along)
        }
        // A fix that agrees with where you are counts as seeing you there.
        if spot.along >= track.along - atStation, spot.along <= reach {
            track.seenAt = fix.at
        }

        // On the train: carried along from its platform. Passing a change station means you're on
        // the next train already — tracking that starts mid-ride catches up here.
        while true {
            let part = parts[track.part]
            if !track.isOnBoard, track.along >= distances[part.firstStop] + boardedAfter {
                track.isOnBoard = true
                track.since = now
            }
            guard track.isOnBoard, track.part < parts.count - 1,
                  track.along >= distances[part.lastStop] - atStation else { break }
            // At a change: off this train and onto the next one's platform.
            track.part += 1
            track.isOnBoard = false
            track.since = now
        }
        if track.part == parts.count - 1, track.along >= (distances.last ?? 0) - atStation {
            track.hasArrived = true
        }
        return track
    }

    /// You've said you're on the train: the minutes count from now.
    static func board(_ track: RideTrack, now: Date) -> RideTrack {
        var track = track
        track.isOnBoard = true
        track.since = now
        return track
    }

    /// Where you're drawn on the line: where GPS last put you, carried on at the train's speed while
    /// there's no fix — underground — but never past the next station. A guess doesn't get to
    /// say you've passed one.
    static func estimatedAlong(_ track: RideTrack, in journey: Journey, now: Date) -> Double {
        let distances = RideLine.distances(journey.stops)
        guard track.isOnBoard, !track.hasArrived, let seen = track.seenAt ?? track.since,
              now.timeIntervalSince(seen) > 30 else { return track.along }
        let next = distances.first { $0 > track.along + atStation } ?? distances.last ?? track.along
        return min(track.along + now.timeIntervalSince(seen) * cruise, next)
    }

    /// Where you are along the ride, worked out from where you are on the line — never from how
    /// long it's been since you set off, which ran ahead of the train while you waited for it.
    static func progress(of track: RideTrack, in journey: Journey, now: Date) -> JourneyProgress {
        let stops = journey.stops
        let distances = RideLine.distances(stops)
        let parts = journey.rideParts
        let last = max(0, stops.count - 1)
        let position = track.hasArrived ? (distances.last ?? 0) : estimatedAlong(track, in: journey, now: now)
        var current = stops.indices.last { distances[$0] <= position + atStation } ?? 0
        if !track.hasArrived { current = min(current, max(0, last - 1)) }
        let next: Int? = track.hasArrived ? nil : current + 1
        let part = parts[min(track.part, parts.count - 1)]
        let changeAt: Int? = track.part < parts.count - 1 ? part.lastStop : nil

        // What's left, from here: the track at the trains' pace, and a wait for each train still
        // to come — half the time between them, on average.
        var minutes = max(0, (distances.last ?? 0) - position) / cruise / 60
        if !track.isOnBoard, !track.hasArrived {
            minutes += Double(part.everyMinutes ?? unknownWait) / 2
        }
        for later in parts.dropFirst(track.part + 1) {
            minutes += Double(later.changeWalk) + Double(later.everyMinutes ?? unknownWait) / 2
        }
        let isFresh = track.seenAt.map { now.timeIntervalSince($0) <= 60 } ?? false
        let point = RideLine.point(at: position, on: stops, distances: distances)

        return JourneyProgress(
            currentIndex: current,
            nextStationIndex: next,
            stopsRemaining: last - current,
            estimatedMinutesRemaining: track.hasArrived ? 0 : max(1, Int(minutes.rounded(.up))),
            isArrivingNext: next == last,
            hasArrived: track.hasArrived,
            isTrackingByLocation: isFresh,
            isChangingNext: next != nil && next == changeAt && track.isOnBoard,
            nextChangeIndex: changeAt.flatMap { $0 > current || !track.isOnBoard ? $0 : nil },
            metresToNext: next.flatMap { isFresh && track.isOnBoard ? max(0, distances[$0] - position) : nil },
            isWaiting: !track.isOnBoard && !track.hasArrived,
            isChanging: track.part > 0 && !track.isOnBoard,
            train: part.train,
            everyMinutes: part.everyMinutes,
            latitude: point?.latitude,
            longitude: point?.longitude
        )
    }

    /// What to do on the ride, as an instruction: whatever needs you next.
    nonisolated struct Instruction: Equatable, Sendable {
        /// "Get off at the next stop: Jayadeva Hospital".
        var headline: String
        /// "About 2 min · then walk to BMS College".
        var detail: String
        var symbol: String
        /// The next stop is one to act at: get off, or change.
        var isAction: Bool
    }

    /// The ride as instructions, the way the platform and the announcements put it: which train
    /// to board, the next station and how far it is, a change coming up, getting off — and, once
    /// off, what comes after (`then`, "Walk to BMS College").
    static func instruction(for progress: JourneyProgress, in journey: Journey, then: String? = nil) -> Instruction {
        let afterwards = then.map { "then " + $0.prefix(1).lowercased() + $0.dropFirst() }
        if progress.hasArrived {
            return Instruction(headline: "You're at \(journey.destination)",
                               detail: then.map { "Exit, " + (afterwards ?? $0) } ?? "End of the ride",
                               symbol: then == nil ? "checkmark.circle.fill" : "figure.walk.departure", isAction: true)
        }
        let minutes = "about \(progress.estimatedMinutesRemaining) min"
        let next = progress.nextStationIndex.map(journey.stationName(at:)) ?? journey.destination
        let stops = progress.stopsRemaining == 1 ? "1 stop" : "\(progress.stopsRemaining) stops"
        let away = progress.metresToNext.map { "\(GeoMath.formatDistance($0)) away" }

        // On the platform: which train, how often they come, and what's ahead once on it.
        if progress.isWaiting {
            let train = progress.train ?? journey.lineName
            let every = progress.everyMinutes.map { "Trains about every \($0) min" }
            return Instruction(
                headline: progress.isChanging ? "Change here: \(train)" : "Board the \(train)",
                detail: [every, "Next: \(next)", "\(stops) to \(journey.destination)", minutes].compactMap { $0 }
                    .joined(separator: " · "),
                symbol: progress.isChanging ? "arrow.triangle.swap" : journey.symbol,
                isAction: progress.isChanging
            )
        }
        if progress.isArrivingNext {
            return Instruction(headline: "Get off at the next stop: \(journey.destination)",
                               detail: [away ?? minutes.prefix(1).uppercased() + minutes.dropFirst(), afterwards]
                                .compactMap { $0 }.joined(separator: " · "),
                               symbol: "figure.walk.departure", isAction: true)
        }
        if progress.isChangingNext, let index = progress.nextStationIndex,
           let change = journey.stops[safe: index]?.changeInstruction {
            // "Change to the Green Line towards Silk Institute" → "To the Green Line towards …".
            let what = change.hasPrefix("Change ") ? String(change.dropFirst("Change ".count)) : change
            return Instruction(headline: "Change at the next stop: \(next)",
                               detail: [away, what.prefix(1).uppercased() + what.dropFirst()].compactMap { $0 }
                                .joined(separator: " · "),
                               symbol: "arrow.triangle.swap", isAction: true)
        }
        var detail = [away, "\(stops) to \(journey.destination)", minutes].compactMap { $0 }
        if let change = progress.nextChangeIndex {
            detail.append("change at \(journey.stationName(at: change))")
        }
        return Instruction(headline: "Next: \(next)", detail: detail.joined(separator: " · "),
                           symbol: journey.symbol, isAction: false)
    }

    /// "4 stops · about 9 min" — always phrased as an estimate.
    static func summary(_ progress: JourneyProgress) -> String {
        if progress.hasArrived { return "You've arrived" }
        let stops = progress.stopsRemaining == 1 ? "1 stop" : "\(progress.stopsRemaining) stops"
        return "\(stops) · about \(progress.estimatedMinutesRemaining) min"
    }
}
