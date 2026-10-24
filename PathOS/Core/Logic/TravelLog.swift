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
    /// Your own vehicle: nothing to pay anyone, and no receipt to wait for.
    case drive

    var name: String {
        switch self {
        case .walk: "Walk"
        case .road: "By road"
        case .auto: "Auto"
        case .bikeTaxi: "Bike taxi"
        case .cab: "Cab"
        case .metro: "Metro"
        case .bus: "Bus"
        case .drive: "Drove"
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
        case .drive: "steeringwheel"
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

    /// Hired by road: what a ride app's receipt or a payment as you get out can be for.
    var isRoad: Bool { [.road, .auto, .bikeTaxi, .cab].contains(self) }

    /// How you said you were going, as the day records it.
    init(_ choice: LegChoice) {
        switch choice {
        case .auto: self = .auto
        case .cab: self = .cab
        case .bikeTaxi: self = .bikeTaxi
        case .walk: self = .walk
        case .drive: self = .drive
        }
    }
}

/// How you're doing a leg PathOS planned by road — asked as it starts, the way "On the train?"
/// is on a platform. A receipt says when it's a ride app's; nothing says when you walked it or
/// drove yourself, unless you do.
nonisolated enum LegChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case cab
    case bikeTaxi
    case walk
    case drive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .cab: "Cab"
        case .bikeTaxi: "Bike taxi"
        case .walk: "Walk"
        case .drive: "I'll drive"
        }
    }

    /// What the card says once you've said.
    var doing: String {
        switch self {
        case .auto: "By auto"
        case .cab: "By cab"
        case .bikeTaxi: "By bike taxi"
        case .walk: "Walking"
        case .drive: "Driving"
        }
    }

    var symbol: String {
        switch self {
        case .auto: "car.rear.fill"
        case .cab: "car.fill"
        case .bikeTaxi: "scooter"
        case .walk: "figure.walk"
        case .drive: "steeringwheel"
        }
    }

    /// The fare a payment would be for, as the plan priced it: none on foot or at your own wheel.
    var fareMode: DoorToDoor.Mode? {
        switch self {
        case .auto: .auto
        case .cab: .cab
        case .bikeTaxi: .bikeTaxi
        case .walk, .drive: nil
        }
    }
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

    /// Moving by road or rail now, or starting to: worth following closely.
    var isMovingByVehicle: Bool {
        ongoing?.moving == .vehicle || pending?.moving == .vehicle
    }

    /// Takes a fix; returns any stretch it finished.
    mutating func feed(_ coordinate: CLLocationCoordinate2D, at time: Date, speed: Double?, accuracy: Double) -> [Piece] {
        guard accuracy > 0, accuracy <= 100 else { return [] }
        let point = Point(latitude: coordinate.latitude, longitude: coordinate.longitude, at: time)
        guard let previous = last, time > previous.at else {
            last = point
            return []
        }
        last = point
        let straight = GeoMath.distance(from: previous.coordinate, to: coordinate)
        let seconds = time.timeIntervalSince(previous.at)
        // Over a long gap, how far you went in it says more than the speed at either end.
        let pace = seconds > 20 || (speed ?? -1) < 0 ? straight / seconds : speed!
        // Fixes far apart are joined by roads, not a straight line.
        let distance = DayDistance.alongRoads(straight)
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
        /// The payment found to be for it, and why it's believed.
        var paid: Paid? = nil
        /// The ride app's receipt it is: its distance, times and fare are the receipt's.
        var receiptID: UUID? = nil

        var minutes: Int { max(0, Int((end.timeIntervalSince(start) / 60).rounded())) }

        /// "Metro · Jayadeva Hospital → Konanakunte Cross".
        var title: String {
            let places = [from, to].compactMap { $0 }
            return places.count == 2 ? "\(mode.name) · \(places[0]) → \(places[1])"
                : places.first.map { "\(mode.name) · \(to == nil ? "from" : "to") \($0)" } ?? mode.name
        }
    }

    /// What a stretch was paid with: a receipt, or a payment whose time and amount fit it.
    nonisolated struct Paid: Equatable, Sendable {
        nonisolated enum Evidence: String, Sendable {
            /// The ride app's own receipt, at the time and over the distance travelled.
            case receipt
            /// Paid for what this costs, when it would have been bought.
            case fareAndTime
            /// Paid just as it would have been — at the station, or getting out — but for a fare
            /// PathOS didn't know.
            case time
        }

        var amount: Double
        /// "Namma Metro", "Uber", "Ramesh K".
        var to: String
        var at: Date
        /// The payment, or the receipt, it was.
        var paymentID: UUID
        var evidence: Evidence
    }

    /// A ride receipt from mail, as put to the day's travel.
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

    /// The stretches a ride app's receipt is the ride of, and replaces: the ones it ran through —
    /// most of their time inside the ride's — or, where the receipt doesn't say when the ride ran,
    /// the one road stretch that ended as it came, about as long as the ride. A walk to the pickup,
    /// mostly before it, isn't the ride.
    static func covered(by receipt: Receipt, window: ClosedRange<Date>?, in stretches: [Stretch]) -> [UUID] {
        let candidates = stretches.filter { $0.mode != .metro && $0.mode != .bus && $0.receiptID == nil }
        if let window {
            return candidates.filter { stretch in
                let overlap = min(stretch.end, window.upperBound).timeIntervalSince(max(stretch.start, window.lowerBound))
                return overlap > 0 && overlap >= 0.6 * max(60, stretch.end.timeIntervalSince(stretch.start))
            }.map(\.id)
        }
        let came = receipt.at.addingTimeInterval(-30 * 60)...receipt.at.addingTimeInterval(10 * 60)
        return candidates.filter { stretch in
            guard stretch.mode.isRoad, came.contains(stretch.end) else { return false }
            // Where both say how far, about the same ride.
            guard let receipted = receipt.distanceMeters, receipted > 0, stretch.distanceMeters > 0 else { return true }
            return (0.6...1.6).contains(receipted / stretch.distanceMeters)
        }
        .min { abs($0.end.timeIntervalSince(receipt.at)) < abs($1.end.timeIntervalSince(receipt.at)) }
        .map { [$0.id] } ?? []
    }

    // MARK: Payments to stretches

    /// A metro ticket is bought on the day, up to this long before boarding — ahead of time, or
    /// at the station.
    static let ticketBoughtBefore: TimeInterval = 3 * 3_600
    /// Bought at the station: paid this close to boarding is the ticket, whatever its amount.
    static let ticketAtStation: TimeInterval = 45 * 60
    /// An auto paid by UPI is paid as you get out: this long either side of the stretch's end.
    static let paidOnArrivalBefore: TimeInterval = 10 * 60
    static let paidOnArrivalAfter: TimeInterval = 20 * 60

    /// The day's payments put to the stretches they paid for, only where the evidence says so:
    ///
    /// - a metro ride, to a payment to Namma Metro that day before the ride ended — for its fare
    ///   (a QR ticket's or a card's discount allowed), or bought at the station just before;
    /// - a ride by road with no receipt, to a payment as it ended for about its fare: an auto
    ///   paid by UPI.
    ///
    /// Anything that doesn't fit is left as it was: an estimate, not a guess dressed as a fact.
    /// `payments` are banks' and cards' word for payments not already a receipt's.
    static func linked(_ stretches: [Stretch], payments: [Spending.Entry], maxTicket: Double = 90,
                       calendar: Calendar = .current) -> [Stretch] {
        var used = Set<UUID>()
        var result = stretches
        for index in result.indices where result[index].paid == nil {
            let stretch = result[index]
            let found: (Spending.Entry, Paid.Evidence)?
            if stretch.mode == .metro {
                found = metroTicket(for: stretch, in: payments.filter { !used.contains($0.id) }, maxTicket: maxTicket,
                                    calendar: calendar)
            } else if stretch.mode.isRoad {
                found = paidOnArrival(for: stretch, in: payments.filter { !used.contains($0.id) })
            } else {
                found = nil
            }
            guard let (payment, evidence) = found else { continue }
            used.insert(payment.id)
            result[index].fare = payment.amount
            result[index].fareIsEstimate = false
            result[index].paid = Paid(amount: payment.amount, to: payment.payee ?? payment.source, at: payment.at,
                                      paymentID: payment.id, evidence: evidence)
        }
        return result
    }

    private static func metroTicket(for stretch: Stretch, in payments: [Spending.Entry], maxTicket: Double,
                                    calendar: Calendar) -> (Spending.Entry, Paid.Evidence)? {
        let tickets = payments.filter { payment in
            PaymentMail.isMetro(payment.payee) && payment.amount <= maxTicket
                && calendar.isDate(payment.at, inSameDayAs: stretch.start)
                && payment.at >= stretch.start.addingTimeInterval(-ticketBoughtBefore) && payment.at <= stretch.end
        }
        let nearest = { (a: Spending.Entry, b: Spending.Entry) in
            abs(a.at.timeIntervalSince(stretch.start)) < abs(b.at.timeIntervalSince(stretch.start))
        }
        // This ride's fare, give or take a QR ticket's or a smart card's discount.
        if let fare = stretch.fareIsEstimate ? stretch.fare : nil,
           let ticket = tickets.filter({ abs($0.amount - fare) <= max(2, fare * 0.1) }).min(by: nearest) {
            return (ticket, .fareAndTime)
        }
        let atStation = stretch.start.addingTimeInterval(-ticketAtStation)...stretch.start.addingTimeInterval(10 * 60)
        return tickets.filter { atStation.contains($0.at) }.min(by: nearest).map { ($0, .time) }
    }

    private static func paidOnArrival(for stretch: Stretch, in payments: [Spending.Entry]) -> (Spending.Entry, Paid.Evidence)? {
        let fare = stretch.fareIsEstimate ? stretch.fare : nil
        // Without a fare to go by, only a payment right as it ended.
        let window = fare == nil
            ? stretch.end.addingTimeInterval(-5 * 60)...stretch.end.addingTimeInterval(10 * 60)
            : stretch.end.addingTimeInterval(-paidOnArrivalBefore)...stretch.end.addingTimeInterval(paidOnArrivalAfter)
        let fitting = payments.filter { payment in
            guard window.contains(payment.at), !PaymentMail.isMetro(payment.payee) else { return false }
            // About what the ride costs: an auto's meter and a tip, not a meal.
            if let fare { return (fare * 0.5...fare * 2).contains(payment.amount) }
            return (20...1_500).contains(payment.amount)
        }
        return fitting.min { abs($0.at.timeIntervalSince(stretch.end)) < abs($1.at.timeIntervalSince(stretch.end)) }
            .map { ($0, fare == nil ? .time : .fareAndTime) }
    }

    nonisolated struct ModeTotal: Identifiable, Equatable, Sendable {
        var mode: WayTravelled
        var distanceMeters: Double
        var minutes: Int
        var fare: Double
        var id: WayTravelled { mode }
    }

    /// The day by mode: how far, how long, what it cost — furthest first. Only what was paid
    /// counts as cost: an estimate is no one's spending.
    static func byMode(_ stretches: [Stretch]) -> [ModeTotal] {
        Dictionary(grouping: stretches, by: \.mode).map { mode, list in
            ModeTotal(mode: mode,
                      distanceMeters: list.map(\.distanceMeters).reduce(0, +),
                      minutes: list.map(\.minutes).reduce(0, +),
                      fare: list.filter { !$0.fareIsEstimate }.compactMap(\.fare).reduce(0, +))
        }
        .sorted { $0.distanceMeters > $1.distanceMeters }
    }

    /// What the day's total holds beyond the stretches known: moving about, and the parts no fix
    /// could place.
    static func otherMovement(total: Double, stretches: [Stretch]) -> Double {
        max(0, total - stretches.map(\.distanceMeters).reduce(0, +))
    }
}
