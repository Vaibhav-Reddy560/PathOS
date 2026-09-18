import CoreGraphics
import Foundation

/// A nighttime street network, generated rather than drawn.
///
/// It's a regular grid pushed through a smooth deformation field, not a set of wandering lines.
/// That matters: a field can't fold a line back on itself, so every road still crosses every road
/// of the other family exactly once. The result keeps real junctions and fully enclosed blocks —
/// which is what makes a map read as a map — while no road ends up straight or evenly spaced.
///
/// The deformation also keeps the grid's own coordinates usable, so a junction is just the field
/// applied to a row/column crossing, and a block is the field applied to the cell between four of
/// them. Nothing has to be intersected geometrically.
public struct CityPlan {
    public struct Street {
        public var points: [CGPoint]
        /// 0 arterial, 1 street, 2 lane.
        public var rank: Int
    }

    public var streets: [Street]
    public var blocks: [[CGPoint]]
    public var openAreas: [[CGPoint]]
    public var junctions: [CGPoint]
    /// One route traced through the streets. Green means "you" in this palette, and a route is the
    /// most literal thing it can mean — drawn as a line with stops, never as a glow.
    public var route: [CGPoint]
    public var routeStops: [CGPoint]
    public var transform: CGAffineTransform
}

/// How the map shows the one thing on it that belongs to you.
///
/// Green means "you" in this palette and Amber means "worth a glance", so whatever this draws has
/// to be geometry with meaning, not decoration: a path you would take, places you would stop.
public enum RouteStyle: String, CaseIterable, Sendable {
    /// A solid route with a marker at each end.
    case line
    /// The same route drawn as a walking path.
    case dashed
    /// No route at all, just the places — three of yours and one worth a glance.
    case points
    /// The same path as breadcrumbs rather than a drawn line.
    case trail
    case none
}

public enum CityMap {

    public static let defaultSeed: UInt64 = 0x9A7D_05E1_C0DE_1F03
    /// Drawn this much larger than the icon, so rotating it never exposes a corner.
    static let oversize = 1.62
    static let rotation = -14.0 * .pi / 180

    private struct Warp {
        struct Harmonic { var amplitude, frequency, phase: Double }
        var horizontal: [Harmonic]
        var vertical: [Harmonic]

        func callAsFunction(_ point: CGPoint) -> CGPoint {
            var x = point.x, y = point.y
            for h in horizontal { x += h.amplitude * sin(point.y * h.frequency + h.phase) }
            for h in vertical { y += h.amplitude * sin(point.x * h.frequency + h.phase) }
            return CGPoint(x: x, y: y)
        }
    }

    public static func plan(size: Double, seed: UInt64 = defaultSeed) -> CityPlan {
        var rng = Seeded(seed: seed)
        let span = size * oversize

        // Amplitudes stay well under the block spacing, which is what keeps the field from
        // folding the grid over itself.
        func harmonics() -> [Warp.Harmonic] {
            (0..<3).map { index in
                Warp.Harmonic(
                    amplitude: span * rng.double(0.018...0.055) / Double(index + 1),
                    frequency: 2 * .pi / (span * rng.double(0.28...0.85)),
                    phase: rng.double(0...(2 * .pi))
                )
            }
        }
        let warp = Warp(horizontal: harmonics(), vertical: harmonics())

        // Road positions: irregular spacing, so no two blocks are the same size.
        func positions() -> [Double] {
            var values: [Double] = []
            var cursor = -span * 0.08
            while cursor < span * 1.08 {
                values.append(cursor)
                cursor += span * rng.double(0.115...0.205)
            }
            return values
        }
        let rows = positions(), columns = positions()

        // Every third road is an arterial, which gives the map a visible hierarchy.
        let arterialRow = rng.int(0...2), arterialColumn = rng.int(0...2)
        func rank(_ index: Int, _ offset: Int) -> Int { index % 3 == offset ? 0 : (index % 2 == 0 ? 1 : 2) }

        var streets: [CityPlan.Street] = []
        let samples = 150
        for (index, row) in rows.enumerated() {
            let points = (0...samples).map { step -> CGPoint in
                let t = Double(step) / Double(samples)
                return warp(CGPoint(x: -span * 0.08 + t * span * 1.16, y: row))
            }
            streets.append(.init(points: points, rank: rank(index, arterialRow)))
        }
        for (index, column) in columns.enumerated() {
            let points = (0...samples).map { step -> CGPoint in
                let t = Double(step) / Double(samples)
                return warp(CGPoint(x: column, y: -span * 0.08 + t * span * 1.16))
            }
            streets.append(.init(points: points, rank: rank(index, arterialColumn)))
        }

        // Two diagonals cutting across the grid, the way a trunk road ignores a street plan.
        for _ in 0..<2 {
            let intercept = rng.double((-0.35)...0.85), slope = rng.double(0.45...1.45) * (rng.chance(0.5) ? 1 : -1)
            let points = (0...samples).map { step -> CGPoint in
                let t = Double(step) / Double(samples)
                return warp(CGPoint(x: -span * 0.1 + t * span * 1.2,
                                    y: (intercept + slope * t) * span))
            }
            streets.append(.init(points: points, rank: 0))
        }

        // A junction is just the field applied to a crossing of the underlying grid.
        var junctions: [CGPoint] = []
        // Every crossing, not every other one: with the roads spaced this widely, sparse junction
        // dots stop the grid reading as a connected network.
        for row in rows {
            for column in columns {
                let point = warp(CGPoint(x: column, y: row))
                guard point.x > 0, point.x < span, point.y > 0, point.y < span else { continue }
                junctions.append(point)
            }
        }

        // Blocks fill the cells, set back from the roads that bound them and split into plots.
        var blocks: [[CGPoint]] = []
        var openAreas: [[CGPoint]] = []
        for rowIndex in 0..<(rows.count - 1) {
            for columnIndex in 0..<(columns.count - 1) {
                let top = rows[rowIndex], bottom = rows[rowIndex + 1]
                let left = columns[columnIndex], right = columns[columnIndex + 1]
                let inset = 0.17
                let height = bottom - top, width = right - left

                // Now and then a cell is a park or a tank rather than buildings.
                if rng.chance(0.045) {
                    var outline: [CGPoint] = []
                    let lobes = 9
                    for lobe in 0..<lobes {
                        let angle = Double(lobe) / Double(lobes) * 2 * .pi
                        let radius = rng.double(0.28...0.44)
                        outline.append(warp(CGPoint(
                            x: left + width * (0.5 + cos(angle) * radius),
                            y: top + height * (0.5 + sin(angle) * radius)
                        )))
                    }
                    openAreas.append(Geometry.smoothPolyline(through: outline + [outline[0]], samplesPerSegment: 10))
                    continue
                }

                // Split across the cell's longer side, so plots stay compact rather than
                // becoming slivers in tall cells.
                let splitAcrossWidth = width >= height
                let plots = rng.int(1...3)
                let gap = 0.05
                for plot in 0..<plots {
                    let a0 = inset + (1 - 2 * inset) * (Double(plot) / Double(plots)) + (plot > 0 ? gap / 2 : 0)
                    let a1 = inset + (1 - 2 * inset) * (Double(plot + 1) / Double(plots)) - (plot < plots - 1 ? gap / 2 : 0)
                    let b0 = inset + rng.double(0...0.06), b1 = 1 - inset - rng.double(0...0.06)
                    let corners = [(a0, b0), (a1, b0), (a1, b1), (a0, b1)].map { a, b in
                        let u = splitAcrossWidth ? a : b
                        let v = splitAcrossWidth ? b : a
                        return warp(CGPoint(x: left + width * u, y: top + height * v))
                    }
                    blocks.append(corners)
                }
            }
        }

        // A short route with stops, sitting in a clear corner rather than crossing the whole icon.
        // Long enough to read as a path, short enough not to compete with the mark.
        //
        // Placed by working backwards through the map's own transform: pick where it should appear
        // in the icon, convert that to map space, and take the roads nearest to it. Guessing at row
        // and column indices says nothing about where a rotated, oversized map actually lands.
        let placement = CGAffineTransform(translationX: size / 2, y: size / 2)
            .rotated(by: rotation)
            .translatedBy(x: -span / 2, y: -span / 2)
        // Kept outside the mark's bounding box. A bright green line running alongside the mark
        // collapses the contrast at that edge, which is the one thing the icon cannot afford.
        let corner = CGPoint(x: size * 0.775, y: size * 0.20).applying(placement.inverted())
        func nearest(_ values: [Double], to target: Double) -> Double {
            values.min { abs($0 - target) < abs($1 - target) } ?? target
        }
        let routeRow = nearest(rows, to: corner.y)
        let routeColumn = nearest(columns, to: corner.x)

        var route: [CGPoint] = []
        // Short enough that both ends stay clear of the mark: an origin dot hidden under the
        // figure is worse than no origin dot, because the route then just fades in from nowhere.
        let approach = span * 0.115, departure = span * 0.165
        var u = routeColumn - approach
        while u <= routeColumn { route.append(warp(CGPoint(x: u, y: routeRow))); u += span * 0.006 }
        var v = routeRow
        while v <= routeRow + departure { route.append(warp(CGPoint(x: routeColumn, y: v))); v += span * 0.006 }
        let routeStops = [route.first!, warp(CGPoint(x: routeColumn, y: routeRow)), route.last!]

        return CityPlan(streets: streets, blocks: blocks, openAreas: openAreas,
                        junctions: junctions, route: route, routeStops: routeStops, transform: placement)
    }

    // MARK: Drawing

    public struct Ink {
        public var roadWidths: [Double] = [9.0, 4.6, 2.4]
        public var roadAlphas: [Double] = [0.210, 0.130, 0.075]
        public var blockFill = 0.032
        public var blockEdge = 0.034
        public var openArea = 0.060
        public var junction = 0.150
        public var route = 0.95
        public var style: RouteStyle = .line
        public var routeWidth = 21.0
        /// One dial for the whole layer, so the map can be pulled back if it crowds the logo.
        public var intensity = 1.0

        public init() {}
    }

    public static func draw(_ plan: CityPlan, in ctx: CGContext, palette: Palette,
                            scale: Double, ink: Ink = Ink()) {
        ctx.saveGState()
        ctx.concatenate(plan.transform)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for area in plan.openAreas {
            ctx.addPath(Geometry.path(area, closed: true))
            ctx.setFillColor(palette.ion.cg(ink.openArea * ink.intensity))
            ctx.fillPath()
        }

        for block in plan.blocks {
            ctx.addPath(Geometry.path(block, closed: true))
            ctx.setFillColor(palette.ice.cg(ink.blockFill * ink.intensity))
            ctx.fillPath()
            ctx.addPath(Geometry.path(block, closed: true))
            ctx.setStrokeColor(palette.ice.cg(ink.blockEdge * ink.intensity))
            ctx.setLineWidth(0.9 * scale)
            ctx.strokePath()
        }

        // Narrowest first, so the wider roads sit over them at the crossings.
        for rank in [2, 1, 0] {
            for street in plan.streets where street.rank == rank {
                ctx.addPath(Geometry.path(street.points))
                ctx.setStrokeColor(palette.mist.cg(ink.roadAlphas[rank] * ink.intensity))
                ctx.setLineWidth(ink.roadWidths[rank] * scale)
                ctx.strokePath()
            }
        }

        for junction in plan.junctions {
            let r = 2.2 * scale
            ctx.addEllipse(in: CGRect(x: junction.x - r, y: junction.y - r, width: r * 2, height: r * 2))
            ctx.setFillColor(palette.ice.cg(ink.junction * ink.intensity))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    /// The route is drawn separately so it can be kept clear of the mark.
    ///
    /// `clearance` is a mask in icon space — white where the route may show. Without it a bright
    /// green stop can end up touching the mark's outline, which collapses the contrast right there
    /// and makes the two shapes bleed into each other. Clipping is also the truthful thing: the
    /// mark sits above the map, so the route should pass under it.
    /// A map pin: a round head with its sides drawn down to a point, and the point is the place.
    ///
    /// The tangent from the tip to the head is computed rather than faked with a triangle, so the
    /// sides meet the circle smoothly at any size.
    static func pinPath(tip: CGPoint, radius: Double) -> CGPath {
        let reach = radius * 2.35                                  // tip to the centre of the head
        let head = CGPoint(x: tip.x, y: tip.y + reach)             // icon space: y grows upward
        let theta = acos(min(1, radius / reach))                   // tip-to-centre line to tangent
        let left = atan2(-cos(theta), -sin(theta))
        let right = atan2(-cos(theta), sin(theta))

        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: head.x + radius * cos(left), y: head.y + radius * sin(left)))
        // Clockwise from the left tangent takes the long way round, over the top of the head.
        path.addArc(center: head, radius: radius, startAngle: left, endAngle: right, clockwise: true)
        path.addLine(to: tip)
        path.closeSubpath()
        return path
    }

    public static func drawRoute(_ plan: CityPlan, in ctx: CGContext, palette: Palette,
                                 scale: Double, ink: Ink = Ink(), clearance: CGImage? = nil) {
        guard ink.route > 0, ink.style != .none else { return }
        let bounds = CGRect(x: 0, y: 0, width: Double(ctx.width), height: Double(ctx.height))
        let canvas = bounds.insetBy(dx: 22 * scale, dy: 22 * scale)

        func applyClip(_ context: CGContext) {
            if let clearance { context.clip(to: bounds, mask: clearance) }
        }

        // MARK: the path itself, drawn in the map's own space so it follows the streets

        ctx.saveGState()
        applyClip(ctx)
        ctx.concatenate(plan.transform)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        func stroke(_ points: [CGPoint], colour: Swatch, width: Double, dashed: Bool = false) {
            ctx.addPath(Geometry.path(points))
            ctx.setStrokeColor(palette.void.cg(0.55 * ink.intensity))
            ctx.setLineWidth((width + 3.5) * scale)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.strokePath()
            ctx.addPath(Geometry.path(points))
            ctx.setStrokeColor(colour.cg(ink.route * ink.intensity))
            ctx.setLineWidth(width * scale)
            if dashed { ctx.setLineDash(phase: 0, lengths: [width * 1.5 * scale, width * 1.6 * scale]) }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        switch ink.style {
        case .line, .dashed:
            stroke(plan.route, colour: palette.aurora, width: ink.routeWidth, dashed: ink.style == .dashed)
        case .trail:
            // Breadcrumbs survive being shrunk better than a thin line: each one stays a shape
            // instead of thinning away to nothing.
            let spacing = max(1, plan.route.count / 9)
            for index in stride(from: 0, to: plan.route.count, by: spacing) {
                let point = plan.route[index]
                let r = 7.0 * scale
                ctx.addEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
                ctx.setFillColor(palette.void.cg(0.6 * ink.intensity))
                ctx.fillPath()
                let inner = r * 0.72
                ctx.addEllipse(in: CGRect(x: point.x - inner, y: point.y - inner,
                                          width: inner * 2, height: inner * 2))
                ctx.setFillColor(palette.aurora.cg(ink.route * ink.intensity))
                ctx.fillPath()
            }
        case .points, .none:
            break
        }
        ctx.restoreGState()

        // MARK: the ends, drawn in icon space
        //
        // A pin has an up. Drawing it in map space would tilt it with the map's rotation, and a
        // leaning pin reads as a mistake — on a real map the pins stay upright however the map sits.

        ctx.saveGState()
        applyClip(ctx)

        /// Where you are: a solid disc inside a dark collar, the way every map draws it.
        func origin(at point: CGPoint, radius: Double) {
            let r = radius * scale
            ctx.addEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
            ctx.setFillColor(palette.void.cg(0.85 * ink.intensity))
            ctx.fillPath()
            let core = r * 0.64
            ctx.addEllipse(in: CGRect(x: point.x - core, y: point.y - core, width: core * 2, height: core * 2))
            ctx.setFillColor(palette.aurora.cg(min(1, ink.route * 1.4) * ink.intensity))
            ctx.fillPath()
        }

        /// Where you're going: a pin, with its point on the place and a hole through the head.
        func destination(at point: CGPoint, radius: Double, colour: Swatch) {
            let r = radius * scale
            let pin = pinPath(tip: point, radius: r)
            ctx.addPath(pin)
            ctx.setStrokeColor(palette.void.cg(0.8 * ink.intensity))
            ctx.setLineWidth(4 * scale)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.addPath(pin)
            ctx.setFillColor(colour.cg(min(1, ink.route * 1.4) * ink.intensity))
            ctx.fillPath()
            let hole = r * 0.40
            let head = CGPoint(x: point.x, y: point.y + r * 2.35)
            ctx.addEllipse(in: CGRect(x: head.x - hole, y: head.y - hole, width: hole * 2, height: hole * 2))
            ctx.setFillColor(palette.void.cg(0.9 * ink.intensity))
            ctx.fillPath()
        }

        func placed(_ point: CGPoint) -> CGPoint? {
            let p = point.applying(plan.transform)
            return canvas.contains(p) ? p : nil
        }

        switch ink.style {
        case .line, .dashed, .trail:
            // Wider than the path itself, or the dot merges into the first dash and the route
            // looks like it simply starts nowhere.
            if let from = placed(plan.routeStops[0]) { origin(at: from, radius: 20) }
            // A pin stands above its point, so it needs headroom the dot does not.
            if let to = placed(plan.routeStops[2]), to.y < canvas.maxY - 44 * scale {
                destination(at: to, radius: 15, colour: palette.amber)
            }
        case .points:
            let centre = CGPoint(x: bounds.midX, y: bounds.midY)
            let reach = Double(ctx.width)
            let outer = plan.junctions.compactMap(placed).filter { p in
                let d = ((p.x - centre.x) * (p.x - centre.x) + (p.y - centre.y) * (p.y - centre.y)).squareRoot()
                return d > reach * 0.30 && d < reach * 0.46 && p.y < canvas.maxY - 44 * scale
            }
            if let first = outer.first { destination(at: first, radius: 16, colour: palette.amber) }
            if outer.count > 1 { origin(at: outer[outer.count / 2], radius: 14) }
        case .none:
            break
        }
        ctx.restoreGState()
    }
}
