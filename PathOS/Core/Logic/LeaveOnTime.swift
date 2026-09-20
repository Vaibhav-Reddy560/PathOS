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

    /// On foot for a short hop, by road otherwise, which is what Apple Maps can time in India.
    static let walkingDistance = 1_500.0

    /// Without a route from Apple Maps: straight-line distance at city speeds.
    static func roughTravelMinutes(distance: Double) -> Int {
        distance <= walkingDistance
            ? GeoMath.walkingMinutes(forDistance: distance)
            : max(5, Int((distance * 1.4 / (18_000.0 / 60)).rounded(.up)))
    }
}
