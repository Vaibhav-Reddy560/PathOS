import AppIntents
import Foundation

/// Assign to the Action Button: Settings → Action Button → Shortcut → "Ask PathOS".
nonisolated struct AskPathOSIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask PathOS"
    static let description = IntentDescription("Ask a hands-free question about what's around you.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppState.shared.activateAssistant(listen: true)
        return .result()
    }
}

struct SaveSpotIntent: AppIntent {
    static let title: LocalizedStringResource = "Save This Spot"
    static let description = IntentDescription("Pins a note to where you're standing, like your parking pillar or locker number.")

    @Parameter(title: "Note", requestValueDialog: "What should I remember here?")
    var note: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = AppState.shared
        guard let here = await state.location.currentLocation() else {
            return .result(dialog: "I couldn't get your location.")
        }
        state.vault.saveNote(
            title: note,
            body: "Saved \(Date().formatted(date: .abbreviated, time: .shortened))",
            at: here.coordinate
        )
        await state.vault.syncGeofences(userLocation: here)
        return .result(dialog: "Saved. I'll bring it up when you're back here.")
    }
}

nonisolated struct FindMySpotIntent: AppIntent {
    static let title: LocalizedStringResource = "Point Me to My Spot"
    static let description = IntentDescription("Opens the compass pointer toward your most recent saved spot.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let state = AppState.shared
        if let note = state.vault.activeNotes().first {
            state.startCompass(to: CompassTarget(id: note.geofenceID, name: note.title, latitude: note.latitude, longitude: note.longitude))
        }
        return .result()
    }
}

/// Runs without opening the app, so a Shortcuts time-of-day automation can pin it each morning.
nonisolated struct PinContextIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pin Context to Lock Screen"
    static let description = IntentDescription("Keeps rain warnings, your next class or event, and when to leave on your Lock Screen.")

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppState.shared.pinContext()
        return .result()
    }
}

nonisolated struct PathOSShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskPathOSIntent(),
            phrases: ["Ask \(.applicationName)", "Hey \(.applicationName)"],
            shortTitle: "Ask PathOS",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: SaveSpotIntent(),
            phrases: ["Save my spot in \(.applicationName)", "Remember this spot with \(.applicationName)"],
            shortTitle: "Save Spot",
            systemImageName: "mappin.and.ellipse"
        )
        AppShortcut(
            intent: FindMySpotIntent(),
            phrases: ["Find my spot with \(.applicationName)"],
            shortTitle: "Find My Spot",
            systemImageName: "location.north.line.fill"
        )
        AppShortcut(
            intent: PinContextIntent(),
            phrases: ["Pin my context in \(.applicationName)", "Put \(.applicationName) on my Lock Screen"],
            shortTitle: "Pin Context",
            systemImageName: "pin.fill"
        )
    }
}
