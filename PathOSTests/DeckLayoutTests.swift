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

    /// The deck's bottom never moves: every stop shares one bottom margin, so collapsing only
    /// lowers the top. When iOS's sheet did the collapsing, its glass rested 8pt lower than the
    /// card, which then rose into place with a flash.
    @Test(arguments: [(874.0, 62.0), (932.0, 59.0), (956.0, 62.0)])
    func theStopsRiseInOrderFromOneBottom(screen: Double, top: Double) {
        let collapsed = DeckLayout.cardHeight(for: .large)
        let heights = DeckStop.allCases.map { DeckLayout.height(of: $0, collapsed: collapsed, screen: screen, topSafeArea: top) }
        #expect(heights == heights.sorted())
        #expect(heights[0] == collapsed)
        // Full, it stops clear of the island.
        #expect(abs(screen - DeckLayout.bottomMargin - heights[1] - (top + DeckLayout.fullTopClearance)) < 0.5)
    }

    @Test func theKeyboardShortensTheDeckButNeverBelowCollapsed() {
        let collapsed = DeckLayout.cardHeight(for: .large)
        let open = DeckLayout.height(of: .full, collapsed: collapsed, screen: 874, topSafeArea: 62)
        let typing = DeckLayout.height(of: .full, collapsed: collapsed, screen: 874, topSafeArea: 62, keyboard: 336)
        #expect(open - typing == 336)
        #expect(DeckLayout.height(of: .full, collapsed: collapsed, screen: 874, topSafeArea: 62, keyboard: 800) == collapsed)
    }

    /// Two stops and nothing between: wherever a drag is let go, the deck ends up closed or
    /// open. A flick goes on its way, and never falls back against it.
    @Test func dragsSettleOpenOrClosed() {
        #expect(DeckStop.allCases == [.collapsed, .full])
        let stops: [DeckStop: CGFloat] = [.collapsed: 126, .full: 736]
        // Let go slowly, it goes to whichever is nearer, even from halfway.
        #expect(DeckLayout.settle(height: 400, velocity: 0, stops: stops) == .collapsed)
        #expect(DeckLayout.settle(height: 450, velocity: 0, stops: stops) == .full)
        // A quick flick up from just above collapsed opens it all the way, however little it moved.
        #expect(DeckLayout.settle(height: 140, velocity: 900, stops: stops) == .full)
        // Flicked down from near full, it doesn't bounce back up.
        #expect(DeckLayout.settle(height: 720, velocity: -700, stops: stops) == .collapsed)
    }

    /// Glass for the first half of the way up, solid at full, darkening only in between.
    @Test func theDeckDarkensOnlyNearFull() {
        #expect(DeckLayout.depth(deckHeight: 126, collapsedHeight: 126, fullHeight: 736) == 0)
        #expect(DeckLayout.depth(deckHeight: 431, collapsedHeight: 126, fullHeight: 736) == 0)
        #expect(abs(DeckLayout.depth(deckHeight: 583.5, collapsedHeight: 126, fullHeight: 736) - 0.5) < 0.001)
        #expect(DeckLayout.depth(deckHeight: 736, collapsedHeight: 126, fullHeight: 736) == 1)
        #expect(DeckLayout.depth(deckHeight: 760, collapsedHeight: 126, fullHeight: 736) == 1)
    }

    @Test func pastItsEndsTheDeckGivesALittle() {
        #expect(DeckLayout.rubberBand(100, lowest: 126, highest: 736) > 100)
        #expect(DeckLayout.rubberBand(100, lowest: 126, highest: 736) < 126)
        #expect(DeckLayout.rubberBand(800, lowest: 126, highest: 736) < 800)
        #expect(DeckLayout.rubberBand(400, lowest: 126, highest: 736) == 400)
    }

    /// Collapsed, only the rows show, with the card's padding; pulled up, the cards fade in over a
    /// short drag while the rows move to the open padding.
    @Test func theCardsFadeInAsTheDeckOpens() {
        let collapsed = DeckLayout.cardHeight(for: .large)
        #expect(DeckLayout.reveal(deckHeight: collapsed + 1, collapsedHeight: collapsed) == 0)
        #expect(DeckLayout.reveal(deckHeight: collapsed + 200, collapsedHeight: collapsed) == 1)
        #expect(DeckLayout.headerTopPadding(reveal: 0) == DeckLayout.cardTopPadding)
        #expect(DeckLayout.headerTopPadding(reveal: 1) == DeckLayout.topPadding)
        #expect(DeckLayout.headerBottomPadding(reveal: 0) == DeckLayout.cardBottomPadding)
        #expect(DeckLayout.headerBottomPadding(reveal: 1) == DeckLayout.bottomPadding)
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
                                                   side: DeckLayout.sideMargin, bottom: DeckLayout.bottomMargin)
        #expect(clearance > DeckLayout.cornerGap)
    }

    @Test func twentyFourRanIntoTheCornersOfA16Plus() {
        // What it looked like on the phone: a bottom corner cut by the screen's curve.
        #expect(DeckLayout.cornerClearance(radius: 24, screen: 55, side: 8, bottom: 8) < 0)
    }

    @Test func squareScreensGetAPlainCard() {
        #expect(DeckLayout.cornerRadius(screen: 0, margin: 8) == DeckLayout.squareScreenCornerRadius)
    }

    @Test func theCollapsedDeckGrowsWithEveryTextSize() {
        let sizes: [DynamicTypeSize] = [.xSmall, .medium, .large, .xxLarge, .accessibility1, .accessibility5]
        let heights = sizes.map(DeckLayout.cardHeight(for:))
        #expect(heights == heights.sorted())
        #expect(heights.first != heights.last)
        // The venue moves onto its own line, so accessibility sizes need considerably more room.
        #expect(DeckLayout.cardHeight(for: .accessibility5) > DeckLayout.cardHeight(for: .large) * 1.5)
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
