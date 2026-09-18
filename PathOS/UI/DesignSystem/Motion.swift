import SwiftUI

/// Shared animation curves. Callers pass Reduce Motion so every morph degrades to a short fade.
enum PathMotion {
    /// Buttons, chips, mode switches.
    static let control = Animation.snappy(duration: 0.25)
    /// The island expanding and collapsing, like the Dynamic Island.
    static let island = Animation.bouncy(duration: 0.45)
    /// Signals arriving on the map.
    static let signal = Animation.smooth(duration: 0.35)

    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : animation
    }
}
