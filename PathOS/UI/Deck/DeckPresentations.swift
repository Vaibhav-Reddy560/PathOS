import PhotosUI
import SwiftUI

/// Everything the deck opens over the map: the scanner and photo picker, and the sheets for
/// events, notes, the timetable, journeys, trips and Settings. They hang off the map screen, so
/// they open the same whether the deck is collapsed or open.
struct DeckPresentations: ViewModifier {
    @Environment(AppState.self) private var state
    @Environment(ScanFlowModel.self) private var scanFlow
    @State private var capture: UIImage?
    @State private var photoItem: PhotosPickerItem?

    func body(content: Content) -> some View {
        @Bindable var state = state
        @Bindable var scanFlow = scanFlow

        content
            .photosPicker(isPresented: $state.isPhotoPickerPresented, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    scanFlow.process(image, state: state)
                }
            }
            .fullScreenCover(isPresented: $state.isScannerPresented, onDismiss: reviewCapture) {
                ScannerSheet { capture = $0 }
            }
            .sheet(item: $scanFlow.eventToAdd) { event in
                EventEditor(draft: event) { saved in
                    scanFlow.eventEditorFinished(saved: saved, state: state)
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $state.isAddingNote) { AddNoteSheet() }
            .sheet(item: $state.waysRequest) { request in
                WaysToGetThereView(request: request)
            }
            .sheet(item: $state.eventSheet) { request in
                EventSheet(request: request)
            }
            .sheet(isPresented: $state.isTimetablePresented) { TimetableSheet() }
            .sheet(item: $state.editingSession) { session in
                if let entry = state.timetable.entry(id: session.slotID) {
                    SessionEditor(entry: entry, occurrence: session) { _, copies in
                        state.timetable.saveChanges()
                        for copy in copies { state.timetable.add(copy) }
                    }
                }
            }
            .sheet(isPresented: $state.isJourneySheetPresented) { JourneySheet() }
            .sheet(isPresented: $state.isTripsPresented) { TripSheet() }
            .sheet(isPresented: $state.isSettingsPresented) { SettingsView() }
    }

    /// Reviewed once the camera has gone, since the review may open an event editor of its own.
    private func reviewCapture() {
        guard let image = capture else { return }
        capture = nil
        scanFlow.process(image, state: state)
    }
}
