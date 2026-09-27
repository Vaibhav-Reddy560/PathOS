import Foundation

/// How the traffic runs along the route, piece by piece.
///
/// Apple Maps publishes no per-street traffic, but it will time any stretch of road for any
/// departure. So the route is cut into pieces of about half a kilometre to a kilometre and each is
/// asked about on its own: how long it takes now, and — once, since it doesn't change — how long
/// it takes at half three in the morning, which is Apple Maps' own answer for the same road with
/// nothing on it. Each piece is coloured by the one against the other.
///
/// Both halves of that matter.
///
/// **Pieces, not the route.** An earlier version timed the next kilometre and the whole of the
/// rest, and so drew at most two colours. A jam on the Outer Ring Road then tinted all eight
/// kilometres orange, including the empty lanes at either end, while a short trip down the same
/// lanes drew green at the same moment. A colour has to belong to the road it's drawn on.
///
/// **Against itself, not against a speed.** The lanes around Jayanagar run at 18 km/h at four in
/// the morning with nothing on them, because of the speed humps and a junction every hundred
/// metres. Judged by speed alone the whole of a city's side streets is a permanent jam.
nonisolated enum RouteTraffic {

    /// A fixed piece of the route. Fixed for as long as the route is: a re-route brings new ones.
    nonisolated struct Piece: Equatable, Sendable {
        var startMetres: Double
        var endMetres: Double

        var metres: Double { endMetres - startMetres }
    }

    /// What's been measured of one piece.
    nonisolated struct Reading: Equatable, Sendable {
        /// How long it takes in the traffic now, and when that was asked.
        var seconds: TimeInterval?
        var measuredAt: Date?
        /// How long it takes with nothing in the way. Asked once per route: it doesn't change.
        var freeFlowSeconds: TimeInterval?
        var freeFlowMisses = 0
        /// Apple Maps answered for a different road than this piece — a one-way, or a U-turn on a
        /// divided road. Not asked about again, and never coloured by its own guess.
        var isUnmeasurable = false

        /// How held up the piece is, once both halves are known.
        var severity: Double? {
            guard !isUnmeasurable, let seconds, let freeFlowSeconds else { return nil }
            return RouteTraffic.severity(seconds: seconds, freeFlow: freeFlowSeconds)
        }
    }

    /// Which of the two things a piece is asked.
    nonisolated enum Ask: Equatable, Sendable {
        case now
        case freeFlow
    }

    nonisolated struct Request: Equatable, Sendable {
        var piece: Int
        var ask: Ask
    }

    nonisolated enum Flow: String, Equatable, Sendable {
        case clear
        case slow
        case heavy

        /// The words for a degree. The colour is a ramp, not these three — `PathOSPalette.traffic`
        /// draws it — but speech and labels have to pick one of a few things to say.
        init(severity: Double) {
            self = severity <= 0 ? .clear : severity < Flow.heavyAbove ? .slow : .heavy
        }

        static let heavyAbove = 0.5

        /// Aurora, amber, coral — the palette's own meanings: moving, worth a glance, urgent.
        var role: SignalRole {
            switch self {
            case .clear: .you
            case .slow: .attention
            case .heavy: .critical
            }
        }

        var label: String {
            switch self {
            case .clear: "Clear"
            case .slow: "Slow"
            case .heavy: "Heavy traffic"
            }
        }
    }

    // MARK: Cutting the route

    /// Never more pieces than this: each costs a request to keep fresh.
    static let pieceLimit = 12
    /// Nor shorter than this. Below it the time for a piece is mostly the junctions at its ends.
    static let shortestPiece = 500.0

    /// The route cut into equal pieces. The same route always cuts the same way, so the map and
    /// the measuring agree on which piece is which without being told.
    static func pieces(routeMetres: Double) -> [Piece] {
        guard routeMetres > 0 else { return [] }
        let count = max(1, min(pieceLimit, Int(routeMetres / shortestPiece)))
        let length = routeMetres / Double(count)
        return (0..<count).map { Piece(startMetres: Double($0) * length, endMetres: Double($0 + 1) * length) }
    }

    // MARK: What a measurement means

    /// Slower than free flow by less than this is the road being the road, not traffic: a road
    /// still moving at four-fifths of its empty speed is what every map draws green.
    static let freeFlowing = 1.25
    /// Taking twice as long as it should — half its empty speed — is as bad as the colour goes.
    static let jammed = 2.0

    /// How badly a stretch is held up, 0…1.
    ///
    /// Zero means "running as it always does", which is not the same as fast: a lane that never
    /// exceeds 18 km/h scores zero when it is doing 18 km/h, and a main road that normally does
    /// 50 scores badly at 20.
    static func severity(seconds: TimeInterval, freeFlow: TimeInterval?) -> Double {
        guard let freeFlow, seconds > 0, freeFlow > 0 else { return 0 }
        let ratio = seconds / freeFlow
        guard ratio > freeFlowing else { return 0 }
        return min(1, (ratio - freeFlowing) / (jammed - freeFlowing))
    }

    /// The degree each piece is drawn at. A piece not yet measured, or that can't be, takes the
    /// milder of its measured neighbours rather than a guess of its own — a gap in a jam shouldn't
    /// read as a clear road, and a gap between two clear pieces shouldn't read as anything else.
    /// With nothing measured on one side of it, it reads as flowing, which is what PathOS drew
    /// before it knew.
    static func severities(_ readings: [Int: Reading], count: Int) -> [Double] {
        let known = (0..<count).map { readings[$0]?.severity }
        return known.indices.map { index in
            if let measured = known[index] { return measured }
            let before = known[..<index].last { $0 != nil } ?? nil
            let after = known[(index + 1)...].first { $0 != nil } ?? nil
            guard let before, let after else { return 0 }
            return min(before, after)
        }
    }

    // MARK: What to ask next

    /// Pieces starting within this of you are kept fresh every minute; further on, every two and
    /// a half. Traffic a few kilometres off will have changed by the time you reach it anyway.
    static let nearMetres = 3_000.0
    static let freshNear: TimeInterval = 60
    static let freshFar: TimeInterval = 150
    /// Requests in one go. Apple Maps throttles an app that asks for much more than one a second.
    static let batchSize = 4

    /// The next few questions worth asking, nearest piece first, so the stretch you're about to
    /// drive is coloured within seconds of setting off and the far end within a minute. Pieces
    /// wholly behind you are never asked about again.
    static func due(_ pieces: [Piece], readings: [Int: Reading], travelledMetres: Double,
                    now: Date, limit: Int = batchSize) -> [Request] {
        var asks: [Request] = []
        for (index, piece) in pieces.enumerated() where piece.endMetres > travelledMetres {
            let reading = readings[index] ?? Reading()
            guard !reading.isUnmeasurable else { continue }
            if reading.freeFlowSeconds == nil {
                asks.append(Request(piece: index, ask: .freeFlow))
            }
            let freshFor = piece.startMetres - travelledMetres < nearMetres ? freshNear : freshFar
            if reading.measuredAt.map({ now.timeIntervalSince($0) >= freshFor }) ?? true {
                asks.append(Request(piece: index, ask: .now))
            }
            if asks.count >= limit { break }
        }
        return Array(asks.prefix(limit))
    }

    /// Free flow is asked for at most this many times before a piece is left alone.
    static let freeFlowTries = 2

    /// A reading with one answer folded in.
    ///
    /// An answer for a different road — much longer or shorter than the piece — marks the piece
    /// unmeasurable rather than colour it with the time of a street it isn't. No answer at all
    /// is waited out: the live time is asked again when it's next due, and free flow is given a
    /// couple of tries.
    static func record(_ answer: (seconds: TimeInterval, metres: Double)?, for ask: Ask,
                       on piece: Piece, into reading: Reading, at now: Date) -> Reading {
        var reading = reading
        guard let answer, answer.seconds > 0 else {
            switch ask {
            case .now:
                reading.measuredAt = now
            case .freeFlow:
                reading.freeFlowMisses += 1
                if reading.freeFlowMisses >= freeFlowTries { reading.isUnmeasurable = true }
            }
            return reading
        }
        guard abs(answer.metres - piece.metres) <= max(150, piece.metres * 0.3) else {
            reading.isUnmeasurable = true
            return reading
        }
        switch ask {
        case .now:
            reading.seconds = answer.seconds
            reading.measuredAt = now
        case .freeFlow:
            reading.freeFlowSeconds = answer.seconds
        }
        return reading
    }

    /// A time the roads are empty, for asking Apple Maps what a stretch takes without traffic.
    ///
    /// Half three in the morning: after the last of the night out and before the first of the
    /// markets. Always the next one, because Apple Maps predicts departures and won't be asked
    /// about the past.
    static func quietHour(after now: Date, calendar: Calendar = .current) -> Date {
        var wanted = DateComponents()
        wanted.hour = 3
        wanted.minute = 30
        // A minute's grace: asking for the very instant it is now can land behind the request.
        return calendar.nextDate(after: now.addingTimeInterval(60), matching: wanted,
                                 matchingPolicy: .nextTime) ?? now.addingTimeInterval(3_600)
    }
}
