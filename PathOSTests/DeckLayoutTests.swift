import SwiftUI
import Testing
@testable import PathOS

/// The peek deck looked cramped because its detent was a hardcoded 96pt while its contents
/// needed 112: the stack overflowed, centred itself, and pushed the strip and the controls
/// against the glass. These guard the arithmetic that replaced the guess.
struct DeckLayoutTests {

    /// Everything the peek draws, with nothing left over for the deck's content.
    private func headerHeight(_ size: DynamicTypeSize) -> CGFloat {
        DeckLayout.topPadding + DeckLayout.rowGap + DeckLayout.bottomPadding + DeckLayout.controlHeight
    }

    @Test func peekLeavesRoomForTheStripAndTheControls() {
        // The strip's own line height is on top of the fixed padding and the control row.
        #expect(DeckPeekDetent.height(for: .large) > headerHeight(.large))
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
