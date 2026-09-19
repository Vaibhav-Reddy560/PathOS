import SwiftUI
import Testing
@testable import PathOS

/// The collapsed deck once looked cramped because its height was a hardcoded 96pt while its
/// contents needed 112: the stack overflowed, centred itself, and pushed the strip and the
/// controls against the glass. These guard the arithmetic that replaced the guess, and the card
/// and corners that came after it.
struct DeckLayoutTests {

    private func lineHeight(_ style: UIFont.TextStyle, _ category: UIContentSizeCategory = .large) -> CGFloat {
        UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)).lineHeight
    }

    /// Collapsed, the deck is a card of just its two rows, with a little less glass below them
    /// than above, where the grabber fills none of it.
    @Test func theCardHoldsJustItsRows() {
        let rows = lineHeight(.headline) + DeckLayout.rowGap + DeckLayout.controlHeight
        #expect(abs(DeckLayout.cardHeight(for: .large) - (DeckLayout.cardTopPadding + rows + DeckLayout.cardBottomPadding)) < 0.5)
        #expect(DeckLayout.cardBottomPadding < DeckLayout.cardTopPadding)
    }

    /// Collapsing, the sheet rests with its top and its rows exactly where the card's are, and its
    /// glass reaching down to where iOS holds a sheet. Handing over, the card only tucks its bottom
    /// edge up: when the card rose as a whole, every readout in the strip jumped.
    ///
    /// iOS lays the sheet out at the screen's width and scales it down to float 8pt in from the
    /// sides, so the sheet is `peek + glassBelowContent` tall before that scale; the card is drawn
    /// at the same scale.
    @Test(arguments: [(402.0, 0.9602), (430.0, 0.9628), (440.0, 0.9636)])
    func theSheetRestsAsTheCard(width: Double, measured: Double) {
        let rows = lineHeight(.headline) + DeckLayout.rowGap + DeckLayout.controlHeight
        let peek = DeckPeekDetent.height(for: .large)
        let card = DeckLayout.restingCardHeight(for: .large)
        let scale = DeckLayout.sheetScale(screenWidth: width)
        #expect(abs(scale - measured) < 0.0001)
        // Tops on screen, measured up from the screen's bottom edge.
        let sheetTop = DeckLayout.sheetBottomMargin + (peek + DeckLayout.glassBelowContent) * scale
        let cardTop = DeckLayout.cardBottomMargin + card * scale
        #expect(abs(sheetTop - cardTop) < 0.5)
        #expect(DeckLayout.sheetOverhang == DeckLayout.cardBottomMargin - DeckLayout.sheetBottomMargin)
        #expect(DeckLayout.headerTopPadding(reveal: 0) == DeckLayout.cardTopPadding)
        // Everything drawn at rest fits the stop exactly, so nothing overflows or centres itself.
        #expect(abs(DeckLayout.headerTopPadding(reveal: 0) + rows + DeckLayout.headerBottomPadding(reveal: 0, size: .large) - peek) < 0.5)
        // Pulled up, the cards fade in over a short drag while the rows rise to the open padding.
        #expect(DeckLayout.reveal(deckHeight: peek + 1, peekHeight: peek) == 0)
        #expect(DeckLayout.reveal(deckHeight: 440, peekHeight: peek) == 1)
        #expect(DeckLayout.headerTopPadding(reveal: 1) == DeckLayout.topPadding)
        #expect(DeckLayout.headerBottomPadding(reveal: 1, size: .large) == DeckLayout.bottomPadding)
    }

    /// Below about 100pt iOS 26 draws a sheet as a compact card, inset 28pt and scaled to 86%: at a
    /// 98.7pt stop the card took over from that, and came up 22pt too low. The rows always fit the
    /// card, which grows to match the sheet where the floor holds it taller.
    @Test(arguments: [DynamicTypeSize.xSmall, .small, .medium, .large, .xxxLarge, .accessibility3])
    func theRestingSheetIsNeverCompact(_ size: DynamicTypeSize) {
        #expect(DeckPeekDetent.height(for: size) >= DeckLayout.smallestFullSheet)
        #expect(DeckLayout.restingCardHeight(for: size) >= DeckLayout.cardHeight(for: size) - 0.01)
    }

    /// iOS floats the open deck 8pt in from the screen's edges and gives it one radius for all
    /// four corners. Its bottom corners must stay clear of the screen's own on every iPhone's
    /// screen, without going back to the pill that corners as round as the screen's make of it.
    @Test(arguments: [39.0, 44.0, 47.33, 53.33, 55.0, 62.0])
    func theOpenDecksCornersClearTheScreens(_ screen: Double) {
        let radius = DeckLayout.cornerRadius(screen: screen, margin: 8)
        let clearance = DeckLayout.cornerClearance(radius: radius, screen: screen, side: 8, bottom: 8)
        #expect(abs(clearance - DeckLayout.cornerGap) < 0.01)
        #expect(radius < screen - 8)
    }

    /// The card shares the open deck's corners and sits higher, so it clears them by more.
    @Test(arguments: [39.0, 44.0, 47.33, 53.33, 55.0, 62.0])
    func theCardClearsTheScreensCornersByMore(_ screen: Double) {
        let radius = DeckLayout.cornerRadius(screen: screen, margin: DeckLayout.sideMargin)
        let clearance = DeckLayout.cornerClearance(radius: radius, screen: screen,
                                                   side: DeckLayout.sideMargin, bottom: DeckLayout.cardBottomMargin)
        #expect(clearance > DeckLayout.cornerGap)
    }

    @Test func twentyFourRanIntoTheCornersOfA16Plus() {
        // What it looked like on the phone: a bottom corner cut by the screen's curve.
        #expect(DeckLayout.cornerClearance(radius: 24, screen: 55, side: 8, bottom: 8) < 0)
    }

    @Test func squareScreensGetAPlainCard() {
        #expect(DeckLayout.cornerRadius(screen: 0, margin: 8) == DeckLayout.squareScreenCornerRadius)
    }

    @Test func peekGrowsWithEveryTextSize() {
        let sizes: [DynamicTypeSize] = [.xSmall, .medium, .large, .xxLarge, .accessibility1, .accessibility5]
        let heights = sizes.map(DeckPeekDetent.height(for:))
        #expect(heights == heights.sorted())
        #expect(heights.first != heights.last)
        // The venue moves onto its own line, so accessibility sizes need considerably more room.
        #expect(DeckPeekDetent.height(for: .accessibility5) > DeckPeekDetent.height(for: .large) * 1.5)
    }

    @Test func controlGlyphsShareTheTextEdges() {
        // A mode button pads itself, so its row starts in by that much less and the icon you
        // see lands on the same edge as the venue name above it.
        #expect(DeckLayout.switcherInset + DeckLayout.switcherButtonPadding == DeckLayout.inset)

        // Same idea on the right: the settings glyph is centred in a bigger tap target.
        let target = DeckLayout.settingsTarget(glyph: DeckLayout.settingsGlyph)
        let inset = DeckLayout.settingsInset(glyph: DeckLayout.settingsGlyph, target: target)
        #expect(inset + (target - DeckLayout.settingsGlyph) / 2 == DeckLayout.inset)
    }

    @Test func settingsStaysOffTheGlassEdgeWhenTextIsHuge() {
        // A glyph big enough to swallow the inset must not slide off the card.
        let target = DeckLayout.settingsTarget(glyph: 60)
        #expect(DeckLayout.settingsInset(glyph: 60, target: target) >= 6)
        #expect(target >= DeckLayout.controlHeight)
    }
}
