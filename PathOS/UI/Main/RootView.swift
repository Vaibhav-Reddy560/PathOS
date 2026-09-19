import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Built underneath from the start, so the map is already drawn when the cover lifts.
            WorldView()
            if !state.isLaunchComplete {
                // Leaves by zooming through, as if into the real map beneath.
                LaunchView()
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 1.08)))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.45), value: state.isLaunchComplete)
        // Long enough for the route to draw and the pin to land; with Reduce Motion there's
        // nothing to watch, so it only waits for PathOS itself.
        .task { await state.finishLaunch(minimum: reduceMotion ? 0.8 : 1.7) }
    }
}
