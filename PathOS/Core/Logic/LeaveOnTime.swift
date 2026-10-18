import CoreLocation
import Foundation

/// When to leave for the next thing on your day that happens somewhere: your weekly schedule at
/// Work, or an event with a place. From how long it takes to get there from where you are now.
///
/// It speaks up when there's a decision to make: the hour before you need to set off, the moment
/// to go, and when you'd no longer make it on time. Once you're there, or already on your way and
/// in good time, it keeps quiet.
nonisolated enum LeaveOnTime {
    nonisolated struct Destination: Hashable, Sendable {
        var id: String
        var title: String
        /// "BMS College", "The Courtyard".
        var placeName: String
        var start: Date
        var end: Date
        var latitude: Double
        var longitude: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    nonisolated enum Status: Equatable, Sendable {
        /// Close enough to be there.
        case there
        /// More than an hour to spare before you need to leave.
        case inGoodTime(leaveBy: Date)
        /// Leave within the hour.
        case leaveSoon(leaveBy: Date)
        /// Time to go.
        case leaveNow(leaveBy: Date)
        /// Setting off now, you'd arrive after it starts.
        case late(arrival: Date, minutes: Int)
    }

    /// Within this, you're there.
    static let arrivalRadius = 300.0
    /// Time to find the room, the gate or the desk.
    static let buffer: TimeInterval = 5 * 60
    /// "Leave by…" shows from this long before.
    static let warnAhead: TimeInterval = 60 * 60
    /// Nothing further ahead than this is worth working out yet.
    static let lookAhead: TimeInterval = 4 * 3_600
    /// Something that started this recently, which you're not at yet, still counts: you're late.
    static let lateGrace: TimeInterval = 30 * 60
    /// This late and still not on your way, you've probably decided not to go: PathOS asks once
    /// instead of reminding you again.
    static let askToDropAfterMinutes = 30

    /// Whether to ask "still going?" rather than say you're late again.
    static func asksToDrop(_ status: Status, isOnTheWay: Bool) -> Bool {
        guard case .late(_, let minutes) = status else { return false }
        return minutes >= askToDropAfterMinutes && !isOnTheWay
    }

    static func status(start: Date, travel: TimeInterval, distance: Double, now: Date) -> Status {
        if distance <= arrivalRadius { return .there }
        let arrival = now.addingTimeInterval(travel)
        if arrival > start {
            return .late(arrival: arrival, minutes: Int((arrival.timeIntervalSince(start) / 60).rounded(.up)))
        }
        let leaveBy = start.addingTimeInterval(-travel - buffer)
        if now >= leaveBy { return .leaveNow(leaveBy: leaveBy) }
        if leaveBy.timeIntervalSince(now) <= warnAhead { return .leaveSoon(leaveBy: leaveBy) }
        return .inGoodTime(leaveBy: leaveBy)
    }

    /// The next place to be: the soonest thing starting within a few hours, or one that began a
    /// little while ago and hasn't ended. Back-to-back sessions at Work need no special case:
    /// after the first, you're there.
    static func next(in destinations: [Destination], now: Date) -> Destination? {
        destinations
            .filter { $0.end > now && $0.start > now.addingTimeInterval(-lateGrace) && $0.start.timeIntervalSince(now) <= lookAhead }
            .min { $0.start < $1.start }
    }

    // MARK: On your way

    /// What PathOS knows of you heading for the next place, from one check to the next.
    nonisolated struct Watch: Equatable, Sendable {
        var id: String
        /// Where you were, and how far from the place, when it was first watched.
        var startLatitude: Double
        var startLongitude: Double
        var startMeters: Double
        /// The distance last compared against: a fair bit closer since is setting off.
        var checkpointMeters: Double
        var isOnTheWay: Bool
    }

    /// Faster than a walk: in an auto, a bus, on a bike.
    static let movingSpeed = 2.0
    /// Moving within this of straight at the place is heading for it. Roads bend; the whole of a
    /// city isn't the way there.
    static let headingTolerance = 60.0
    /// Closer by this since the last check, or this far from where you were first seen and
    /// closer than you were, and you've set off.
    static let progressMeters = 150.0
    static let leftMeters = 300.0

    /// Whether you're on your way to the next place, from everything PathOS can see at this
    /// check: closer than the check before, gone from where you were when it was first watched,
    /// or moving at more than a walk towards it right now — which is what's known the moment you
    /// open PathOS in an auto, before any two checks could be compared. Only closer-by-150-m
    /// used to count, and with checks minutes apart in your pocket, it said you hadn't left home
    /// from halfway there.
    static func watch(_ previous: Watch?, id: String, here: CLLocationCoordinate2D, distance: Double,
                      speed: Double?, course: Double?, bearingToPlace: Double) -> Watch {
        let heading = isHeading(speed: speed, course: course, towards: bearingToPlace)
        guard var watch = previous, watch.id == id else {
            return Watch(id: id, startLatitude: here.latitude, startLongitude: here.longitude, startMeters: distance,
                         checkpointMeters: distance, isOnTheWay: heading)
        }
        let start = CLLocationCoordinate2D(latitude: watch.startLatitude, longitude: watch.startLongitude)
        let hasLeft = GeoMath.distance(from: start, to: here) >= leftMeters && distance < watch.startMeters - progressMeters
        if distance < watch.checkpointMeters - progressMeters {
            watch.checkpointMeters = distance
            watch.isOnTheWay = true
        } else if distance > watch.checkpointMeters + progressMeters {
            // Heading away again: not on your way, unless you're plainly moving towards it now.
            watch.checkpointMeters = distance
            watch.isOnTheWay = heading
        } else if heading || hasLeft {
            watch.isOnTheWay = true
        }
        return watch
    }

    /// Moving faster than a walk, roughly towards the place.
    static func isHeading(speed: Double?, course: Double?, towards bearing: Double) -> Bool {
        guard let speed, speed >= movingSpeed, let course, course >= 0 else { return false }
        let off = abs((course - bearing + 540).truncatingRemainder(dividingBy: 360) - 180)
        return off <= headingTolerance
    }

    // MARK: Reminders

    static let reminderPrefix = "pathos.leave."

    /// Whether a waiting "time to leave" should go: anything but the reminders for `keeping`,
    /// the one thing that's next. Something deleted, skipped, dropped or taken the day off from
    /// is no longer next, so its reminders go with it — they used to fire regardless.
    static func isStaleReminder(_ identifier: String, keeping id: String?) -> Bool {
        guard identifier.hasPrefix(reminderPrefix) else { return false }
        guard let id else { return true }
        return !identifier.hasPrefix(reminderPrefix + id + ".")
    }

    /// On foot for a short hop, by road otherwise, which is what Apple Maps can time in India.
    static let walkingDistance = 1_500.0

    /// Without a route from Apple Maps: straight-line distance at city speeds.
    static func roughTravelMinutes(distance: Double) -> Int {
        distance <= walkingDistance
            ? GeoMath.walkingMinutes(forDistance: distance)
            : max(5, Int((distance * 1.4 / (18_000.0 / 60)).rounded(.up)))
    }
}
