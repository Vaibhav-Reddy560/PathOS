import CoreLocation
import Foundation

/// Whether you actually turned up to the things on your day.
///
/// PathOS counts a day's events, and counting the ones you skipped makes the number a lie. But it
/// can only ever have glimpses: the phone is closed for most of the day, and a location it doesn't
/// have is not evidence of absence. So the rule is deliberately one-sided — an event counts as
/// attended unless PathOS *saw* you somewhere else while it was on, or you said you weren't going.
/// Silence always means you went.
nonisolated enum Attendance {

    /// What one look at where you are says about one thing on your day.
    nonisolated enum Sighting: Equatable, Sendable {
        case there
        case away
        /// Somewhere in between, or nowhere known: says nothing either way.
        case unknown
    }

    nonisolated enum Verdict: Equatable, Sendable {
        case attended
        case missed
        /// Never seen either way: counted as attended, and not written down.
        case unknown
    }

    /// Close enough to be at it. A campus, a college, a hall: the same radius the rest of PathOS
    /// treats as having arrived.
    static let thereRadius = LeaveOnTime.arrivalRadius
    /// Far enough that you are plainly not there. The gap between the two is deliberate: nothing
    /// is concluded from being somewhere on the edge of a big site.
    static let awayRadius = 800.0

    static func sighting(at location: CLLocationCoordinate2D?, of place: CLLocationCoordinate2D?) -> Sighting {
        guard let location, let place else { return .unknown }
        let away = GeoMath.distance(from: location, to: place)
        if away <= thereRadius { return .there }
        return away >= awayRadius ? .away : .unknown
    }

    /// What to write down once something has finished.
    static func verdict(sawThere: Bool, sawAway: Bool, wasDropped: Bool) -> Verdict {
        if sawThere { return .attended }
        if wasDropped { return .missed }
        return sawAway ? .missed : .unknown
    }

    /// How many of a day's things you were at: everything except what's known to have been missed.
    static func count(_ ids: [String], missed: Set<String>) -> Int {
        ids.filter { !missed.contains($0) }.count
    }

    /// How many of a day's things are behind you: marked done, or over and not seen missed.
    ///
    /// Not what's still to come. Counting the whole day's list from the morning on meant marking
    /// something done changed nothing — it was already in the number.
    static func finished(_ items: [(id: String, end: Date)], done: Set<String>, missed: Set<String>, now: Date) -> Int {
        items.filter { done.contains($0.id) || ($0.end <= now && !missed.contains($0.id)) }.count
    }
}

/// What a thing on your day offers from its long-press menu: only what makes sense at that moment.
///
/// A session you were seen at and finished offered "I didn't go", "Not done yet" and "Skip this
/// session today" — three things that can't be true of something already done and behind you.
nonisolated enum DayItemMenu {

    nonisolated enum Action: Hashable, Sendable {
        case takeMeThere
        case markDone
        case notDoneYet
        case iWasThere
        case iDidntGo
        case skipToday
    }

    static func actions(start: Date, end: Date, now: Date, isDone: Bool, seenThere: Bool, isMissed: Bool,
                        hasPlace: Bool, canBeDone: Bool, canBeSkipped: Bool) -> Set<Action> {
        var actions: Set<Action> = []
        let isOver = isDone || end <= now
        let isOn = start <= now && now < end
        // Getting there is for something still to come, or on.
        if hasPlace, !isOver {
            actions.insert(.takeMeThere)
        }
        // Done is said while it's on; taken back only before it was meant to end, since after
        // that it's over whether or not you said so.
        if canBeDone {
            if !isDone, isOn { actions.insert(.markDone) }
            if isDone, now < end { actions.insert(.notDoneYet) }
        }
        // PathOS's guess about where you were is put right only where it guessed: not when it
        // saw you there, and not when you said you'd done it.
        if hasPlace, start < now {
            if isMissed {
                actions.insert(.iWasThere)
            } else if !seenThere, !isDone {
                actions.insert(.iDidntGo)
            }
        }
        // Skipping is for a session that hasn't happened, or is happening — not one that has.
        if canBeSkipped, !isOver {
            actions.insert(.skipToday)
        }
        return actions
    }
}
