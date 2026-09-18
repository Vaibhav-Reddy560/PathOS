import CoreGraphics
import Foundation

/// The `d="…"` mini-language.
///
/// The current logo only uses M, C and Z, but the whole command set is here so that swapping in a
/// different export — relative commands, shorthand curves, arcs — still produces the right mark
/// rather than a silently mangled one.
enum SVGPathData {

    static func path(from d: String) -> CGPath? {
        var scanner = Scanner(d)
        let path = CGMutablePath()

        var point = CGPoint.zero          // current point
        var start = CGPoint.zero          // start of the current subpath, where Z returns to
        var lastControl: CGPoint?         // for S/T shorthand
        var lastCommand: Character = " "
        var command: Character = " "

        while true {
            if let next = scanner.command() {
                command = next
            } else if scanner.atEnd {
                break
            } else if command == "M" || command == "m" {
                // Extra coordinate pairs after a moveto are implicit linetos.
                command = command == "M" ? "L" : "l"
            } else if command == " " {
                break   // leading junk, nothing to draw
            }

            let relative = command.isLowercase
            func absolute(_ x: Double, _ y: Double) -> CGPoint {
                relative ? CGPoint(x: point.x + x, y: point.y + y) : CGPoint(x: x, y: y)
            }

            switch command.uppercased().first! {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { return finish(path) }
                point = absolute(x, y); start = point
                path.move(to: point); lastControl = nil

            case "L":
                guard let x = scanner.number(), let y = scanner.number() else { return finish(path) }
                point = absolute(x, y)
                path.addLine(to: point); lastControl = nil

            case "H":
                guard let x = scanner.number() else { return finish(path) }
                point = CGPoint(x: relative ? point.x + x : x, y: point.y)
                path.addLine(to: point); lastControl = nil

            case "V":
                guard let y = scanner.number() else { return finish(path) }
                point = CGPoint(x: point.x, y: relative ? point.y + y : y)
                path.addLine(to: point); lastControl = nil

            case "C":
                guard let a = scanner.point(), let b = scanner.point(), let c = scanner.point() else { return finish(path) }
                let c1 = absolute(a.x, a.y), c2 = absolute(b.x, b.y), end = absolute(c.x, c.y)
                path.addCurve(to: end, control1: c1, control2: c2)
                point = end; lastControl = c2

            case "S":
                guard let b = scanner.point(), let c = scanner.point() else { return finish(path) }
                // The first control point mirrors the previous one; without one it sits on the point.
                let mirrored = (lastCommand.uppercased() == "C" || lastCommand.uppercased() == "S")
                    ? CGPoint(x: 2 * point.x - (lastControl ?? point).x, y: 2 * point.y - (lastControl ?? point).y)
                    : point
                let c2 = absolute(b.x, b.y), end = absolute(c.x, c.y)
                path.addCurve(to: end, control1: mirrored, control2: c2)
                point = end; lastControl = c2

            case "Q":
                guard let a = scanner.point(), let b = scanner.point() else { return finish(path) }
                let control = absolute(a.x, a.y), end = absolute(b.x, b.y)
                path.addQuadCurve(to: end, control: control)
                point = end; lastControl = control

            case "T":
                guard let b = scanner.point() else { return finish(path) }
                let mirrored = (lastCommand.uppercased() == "Q" || lastCommand.uppercased() == "T")
                    ? CGPoint(x: 2 * point.x - (lastControl ?? point).x, y: 2 * point.y - (lastControl ?? point).y)
                    : point
                let end = absolute(b.x, b.y)
                path.addQuadCurve(to: end, control: mirrored)
                point = end; lastControl = mirrored

            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let largeArc = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return finish(path) }
                let end = absolute(x, y)
                appendArc(to: path, from: point, to: end, rx: rx, ry: ry,
                          rotation: rotation, largeArc: largeArc, sweep: sweep)
                point = end; lastControl = nil

            case "Z":
                path.closeSubpath()
                point = start; lastControl = nil

            default:
                return finish(path)
            }
            lastCommand = command
        }
        return finish(path)
    }

    private static func finish(_ path: CGMutablePath) -> CGPath? {
        path.isEmpty ? nil : path.copy()
    }

    /// Endpoint to centre parameterisation, then the arc as up to four cubics (W3C SVG appendix F.6).
    private static func appendArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
                                  rx: Double, ry: Double, rotation: Double, largeArc: Bool, sweep: Bool) {
        // Degenerate radii mean a straight line, per the spec.
        var rx = abs(rx), ry = abs(ry)
        guard rx > 1e-9, ry > 1e-9, p0 != p1 else { path.addLine(to: p1); return }

        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        // Scale the radii up if they're too small to span the chord.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }

        let sign: Double = largeArc == sweep ? -1 : 1
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coefficient = sign * (denominator > 0 ? (numerator / denominator).squareRoot() : 0)
        let cx1 = coefficient * rx * y1 / ry
        let cy1 = -coefficient * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let len = ((ux * ux + uy * uy) * (vx * vx + vy * vy)).squareRoot()
            let value = len > 0 ? max(-1, min(1, dot / len)) : 0
            return (ux * vy - uy * vx < 0 ? -1 : 1) * acos(value)
        }

        let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / Double(segments)
        // Magic constant for approximating a circular arc of `step` radians with a cubic.
        let alpha = sin(step) * ((4 + 3 * pow(tan(step / 2), 2)).squareRoot() - 1) / 3

        var current = theta
        for _ in 0..<segments {
            let next = current + step
            func onArc(_ t: Double) -> CGPoint {
                CGPoint(x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi,
                        y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
            }
            func derivative(_ t: Double) -> CGPoint {
                CGPoint(x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi,
                        y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
            }
            let from = onArc(current), to = onArc(next)
            let d1 = derivative(current), d2 = derivative(next)
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x + alpha * d1.x, y: from.y + alpha * d1.y),
                control2: CGPoint(x: to.x - alpha * d2.x, y: to.y - alpha * d2.y)
            )
            current = next
        }
    }

    /// Numbers in path data run together: "1-2" is two numbers, and ".5.5" is two more.
    private struct Scanner {
        private let chars: [Character]
        private var index = 0

        init(_ string: String) { chars = Array(string) }

        var atEnd: Bool {
            var i = index
            while i < chars.count, isSeparator(chars[i]) { i += 1 }
            return i >= chars.count
        }

        private func isSeparator(_ c: Character) -> Bool { c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" }

        private mutating func skipSeparators() {
            while index < chars.count, isSeparator(chars[index]) { index += 1 }
        }

        mutating func command() -> Character? {
            skipSeparators()
            guard index < chars.count, chars[index].isLetter, chars[index] != "e", chars[index] != "E" else { return nil }
            defer { index += 1 }
            return chars[index]
        }

        mutating func number() -> Double? {
            skipSeparators()
            let begin = index
            if index < chars.count, chars[index] == "+" || chars[index] == "-" { index += 1 }
            while index < chars.count, chars[index].isNumber { index += 1 }
            if index < chars.count, chars[index] == "." {
                index += 1
                while index < chars.count, chars[index].isNumber { index += 1 }
            }
            if index < chars.count, chars[index] == "e" || chars[index] == "E" {
                let exponent = index
                index += 1
                if index < chars.count, chars[index] == "+" || chars[index] == "-" { index += 1 }
                if index < chars.count, chars[index].isNumber {
                    while index < chars.count, chars[index].isNumber { index += 1 }
                } else {
                    index = exponent   // a trailing "e" belongs to the next command, not this number
                }
            }
            guard index > begin, let value = Double(String(chars[begin..<index])) else { index = begin; return nil }
            return value
        }

        mutating func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }

        /// Arc flags are single digits and may be packed: "1 0 1" can appear as "101".
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < chars.count, chars[index] == "0" || chars[index] == "1" else { return number().map { $0 != 0 } }
            defer { index += 1 }
            return chars[index] == "1"
        }
    }
}
