import CoreLocation
import Observation
import UIKit

/// One scan at a time: capture → read → a draft the user can fix → an action.
/// Shared by the rail's camera button, the photo picker and the review page in the deck.
@Observable
final class ScanFlowModel {
    var draft: ScanDraft?
    var eventToAdd: EventDraft?
    private(set) var isAnalyzing = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var capturedImage: UIImage?

    /// The deck shows the review page while this is true.
    var isReviewing: Bool { isAnalyzing || draft != nil || errorMessage != nil }

    func process(_ image: UIImage, state: AppState) {
        capturedImage = image
        draft = nil
        errorMessage = nil
        isAnalyzing = true
        state.selectedSignalID = nil
        state.deckDetent = .large
        Task {
            defer { isAnalyzing = false }
            do {
                draft = try await state.snap.analyze(image: image)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func addToCalendar(state: AppState) {
        guard let draft else { return }
        eventToAdd = EventDraft(
            title: draft.title,
            start: draft.eventStart ?? Date().addingTimeInterval(3_600),
            location: draft.venue,
            notes: draft.summary
        )
        state.snap.saveRecord(draft, at: state.location.location)
    }

    func eventEditorFinished(saved: Bool, state: AppState) {
        eventToAdd = nil
        if saved {
            finish("Added to Calendar", state: state)
        }
    }

    func logExpense(state: AppState) {
        guard let draft else { return }
        if state.snap.saveExpense(draft) != nil {
            state.snap.saveRecord(draft, at: state.location.location)
            finish("Expense logged", state: state)
        } else {
            state.showToast("Enter the amount first", role: .attention, symbol: "exclamationmark.circle.fill")
        }
    }

    func pinToThisSpot(state: AppState) async {
        guard let draft else { return }
        guard let here = await state.location.currentLocation() else {
            state.showToast("Couldn't get your location", role: .attention, symbol: "location.slash.fill")
            return
        }
        state.vault.saveNote(
            title: draft.title,
            body: draft.parkingLabel ?? draft.summary,
            at: here.coordinate,
            photoData: capturedImage?.jpegData(compressionQuality: 0.5)
        )
        state.snap.saveRecord(draft, at: here)
        await state.vault.syncGeofences(userLocation: here)
        finish("Pinned. PathOS will bring it back when you return", state: state)
    }

    func justSave(state: AppState) {
        guard let draft else { return }
        state.snap.saveRecord(draft, at: state.location.location)
        finish("Saved to Vault", state: state)
    }

    func cancel() {
        draft = nil
        errorMessage = nil
        capturedImage = nil
    }

    private func finish(_ message: String, state: AppState) {
        draft = nil
        capturedImage = nil
        state.haptics.success()
        state.showToast(message)
    }
}
