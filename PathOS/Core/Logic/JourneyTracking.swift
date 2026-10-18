import CoreLocation
import Foundation

/// One stop along a journey, in riding order.
nonisolated struct JourneyStop: Hashable, Sendable {
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
nonisolated struct Journey: Identifiable, Sendable {
    nonisolated enum Kind: String, Sendable {
        case metro
        case bus
    }

    var id = UUID()
    var kind: Kind
    /// "Purple Line", "Purple → Green Line", "Bus 500D".
    var lineName: String
    var stops: [JourneyStop]
    var startedAt: Date
    /// The first train, as the platform signs it: "Yellow Line towards Delta Electronics Bommasandra".
    var boarding: String? = nil

    var origin: String { stops.first?.name ?? "" }
    var destination: String { stops.last?.name ?? "" }
    var symbol: String { kind == .metro ? "tram.fill" : "bus.fill" }
    /// How close to a stop counts as being at it. Metro stations are big and GPS is poor near them.
    var stopRadius: Double { kind == .metro ? 700 : 200 }

    func stationName(at index: Int) -> String {
        stops[safe: index]?.name ?? ""
    }

    static func metro(_ route: MetroRoute, startedAt: Date = Date()) -> Journey {
        let changes = Dictionary(uniqueKeysWithValues: route.rides.dropFirst().map {
            ($0.boardAt, "Change to the \($0.lineName) towards \($0.towards)")
        })
        let stops = zip(route.path, route.arrivalMinutes).map { station, minutes in
            JourneyStop(name: station.name, latitude: station.lat, longitude: station.lon,
                        minutesFromStart: minutes, changeInstruction: changes[station.name])
        }
        return Journey(kind: .metro, lineName: route.lineSummary, stops: stops, startedAt: startedAt,
                       boarding: route.rides.first.map { "\($0.lineName) towards \($0.towards)" })
    }
}

/// Where you are along a journey. Times are estimates: no Indian metro or bus service publishes
/// live vehicle positions, so PathOS measures *you* and estimates the rest.
nonisolated struct JourneyProgress: Equatable, Sendable {
    var currentIndex: Int
    var nextStationIndex: Int?
    var stopsRemaining: Int
    var estimatedMinutesRemaining: Int
    /// The next stop is where you get off.
    var isArrivingNext: Bool
    var hasArrived: Bool
    /// True when the position came from GPS rather than the clock.
    var isTrackingByLocation: Bool
    /// The next stop is where you change lines.
    var isChangingNext = false
    /// The next change still ahead, if any.
    var nextChangeIndex: Int?
    /// How far the next station is, when GPS knows where you are.
    var metresToNext: Double? = nil
}

nonisolated enum JourneyTracker {
    /// The stop you're closest to, if you're close enough to call it.
    static func nearestStopIndex(to coordinate: CLLocationCoordinate2D, stops: [JourneyStop], radius: Double) -> Int? {
        let ranked = stops.enumerated()
            .map { ($0.offset, GeoMath.distance(from: coordinate, to: $0.element.coordinate)) }
            .min { $0.1 < $1.1 }
        guard let ranked, ranked.1 <= radius else { return nil }
        return ranked.0
    }

    /// The last station you've reached, from where you are on the line: at it, or past it on the
    /// way to the next. The nearest station used to stand for this, so halfway between two the
    /// next one already counted as reached — "get off at the next stop" came a stop early.
    /// Nil when you're nowhere near the line.
    static func reachedIndex(at coordinate: CLLocationCoordinate2D, stops: [JourneyStop], radius: Double,
                             atStation: Double = 150) -> Int? {
        guard let first = stops.first else { return nil }
        if stops.count == 1 {
            return GeoMath.distance(from: coordinate, to: first.coordinate) <= radius ? 0 : nil
        }
        var best: (index: Int, offset: Double, along: Double, length: Double)?
        for index in 0..<(stops.count - 1) {
            let a = stops[index].coordinate, b = stops[index + 1].coordinate
            // Flat metres around the segment's start: plenty for a kilometre of track.
            let metresPerDegree = 111_320.0
            let scale = cos(a.latitude * .pi / 180)
            let bx = (b.longitude - a.longitude) * metresPerDegree * scale, by = (b.latitude - a.latitude) * metresPerDegree
            let px = (coordinate.longitude - a.longitude) * metresPerDegree * scale
            let py = (coordinate.latitude - a.latitude) * metresPerDegree
            let length = max(1, (bx * bx + by * by).squareRoot())
            let along = min(max((px * bx + py * by) / length, 0), length)
            let offset = ((px - bx * along / length) * (px - bx * along / length)
                          + (py - by * along / length) * (py - by * along / length)).squareRoot()
            if best == nil || offset < best!.offset {
                best = (index, offset, along, length)
            }
        }
        guard let best, best.offset <= radius else { return nil }
        // Within a platform's length of the next station is being at it.
        return best.length - best.along <= atStation ? best.index + 1 : best.index
    }

    /// Progress along the journey's stops. `nearestIndex` comes from GPS when available; otherwise
    /// the clock carries the estimate, which is what happens in the underground stretches.
    /// `reached` is the furthest stop GPS has already put you at: nothing goes back from there.
    static func progress(stops: [JourneyStop], nearestIndex: Int?, elapsed: TimeInterval, reached: Int = 0) -> JourneyProgress {
        let last = max(0, stops.count - 1)
        let elapsedMinutes = elapsed / 60
        let estimatedIndex = stops.lastIndex { $0.minutesFromStart <= elapsedMinutes } ?? 0
        let floor = min(max(reached, 0), last)

        // GPS is believed over the clock — a train held at a signal is behind the timetable, not
        // you — but never behind a stop it already put you at: a stray fix from the station you
        // left used to send you back to it.
        var currentIndex = max(min(estimatedIndex, last), floor)
        var byLocation = false
        if let nearestIndex {
            let clamped = min(max(nearestIndex, 0), last)
            if clamped >= floor, clamped >= currentIndex || currentIndex - clamped <= 1 {
                currentIndex = clamped
                byLocation = true
            }
        }

        let stopsRemaining = last - currentIndex
        let hasArrived = stopsRemaining == 0
        let nextIndex = hasArrived ? nil : currentIndex + 1
        let remaining = (stops.last?.minutesFromStart ?? 0) - (stops[safe: currentIndex]?.minutesFromStart ?? 0)
        let nextChange = stops.indices.first { $0 > currentIndex && stops[$0].changeInstruction != nil }

        return JourneyProgress(
            currentIndex: currentIndex,
            nextStationIndex: nextIndex,
            stopsRemaining: stopsRemaining,
            estimatedMinutesRemaining: max(0, Int(remaining.rounded())),
            isArrivingNext: stopsRemaining == 1,
            hasArrived: hasArrived,
            isTrackingByLocation: byLocation,
            isChangingNext: nextChange != nil && nextChange == nextIndex,
            nextChangeIndex: nextChange
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
    /// to board, the next station, a change coming up, getting off — and, once off, what comes
    /// after (`then`, "Walk to BMS College").
    static func instruction(for progress: JourneyProgress, in journey: Journey, then: String? = nil) -> Instruction {
        let afterwards = then.map { "then " + $0.prefix(1).lowercased() + $0.dropFirst() }
        if progress.hasArrived {
            return Instruction(headline: "You're at \(journey.destination)",
                               detail: then.map { "Exit, " + (afterwards ?? $0) } ?? "End of the ride",
                               symbol: then == nil ? "checkmark.circle.fill" : "figure.walk.departure", isAction: true)
        }
        let minutes = "about \(progress.estimatedMinutesRemaining) min"
        let next = progress.nextStationIndex.map(journey.stationName(at:)) ?? journey.destination

        if progress.isArrivingNext {
            return Instruction(headline: "Get off at the next stop: \(journey.destination)",
                               detail: [minutes.prefix(1).uppercased() + minutes.dropFirst(), afterwards]
                                .compactMap { $0 }.joined(separator: " · "),
                               symbol: "figure.walk.departure", isAction: true)
        }
        if progress.isChangingNext, let index = progress.nextStationIndex,
           let change = journey.stops[safe: index]?.changeInstruction {
            // "Change to the Green Line towards Silk Institute" → "To the Green Line towards …".
            let what = change.hasPrefix("Change ") ? String(change.dropFirst("Change ".count)) : change
            return Instruction(headline: "Change at the next stop: \(next)",
                               detail: what.prefix(1).uppercased() + what.dropFirst(),
                               symbol: "arrow.triangle.swap", isAction: true)
        }

        let stops = progress.stopsRemaining == 1 ? "1 stop" : "\(progress.stopsRemaining) stops"
        var detail = ["\(stops) to \(journey.destination)", minutes]
        // Pulled out of the first station: a good way closer to the second than the platform is.
        let hasSetOff = progress.currentIndex > 0 || progress.metresToNext.map { metres in
            guard let first = journey.stops.first, let second = journey.stops[safe: 1] else { return false }
            return metres < GeoMath.distance(from: first.coordinate, to: second.coordinate) - 250
        } ?? false
        // How near the next station is, while GPS can say.
        if let metres = progress.metresToNext, hasSetOff {
            detail.insert("\(GeoMath.formatDistance(metres)) away", at: 0)
        }
        if let change = progress.nextChangeIndex {
            detail.append("change at \(journey.stationName(at: change))")
        }
        // Still at the first station: which train to get on, as the platform signs it.
        if !hasSetOff {
            let board = "Board the " + (journey.boarding ?? journey.lineName)
            return Instruction(headline: board, detail: (["Next: \(next)"] + detail).joined(separator: " · "),
                               symbol: journey.symbol, isAction: false)
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
