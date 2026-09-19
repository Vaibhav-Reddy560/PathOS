import SwiftUI
import UIKit

/// Where the collapsed sheet came to rest, as drawn on screen.
struct SheetRest: Equatable {
    /// The sheet's glass.
    var glass: CGRect
    /// Where the deck's content begins, a fraction of a point off the glass's top after iOS rounds
    /// the detent to the pixel grid.
    var contentTop: CGFloat
    /// iOS lays a floating sheet out at the screen's full width and scales it down to float in from
    /// the edges; this is by how much.
    var scale: CGFloat
    var screenHeight: CGFloat
}

/// Says when the sheet it sits in has come to rest on screen, and where.
///
/// The detent changes as soon as a drag ends, well before the sheet's spring has settled, and how
/// long that takes depends on the flick. Swapping the sheet for the card after a fixed wait swapped
/// it mid-flight. This follows the sheet's on-screen position frame by frame, as it is drawn rather
/// than where it's headed, and reports once it has stopped, so the card can take its place exactly.
struct SheetRestProbe: UIViewRepresentable {
    /// Watching only while this is true; it fires at most once each time it's set.
    var isArmed: Bool
    var onRest: (SheetRest) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onRest = onRest
        view.isArmed = isArmed
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: ()) {
        view.isArmed = false
    }

    final class ProbeView: UIView {
        /// Slower than this, in points a second, counts as still: within half a point of rest.
        static let stillSpeed: CGFloat = 10
        /// How long it must stay that slow, so the turn at the top of a bounce doesn't count.
        static let stillFor: CFTimeInterval = 0.08

        var onRest: ((SheetRest) -> Void)?
        var isArmed = false {
            didSet {
                guard isArmed != oldValue else { return }
                link?.invalidate()
                link = nil
                last = nil
                stillSince = nil
                if isArmed {
                    let link = CADisplayLink(target: self, selector: #selector(tick))
                    link.add(to: .main, forMode: .common)
                    self.link = link
                }
            }
        }

        private var link: CADisplayLink?
        private var last: (top: CGFloat, time: CFTimeInterval)?
        private var stillSince: CFTimeInterval?

        @objc private func tick(_ link: CADisplayLink) {
            // Presentation layers are what's on screen mid-animation; the model layers already
            // hold where the sheet is going.
            guard let window, let shown = layer.presentation() else { return }
            let top = shown.convert(CGPoint.zero, to: window.layer.presentation() ?? window.layer).y
            let now = link.timestamp
            defer { last = (top, now) }
            guard let last, now > last.time else { return }

            let speed = abs(top - last.top) / (now - last.time)
            guard speed < Self.stillSpeed else {
                stillSince = nil
                return
            }
            let since = stillSince ?? last.time
            stillSince = since
            if now - since >= Self.stillFor {
                isArmed = false
                onRest?(rest(in: window))
            }
        }

        /// At rest, so the model layers are what's on screen.
        private func rest(in window: UIWindow) -> SheetRest {
            let contentTop = convert(CGPoint.zero, to: nil).y
            // The sheet's container is the ancestor iOS scales down.
            var view = superview
            while let current = view, current !== window {
                if current.transform.a != 1 {
                    return SheetRest(glass: current.convert(current.bounds, to: nil), contentTop: contentTop,
                                     scale: current.transform.a, screenHeight: window.bounds.height)
                }
                view = current.superview
            }
            return SheetRest(glass: convert(bounds, to: nil), contentTop: contentTop, scale: 1, screenHeight: window.bounds.height)
        }
    }
}
