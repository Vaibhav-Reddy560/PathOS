import SwiftUI
import UIKit

/// The deck's three resting heights.
nonisolated enum DeckStop: Hashable, Sendable, CaseIterable {
    /// Just the strip and the controls, floating above the bottom of the screen.
    case collapsed
    /// Half the screen, the map still in view above it.
    case half
    /// Up to just under the island.
    case full
}

/// The deck's geometry: one set of edges for its header, and the heights it rests at and moves
/// between.
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
    /// selected pill's glass never reaches the deck's rounded corner, where it looks pinched.
    static let switcherButtonPadding: CGFloat = 10
    static let switcherInset = inset - switcherButtonPadding
    /// The settings glyph is centred in its tap target, so the row sits in by less than the text.
    static func settingsInset(glyph: CGFloat, target: CGFloat) -> CGFloat {
        max(6, inset - (target - glyph) / 2)
    }
    static func settingsTarget(glyph: CGFloat) -> CGFloat {
        max(controlHeight, glyph + 24)
    }

    // MARK: The panel

    /// Glass above the strip when collapsed, the grabber included.
    static let cardTopPadding: CGFloat = 28
    /// Glass below the controls when collapsed: less than above, since the grabber fills part of
    /// the top.
    static let cardBottomPadding: CGFloat = 18
    /// In from the screen's sides.
    static let sideMargin: CGFloat = 8
    /// Up from the screen's bottom edge, clear of the home indicator. The same at every height,
    /// so collapsing only ever moves the top: once iOS's sheet did the moving, and it held its
    /// glass lower than the collapsed card, which then had to rise into place.
    static let bottomMargin: CGFloat = 16
    /// Below the top of the safe area when full: clear of the island.
    static let fullTopClearance: CGFloat = 60
    /// Half open, the deck's top sits this far down the screen, as a sheet's medium height does.
    static let halfFraction: CGFloat = 0.5
    /// How far past its collapsed height the deck is pulled before its cards have fully faded in.
    static let revealDistance: CGFloat = 72

    /// Collapsed: the strip and the mode switcher with the card's padding, measured rather than
    /// guessed. Once a guess, which left the rows too little room: the stack overflowed, centred
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

    /// The deck's height at each stop, given the whole screen's height, its top safe area and how
    /// tall the collapsed card is. With the keyboard up, the deck sits on it and is never taller
    /// than the room left.
    static func height(of stop: DeckStop, collapsed: CGFloat, screen: CGFloat, topSafeArea: CGFloat, keyboard: CGFloat = 0) -> CGFloat {
        let tallest = screen - keyboard - topSafeArea - fullTopClearance - bottomMargin
        let height: CGFloat = switch stop {
        case .collapsed: collapsed
        case .half: screen * (1 - halfFraction) - bottomMargin
        case .full: tallest
        }
        return max(collapsed, min(height, tallest))
    }

    /// Where a drag that ends at `height`, moving at `velocity` points a second (positive is
    /// growing), comes to rest. It carries on as far as a flick would, like a scroll view; a
    /// deliberate flick always goes on to the next stop that way rather than settling back.
    static func settle(height: CGFloat, velocity: CGFloat, stops: [DeckStop: CGFloat]) -> DeckStop {
        let projected = height + velocity * 0.2
        let onward = abs(velocity) > 300
            ? stops.filter { velocity > 0 ? $0.value > height + 1 : $0.value < height - 1 }
            : [:]
        let pool = onward.isEmpty ? stops : onward
        return pool.min { abs($0.value - projected) < abs($1.value - projected) }?.key ?? .collapsed
    }

    /// Past its shortest or tallest, the deck gives a little and pulls back, as a scroll view does.
    static func rubberBand(_ height: CGFloat, lowest: CGFloat, highest: CGFloat) -> CGFloat {
        if height < lowest { return lowest - (lowest - height) * 0.3 }
        if height > highest { return highest + (height - highest) * 0.3 }
        return height
    }

    /// How much of the deck's cards show, from 0 collapsed to 1 a short pull above it.
    static func reveal(deckHeight: CGFloat, collapsedHeight: CGFloat) -> Double {
        min(max((deckHeight - collapsedHeight - 2) / revealDistance, 0), 1)
    }

    /// Glass above the strip: the card's when collapsed, rising to the open deck's as the cards
    /// appear.
    static func headerTopPadding(reveal: Double) -> CGFloat {
        cardTopPadding + (topPadding - cardTopPadding) * reveal
    }

    /// Below the controls: the card's when collapsed; open, the gap above the cards.
    static func headerBottomPadding(reveal: Double) -> CGFloat {
        cardBottomPadding + (bottomPadding - cardBottomPadding) * reveal
    }

    // MARK: Corners

    /// The least room between the deck's bottom corners and the screen's own rounded corners.
    static let cornerGap: CGFloat = 4
    /// On a screen with square corners, where nothing constrains the deck's.
    static let squareScreenCornerRadius: CGFloat = 28
    /// Where a circular corner crosses its diagonal, as a fraction of its radius. Apple's
    /// continuous corners measure 0.2916, near enough the same.
    private static let cornerReach = 1 - 1 / 2.squareRoot()

    /// The deck's corner radius: as low as it can go while its bottom corners, `margin` in from
    /// the screen's side and bottom, keep `cornerGap` from the screen's. The deck floats higher
    /// than that, so they clear it by more.
    ///
    /// As round as the screen's less the margin, the corners run parallel to the screen's but make
    /// a pill of a short card. Each point of radius less brings a bottom corner closer to the
    /// screen's curve, until it touches it: at 24 on an iPhone 16 Plus, 8pt from the edges, it did.
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
