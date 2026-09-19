import PhotosUI
import SwiftUI

extension PresentationDetent {
    /// The deck collapsed: the sheet resting at the card's size, or the card that takes over.
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
    /// Open, the glass above the strip.
    static let topPadding: CGFloat = 20
    static let rowGap: CGFloat = 14
    /// Open, between the controls and the cards.
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

    // MARK: The collapsed card

    /// Glass above the strip, the grabber included.
    static let cardTopPadding: CGFloat = 28
    /// Glass below the controls: less than above, since the grabber fills part of the top.
    static let cardBottomPadding: CGFloat = 18
    /// How far in from the screen's sides iOS floats the open sheet; the card matches it.
    static let sideMargin: CGFloat = 8

    /// iOS lays a floating sheet out at the screen's full width, then scales the whole of it down,
    /// text and all, until it floats `sideMargin` in from the sides. The card is drawn the same way,
    /// or its rows would grow the moment it took over.
    static func sheetScale(screenWidth: CGFloat) -> CGFloat {
        screenWidth > 2 * sideMargin ? (screenWidth - 2 * sideMargin) / screenWidth : 1
    }

    /// For the detent, which isn't told the screen's width: every iPhone's scale is within a
    /// fraction of a percent of it (0.960 on an iPhone 17, 0.963 on a 16 Plus).
    static let typicalSheetScale: CGFloat = 0.96
    /// Up from the screen's bottom edge: higher than iOS would hold a sheet, clear of the home
    /// indicator.
    static let cardBottomMargin: CGFloat = 16
    /// How far the card is dragged up before the deck opens.
    static let openDragDistance: CGFloat = 24

    // MARK: Collapsing

    /// Where iOS floats a sheet above the screen's bottom edge.
    static let sheetBottomMargin: CGFloat = 8
    /// How much further down the resting sheet's glass reaches than the card's. The sheet rests
    /// with its top and its rows exactly where the card's are, so when the card takes over only its
    /// bottom edge tucks up: the strip's text never moves. Rising the card this far as a whole,
    /// as it once did, shifted every readout in the strip on each collapse.
    static let sheetOverhang = cardBottomMargin - sheetBottomMargin
    /// Below this detent iOS 26 draws a sheet as a smaller floating card instead, inset 28pt and
    /// scaled to 86%, which the card can't take over from. Measured: 98.7 was, 100.1 wasn't.
    static let smallestFullSheet: CGFloat = 102

    /// The card's height as laid out, before the sheet's scale: its rows, or the resting sheet's
    /// glass less the overhang where that's taller, so the card is exactly what the sheet was.
    static func restingCardHeight(for size: DynamicTypeSize) -> CGFloat {
        DeckPeekDetent.height(for: size) + glassBelowContent - sheetOverhang / typicalSheetScale
    }

    /// How much taller iOS makes the sheet than its detent, before scaling it: the glass reaches
    /// this far below the content, over the home indicator. Measured on iOS 26 at 32.5 to 33.9, as
    /// iOS rounds the detent to the pixel grid; the hand-over measures the real thing.
    static let glassBelowContent: CGFloat = 33.9
    /// How far past its resting size the sheet is dragged before its cards have fully faded in.
    static let revealDistance: CGFloat = 72

    /// The card: the strip and the mode switcher with the card's padding, measured rather than
    /// guessed. Laid out at the screen's width, like the sheet, so on screen it's this times the
    /// sheet's scale. Once a guess, which left the rows too little room: the stack overflowed, centred
    /// itself and pushed them hard against the glass.
    static func cardHeight(for size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let line = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits).lineHeight
        // At accessibility sizes the venue sits above the readouts instead of beside them.
        let strip = size.isAccessibilitySize ? line * 2 + 4 : line
        let controls = max(
            controlHeight,
            UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).lineHeight + 22
        )
        return cardTopPadding + strip + rowGap + controls + cardBottomPadding
    }

    /// How much of the deck's cards show, from 0 at its resting size to 1 a short drag above it.
    /// The sheet rounds its height to the pixel grid, so the first couple of points don't count.
    static func reveal(deckHeight: CGFloat, peekHeight: CGFloat) -> Double {
        min(max((deckHeight - peekHeight - 2) / revealDistance, 0), 1)
    }

    /// Glass above the strip: the card's at rest, rising to the open deck's as the cards appear.
    static func headerTopPadding(reveal: Double) -> CGFloat {
        cardTopPadding + (topPadding - cardTopPadding) * reveal
    }

    /// Below the controls: at rest, whatever of the resting detent the rows leave; open, the gap
    /// above the cards.
    static func headerBottomPadding(reveal: Double, size: DynamicTypeSize) -> CGFloat {
        let resting = DeckPeekDetent.height(for: size) - (cardHeight(for: size) - cardBottomPadding)
        return resting + (bottomPadding - resting) * reveal
    }

    // MARK: Corners

    /// The least room between the deck's bottom corners and the screen's own rounded corners.
    static let cornerGap: CGFloat = 4
    /// On a screen with square corners, where nothing constrains the deck's.
    static let squareScreenCornerRadius: CGFloat = 28
    /// Where a circular corner crosses its diagonal, as a fraction of its radius. Apple's
    /// continuous corners measure 0.2916, near enough the same.
    private static let cornerReach = 1 - 1 / 2.squareRoot()

    /// The deck's corner radius: as low as it can go while the open sheet's bottom corners keep
    /// `cornerGap` from the screen's. The collapsed card shares it, so the deck keeps its shape
    /// as it opens.
    ///
    /// iOS floats the sheet `margin` in from the screen's edges, draws its glass itself and gives
    /// it one radius for all four corners. As round as the screen's less the margin, the corners
    /// run parallel to the screen's but make a pill of a short card. Each point of radius less
    /// brings a bottom corner closer to the screen's curve, until it touches it: at 24 on an
    /// iPhone 16 Plus, it did.
    static func cornerRadius(screen: CGFloat, margin: CGFloat) -> CGFloat {
        guard screen > 0 else { return squareScreenCornerRadius }
        let radius = screen - (margin - cornerGap / 2.squareRoot()) / cornerReach
        return min(max(radius, 0), screen - margin)
    }

    /// The least room between a corner of this radius, set `side` in from the screen's side and
    /// `bottom` up from its bottom, and the screen's own corner.
    static func cornerClearance(radius: CGFloat, screen: CGFloat, side: CGFloat, bottom: CGFloat) -> CGFloat {
        // Measured from the screen's corner, the offsets between the two arcs' centres.
        let across = screen - side - radius
        let along = screen - bottom - radius
        guard across > 0, along > 0 else { return min(side, bottom) }
        return screen - radius - (across * across + along * along).squareRoot()
    }
}

/// The sheet's resting stop: collapsing, the deck shrinks to this under your finger, with its top
/// where the card's will be, then hands over to the card.
nonisolated struct DeckPeekDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        height(for: context.dynamicTypeSize)
    }

    /// Less the glass iOS adds below the content, so the glass is the card's height and the few
    /// points iOS holds a sheet lower than the card; the overhang is on screen, so unscaled here.
    /// Never so short that iOS switches to its compact sheet.
    static func height(for size: DynamicTypeSize) -> CGFloat {
        max(
            DeckLayout.cardHeight(for: size) + DeckLayout.sheetOverhang / DeckLayout.typicalSheetScale - DeckLayout.glassBelowContent,
            DeckLayout.smallestFullSheet
        )
    }
}

extension UIContentSizeCategory {
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

/// The deck as a sheet over the map. Every other presentation hangs off it while it is up,
/// because it is then the top-most presenter; once it has handed over to `DeckCard`, the map
/// presents instead.
struct DeckView: View {

    let signals: [WorldSignal]
    /// The screen's own corner radius, which the sheet's bottom corners must keep clear of.
    var screenCornerRadius: CGFloat = 0
    /// Collapsing, the sheet has come to rest at the card's place and can hand over to it.
    var onRestCollapsed: (SheetRest) -> Void = { _ in }

    @Environment(AppState.self) private var state
    @Environment(ScanFlowModel.self) private var scanFlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var photoItem: PhotosPickerItem?
    @State private var deckHeight: CGFloat = 0

    var body: some View {
        @Bindable var state = state
        @Bindable var scanFlow = scanFlow

        // At rest the deck is only its two rows, like the card it hands over to; the cards below
        // wait until it's pulled up, rather than peeking out from under the controls.
        let reveal = DeckLayout.reveal(deckHeight: deckHeight, peekHeight: DeckPeekDetent.height(for: dynamicTypeSize))

        VStack(spacing: 0) {
            InstrumentStrip()
                .padding(.horizontal, DeckLayout.inset)
                .padding(.top, DeckLayout.headerTopPadding(reveal: reveal))

            DeckControlsRow()
                .padding(.top, DeckLayout.rowGap)
                .padding(.bottom, DeckLayout.headerBottomPadding(reveal: reveal, size: dynamicTypeSize))

            if let toast = state.toast, reveal > 0.5 {
                ToastBanner(toast: toast)
                    .padding(.horizontal, DeckLayout.switcherInset)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            content
                .frame(maxHeight: .infinity, alignment: .top)
                .opacity(reveal)
                .allowsHitTesting(reveal > 0.5)
                .accessibilityHidden(reveal == 0)
        }
        // Anchored to the top so that if the deck is ever shorter than its header, the overflow
        // falls off the bottom instead of being centred and clipped at both glass edges.
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            SheetRestProbe(isArmed: state.deckDetent == .deckPeek, onRest: onRestCollapsed)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { deckHeight = $0 }
        // A constant, not the sheet's measured position: read while the sheet moves, it changed
        // the radius mid-drag and the sheet shook.
        .presentationCornerRadius(DeckLayout.cornerRadius(screen: screenCornerRadius, margin: DeckLayout.sideMargin))
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

/// The mode switcher and the settings glyph: the deck's second row, open or collapsed.
struct DeckControlsRow: View {
    @Environment(AppState.self) private var state
    @ScaledMetric(relativeTo: .subheadline) private var settingsGlyph = DeckLayout.settingsGlyph

    var body: some View {
        HStack(spacing: 12) {
            // Choosing a mode opens the deck at it, since collapsed it shows none of the mode.
            DeckModeSwitcher(selection: Binding { state.selectedTab } set: { state.showDeck($0) })
                .padding(.leading, DeckLayout.switcherInset)
            Spacer(minLength: 0)
            // No glass disc: a second glass edge this near the deck's rounded corner reads
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
    }

    private var settingsTarget: CGFloat { DeckLayout.settingsTarget(glyph: settingsGlyph) }
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
