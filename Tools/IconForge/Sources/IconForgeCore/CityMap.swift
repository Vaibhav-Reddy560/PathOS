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
    /// Routes through other pairs of roads. Which one gets drawn depends on how much clear space
    /// each has once the mark and the icon's rounded edge are taken into account, and that is only
    /// known at draw time — so the choice is made there, from these.
    public var routeCandidates: [[CGPoint]]
    public var transform: CGAffineTransform
    /// Only in a fine map: the side streets inside each block of the main grid, the buildings
    /// between them, and the odd pocket park.
    public var sideStreets: [[CGPoint]] = []
    public var buildings: [[CGPoint]] = []
    public var pocketParks: [[CGPoint]] = []
    /// A river across the fine map, and how wide it runs.
    public var river: [CGPoint] = []
    public var riverWidth = 0.0
}

/// How much of the city the map shows.
public enum MapDetail: String, CaseIterable, Sendable {
    /// The main roads and a few plots in each block: a texture behind the mark.
    case standard
    /// Every side street and every building, drawn crisp, so the map reads as a real one.
    case fine
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

        func scaled(_ factor: Double) -> Warp {
            func scale(_ harmonics: [Harmonic]) -> [Harmonic] {
                harmonics.map { Harmonic(amplitude: $0.amplitude * factor, frequency: $0.frequency, phase: $0.phase) }
            }
            return Warp(horizontal: scale(horizontal), vertical: scale(vertical))
        }

        func callAsFunction(_ point: CGPoint) -> CGPoint {
            var x = point.x, y = point.y
            for h in horizontal { x += h.amplitude * sin(point.y * h.frequency + h.phase) }
            for h in vertical { y += h.amplitude * sin(point.x * h.frequency + h.phase) }
            return CGPoint(x: x, y: y)
        }
    }

    public static func plan(size: Double, seed: UInt64 = defaultSeed, detail: MapDetail = .standard) -> CityPlan {
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
        var warp = Warp(horizontal: harmonics(), vertical: harmonics())
        // Drawn sharp, every wobble shows, and a strongly bent grid reads as rippled cloth rather
        // than as streets. A fine map keeps the same bends, gentler.
        if detail == .fine { warp = warp.scaled(0.18) }

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
        var openCells: Set<[Int]> = []
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
                    openCells.insert([rowIndex, columnIndex])
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

        // Routes through several pairs of roads, all generated long. Which one is drawn, and how
        // much of it, is decided at draw time against the clear space available — hand-placing a
        // single route means re-tuning it every time the mark or the street layout changes, and
        // the position snaps to the nearest road anyway, so small adjustments do nothing.
        func nearest(_ values: [Double], to target: Double) -> Double {
            values.min { abs($0 - target) < abs($1 - target) } ?? target
        }
        func lRoute(row: Double, column: Double, before: Double, after: Double) -> [CGPoint] {
            var points: [CGPoint] = []
            var u = column - before
            while u <= column { points.append(warp(CGPoint(x: u, y: row))); u += span * 0.006 }
            var v = row
            while v <= row + after { points.append(warp(CGPoint(x: column, y: v))); v += span * 0.006 }
            return points
        }

        var routeCandidates: [[CGPoint]] = []
        for rowTarget in [0.26, 0.40, 0.56, 0.70] {
            for columnTarget in [0.30, 0.46, 0.62, 0.76] {
                let row = nearest(rows, to: span * rowTarget)
                let column = nearest(columns, to: span * columnTarget)
                routeCandidates.append(lRoute(row: row, column: column,
                                              before: span * 0.42, after: span * 0.34))
            }
        }
        let route = routeCandidates[0]
        let routeStops = [route.first!, route[route.count / 2], route.last!]

        // Centre the oversized map, rotate it, then bring it back into icon space.
        let placement = CGAffineTransform(translationX: size / 2, y: size / 2)
            .rotated(by: rotation)
            .translatedBy(x: -span / 2, y: -span / 2)

        var plan = CityPlan(streets: streets, blocks: blocks, openAreas: openAreas,
                            junctions: junctions, route: route, routeStops: routeStops,
                            routeCandidates: routeCandidates, transform: placement)
        if detail == .fine {
            fillIn(&plan, rows: rows, columns: columns, openCells: openCells, span: span, seed: seed, warp: warp)
        }
        return plan
    }

    /// The fine map's side streets and buildings, inside the main grid's blocks. It draws from a
    /// generator of its own, so the standard map, and the app icon made from it, never change.
    private static func fillIn(_ plan: inout CityPlan, rows: [Double], columns: [Double], openCells: Set<[Int]>,
                               span: Double, seed: UInt64, warp: Warp) {
        var rng = Seeded(seed: seed ^ 0x51DE_57EE_75B1_0C4D)

        // In from a main road, and in from a side street: room for the road and a pavement.
        let mainSetback = span * 0.0095, sideSetback = span * 0.0048
        let buildingGap = span * 0.0021

        // A river across the lower part of the icon, below the mark's feet, meandering gently.
        // Nothing is built in it; the main roads cross it as bridges.
        let bends = (0...6).map { index -> CGPoint in
            let t = Double(index) / 6
            return CGPoint(x: -span * 0.1 + t * span * 1.2,
                           y: span * (0.27 + 0.05 * sin(t * 2 * .pi * 1.1 + rng.double(0...0.6)) + rng.double(-0.012...0.012)))
        }
        plan.river = Geometry.smoothPolyline(through: bends, samplesPerSegment: 24).map { warp($0) }
        plan.riverWidth = span * 0.042
        let riverRoom = plan.riverWidth / 2 + mainSetback
        func isInRiver(_ point: CGPoint) -> Bool {
            plan.river.indices.dropFirst().contains { index in
                Geometry.distance(from: point, toSegment: plan.river[index - 1], plan.river[index]) < riverRoom
            }
        }
        /// Tested at its corners, the middle of each side and its centre: closer together than the
        /// river is wide, so the river can't slip between them.
        func isInRiver(_ shape: [CGPoint]) -> Bool {
            let sides = shape.indices.map { index in
                let a = shape[index], b = shape[(index + 1) % shape.count]
                return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            }
            let centre = CGPoint(x: shape.map(\.x).reduce(0, +) / Double(shape.count),
                                 y: shape.map(\.y).reduce(0, +) / Double(shape.count))
            return (shape + sides + [centre]).contains(where: isInRiver)
        }

        func line(_ from: CGPoint, _ to: CGPoint) -> [CGPoint] {
            (0...24).map { step in
                let t = Double(step) / 24
                return warp(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            }
        }
        func quad(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [CGPoint] {
            [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)].map { warp($0) }
        }
        /// Cuts `from...to` at irregular spacing near `spacing`.
        func cuts(_ from: Double, _ to: Double, spacing: Double) -> [Double] {
            let count = max(1, Int(((to - from) / spacing).rounded()))
            let step = (to - from) / Double(count)
            return (0...count).map { index in
                index == 0 || index == count ? from + step * Double(index)
                    : from + step * (Double(index) + rng.double(-0.18...0.18))
            }
        }

        for rowIndex in 0..<(rows.count - 1) {
            for columnIndex in 0..<(columns.count - 1) where !openCells.contains([rowIndex, columnIndex]) {
                let top = rows[rowIndex], bottom = rows[rowIndex + 1]
                let left = columns[columnIndex], right = columns[columnIndex + 1]
                // Side streets every so often, one way more densely than the other, as a
                // neighbourhood's lanes run mostly one way.
                let alongX = rng.chance(0.5)
                let xs = cuts(left, right, spacing: span * (alongX ? 0.058 : 0.095))
                let ys = cuts(top, bottom, spacing: span * (alongX ? 0.095 : 0.058))
                for x in xs.dropFirst().dropLast() {
                    // Now and then a lane stops at a building rather than running through.
                    if rng.chance(0.14) {
                        let stop = top + (bottom - top) * rng.double(0.35...0.7)
                        plan.sideStreets.append(line(CGPoint(x: x, y: rng.chance(0.5) ? top : bottom), CGPoint(x: x, y: stop)))
                    } else {
                        plan.sideStreets.append(line(CGPoint(x: x, y: top), CGPoint(x: x, y: bottom)))
                    }
                }
                for y in ys.dropFirst().dropLast() {
                    plan.sideStreets.append(line(CGPoint(x: left, y: y), CGPoint(x: right, y: y)))
                }

                for i in 0..<(xs.count - 1) {
                    for j in 0..<(ys.count - 1) {
                        let x0 = xs[i] + (i == 0 ? mainSetback : sideSetback)
                        let x1 = xs[i + 1] - (i == xs.count - 2 ? mainSetback : sideSetback)
                        let y0 = ys[j] + (j == 0 ? mainSetback : sideSetback)
                        let y1 = ys[j + 1] - (j == ys.count - 2 ? mainSetback : sideSetback)
                        guard x1 - x0 > buildingGap * 3, y1 - y0 > buildingGap * 3 else { continue }
                        if rng.chance(0.06) {
                            let park = quad(x0, y0, x1, y1)
                            if !isInRiver(park) { plan.pocketParks.append(park) }
                            continue
                        }
                        // A row of buildings along the longer side, two deep where there's room.
                        let wide = x1 - x0 >= y1 - y0
                        let length = wide ? x1 - x0 : y1 - y0, depth = wide ? y1 - y0 : x1 - x0
                        let deep = depth > span * 0.045 ? 2 : 1
                        for row in 0..<deep {
                            let d0 = Double(row) / Double(deep) * depth + (row > 0 ? buildingGap / 2 : 0)
                            let d1 = Double(row + 1) / Double(deep) * depth - (row < deep - 1 ? buildingGap / 2 : 0)
                            var along = 0.0
                            while along < length - buildingGap {
                                let width = min(length - along, span * rng.double(0.015...0.036))
                                // A plot left empty now and then, so the rows don't read as a comb.
                                if !rng.chance(0.08), width > buildingGap * 2 {
                                    let a0 = along, a1 = along + width - buildingGap
                                    let back = rng.double(0...(0.25 * (d1 - d0)))
                                    let building = wide
                                        ? quad(x0 + a0, y0 + d0 + (row == 0 ? 0 : back), x0 + a1, y0 + d1 - (row == 0 ? back : 0))
                                        : quad(x0 + d0 + (row == 0 ? 0 : back), y0 + a0, x0 + d1 - (row == 0 ? back : 0), y0 + a1)
                                    if !isInRiver(building) { plan.buildings.append(building) }
                                }
                                along += width
                            }
                        }
                    }
                }
            }
        }
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
        public var routeWidth = 27.0
        /// One dial for the whole layer, so the map can be pulled back if it crowds the logo.
        public var intensity = 1.0

        public init() {}
    }

    public static func draw(_ plan: CityPlan, in ctx: CGContext, palette: Palette,
                            scale: Double, ink: Ink = Ink()) {
        if !plan.buildings.isEmpty {
            drawFine(plan, in: ctx, palette: palette, scale: scale, intensity: ink.intensity)
            return
        }
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

    /// A fine map, drawn the way a night map is: buildings as crisp footprints, parks as quiet
    /// patches, and roads as light lines inside darker edges, widest on top, so the hierarchy
    /// reads at a glance and every edge stays sharp.
    static func drawFine(_ plan: CityPlan, in ctx: CGContext, palette: Palette, scale: Double, intensity: Double) {
        ctx.saveGState()
        ctx.concatenate(plan.transform)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        func fill(_ shapes: [[CGPoint]], _ colour: CGColor) {
            for shape in shapes { ctx.addPath(Geometry.path(shape, closed: true)) }
            ctx.setFillColor(colour)
            ctx.fillPath()
        }

        fill(plan.openAreas, palette.ion.cg(0.10 * intensity))
        fill(plan.pocketParks, palette.ion.cg(0.075 * intensity))
        fill(plan.buildings, palette.ice.cg(0.085 * intensity))
        for building in plan.buildings { ctx.addPath(Geometry.path(building, closed: true)) }
        ctx.setStrokeColor(palette.ice.cg(0.105 * intensity))
        ctx.setLineWidth(1.0 * scale)
        ctx.strokePath()

        func ranked(_ rank: Int) -> [[CGPoint]] {
            plan.streets.filter { $0.rank == rank }.map(\.points)
        }
        // Side streets, then the grid's own roads by rank, narrowest first so wider ones cross over.
        // Evenly brighter than a plain night map, so the streets read at icon size. Brightness
        // belongs to the whole network: lighting a few stretches and not others only looked like
        // scratches across the map.
        let tiers: [(lines: [[CGPoint]], width: Double, core: Double)] = [
            (plan.sideStreets, 3.2, 0.17),
            (ranked(2), 5.0, 0.25),
            (ranked(1), 6.6, 0.31),
            (ranked(0), 12, 0.44),
        ]
        for (index, tier) in tiers.enumerated() {
            // The river goes over the lesser roads, which end at its banks, and under the main
            // ones, which cross it as bridges.
            if index == tiers.count - 1, !plan.river.isEmpty {
                ctx.addPath(Geometry.path(plan.river))
                ctx.setStrokeColor(palette.ion.cg(0.22 * intensity))
                ctx.setLineWidth((plan.riverWidth + 5) * scale)
                ctx.strokePath()
                ctx.addPath(Geometry.path(plan.river))
                ctx.setStrokeColor(palette.ionCool.scaled(0.62).mixed(with: palette.void, 0.22).cg(intensity))
                ctx.setLineWidth(plan.riverWidth * scale)
                ctx.strokePath()
            }
            for points in tier.lines { ctx.addPath(Geometry.path(points)) }
            ctx.setStrokeColor(palette.void.cg(0.55 * intensity))
            ctx.setLineWidth((tier.width + 2.4) * scale)
            ctx.strokePath()
            for points in tier.lines { ctx.addPath(Geometry.path(points)) }
            ctx.setStrokeColor(palette.mist.cg(tier.core * intensity))
            ctx.setLineWidth(tier.width * scale)
            ctx.strokePath()

        }
        // A fine centre line down the arterials, the one bright thread in the network.
        for points in tiers[3].lines { ctx.addPath(Geometry.path(points)) }
        ctx.setStrokeColor(palette.ice.cg(0.20 * intensity))
        ctx.setLineWidth(1.4 * scale)
        ctx.strokePath()
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

    /// - Parameters:
    ///   - clearance: where the path may show — white is allowed.
    ///   - markerClearance: where an end marker may sit. Stricter than `clearance`: a marker is a
    ///     solid object that needs room around it, and it has to stay inside the rounded shape iOS
    ///     masks the icon to, not merely inside the square the file happens to be.
    public static func drawRoute(_ plan: CityPlan, in ctx: CGContext, palette: Palette,
                                 scale: Double, ink: Ink = Ink(), clearance: CGImage? = nil,
                                 markerClearance: CGImage? = nil) {
        guard ink.route > 0, ink.style != .none else { return }
        let bounds = CGRect(x: 0, y: 0, width: Double(ctx.width), height: Double(ctx.height))
        let canvas = bounds.insetBy(dx: 22 * scale, dy: 22 * scale)

        func applyClip(_ context: CGContext) {
            if let clearance { context.clip(to: bounds, mask: clearance) }
        }

        // Trim the route to the longest stretch that is both on the icon and clear of the mark,
        // then hang the markers off the trimmed ends.
        //
        // Placing them at the route's own ends means hand-tuning its length until they happen to
        // miss the mark, and any later change to the mark or its size silently breaks it: an end
        // marker half-dissolved by the clearance mask, or off the icon altogether. Reading the
        // clearance back means the route sizes itself to whatever room it has.
        let n = ctx.width
        let clear: [Double]? = clearance.map { GlassShading.gray($0, size: n) }
        let markerRoom: [Double]? = markerClearance.map { GlassShading.gray($0, size: n) }

        func sample(_ buffer: [Double]?, at iconPoint: CGPoint) -> Bool {
            guard canvas.contains(iconPoint) else { return false }
            guard let buffer else { return true }
            // Bitmap row 0 is the top of the image; user space has y growing upward.
            let column = Int(iconPoint.x), row = n - 1 - Int(iconPoint.y)
            guard column >= 0, column < n, row >= 0, row < n else { return false }
            return buffer[row * n + column] > 0.94
        }

        func isClear(_ iconPoint: CGPoint) -> Bool { sample(clear, at: iconPoint) }

        /// Every marker is tested by its whole footprint, not by the one point it sits on. A pin
        /// stands well above its tip, so a tip with room is no guarantee the head has any.
        func hasRoom(for footprint: [CGPoint]) -> Bool {
            footprint.allSatisfy { sample(markerRoom, at: $0) }
        }

        func ring(_ centre: CGPoint, _ radius: Double) -> [CGPoint] {
            [centre] + (0..<10).map { step in
                let angle = Double(step) / 10 * 2 * .pi
                return CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
            }
        }

        func dotFootprint(_ point: CGPoint, radius: Double) -> [CGPoint] {
            ring(point, radius * scale)
        }

        func pinFootprint(tip: CGPoint, radius: Double) -> [CGPoint] {
            let r = radius * scale
            return [tip] + ring(CGPoint(x: tip.x, y: tip.y + r * 2.35), r)
        }

        /// Slides a marker in from one end of the route until its footprint fits, and reports
        /// where it stopped so the path can be cut to meet it.
        func settle(_ points: [CGPoint], fromEnd: Bool, footprint: (CGPoint) -> [CGPoint]) -> Int? {
            let order = fromEnd ? Array(points.indices.reversed()) : Array(points.indices)
            return order.first { hasRoom(for: footprint(points[$0].applying(plan.transform))) }
        }

        func longestClearRun(_ points: [CGPoint]) -> ArraySlice<CGPoint> {
            var best = 0..<0, current = 0
            for index in points.indices {
                if isClear(points[index].applying(plan.transform)) {
                    if index - current + 1 > best.count { best = current..<(index + 1) }
                } else {
                    current = index + 1
                }
            }
            return points[best]
        }

        // Pick the candidate with the most drawn length left after trimming, so the route uses
        // whatever corridor the map and the mark actually leave open.
        var clearRoute: [CGPoint] = []
        var routeEndsFor: (dot: Int, pin: Int)?
        for candidate in plan.routeCandidates {
            let run = Array(longestClearRun(candidate))
            guard let first = run.first, let last = run.last else { continue }
            let startIsLower = first.applying(plan.transform).y < last.applying(plan.transform).y
            guard let dot = settle(run, fromEnd: !startIsLower, footprint: { dotFootprint($0, radius: 33) }),
                  let pin = settle(run, fromEnd: startIsLower, footprint: { pinFootprint(tip: $0, radius: 26) }),
                  abs(pin - dot) > run.count / 8
            else { continue }
            // Below the figure's waist. The longest corridor is often the strip across the top,
            // but a route up there reads as a banner hung above the mark rather than as ground
            // the mark is moving over.
            let middle = run[(dot + pin) / 2].applying(plan.transform)
            guard middle.y < Double(ctx.height) * 0.54 else { continue }
            if abs(pin - dot) > (routeEndsFor.map { abs($0.pin - $0.dot) } ?? 0) {
                clearRoute = run
                routeEndsFor = (dot, pin)
            }
        }

        // Where the two ends settle decides where the path stops. Drawing the path to its own
        // extent and then sliding the markers inward leaves the route running past its own
        // destination, which is not what a route does.
        let routeEnds = routeEndsFor
        let visibleRoute = routeEnds.map { ends in
            Array(clearRoute[min(ends.dot, ends.pin)...max(ends.dot, ends.pin)])
        } ?? clearRoute

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
            stroke(visibleRoute, colour: palette.aurora, width: ink.routeWidth, dashed: ink.style == .dashed)
        case .trail:
            // Breadcrumbs survive being shrunk better than a thin line: each one stays a shape
            // instead of thinning away to nothing.
            let spacing = max(1, visibleRoute.count / 9)
            for index in stride(from: 0, to: visibleRoute.count, by: spacing) {
                let point = visibleRoute[index]
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
            ctx.setLineWidth(6 * scale)
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
            if let ends = routeEnds {
                // Wider than the path itself, or the dot merges into the first dash and the route
                // looks like it simply starts nowhere.
                origin(at: clearRoute[ends.dot].applying(plan.transform), radius: 33)
                destination(at: clearRoute[ends.pin].applying(plan.transform), radius: 26,
                            colour: palette.amber)
            }

        case .points:
            let centre = CGPoint(x: bounds.midX, y: bounds.midY)
            let reach = Double(ctx.width)
            let outer = plan.junctions.map { $0.applying(plan.transform) }.filter { p in
                let d = ((p.x - centre.x) * (p.x - centre.x) + (p.y - centre.y) * (p.y - centre.y)).squareRoot()
                return d > reach * 0.30 && d < reach * 0.46
            }
            if let pin = outer.first(where: { hasRoom(for: pinFootprint(tip: $0, radius: 26)) }) {
                destination(at: pin, radius: 26, colour: palette.amber)
            }
            if let dot = outer.last(where: { hasRoom(for: dotFootprint($0, radius: 30)) }) {
                origin(at: dot, radius: 30)
            }

        case .none:
            break
        }
        ctx.restoreGState()
    }
}
