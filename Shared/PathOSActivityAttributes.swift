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

        init(
            mode: Mode,
            title: String,
            subtitle: String,
            symbol: String,
            relativeBearing: Double? = nil,
            distanceMeters: Double? = nil,
            etaMinutes: Int? = nil,
            deepLink: URL? = nil
        ) {
            self.mode = mode
            self.title = title
            self.subtitle = subtitle
            self.symbol = symbol
            self.relativeBearing = relativeBearing
            self.distanceMeters = distanceMeters
            self.etaMinutes = etaMinutes
            self.deepLink = deepLink
        }
    }

    var sessionName: String
}
