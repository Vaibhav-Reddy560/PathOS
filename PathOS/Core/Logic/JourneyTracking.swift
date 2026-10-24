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
        /// The metro line it runs on, for following the ride along its track.
        var lineID: String? = nil
        /// Where it leaves from: "2", "2 or 3".
        var platform: String? = nil
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
            ($0.boardAt, "Change to the \($0.lineName) towards \($0.towards)" + ($0.platform.map { ", platform \($0)" } ?? ""))
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
                              changeWalk: index == 0 ? 0 : MetroNetwork.interchangeWalkMinutes(at: ride.boardAt),
                              lineID: ride.lineID, platform: ride.platform))
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
    /// The platform it leaves from, when known: "2", "2 or 3".
    var platform: String? = nil
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
    /// The train's speed as GPS last read it, and when: good in a coach even when the position isn't.
    var speed: Double?
    var speedAt: Date?
    /// Where you've been shown, so the dot never goes back a station to wait for GPS to catch up.
    var shown: Double?
}

/// A position from GPS, as a ride reads it.
nonisolated struct RideFix: Sendable {
    var coordinate: CLLocationCoordinate2D
    /// Metres either way; negative when unknown.
    var accuracy: Double
    var at: Date
    /// Metres a second, when GPS knows.
    var speed: Double? = nil
}

/// The ride's line, as it's drawn and followed: along the track where it's known, straight from
/// each station to the next where it isn't, as on a bus.
nonisolated struct RideGeometry: Sendable {
    var points: [CLLocationCoordinate2D]
    /// Metres along the line to each point.
    var along: [Double]
    /// Metres along the line to each stop.
    var stops: [Double]
    /// Measured along the rails, rather than straight between stations.
    var followsTrack: Bool

    var length: Double { along.last ?? 0 }
}

nonisolated enum RideLine {
    /// The journey's line: each train's stretch of its own line's track, end to end.
    static func geometry(of journey: Journey) -> RideGeometry {
        let stops = journey.stops
        guard stops.count > 1 else {
            return RideGeometry(points: stops.map(\.coordinate), along: stops.map { _ in 0 }, stops: stops.map { _ in 0 },
                                followsTrack: false)
        }
        var points: [CLLocationCoordinate2D] = []
        var followsTrack = journey.kind == .metro
        for part in journey.rideParts {
            let first = min(part.firstStop, stops.count - 1), last = min(part.lastStop, stops.count - 1)
            var piece: [CLLocationCoordinate2D]?
            if let id = part.lineID, let track = MetroNetwork.line(id: id)?.trackPoints, track.count > 1 {
                piece = slice(track, from: stops[first].coordinate, to: stops[last].coordinate)
            }
            if piece == nil {
                followsTrack = false
                piece = stops[first...last].map(\.coordinate)
            }
            points += piece ?? []
        }
        let along = cumulative(points)
        // Each stop where it falls on the line, never behind the one before.
        var stopAlong: [Double] = []
        var segment = 0
        for stop in stops {
            let spot = project(stop.coordinate, onto: points, along: along, from: segment)
            segment = spot.segment
            stopAlong.append(max(spot.along, stopAlong.last ?? 0))
        }
        return RideGeometry(points: points, along: along, stops: stopAlong, followsTrack: followsTrack)
    }

    /// Where a point falls on the line: metres along it, and how far off it.
    static func locate(_ point: CLLocationCoordinate2D, on line: RideGeometry) -> (along: Double, offset: Double)? {
        guard let first = line.points.first else { return nil }
        guard line.points.count > 1 else { return (0, GeoMath.distance(from: point, to: first)) }
        let spot = project(point, onto: line.points, along: line.along, from: 0)
        return (spot.along, spot.offset)
    }

    /// The point a distance along the line, to draw you on it.
    static func point(at along: Double, on line: RideGeometry) -> CLLocationCoordinate2D? {
        point(at: along, on: line.points, along: line.along)
    }

    // MARK: Working it out

    /// Metres from the first point to each.
    static func cumulative(_ points: [CLLocationCoordinate2D]) -> [Double] {
        var total = 0.0
        return points.enumerated().map { index, point in
            if index > 0 { total += GeoMath.distance(from: points[index - 1], to: point) }
            return total
        }
    }

    /// The nearest place on a polyline to a point, from a segment on.
    static func project(_ point: CLLocationCoordinate2D, onto points: [CLLocationCoordinate2D], along: [Double],
                        from start: Int) -> (segment: Int, along: Double, offset: Double) {
        guard points.count > 1 else {
            return (0, 0, points.first.map { GeoMath.distance(from: point, to: $0) } ?? .infinity)
        }
        var best = (segment: start, along: along[min(start, along.count - 1)], offset: Double.infinity)
        for index in min(start, points.count - 2)..<(points.count - 1) {
            let a = points[index], b = points[index + 1]
            // Flat metres around the segment's start: plenty for a stretch of track.
            let scale = cos(a.latitude * .pi / 180) * 111_320.0
            let bx = (b.longitude - a.longitude) * scale, by = (b.latitude - a.latitude) * 111_320.0
            let px = (point.longitude - a.longitude) * scale, py = (point.latitude - a.latitude) * 111_320.0
            let squared = bx * bx + by * by
            let t = squared > 0 ? min(max((px * bx + py * by) / squared, 0), 1) : 0
            let dx = px - bx * t, dy = py - by * t
            let offset = (dx * dx + dy * dy).squareRoot()
            if offset < best.offset {
                best = (index, along[index] + (along[index + 1] - along[index]) * t, offset)
            }
        }
        return best
    }

    static func point(at distance: Double, on points: [CLLocationCoordinate2D], along: [Double]) -> CLLocationCoordinate2D? {
        guard let first = points.first else { return nil }
        guard distance > 0 else { return first }
        for index in 0..<max(0, points.count - 1) where distance <= along[index + 1] {
            let span = along[index + 1] - along[index]
            let t = span > 0 ? (distance - along[index]) / span : 0
            let a = points[index], b = points[index + 1]
            return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                          longitude: a.longitude + (b.longitude - a.longitude) * t)
        }
        return points.last
    }

    /// The stretch of a line's track between two stations, in the direction you ride it.
    static func slice(_ track: [CLLocationCoordinate2D], from a: CLLocationCoordinate2D,
                      to b: CLLocationCoordinate2D) -> [CLLocationCoordinate2D]? {
        let along = cumulative(track)
        let start = project(a, onto: track, along: along, from: 0)
        let end = project(b, onto: track, along: along, from: 0)
        // A station that isn't on this track means the wrong line: straight lines are better.
        guard start.offset <= 150, end.offset <= 150 else { return nil }
        let low = min(start.along, end.along), high = max(start.along, end.along)
        var piece = [point(at: low, on: track, along: along)].compactMap { $0 }
        piece += track.indices.filter { along[$0] > low && along[$0] < high }.map { track[$0] }
        if let last = point(at: high, on: track, along: along) { piece.append(last) }
        return start.along <= end.along ? piece : piece.reversed()
    }
}

nonisolated enum JourneyTracker {
    /// A fix this sure of itself, or surer, moves you along as far as it says.
    static let goodFix = 100.0
    /// Inside a coach GPS is rarely surer than this, on a viaduct as much as underground; a fix
    /// up to it still moves you along, by less than it says — no further than it can be sure of.
    /// Leaving them out held the ride a station or two behind until a platform's clearer sky.
    static let usableFix = 400.0
    /// Between fixes you're carried on at a little under the trains' average pace, so a guess
    /// falls behind rather than running ahead.
    static let carriedPace = 0.9
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
    /// Average speed along the track, stops included: BMRCL's end-to-end running times. Where the
    /// line is straight from station to station it's shorter than the track, and so is the speed.
    static func cruise(on line: RideGeometry) -> Double {
        MetroRouter.averageSpeedKmh / 3.6 / (line.followsTrack ? 1 : MetroRouter.trackFactor)
    }
    /// Minutes to wait for a train when how often they run isn't known.
    static let unknownWait = 8

    /// Moves you along the ride by one fix: forward only, never faster than a train, and only when
    /// the fix is good and on the line. A fix that jumps back — to the station you left, as GPS
    /// does under a platform roof — or kilometres ahead is left out rather than believed.
    static func advance(_ track: RideTrack, in journey: Journey, fix: RideFix?, now: Date) -> RideTrack {
        let line = RideLine.geometry(of: journey)
        let parts = journey.rideParts
        var moved = advance(track, line: line, parts: parts, fix: fix, now: now)
        // Shown as far as you've been shown, at least: the dot doesn't go back to wait for GPS.
        moved.shown = max(moved.shown ?? 0, moved.along, estimatedAlong(moved, on: line, parts: parts, now: now))
        return moved
    }

    private static func advance(_ track: RideTrack, line: RideGeometry, parts: [Journey.Part], fix: RideFix?,
                                now: Date) -> RideTrack {
        var track = track
        if track.since == nil { track.since = now }
        let distances = line.stops
        guard let fix, fix.accuracy > 0, fix.accuracy <= usableFix,
              let spot = RideLine.locate(fix.coordinate, on: line),
              spot.offset <= max(onLine, fix.accuracy * 1.5) else { return track }

        // A vaguer fix counts for less: as far along as it could be sure of.
        let doubt = max(0, fix.accuracy - goodFix)
        let credited = spot.along - doubt
        let reach = track.seenAt.map { track.along + max(500, fix.at.timeIntervalSince($0) * fastest) } ?? .infinity
        if credited <= reach {
            track.along = max(track.along, credited)
        }
        // A fix that agrees with where you are counts as seeing you there.
        if spot.along >= track.along - atStation - doubt, credited <= reach {
            track.seenAt = fix.at
            if let speed = fix.speed, speed >= 0 {
                track.speed = min(speed, fastest)
                track.speedAt = fix.at
            }
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

    /// Where you're drawn on the line: where GPS last put you, carried on while there's no fix —
    /// at the train's own speed just after one, then a little under its average — through the
    /// stations between, but never by a guess to where you change or get off: those wait for GPS
    /// to see you there. It used to stop at the very next station, and a ride with few good
    /// fixes ran a station or two behind.
    static func estimatedAlong(_ track: RideTrack, in journey: Journey, now: Date) -> Double {
        estimatedAlong(track, on: RideLine.geometry(of: journey), parts: journey.rideParts, now: now)
    }

    static func estimatedAlong(_ track: RideTrack, on line: RideGeometry, parts: [Journey.Part], now: Date) -> Double {
        let distances = line.stops
        // From whichever was later: the last fix that saw you, or getting on — time on the platform
        // isn't riding.
        guard track.isOnBoard, !track.hasArrived, let seen = [track.seenAt, track.since].compactMap({ $0 }).max(),
              !distances.isEmpty else {
            return track.along
        }
        let elapsed = now.timeIntervalSince(seen)
        guard elapsed > 10 else { return track.along }
        let pace: Double
        if let speed = track.speed, let at = track.speedAt, now.timeIntervalSince(at) <= 45, speed >= 3 {
            pace = speed
        } else {
            pace = cruise(on: line) * carriedPace
        }
        let part = parts[min(track.part, parts.count - 1)]
        let stopBefore = distances[min(part.lastStop, distances.count - 1)] - atStation - 1
        return max(track.along, min(track.along + elapsed * pace, stopBefore))
    }

    /// Where you are along the ride, worked out from where you are on the line — never from how
    /// long it's been since you set off, which ran ahead of the train while you waited for it.
    static func progress(of track: RideTrack, in journey: Journey, now: Date) -> JourneyProgress {
        let stops = journey.stops
        let line = RideLine.geometry(of: journey)
        let distances = line.stops
        let parts = journey.rideParts
        let last = max(0, stops.count - 1)
        let position = track.hasArrived
            ? (distances.last ?? 0)
            : max(track.shown ?? 0, estimatedAlong(track, on: line, parts: parts, now: now))
        var current = stops.indices.last { distances[$0] <= position + atStation } ?? 0
        if !track.hasArrived { current = min(current, max(0, last - 1)) }
        let next: Int? = track.hasArrived ? nil : current + 1
        let part = parts[min(track.part, parts.count - 1)]
        let changeAt: Int? = track.part < parts.count - 1 ? part.lastStop : nil

        // What's left, from here: the track at the trains' pace, and a wait for each train still
        // to come — half the time between them, on average.
        var minutes = max(0, (distances.last ?? 0) - position) / cruise(on: line) / 60
        if !track.isOnBoard, !track.hasArrived {
            minutes += Double(part.everyMinutes ?? unknownWait) / 2
        }
        for later in parts.dropFirst(track.part + 1) {
            minutes += Double(later.changeWalk) + Double(later.everyMinutes ?? unknownWait) / 2
        }
        let isFresh = track.seenAt.map { now.timeIntervalSince($0) <= 60 } ?? false
        let point = RideLine.point(at: position, on: line)

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
            platform: part.platform,
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
            // The platform first: it's what you're looking for on the concourse.
            let platform = progress.platform.map { "Platform \($0)" }
            return Instruction(
                headline: progress.isChanging ? "Change here: \(train)" : "Board the \(train)",
                detail: [platform, every, "Next: \(next)", "\(stops) to \(journey.destination)", minutes].compactMap { $0 }
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
