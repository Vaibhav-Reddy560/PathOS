import SwiftData
import SwiftUI

@main
struct PathOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .tint(.aurora)
                .onOpenURL { appState.handle(url: $0) }
        }
        .modelContainer(appState.modelContainer)
        .onChange(of: scenePhase) { _, phase in
            appState.scenePhaseChanged(phase)
        }
        .backgroundTask(.appRefresh(AppState.refreshTaskID)) {
            await AppState.shared.performBackgroundRefresh()
        }
    }
}
