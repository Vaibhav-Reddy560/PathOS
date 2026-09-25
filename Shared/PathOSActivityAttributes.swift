import ActivityKit
import Foundation

/// Which card this is. PathOS keeps one Live Activity per lane, so two things happening at once
/// get a card each — the pinned context stays put while a journey runs — rather than being cut
/// down to share one.
nonisolated enum ActivityLane: String, Codable, Hashable, Sendable, CaseIterable {
    /// Where you are and what's next: the card you pin.
    case context
    /// A way being followed, a metro journey, or a trip leg.
    case journey
    /// The pointer.
    case pointer
    /// Something that just happened and can't wait: an exit check, a note you left here.
    case alert

    /// Which gives way when iOS won't start another: the least urgent first.
    static let byImportance: [ActivityLane] = [.context, .alert, .pointer, .journey]
}

/// Shared between the app (which starts/updates activities) and the widget extension (which renders them).
nonisolated struct PathOSActivityAttributes: ActivityAttributes {
    nonisolated enum Mode: String, Codable, Hashable, Sendable {
        case exitCheck
        case commute
        case compass
        case spatialNote
        case venue
        case journey
        case trip
    }

    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var mode: Mode
        var title: String
        var subtitle: String
        /// SF Symbol name.
        var symbol: String
        /// Arrow angle relative to where the phone points; 0 = straight ahead.
        var relativeBearing: Double?
        var distanceMeters: Double?
        var etaMinutes: Int?
        /// `pathos://` URL opened when the activity is tapped.
        var deepLink: URL?
        /// When what's shown starts and ends. iOS doesn't wake PathOS on the minute, so the Lock
        /// Screen counts down to the start, and then to the end, on its own between updates.
        var startDate: Date?
        var endDate: Date?
        /// Short lines under the main one: an umbrella warning, what's next.
        var notes: [Note]?
        /// Overrides the mode's colour, such as amber for a class about to start.
        var role: SignalRole?
        /// When a journey gets you there. The Lock Screen counts down to it by itself, so the
        /// time left is right whenever you look, not whenever PathOS last ran.
        var arrivalDate: Date? = nil

        init(
            mode: Mode,
            title: String,
            subtitle: String,
            symbol: String,
            relativeBearing: Double? = nil,
            distanceMeters: Double? = nil,
            etaMinutes: Int? = nil,
            deepLink: URL? = nil,
            startDate: Date? = nil,
            endDate: Date? = nil,
            notes: [Note]? = nil,
            role: SignalRole? = nil,
            arrivalDate: Date? = nil
        ) {
            self.mode = mode
            self.title = title
            self.subtitle = subtitle
            self.symbol = symbol
            self.relativeBearing = relativeBearing
            self.distanceMeters = distanceMeters
            self.etaMinutes = etaMinutes
            self.deepLink = deepLink
            self.startDate = startDate
            self.endDate = endDate
            self.notes = notes
            self.role = role
            self.arrivalDate = arrivalDate
        }

        /// The colour it's drawn in.
        var tint: SignalRole { role ?? mode.role }

        /// Where a timed item is at `now`. The Lock Screen redraws when the content goes stale,
        /// at the item's start, and works this out afresh without PathOS running.
        func timing(at now: Date) -> Timing? {
            guard let startDate else { return nil }
            if now < startDate { return .startsIn(startDate) }
            if let endDate, now < endDate { return .endsIn(start: startDate, end: endDate) }
            return .over
        }
    }

    nonisolated enum Timing: Hashable, Sendable {
        case startsIn(Date)
        case endsIn(start: Date, end: Date)
        case over
    }

    nonisolated struct Note: Codable, Hashable, Sendable {
        var symbol: String
        var text: String
        var role: SignalRole
        /// Past this, the line says `laterText` instead, or goes: "Leave by 11:36" becomes
        /// "Leave now" at 11:36 without PathOS having to run, and "Next: CNS at 2:55" leaves
        /// once CNS starts.
        var until: Date? = nil
        var laterText: String? = nil

        /// What it says at `now`, or nil once it has nothing left to say.
        func text(at now: Date) -> String? {
            guard let until, now >= until else { return text }
            return laterText
        }
    }

    var sessionName: String
    /// Fixed when the card is started: it's what tells one of PathOS's cards from another.
    var lane: ActivityLane = .context
}
