import SwiftUI

/// The deck: one glass panel over the map, from the collapsed strip up to just under the island.
///
/// Drawn here rather than as an iOS sheet. A sheet holds its glass 8pt off the bottom, draws that
/// glass itself and scales its content to float in from the sides, so the collapsed deck, which
/// sits higher, had to be a separate card that took over when a collapse finished: the glass
/// brightened, the grabber shrank and the bottom edge rose, every time. One panel at every
/// height has nothing to hand over. Its bottom never moves; dragging and collapsing only move
/// its top.
struct DeckPanel: View {
    let signals: [WorldSignal]
    /// The screen's own corner radius, which the deck's bottom corners keep clear of.
    var screenCornerRadius: CGFloat
    var screenHeight: CGFloat
    var topSafeArea: CGFloat

    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The stop the panel is drawn at. It follows `state.deckStop`, animated, except at the end
    /// of a drag, which animates it itself so the spring carries on at the finger's speed.
    @State private var shownStop: DeckStop = .collapsed
    /// How far the finger has moved the panel, down positive.
    @State private var drag: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        // Respects the keyboard only: with it up, the deck sits on it rather than under it.
        GeometryReader { proxy in
            let heights = self.heights(keyboard: max(0, screenHeight - proxy.size.height))
            let height = currentHeight(heights)
            let collapsed = heights[.collapsed] ?? 0
            let reveal = DeckLayout.reveal(deckHeight: height, collapsedHeight: collapsed)
            let depth = DeckLayout.depth(deckHeight: height, collapsedHeight: collapsed, fullHeight: heights[.full] ?? 0)
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

            DeckView(
                signals: signals,
                reveal: reveal,
                drag: dragGesture(heights: heights)
            )
            // A set width: content that wants more room is fitted or clipped, never allowed to
            // widen the deck past the screen's edge, which a row of buttons once did.
            .frame(width: max(0, proxy.size.width - 2 * DeckLayout.sideMargin), height: height, alignment: .top)
            // Pulled all the way up, the deck is a page of its own: the map behind goes dark.
            // Collapsed, it's glass over the map.
            .background(Color.deepSurface.opacity(depth), in: shape)
            .clipShape(shape)
            .glassEffect(.regular, in: shape)
            .contentShape(shape)
            .overlay(alignment: .top) {
                // Says the deck can be pulled; the same at every height.
                Capsule()
                    .fill(Color.mist.opacity(0.5))
                    .frame(width: 36, height: 5)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DeckLayout.sideMargin)
            .padding(.bottom, DeckLayout.bottomMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .accessibilityAction(named: shownStop == .collapsed ? "Open" : "Collapse") {
                state.deckStop = shownStop == .collapsed ? .full : .collapsed
            }
        }
        .ignoresSafeArea(.container)
        .onAppear { shownStop = state.deckStop }
        .onChange(of: state.deckStop) { _, stop in
            guard stop != shownStop else { return }
            withAnimation(PathMotion.resolve(.spring(duration: 0.45, bounce: 0), reduceMotion: reduceMotion)) {
                shownStop = stop
            }
        }
        .onChange(of: state.selectedTab) {
            state.selectedSignalID = nil
        }
    }

    private var cornerRadius: CGFloat {
        DeckLayout.cornerRadius(screen: screenCornerRadius, margin: DeckLayout.sideMargin)
    }

    private func heights(keyboard: CGFloat) -> [DeckStop: CGFloat] {
        let collapsed = DeckLayout.cardHeight(for: dynamicTypeSize)
        return Dictionary(uniqueKeysWithValues: DeckStop.allCases.map { stop in
            (stop, DeckLayout.height(of: stop, collapsed: collapsed, screen: screenHeight, topSafeArea: topSafeArea, keyboard: keyboard))
        })
    }

    private func currentHeight(_ heights: [DeckStop: CGFloat]) -> CGFloat {
        let base = heights[shownStop] ?? 0
        guard isDragging else { return base }
        return DeckLayout.rubberBand(base - drag, lowest: heights[.collapsed] ?? 0, highest: heights[.full] ?? 0)
    }

    /// Follows the finger, measured on the screen rather than on the panel: the panel moves with
    /// the finger, and a translation measured against something moving feeds back on itself.
    private func dragGesture(heights: [DeckStop: CGFloat]) -> AnyGesture<Void> {
        AnyGesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                isDragging = true
                drag = value.translation.height
            }
            .onEnded { value in
                let base = heights[shownStop] ?? 0
                let released = DeckLayout.rubberBand(base - value.translation.height, lowest: heights[.collapsed] ?? 0, highest: heights[.full] ?? 0)
                // The deck grows as the finger moves up.
                let velocity = -value.velocity.height
                let target = DeckLayout.settle(height: released, velocity: velocity, stops: heights)
                let distance = (heights[target] ?? released) - released
                // The spring starts at the finger's speed, as a share of the distance left to go.
                let initial = abs(distance) > 1 ? max(-8, min(velocity / distance, 8)) : 0
                withAnimation(PathMotion.resolve(.interpolatingSpring(duration: 0.45, bounce: 0, initialVelocity: initial), reduceMotion: reduceMotion)) {
                    shownStop = target
                    isDragging = false
                    drag = 0
                }
                state.deckStop = target
            }
            .map { _ in () })
    }
}

/// What the deck holds: the strip and the controls, then the mode's cards, which fade in as the
/// deck opens.
struct DeckView: View {
    let signals: [WorldSignal]
    /// How open the deck is, from 0 collapsed to 1 a short pull above.
    var reveal: Double
    var drag: AnyGesture<Void>

    @Environment(AppState.self) private var state
    @Environment(ScanFlowModel.self) private var scanFlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                InstrumentStrip()
                    .padding(.horizontal, DeckLayout.inset)
                    .padding(.top, DeckLayout.headerTopPadding(reveal: reveal))

                DeckControlsRow()
                    .padding(.top, DeckLayout.rowGap)
                    .padding(.bottom, DeckLayout.headerBottomPadding(reveal: reveal))
            }
            // The header always moves the deck, at any height.
            .contentShape(.rect)
            .gesture(drag)

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
                // Below full, the cards don't scroll and a drag on them moves the deck; at full
                // they scroll, and moving the deck is the header's job.
                .gesture(drag, including: state.deckStop == .full ? .subviews : .all)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion), value: state.toast)
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
            case .search: SearchDeck()
            }
        }
    }
}

/// For a deck mode's main scroll view. Below full it stays still, so a drag moves the deck
/// instead, the way a sheet's content does; at full, pulled down from its top, it collapses the
/// deck. Only a pull that starts at the top counts: scrolling back up and overshooting it
/// doesn't. Radar keeps that pull for scanning again.
struct DeckScroll: ViewModifier {
    var lowersOnPull = true

    @Environment(AppState.self) private var state
    /// How far above its top the content is, pulled down.
    @State private var pull: CGFloat = 0
    @State private var isAtTop = true
    @State private var startedAtTop = false

    func body(content: Content) -> some View {
        content
            .scrollDisabled(state.deckStop != .full)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                pull = max(0, -offset)
                isAtTop = offset <= 1
            }
            .onScrollPhaseChange { old, new in
                if new == .interacting {
                    startedAtTop = isAtTop
                } else if old == .interacting {
                    if lowersOnPull, startedAtTop, pull > 64 {
                        state.deckStop = .collapsed
                    }
                    startedAtTop = false
                }
            }
    }
}

extension View {
    func deckScroll(lowersOnPull: Bool = true) -> some View {
        modifier(DeckScroll(lowersOnPull: lowersOnPull))
    }
}

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
