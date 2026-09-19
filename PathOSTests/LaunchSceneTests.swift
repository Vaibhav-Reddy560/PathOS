import CoreGraphics
import Foundation
import Testing
@testable import PathOS

struct LaunchSceneTests {
    private let mark = CGSize(width: 140, height: 115)

    /// Screen size in points with the top and bottom safe-area insets, smallest to largest.
    private nonisolated static let screens: [(name: String, size: CGSize, top: Double, bottom: Double)] = [
        ("iPhone SE", CGSize(width: 375, height: 667), 20, 0),
        ("iPhone 13 mini", CGSize(width: 375, height: 812), 50, 34),
        ("iPhone 16 Plus", CGSize(width: 430, height: 932), 59, 34),
        ("iPhone 17 Pro Max", CGSize(width: 440, height: 956), 62, 34),
    ]

    private func scene(_ screen: (name: String, size: CGSize, top: Double, bottom: Double)) -> LaunchScene {
        LaunchScene(map: LaunchMapData.bundled, size: screen.size, markSize: mark,
                    topInset: screen.top, bottomInset: screen.bottom)
    }

    @Test func theMapIsBundled() throws {
        let map = try #require(LaunchMapData.bundled)
        #expect(map.source.licence.contains("OpenStreetMap"))
        #expect((map.roads["major"]?.count ?? 0) > 50)
        #expect((map.roads["minor"]?.count ?? 0) > 500)
        #expect(!map.green.isEmpty && !map.water.isEmpty)
    }

    @Test(arguments: screens.map(\.name))
    func theRouteKeepsItsDistanceOnEveryScreen(_ name: String) {
        let screen = Self.screens.first { $0.name == name }!
        let scene = scene(screen)
        #expect(scene.route.count > 20, "\(name) has no route")

        let top = screen.top + LaunchScene.islandGap
        let bottom = Double(screen.size.height) - screen.bottom - LaunchScene.textBand
        for point in scene.route {
            #expect(LaunchScene.distance(from: point, to: scene.markRect) >= LaunchScene.markClearance, "\(name): route touches the mark")
            #expect(point.x >= LaunchScene.lineMargin && point.x <= Double(screen.size.width) - LaunchScene.lineMargin, "\(name): route near an edge")
            #expect(point.y >= top && point.y <= bottom, "\(name): route under the island or the name")
        }
        // The solid markers keep a wider margin than the line, and the pin's head clears the island.
        for marker in [scene.start, scene.end] {
            #expect(marker.x >= LaunchScene.edgeMargin && marker.x <= Double(screen.size.width) - LaunchScene.edgeMargin, "\(name): marker near an edge")
        }
        #expect(scene.end.y - LaunchScene.pinHeight >= top, "\(name): pin under the island")
        #expect(scene.fits(scene.route))
    }

    @Test func itStartsBelowLeftAndEndsAboveRight() {
        let scene = scene(Self.screens[2])
        #expect(scene.start.x < scene.center.x && scene.start.y > scene.center.y)
        #expect(scene.end.x > scene.center.x && scene.end.y < scene.center.y)
    }

    @Test func theRouteRunsOnRealRoads() {
        let scene = scene(Self.screens[2])
        let roads = LaunchScene.RoadClass.allCases.flatMap { scene.roads[$0] ?? [] }
        let segments = roads.flatMap { line in zip(line, line.dropFirst()).map { ($0, $1) } }
        func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
        }
        // Within a couple of points: the drawn roads are simplified slightly for size.
        for point in scene.route {
            let nearest = segments.lazy.map { distance(point, $0.0, $0.1) }.min() ?? .infinity
            #expect(nearest < 2.5, "Route point \(point) is \(nearest) pt from any road")
        }
    }

    @Test func theMapFillsEveryScreen() {
        for screen in Self.screens {
            let scene = scene(screen)
            let points = (scene.roads[.major] ?? []).flatMap { $0 } + (scene.roads[.minor] ?? []).flatMap { $0 }
            #expect(points.contains { $0.x < 30 && $0.y < 60 }, "\(screen.name): top left is empty")
            #expect(points.contains { $0.x > screen.size.width - 30 && $0.y > screen.size.height - 60 }, "\(screen.name): bottom right is empty")
        }
    }

    @Test func theNameSitsAboveTheHomeIndicator() {
        let screen = Self.screens[2]
        let scene = scene(screen)
        #expect(Double(scene.nameCenter.y) == Double(screen.size.height) - screen.bottom - LaunchScene.textBand / 2)
        #expect(scene.nameCenter.y > scene.start.y)
    }
}
