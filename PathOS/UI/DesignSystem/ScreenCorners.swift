import SwiftUI
import UIKit

/// Reports the radius of the screen's own rounded corners.
///
/// A view whose corners follow its container's, laid over the whole screen, has exactly the
/// screen's corners, and UIKit will say what radius that resolved to. Zero on a screen with square
/// corners.
struct ScreenCornerReader: UIViewRepresentable {
    var onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.cornerConfiguration = .corners(radius: .containerConcentric())
        probe.onChange = onChange
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.onChange = onChange
    }

    final class Probe: UIView {
        var onChange: ((CGFloat) -> Void)?
        private var reported: CGFloat?

        override func layoutSubviews() {
            super.layoutSubviews()
            let radius = effectiveRadius(corner: .bottomLeft)
            guard radius != reported else { return }
            reported = radius
            // Outside layout, so the state it sets doesn't re-enter it.
            DispatchQueue.main.async { [onChange] in onChange?(radius) }
        }
    }
}
