import CoreGraphics
import Foundation
import Testing
@testable import IconForgeCore

/// The parser is the one piece that has to keep working when the logo is replaced, so it's the
/// piece worth pinning down.
struct SVGPathTests {

    private func document(_ body: String) throws -> SVGDocument {
        try SVGParser.parse(data: Data(#"<svg viewBox="0 0 100 100">\#(body)</svg>"#.utf8))
    }

    private func subpathCount(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { if $0.pointee.type == .moveToPoint { count += 1 } }
        return count
    }

    private func endPoint(_ path: CGPath) -> CGPoint {
        var last = CGPoint.zero
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: last = element.pointee.points[0]
            case .addQuadCurveToPoint: last = element.pointee.points[1]
            case .addCurveToPoint: last = element.pointee.points[2]
            case .closeSubpath: break
            @unknown default: break
            }
        }
        return last
    }

    @Test func readsTheRealLogo() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PathOS_Logo.svg")
        let logo = try SVGParser.parse(contentsOf: url)

        #expect(logo.elementCount == 3)
        #expect(subpathCount(logo.path) == 4)      // one path carries a second subpath
        #expect(logo.fillRule == .winding)
        #expect(logo.viewBox == CGRect(x: 0, y: 0, width: 1193, height: 979))
        let bounds = logo.bounds
        #expect(abs(bounds.width - 1192.5) < 1.0)
        #expect(abs(bounds.height - 978.8) < 1.0)
    }

    @Test func relativeCommandsAccumulate() throws {
        // m then l twice: 10,10 -> 30,10 -> 30,40
        let path = try document(#"<path d="m10 10 l20 0 l0 30"/>"#).path
        #expect(endPoint(path) == CGPoint(x: 30, y: 40))
    }

    @Test func extraPairsAfterMovetoAreLines() throws {
        // A second pair after M is an implicit lineto, not a second subpath.
        let path = try document(#"<path d="M0 0 10 0 10 10"/>"#).path
        #expect(subpathCount(path) == 1)
        #expect(endPoint(path) == CGPoint(x: 10, y: 10))
    }

    @Test func horizontalAndVerticalShorthand() throws {
        let path = try document(#"<path d="M5 5 H45 V25 h-10 v-5"/>"#).path
        #expect(endPoint(path) == CGPoint(x: 35, y: 20))
    }

    @Test func smoothCurvesMirrorThePreviousControlPoint() throws {
        let path = try document(#"<path d="M0 0 C10 0 20 0 30 0 S50 0 60 0"/>"#).path
        #expect(endPoint(path) == CGPoint(x: 60, y: 0))
        // The mirrored control point is implied, so the curve keeps going rather than kinking.
        #expect(path.boundingBoxOfPath.height < 0.001)
    }

    @Test func quadraticAndItsShorthand() throws {
        let path = try document(#"<path d="M0 0 Q10 20 20 0 T40 0"/>"#).path
        #expect(endPoint(path) == CGPoint(x: 40, y: 0))
    }

    @Test func arcsLandOnTheirEndPoint() throws {
        // A half circle of radius 10 from (0,0) ends at (20,0) and bulges 10 below.
        let path = try document(#"<path d="M0 0 A10 10 0 0 1 20 0"/>"#).path
        let end = endPoint(path)
        #expect(abs(end.x - 20) < 0.01)
        #expect(abs(end.y) < 0.01)
        #expect(abs(path.boundingBoxOfPath.height - 10) < 0.2)
    }

    @Test func arcFlagsMayBePackedTogether() throws {
        // The two flags of "0 1" may be written "01", which trips up naive number scanning.
        let packed = try document(#"<path d="M0 0 A10 10 0 01 20 0"/>"#).path
        let spaced = try document(#"<path d="M0 0 A10 10 0 0 1 20 0"/>"#).path
        #expect(abs(endPoint(packed).x - endPoint(spaced).x) < 0.01)
    }

    @Test func runOnNumbersAndExponents() throws {
        // "10-20" is two numbers; "1e1" is ten.
        let path = try document(#"<path d="M10-20L1e1 3.5e1"/>"#).path
        #expect(endPoint(path) == CGPoint(x: 10, y: 35))
    }

    @Test func basicShapesAreDrawnToo() throws {
        let circle = try document(#"<circle cx="50" cy="50" r="20"/>"#)
        #expect(abs(circle.bounds.width - 40) < 0.5)
        let rect = try document(#"<rect x="10" y="20" width="30" height="40"/>"#)
        #expect(rect.bounds == CGRect(x: 10, y: 20, width: 30, height: 40))
        let polygon = try document(#"<polygon points="0,0 10,0 10,10"/>"#)
        #expect(polygon.bounds == CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test func transformsComposeDownTheTree() throws {
        let plain = try document(#"<rect x="0" y="0" width="10" height="10"/>"#)
        let nested = try document(#"<g transform="translate(5 5)"><g transform="scale(2)"><rect x="0" y="0" width="10" height="10"/></g></g>"#)
        #expect(plain.bounds == CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(nested.bounds == CGRect(x: 5, y: 5, width: 20, height: 20))
    }

    @Test func evenOddIsCarriedThrough() throws {
        let document = try document(#"<path fill-rule="evenodd" d="M0 0 H10 V10 H0 Z"/>"#)
        #expect(document.fillRule == .evenOdd)
    }

    @Test func aFileWithNothingToDrawIsAnError() {
        #expect(throws: SVGError.self) {
            try SVGParser.parse(data: Data(#"<svg viewBox="0 0 10 10"><title>hi</title></svg>"#.utf8))
        }
        // No viewBox and no size: there's no way to know how big the mark is meant to be.
        #expect(throws: SVGError.self) {
            try SVGParser.parse(data: Data(#"<svg><path d="M0 0 H10"/></svg>"#.utf8))
        }
    }

    @Test func widthAndHeightStandInForAMissingViewBox() throws {
        let document = try SVGParser.parse(data: Data(#"<svg width="64" height="48"><path d="M0 0 H10"/></svg>"#.utf8))
        #expect(document.viewBox == CGRect(x: 0, y: 0, width: 64, height: 48))
    }
}
