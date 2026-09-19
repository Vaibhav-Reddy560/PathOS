import CoreGraphics
import Foundation

/// The launch screen's map: the real streets of central Bengaluru around MG Road, from
/// OpenStreetMap, with a route along real roads from a start dot to a pin.
///
/// Built by `Tools/TransitData/build.py city`. Coordinates are 0–1 within a box twice as tall as
/// it is wide; the app fills the screen with the box.
nonisolated struct LaunchMapData: Decodable, Sendable {
    nonisolated struct Source: Decodable, Sendable {
        var what: String
        var url: String
        var licence: String
    }

    var generated: String
    var source: Source
    var aspect: Double
    var roads: [String: [[Double]]]
    var green: [[Double]]
    var water: [[Double]]
    var rail: [[Double]]
    var route: [Double]

    static let bundled: LaunchMapData? = {
        guard let url = Bundle.main.url(forResource: "launch-map", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LaunchMapData.self, from: data)
    }()
}

/// The map laid out on one screen, around the mark in the middle.
///
/// Plain geometry, so where things land can be tested on every screen size.
nonisolated struct LaunchScene: Sendable {
    /// Drawn in this order, lightest first, so main roads sit on top.
    nonisolated enum RoadClass: String, CaseIterable, Sendable {
        case service
        case minor
        case secondary
        case major
    }

    static let markClearance = 36.0
    /// For the start dot and the pin, which are solid and would look cramped near an edge.
    static let edgeMargin = 40.0
    /// For the route's thin line between them.
    static let lineMargin = 20.0
    /// Kept for the "PathOS" name at the bottom.
    static let textBand = 84.0
    /// Below the Dynamic Island and status bar.
    static let islandGap = 24.0
    /// The pin stands on the route's end and rises this far above it.
    static let pinHeight = 34.0

    let size: CGSize
    let markRect: CGRect
    let topInset: Double
    let bottomInset: Double
    let roads: [RoadClass: [[CGPoint]]]
    let green: [[CGPoint]]
    let water: [[CGPoint]]
    let rail: [[CGPoint]]
    let route: [CGPoint]

    var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    var start: CGPoint { route.first ?? center }
    var end: CGPoint { route.last ?? center }

    /// Where the "PathOS" name sits: the middle of the band above the home indicator.
    var nameCenter: CGPoint {
        CGPoint(x: size.width / 2, y: size.height - bottomInset - Self.textBand / 2)
    }

    init(map: LaunchMapData?, size: CGSize, markSize: CGSize, topInset: Double, bottomInset: Double) {
        self.size = size
        self.topInset = topInset
        self.bottomInset = bottomInset
        markRect = CGRect(x: (size.width - markSize.width) / 2, y: (size.height - markSize.height) / 2,
                          width: markSize.width, height: markSize.height)

        // Fill the screen with the box, keeping its proportions: tall phones lose a little at the
        // sides, the iPhone SE a little at the top and bottom.
        let aspect = map?.aspect ?? 0.5
        let boxHeight = max(Double(size.height), Double(size.width) / aspect)
        let boxWidth = aspect * boxHeight
        let origin = CGPoint(x: (Double(size.width) - boxWidth) / 2, y: (Double(size.height) - boxHeight) / 2)
        func place(_ flat: [Double]) -> [CGPoint] {
            stride(from: 0, to: flat.count - 1, by: 2).map {
                CGPoint(x: origin.x + flat[$0] * boxWidth, y: origin.y + flat[$0 + 1] * boxHeight)
            }
        }

        var roads: [RoadClass: [[CGPoint]]] = [:]
        for roadClass in RoadClass.allCases {
            roads[roadClass] = (map?.roads[roadClass.rawValue] ?? []).map(place)
        }
        self.roads = roads
        green = (map?.green ?? []).map(place)
        water = (map?.water ?? []).map(place)
        rail = (map?.rail ?? []).map(place)
        route = place(map?.route ?? [])
    }

    /// Every point clear of the mark and inside the safe part of the screen, the start and the
    /// pin (which stands above the last point) with a wider margin than the line.
    func fits(_ path: [CGPoint]) -> Bool {
        guard let first = path.first, let last = path.last else { return false }
        let top = topInset + Self.islandGap
        let bottom = Double(size.height) - bottomInset - Self.textBand
        func inside(_ p: CGPoint, margin: Double) -> Bool {
            p.x >= margin && p.x <= Double(size.width) - margin && p.y >= top && p.y <= bottom
                && Self.distance(from: p, to: markRect) >= Self.markClearance
        }
        let pinHead = CGPoint(x: last.x, y: last.y - Self.pinHeight)
        return [first, last, pinHead].allSatisfy { inside($0, margin: Self.edgeMargin) }
            && path.allSatisfy { inside($0, margin: Self.lineMargin) }
    }

    static func distance(from p: CGPoint, to rect: CGRect) -> Double {
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
        let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return hypot(dx, dy)
    }
}
