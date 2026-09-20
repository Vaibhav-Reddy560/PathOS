import CoreGraphics
import Foundation

/// SplitMix64. The map has to look hand-placed but be identical on every machine and every run,
/// so nothing here touches the system generator.
public struct Seeded {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    public mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }

    public mutating func double(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }

    public mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(unit() * Double(range.upperBound - range.lowerBound + 1))
            .clamped(to: 0...(range.upperBound - range.lowerBound))
    }

    public mutating func chance(_ probability: Double) -> Bool { unit() < probability }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.max(range.lowerBound, Swift.min(range.upperBound, self)) }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.max(range.lowerBound, Swift.min(range.upperBound, self)) }
}

enum Geometry {
    /// Catmull-Rom through the given points, sampled as a dense polyline. Polylines rather than
    /// curves because the map needs to be measured as well as drawn: branches grow from points
    /// along a road, and junction dots sit where roads meet.
    static func smoothPolyline(through points: [CGPoint], samplesPerSegment: Int = 24) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var padded = points
        padded.insert(points[0], at: 0)
        padded.append(points[points.count - 1])

        var result: [CGPoint] = []
        for i in 0..<(padded.count - 3) {
            let p0 = padded[i], p1 = padded[i + 1], p2 = padded[i + 2], p3 = padded[i + 3]
            for s in 0..<samplesPerSegment {
                let t = Double(s) / Double(samplesPerSegment)
                let t2 = t * t, t3 = t2 * t
                let x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t
                    + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                    + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
                let y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t
                    + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
                    + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
                result.append(CGPoint(x: x, y: y))
            }
        }
        result.append(points[points.count - 1])
        return result
    }

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? (((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared).clamped(to: 0...1) : 0
        let x = a.x + t * dx - point.x, y = a.y + t * dy - point.y
        return (x * x + y * y).squareRoot()
    }

    static func tangent(_ polyline: [CGPoint], at index: Int) -> CGVector {
        let a = polyline[max(0, index - 1)], b = polyline[min(polyline.count - 1, index + 1)]
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-6 else { return CGVector(dx: 1, dy: 0) }
        return CGVector(dx: dx / length, dy: dy / length)
    }

    static func path(_ polyline: [CGPoint], closed: Bool = false) -> CGPath {
        let path = CGMutablePath()
        guard let first = polyline.first else { return path }
        path.move(to: first)
        for point in polyline.dropFirst() { path.addLine(to: point) }
        if closed { path.closeSubpath() }
        return path
    }
}
