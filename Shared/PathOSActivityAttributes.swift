import ActivityKit
import Foundation

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
            role: SignalRole? = nil
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
    }

    var sessionName: String
}
