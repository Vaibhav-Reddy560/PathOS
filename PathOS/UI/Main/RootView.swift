import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Built underneath from the start, so the map is already drawn when the cover lifts.
            WorldView()
            if !state.isLaunchComplete {
                // Leaves by carrying on into the map underneath: the drawn city keeps growing at
                // the rate it was already growing at, so the two read as one move rather than a
                // picture being swapped for a map.
                LaunchView()
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 1.22)))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.55), value: state.isLaunchComplete)
        // Long enough for the route to draw and the pin to land; with Reduce Motion there's
        // nothing to watch, so it only waits for PathOS itself.
        .task { await state.finishLaunch(minimum: reduceMotion ? 0.7 : 1.35) }
    }
}
