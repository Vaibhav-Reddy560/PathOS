import CoreLocation
import Foundation

/// How a stretch of a day was travelled.
nonisolated enum WayTravelled: String, Codable, CaseIterable, Sendable {
    case walk
    /// By road, in something PathOS can't name: an auto, a cab, a bike — until a receipt says.
    case road
    case auto
    case bikeTaxi
    case cab
    case metro
    case bus

    var name: String {
        switch self {
        case .walk: "Walk"
        case .road: "By road"
        case .auto: "Auto"
        case .bikeTaxi: "Bike taxi"
        case .cab: "Cab"
        case .metro: "Metro"
        case .bus: "Bus"
        }
    }

    var symbol: String {
        switch self {
        case .walk: "figure.walk"
        case .road: "car.side.fill"
        case .auto: "car.rear.fill"
        case .bikeTaxi: "scooter"
        case .cab: "car.fill"
        case .metro: "tram.fill"
        case .bus: "bus.fill"
        }
    }

    /// A way's leg as travelled. A road leg is priced as an auto, a bike taxi and a cab because
    /// any of them might pull up; which one did isn't known until a receipt says.
    init(_ leg: DoorToDoor.Mode) {
        switch leg {
        case .walk: self = .walk
        case .metro: self = .metro
        case .bus: self = .bus
        case .auto, .bikeTaxi, .cab: self = .road
        }
    }

    /// The way the ride app names the vehicle on its receipt.
    init?(receipt vehicle: DoorToDoor.Mode?) {
        switch vehicle {
        case .auto?: self = .auto
        case .bikeTaxi?: self = .bikeTaxi
        case .cab?: self = .cab
        default: return nil
        }
    }

    var isRoad: Bool { [.road, .auto, .bikeTaxi, .cab].contains(self) }
}

/// Stretches of travel noticed from movement alone, when no way is being followed: walking, by
/// road, or along a metro line. Fed a fix at a time.
///
/// Its edges are only as sharp as the fixes. With PathOS open they're seconds apart; in your
/// pocket iOS wakes it every few hundred metres, so a stretch noticed then is the broad shape of
/// it — what's left over shows in the day as other movement.
nonisolated struct MotionSegmenter: Sendable {
    nonisolated struct Piece: Equatable, Sendable {
        var mode: WayTravelled
        var start: Date
        var end: Date
        var distanceMeters: Double
        var fromLatitude: Double
        var fromLongitude: Double
        var toLatitude: Double
        var toLongitude: Double
    }

    private enum Moving: Equatable, Sendable {
        case walk
        case vehicle
    }

    private struct Point: Sendable {
        var latitude: Double
        var longitude: Double
        var at: Date
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    private struct Ongoing: Sendable {
        var moving: Moving
        var start: Point
        var end: Point
        var distance: Double
        /// Every couple of hundred metres, for telling a metro ride from a road.
        var trail: [Point]
    }

    private var last: Point?
    private var ongoing: Ongoing?
    private var stillSince: Date?
    /// A different way of moving, seen but not yet long enough to believe.
    private var pending: (moving: Moving, since: Point, distance: Double)?

    /// Slower than this, you're standing still; faster than `vehicleAbove`, you're not on foot.
    static let stillBelow = 0.5
    static let walkBelow = 2.8
    static let vehicleAbove = 4.0
    /// Still this long, and the stretch is over.
    static let stillFor: TimeInterval = 3 * 60
    /// A new way of moving counts once it's lasted this long.
    static let changeAfter: TimeInterval = 60
    /// Shorter than this, a stretch isn't worth a line in the day.
    static let shortestWalk = 200.0
    static let shortestRide = 500.0

    init() {}

    /// Takes a fix; returns any stretch it finished.
    mutating func feed(_ coordinate: CLLocationCoordinate2D, at time: Date, speed: Double?, accuracy: Double) -> [Piece] {
        guard accuracy > 0, accuracy <= 100 else { return [] }
        let point = Point(latitude: coordinate.latitude, longitude: coordinate.longitude, at: time)
        guard let previous = last, time > previous.at else {
            last = point
            return []
        }
        last = point
        let distance = GeoMath.distance(from: previous.coordinate, to: coordinate)
        let seconds = time.timeIntervalSince(previous.at)
        // Over a long gap, how far you went in it says more than the speed at either end.
        let pace = seconds > 20 || (speed ?? -1) < 0 ? distance / seconds : speed!
        var finished: [Piece] = []

        if pace < Self.stillBelow {
            stillSince = stillSince ?? previous.at
            if let since = stillSince, time.timeIntervalSince(since) >= Self.stillFor {
                finished += close(at: since)
            }
            return finished
        }
        stillSince = nil
        let moving: Moving? = pace < Self.walkBelow ? .walk : pace > Self.vehicleAbove ? .vehicle : nil

        guard var current = ongoing else {
            ongoing = Ongoing(moving: moving ?? .walk, start: previous, end: point, distance: distance,
                              trail: [previous, point])
            return finished
        }
        if moving == nil || moving == current.moving {
            // More of the same — and a change that didn't last goes back to it.
            current.distance += distance + (pending?.distance ?? 0)
            pending = nil
            extend(&current, to: point)
            ongoing = current
            return finished
        }
        // Something else: believed once it's lasted a minute.
        if let seen = pending, seen.moving == moving {
            let total = seen.distance + distance
            if time.timeIntervalSince(seen.since.at) >= Self.changeAfter {
                finished += close(at: seen.since.at)
                ongoing = Ongoing(moving: moving!, start: seen.since, end: point, distance: total, trail: [seen.since, point])
                pending = nil
            } else {
                pending = (seen.moving, seen.since, total)
            }
        } else {
            pending = (moving!, previous, distance)
        }
        return finished
    }

    /// Ends whatever's under way: a way is about to be followed instead, or the day is over.
    mutating func finish() -> [Piece] {
        let finished = close(at: ongoing?.end.at ?? Date())
        last = nil
        stillSince = nil
        return finished
    }

    private mutating func close(at time: Date) -> [Piece] {
        defer { ongoing = nil; pending = nil }
        guard let current = ongoing else { return [] }
        let isRide = current.moving == .vehicle
        guard current.distance >= (isRide ? Self.shortestRide : Self.shortestWalk) else { return [] }
        let mode: WayTravelled = !isRide ? .walk : TravelLog.isAlongMetro(current.trail.map(\.coordinate)) ? .metro : .road
        return [Piece(mode: mode, start: current.start.at, end: max(current.start.at, min(time, current.end.at)),
                      distanceMeters: current.distance,
                      fromLatitude: current.start.latitude, fromLongitude: current.start.longitude,
                      toLatitude: current.end.latitude, toLongitude: current.end.longitude)]
    }

    private func extend(_ current: inout Ongoing, to point: Point) {
        current.end = point
        if let lastKept = current.trail.last, GeoMath.distance(from: lastKept.coordinate, to: point.coordinate) >= 200 {
            current.trail.append(point)
        }
    }
}

/// The day's travel, added up.
nonisolated enum TravelLog {
    /// A ride by road between stations is told from one along a metro line by where it went:
    /// almost all of it within this of the line.
    static let nearMetroLine = 200.0

    /// Whether a trail of points follows a metro line, near enough all the way.
    static func isAlongMetro(_ points: [CLLocationCoordinate2D]) -> Bool {
        guard points.count >= 3 else { return false }
        let near = points.filter { point in
            MetroNetwork.lines.contains { line in
                zip(line.stops, line.stops.dropFirst()).contains { a, b in
                    distance(from: point, toSegment: a.coordinate, b.coordinate) <= nearMetroLine
                }
            }
        }
        return Double(near.count) / Double(points.count) >= 0.8
    }

    /// Metres from a point to the straight line between two others.
    static func distance(from point: CLLocationCoordinate2D, toSegment a: CLLocationCoordinate2D,
                         _ b: CLLocationCoordinate2D) -> Double {
        let scale = cos(a.latitude * .pi / 180) * 111_320.0
        let bx = (b.longitude - a.longitude) * scale, by = (b.latitude - a.latitude) * 111_320.0
        let px = (point.longitude - a.longitude) * scale, py = (point.latitude - a.latitude) * 111_320.0
        let length = bx * bx + by * by
        let t = length > 0 ? min(max((px * bx + py * by) / length, 0), 1) : 0
        let dx = px - bx * t, dy = py - by * t
        return (dx * dx + dy * dy).squareRoot()
    }

    /// One stretch, as the day shows it.
    nonisolated struct Stretch: Identifiable, Equatable, Sendable {
        var id: UUID
        var mode: WayTravelled
        var start: Date
        var end: Date
        var distanceMeters: Double
        var from: String?
        var to: String?
        /// What it cost, in rupees, and whether that's PathOS's estimate or the receipt's.
        var fare: Double?
        var fareIsEstimate: Bool
        /// The ride app whose receipt priced it.
        var provider: String? = nil

        var minutes: Int { max(0, Int((end.timeIntervalSince(start) / 60).rounded())) }
    }

    /// A ride receipt from mail, as matched to a stretch.
    nonisolated struct Receipt: Equatable, Sendable {
        var at: Date
        var fare: Double?
        var vehicle: DoorToDoor.Mode?
        var provider: String
        var distanceMeters: Double? = nil
        var minutes: Int? = nil
        var pickup: String? = nil
        var drop: String? = nil
        var id = UUID()
    }

    /// A receipt arrives as the ride ends, give or take: one in that window belongs to the stretch,
    /// and its fare and vehicle replace the estimate.
    static func matching(_ stretch: Stretch, receipts: [Receipt]) -> Stretch {
        receiptIndex(for: stretch, in: receipts).map { applying(receipts[$0], to: stretch) } ?? stretch
    }

    /// The day's stretches with its receipts, each receipt used once. One that matches nothing was
    /// a ride PathOS didn't see, and stands as a stretch of its own.
    static func priced(_ stretches: [Stretch], receipts: [Receipt]) -> [Stretch] {
        var unused = receipts.sorted { $0.at < $1.at }
        var priced = stretches.sorted { $0.start < $1.start }.map { stretch in
            guard let index = receiptIndex(for: stretch, in: unused) else { return stretch }
            return applying(unused.remove(at: index), to: stretch)
        }
        priced += unused.map { receipt in
            Stretch(id: receipt.id, mode: WayTravelled(receipt: receipt.vehicle) ?? .road,
                    start: receipt.at.addingTimeInterval(-Double(receipt.minutes ?? 0) * 60), end: receipt.at,
                    distanceMeters: receipt.distanceMeters ?? 0, from: receipt.pickup, to: receipt.drop,
                    fare: receipt.fare, fareIsEstimate: false, provider: receipt.provider)
        }
        return priced.sorted { $0.start < $1.start }
    }

    private static func receiptIndex(for stretch: Stretch, in receipts: [Receipt]) -> Int? {
        guard stretch.mode.isRoad else { return nil }
        let window = stretch.start.addingTimeInterval(-10 * 60)...stretch.end.addingTimeInterval(30 * 60)
        return receipts.indices.filter { window.contains(receipts[$0].at) }
            .min { abs(receipts[$0].at.timeIntervalSince(stretch.end)) < abs(receipts[$1].at.timeIntervalSince(stretch.end)) }
    }

    private static func applying(_ receipt: Receipt, to stretch: Stretch) -> Stretch {
        var matched = stretch
        if let fare = receipt.fare {
            matched.fare = fare
            matched.fareIsEstimate = false
        }
        matched.mode = WayTravelled(receipt: receipt.vehicle) ?? stretch.mode
        matched.provider = receipt.provider
        return matched
    }

    nonisolated struct ModeTotal: Identifiable, Equatable, Sendable {
        var mode: WayTravelled
        var distanceMeters: Double
        var minutes: Int
        var fare: Double
        var id: WayTravelled { mode }
    }

    /// The day by mode: how far, how long, what it cost — furthest first.
    static func byMode(_ stretches: [Stretch]) -> [ModeTotal] {
        Dictionary(grouping: stretches, by: \.mode).map { mode, list in
            ModeTotal(mode: mode,
                      distanceMeters: list.map(\.distanceMeters).reduce(0, +),
                      minutes: list.map(\.minutes).reduce(0, +),
                      fare: list.compactMap(\.fare).reduce(0, +))
        }
        .sorted { $0.distanceMeters > $1.distanceMeters }
    }

    /// What the day's total holds beyond the stretches known: moving about, and the parts no fix
    /// could place.
    static func otherMovement(total: Double, stretches: [Stretch]) -> Double {
        max(0, total - stretches.map(\.distanceMeters).reduce(0, +))
    }
}
