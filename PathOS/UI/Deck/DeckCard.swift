import PhotosUI
import SwiftUI

/// The deck collapsed: a glass card holding just the strip and the controls, floating a little
/// above the bottom of the screen.
///
/// iOS holds a sheet's smallest detent 8pt off the bottom edge, draws its glass itself, and
/// shows whatever sits below its first rows. Drawn here instead, the card sits where it should,
/// shows nothing but its rows, and opens the deck as a sheet when tapped, dragged up or given
/// a mode.
struct DeckCard: View {
    var cornerRadius: CGFloat
    /// The sheet's scale. The card is laid out at the screen's width and shrunk the same way, so its
    /// rows are drawn exactly as the resting sheet's were: laid out at its own width, they grew 4%
    /// the moment it took over, and every readout in the strip shifted.
    var scale: CGFloat
    var screenWidth: CGFloat
    /// From the resting sheet it took over from: how much further its glass reached above and below
    /// the card's own, on screen, and how far its rows sat from the glass's top. The bottom tucks
    /// away; the top and the rows stay where the sheet had them.
    var extraTop: CGFloat = 0
    var extraBottom: CGFloat = 0
    var contentShift: CGFloat = 0

    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// How far the card is being dragged, so it follows the finger until the deck opens.
    @State private var pull: CGFloat = 0
    @State private var isOpening = false

    var body: some View {
        VStack(spacing: 0) {
            InstrumentStrip()
                .padding(.horizontal, DeckLayout.inset)
                .padding(.top, DeckLayout.cardTopPadding + contentShift)

            DeckControlsRow()
                .padding(.top, DeckLayout.rowGap)
        }
        .frame(
            width: screenWidth,
            height: DeckLayout.restingCardHeight(for: dynamicTypeSize) + (extraTop + extraBottom) / scale,
            alignment: .top
        )
        .overlay(alignment: .top) {
            // The sheet's grabber, so the card still says it can be pulled up.
            Capsule()
                .fill(Color.mist.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 6)
                .accessibilityHidden(true)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .scaleEffect(scale, anchor: .bottom)
        .offset(y: pull)
        .gesture(
            // Measured on the screen, not on the card: the card moves with the finger, and a
            // translation measured against something moving feeds back on itself and shakes.
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in
                    // Up follows the finger, a little behind it; down barely gives.
                    let dy = value.translation.height
                    pull = dy < 0 ? dy * 0.6 : min(dy * 0.15, 6)
                    // Opens as soon as the swipe is plainly upward, rather than waiting for the
                    // finger to lift, so the card never stalls halfway.
                    if dy < -DeckLayout.openDragDistance, !isOpening {
                        isOpening = true
                        state.deckDetent = .medium
                    }
                }
                .onEnded { value in
                    // A short, quick flick opens it too.
                    if !isOpening, value.predictedEndTranslation.height < -DeckLayout.openDragDistance * 3 {
                        state.deckDetent = .medium
                    }
                    isOpening = false
                    withAnimation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion)) {
                        pull = 0
                    }
                }
        )
        .accessibilityAction(named: "Open") {
            state.deckDetent = .medium
        }
    }
}

/// What the deck presents while it is collapsed, and so not there to present anything.
///
/// Settings and the scanner open straight from the map. Anything else asked for while the deck
/// is collapsed opens the deck, which then presents it.
struct CollapsedDeckPresentations: ViewModifier {
    var isCollapsed: Bool

    @Environment(AppState.self) private var state
    @Environment(ScanFlowModel.self) private var scanFlow
    @State private var capture: UIImage?
    @State private var photoItem: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding { isCollapsed && state.isSettingsPresented } set: { state.isSettingsPresented = $0 }) {
                SettingsView()
            }
            .fullScreenCover(
                isPresented: Binding { isCollapsed && state.isScannerPresented } set: { state.isScannerPresented = $0 },
                onDismiss: reviewCapture
            ) {
                ScannerSheet { capture = $0 }
            }
            .photosPicker(
                isPresented: Binding { isCollapsed && state.isPhotoPickerPresented } set: { state.isPhotoPickerPresented = $0 },
                selection: $photoItem,
                matching: .images
            )
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    // The review opens the deck, which can't present while the picker is leaving.
                    while state.isPhotoPickerPresented {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    try? await Task.sleep(for: .milliseconds(400))
                    scanFlow.process(image, state: state)
                }
            }
            // Also when the card appears with a request already waiting, such as a link that
            // arrived during the launch screen.
            .onChange(of: isCollapsed && needsTheDeck, initial: true) { _, waiting in
                if waiting {
                    state.deckDetent = .medium
                }
            }
    }

    /// The review opens the deck, so it waits until the camera has gone.
    private func reviewCapture() {
        guard let image = capture else { return }
        capture = nil
        scanFlow.process(image, state: state)
    }

    /// Sheets only the open deck presents.
    private var needsTheDeck: Bool {
        state.isAddingNote || state.eventSheet != nil || state.isTimetablePresented
            || state.isJourneySheetPresented || state.isTripsPresented || scanFlow.eventToAdd != nil
    }
}
