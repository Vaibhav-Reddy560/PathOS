import SwiftUI

/// The map pin from the icon: a round head tapering to a point, with a hole in the head.
///
/// One shape for wherever PathOS marks where you're going — the launch animation, and the end of
/// the line on the map that leads you there — so the pin you see land on the first screen is the
/// one waiting at the end of every drive.
nonisolated enum PinShape {
    static let headRadius = 11.0
    static let height = 30.0

    static func path(tip: CGPoint, inset: Double = 0) -> Path {
        let r = headRadius - inset
        let head = CGPoint(x: tip.x, y: tip.y - (height - headRadius))
        // Tangents from the tip to the head's circle, so the sides meet the head smoothly.
        let distance = hypot(tip.x - head.x, tip.y - head.y)
        let spread = asin(min(1, r / distance))
        let down = Double.pi / 2
        var path = Path()
        path.move(to: CGPoint(x: tip.x, y: tip.y - inset * 1.4))
        path.addArc(center: head, radius: r,
                    startAngle: .radians(down + (Double.pi / 2 - spread)),
                    endAngle: .radians(down - (Double.pi / 2 - spread)),
                    clockwise: false)
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: head.x - 4.2, y: head.y - 4.2, width: 8.4, height: 8.4))
        return path
    }
}
