import PhotosUI
import SwiftUI

extension PresentationDetent {
    static let deckPeek = PresentationDetent.custom(DeckPeekDetent.self)
}

/// One set of edges for the whole deck header, so the strip's text, the mode icons and the
/// settings glyph line up down the left and right of the glass.
///
/// Controls are inset by less than the text because they carry their own padding: what should
/// line up is what you can see — the arrow with the first mode icon, the last readout with the
/// settings glyph — not the invisible boxes they sit in.
nonisolated enum DeckLayout {
    /// Where visible text and glyphs begin.
    static let inset: CGFloat = 24
    static let topPadding: CGFloat = 18
    static let rowGap: CGFloat = 8
    static let bottomPadding: CGFloat = 18
    static let controlHeight: CGFloat = 44
    /// At the default text size. It scales with Dynamic Type so it matches the mode icons.
    static let settingsGlyph: CGFloat = 17
    /// Mode buttons pad themselves, so their row starts further out. Kept small enough that the
    /// selected pill's glass never reaches the sheet's rounded corner, where it looks pinched.
    static let switcherButtonPadding: CGFloat = 10
    static let switcherInset = inset - switcherButtonPadding
    /// The settings glyph is centred in its tap target, so the row sits in by less than the text.
    static func settingsInset(glyph: CGFloat, target: CGFloat) -> CGFloat {
        max(6, inset - (target - glyph) / 2)
    }
    static func settingsTarget(glyph: CGFloat) -> CGFloat {
        max(controlHeight, glyph + 24)
    }
    /// iOS floats the sheet inside a margin, so the card draws a little shorter than the detent.
    static let cardMargin: CGFloat = 12
}

/// Just the instrument strip and the mode switcher, measured rather than guessed.
///
/// When this is too short the sheet's stack overflows and centres itself, pushing the strip and
/// the controls hard against the rounded glass edge — which reads as bad padding but is really
/// the deck being asked to fit in less room than its contents need.
nonisolated struct DeckPeekDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        height(for: context.dynamicTypeSize)
    }

    static func height(for size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let line = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits).lineHeight
        // At accessibility sizes the venue sits above the readouts instead of beside them.
        let strip = size.isAccessibilitySize ? line * 2 + 4 : line
        let controls = max(
            DeckLayout.controlHeight,
            UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).lineHeight + 22
        )
        return DeckLayout.topPadding + strip + DeckLayout.rowGap + controls
            + DeckLayout.bottomPadding + DeckLayout.cardMargin
    }
}

private extension UIContentSizeCategory {
    nonisolated init(_ size: DynamicTypeSize) {
        self = switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

/// The persistent bottom sheet. Every other presentation hangs off it, because while it is up
/// it is the top-most presenter.
struct DeckView: View {

    let signals: [WorldSignal]

    @Environment(AppState.self) private var state
    @Environment(ScanFlowModel.self) private var scanFlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var photoItem: PhotosPickerItem?
    @ScaledMetric(relativeTo: .subheadline) private var settingsGlyph = DeckLayout.settingsGlyph

    var body: some View {
        @Bindable var state = state
        @Bindable var scanFlow = scanFlow

        VStack(spacing: 0) {
            InstrumentStrip()
                .padding(.horizontal, DeckLayout.inset)
                .padding(.top, DeckLayout.topPadding)

            HStack(spacing: 12) {
                DeckModeSwitcher(selection: $state.selectedTab)
                    .padding(.leading, DeckLayout.switcherInset)
                Spacer(minLength: 0)
                // No glass disc: a second glass edge this near the sheet's rounded corner reads
                // as crowding. The glyph alone matches the unselected mode icons beside it.
                Button {
                    state.isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: settingsGlyph, weight: .semibold))
                        .foregroundStyle(.mist)
                        .frame(width: settingsTarget, height: settingsTarget)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .padding(.trailing, DeckLayout.settingsInset(glyph: settingsGlyph, target: settingsTarget))
                .accessibilityLabel("Settings")
            }
            .padding(.top, DeckLayout.rowGap)
            .padding(.bottom, DeckLayout.bottomPadding)

            if let toast = state.toast {
                ToastBanner(toast: toast)
                    .padding(.horizontal, DeckLayout.switcherInset)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            content
                .frame(maxHeight: .infinity, alignment: .top)
        }
        // Anchored to the top so that if the deck is ever shorter than its header, the overflow
        // falls off the bottom instead of being centred and clipped at both glass edges.
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion), value: state.toast)
        .onChange(of: state.selectedTab) {
            state.selectedSignalID = nil
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    scanFlow.process(image, state: state)
                }
                photoItem = nil
            }
        }
        .photosPicker(isPresented: $state.isPhotoPickerPresented, selection: $photoItem, matching: .images)
        .fullScreenCover(isPresented: $state.isScannerPresented) {
            ScannerSheet { image in
                scanFlow.process(image, state: state)
            }
        }
        .sheet(item: $scanFlow.eventToAdd) { event in
            EventEditor(draft: event) { saved in
                scanFlow.eventEditorFinished(saved: saved, state: state)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $state.isAddingNote) { AddNoteSheet() }
        .sheet(item: $state.eventSheet) { request in
            EventSheet(request: request)
        }
        .sheet(isPresented: $state.isTimetablePresented) { TimetableSheet() }
        .sheet(isPresented: $state.isJourneySheetPresented) { JourneySheet() }
        .sheet(isPresented: $state.isTripsPresented) { TripSheet() }
        .sheet(isPresented: $state.isSettingsPresented) { SettingsView() }
    }

    private var settingsTarget: CGFloat { DeckLayout.settingsTarget(glyph: settingsGlyph) }

    @ViewBuilder
    private var content: some View {
        if scanFlow.isReviewing {
            ScanReviewView()
        } else if let id = state.selectedSignalID, let signal = signals.first(where: { $0.id == id }) {
            SignalDetailView(signal: signal)
        } else {
            switch state.selectedTab {
            case .now: NowDeck()
            case .day: DayDeck()
            case .radar: RadarDeck()
            case .vault: VaultDeck()
            }
        }
    }
}

private struct ToastBanner: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(toast.role.color)
            Text(toast.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.ice)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.void.opacity(0.9), in: .capsule)
        .overlay { Capsule().strokeBorder(toast.role.color.opacity(0.35), lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}
