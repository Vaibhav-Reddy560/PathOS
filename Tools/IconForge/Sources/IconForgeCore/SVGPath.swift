import CoreGraphics
import Foundation

public enum SVGError: Error, CustomStringConvertible {
    case unreadable(String)
    case malformedXML(String)
    case noViewBox
    case noGeometry

    public var description: String {
        switch self {
        case .unreadable(let path): "Can't read the SVG at \(path)."
        case .malformedXML(let reason): "The SVG isn't valid XML: \(reason)"
        case .noViewBox: "The SVG needs a viewBox, or a width and height, to be placed."
        case .noGeometry: "The SVG has no drawable geometry."
        }
    }
}

/// Everything the icon needs from the logo file: one combined path and the box it was drawn in.
///
/// The path is in SVG user space, y pointing down, exactly as authored. Every effect in the icon
/// is derived from this path or its alpha mask, so replacing the file changes the mark and nothing
/// else.
public struct SVGDocument {
    public let path: CGPath
    public let viewBox: CGRect
    /// Nonzero unless the file asks for even-odd. Mixed rules across elements resolve to even-odd,
    /// which is the safe choice: it can only ever punch a hole, never flood one.
    public let fillRule: CGPathFillRule
    public let elementCount: Int

    /// The tight box around the drawn geometry, which is what the icon centres and scales.
    public var bounds: CGRect { path.boundingBoxOfPath }
}

public enum SVGParser {

    public static func parse(contentsOf url: URL) throws -> SVGDocument {
        guard let data = try? Data(contentsOf: url) else { throw SVGError.unreadable(url.path) }
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> SVGDocument {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else {
            throw SVGError.malformedXML(parser.parserError?.localizedDescription ?? "unknown")
        }
        guard let viewBox = collector.viewBox else { throw SVGError.noViewBox }
        guard collector.elementCount > 0, !collector.path.isEmpty else { throw SVGError.noGeometry }
        return SVGDocument(
            path: collector.path.copy() ?? collector.path,
            viewBox: viewBox,
            fillRule: collector.sawEvenOdd ? .evenOdd : .winding,
            elementCount: collector.elementCount
        )
    }

    // MARK: XML

    private final class Collector: NSObject, XMLParserDelegate {
        let path = CGMutablePath()
        var viewBox: CGRect?
        var sawEvenOdd = false
        var elementCount = 0
        /// `<g>` nests, so transforms compose down the tree.
        private var transforms: [CGAffineTransform] = [.identity]

        private var current: CGAffineTransform { transforms[transforms.count - 1] }

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let local = name.contains(":") ? String(name.split(separator: ":").last!) : name
            let own = attributes["transform"].map(SVGTransform.parse) ?? .identity
            transforms.append(own.concatenating(current))

            if local == "svg" { viewBox = Self.viewBox(from: attributes) }
            if attributes["fill-rule"] == "evenodd" || attributes["clip-rule"] == "evenodd" { sawEvenOdd = true }
            // display:none and fill:none elements are guides, not artwork.
            guard attributes["display"] != "none", !(attributes["style"]?.contains("display:none") ?? false) else { return }

            guard let shape = Self.shape(local, attributes) else { return }
            path.addPath(shape, transform: current)
            elementCount += 1
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if transforms.count > 1 { transforms.removeLast() }
        }

        private static func viewBox(from attributes: [String: String]) -> CGRect? {
            if let box = attributes["viewBox"] {
                let n = box.split(whereSeparator: { " ,\n\t".contains($0) }).compactMap { Double($0) }
                if n.count == 4 { return CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
            }
            // Falling back to width/height covers files exported without a viewBox.
            if let w = length(attributes["width"]), let h = length(attributes["height"]), w > 0, h > 0 {
                return CGRect(x: 0, y: 0, width: w, height: h)
            }
            return nil
        }

        private static func length(_ value: String?) -> Double? {
            guard let value else { return nil }
            return Double(value.trimmingCharacters(in: CharacterSet(charactersIn: "px pt "))) 
        }

        /// The drawable elements. Anything else (text, images, gradients) is ignored — an icon mark
        /// should be outlines, and silently dropping the rest is better than drawing it wrong.
        private static func shape(_ name: String, _ a: [String: String]) -> CGPath? {
            func number(_ key: String, _ fallback: Double = 0) -> Double { length(a[key]) ?? fallback }
            switch name {
            case "path":
                guard let d = a["d"], !d.isEmpty else { return nil }
                return SVGPathData.path(from: d)
            case "rect":
                let w = number("width"), h = number("height")
                guard w > 0, h > 0 else { return nil }
                let rect = CGRect(x: number("x"), y: number("y"), width: w, height: h)
                let rx = number("rx", number("ry")), ry = number("ry", number("rx"))
                return rx > 0 || ry > 0
                    ? CGPath(roundedRect: rect, cornerWidth: min(rx, w / 2), cornerHeight: min(ry, h / 2), transform: nil)
                    : CGPath(rect: rect, transform: nil)
            case "circle":
                let r = number("r")
                guard r > 0 else { return nil }
                return CGPath(ellipseIn: CGRect(x: number("cx") - r, y: number("cy") - r, width: r * 2, height: r * 2), transform: nil)
            case "ellipse":
                let rx = number("rx"), ry = number("ry")
                guard rx > 0, ry > 0 else { return nil }
                return CGPath(ellipseIn: CGRect(x: number("cx") - rx, y: number("cy") - ry, width: rx * 2, height: ry * 2), transform: nil)
            case "polygon", "polyline":
                guard let points = a["points"] else { return nil }
                let n = points.split(whereSeparator: { " ,\n\t".contains($0) }).compactMap { Double($0) }
                guard n.count >= 4 else { return nil }
                let p = CGMutablePath()
                p.move(to: CGPoint(x: n[0], y: n[1]))
                for i in stride(from: 2, to: n.count - 1, by: 2) { p.addLine(to: CGPoint(x: n[i], y: n[i + 1])) }
                if name == "polygon" { p.closeSubpath() }
                return p
            case "line":
                let p = CGMutablePath()
                p.move(to: CGPoint(x: number("x1"), y: number("y1")))
                p.addLine(to: CGPoint(x: number("x2"), y: number("y2")))
                return p
            default:
                return nil
            }
        }
    }
}

// MARK: - transform="…"

enum SVGTransform {
    static func parse(_ value: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        // translate(3 4) scale(2) rotate(45 10 10) matrix(…) — applied left to right.
        let pattern = /([a-zA-Z]+)\s*\(([^)]*)\)/
        for match in value.matches(of: pattern) {
            let numbers = String(match.2).split(whereSeparator: { " ,\n\t".contains($0) }).compactMap { Double($0) }
            let step: CGAffineTransform = switch match.1.lowercased() {
            case "translate":
                CGAffineTransform(translationX: numbers.first ?? 0, y: numbers.count > 1 ? numbers[1] : 0)
            case "scale":
                CGAffineTransform(scaleX: numbers.first ?? 1, y: numbers.count > 1 ? numbers[1] : (numbers.first ?? 1))
            case "rotate":
                rotation(numbers)
            case "skewx":
                CGAffineTransform(a: 1, b: 0, c: tan((numbers.first ?? 0) * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewy":
                CGAffineTransform(a: 1, b: tan((numbers.first ?? 0) * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            case "matrix" where numbers.count == 6:
                CGAffineTransform(a: numbers[0], b: numbers[1], c: numbers[2], d: numbers[3], tx: numbers[4], ty: numbers[5])
            default:
                .identity
            }
            result = step.concatenating(result)
        }
        return result
    }

    private static func rotation(_ numbers: [Double]) -> CGAffineTransform {
        let angle = (numbers.first ?? 0) * .pi / 180
        guard numbers.count >= 3 else { return CGAffineTransform(rotationAngle: angle) }
        return CGAffineTransform(translationX: numbers[1], y: numbers[2])
            .rotated(by: angle)
            .translatedBy(x: -numbers[1], y: -numbers[2])
    }
}
