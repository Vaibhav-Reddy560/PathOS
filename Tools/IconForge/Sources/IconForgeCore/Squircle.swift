import CoreGraphics
import Foundation

/// The iOS icon outline.
///
/// The PNG itself is a full-bleed square — iOS applies the real mask — but the bevel and the rim
/// light have to be drawn where that mask will land, or they get trimmed unevenly at the corners.
public enum Squircle {
    /// A superellipse with this exponent is the usual close fit for Apple's continuous-corner icon
    /// shape; the corners stay curved the whole way round instead of meeting a straight edge.
    public static let exponent = 5.0

    public static func path(size: Double, inset: Double = 0, samples: Int = 1440) -> CGPath {
        let radius = size / 2 - inset
        let center = size / 2
        let path = CGMutablePath()
        for i in 0...samples {
            let angle = Double(i) / Double(samples) * 2 * .pi
            let cosine = cos(angle), sine = sin(angle)
            // |x|^n + |y|^n = 1, solved outward along each direction.
            let x = copysign(pow(abs(cosine), 2 / exponent), cosine)
            let y = copysign(pow(abs(sine), 2 / exponent), sine)
            let point = CGPoint(x: center + x * radius, y: center + y * radius)
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}
