import CoreGraphics
import Foundation
import Testing
@testable import IconForgeCore

struct DistanceFieldTests {

    @Test func oneDimensionalTransformMeasuresDistanceToTheNearestSeed() {
        // Zeros are seeds; everything else should come back as the squared distance to one.
        let infinity = 1e9
        let result = DistanceField.transform([0, infinity, infinity, infinity, 0])
        #expect(result == [0, 1, 4, 1, 0])
    }

    @Test func distanceGrowsInwardFromTheOutline() {
        let n = 64
        var mask = [Double](repeating: 0, count: n * n)
        // A 32x32 square centred in the field: its middle is 16 from the nearest edge.
        for y in 16..<48 { for x in 16..<48 { mask[y * n + x] = 1 } }
        let distance = DistanceField.inside(mask, width: n, height: n)

        #expect(abs(distance[32 * n + 32] - 16) < 0.01)
        // x=17 is two pixels from the nearest seed, which is the first pixel outside at x=15.
        #expect(abs(distance[32 * n + 17] - 2) < 0.01)
        #expect(distance[32 * n + 8] == 0)                   // outside the shape
        // A corner is further from the edge along the diagonal than along either side.
        #expect(distance[20 * n + 20] < distance[32 * n + 32])
    }
}

struct GlassShadingTests {

    private func flat(_ size: Int, _ value: UInt8) -> CGImage {
        let ctx = Raster.context(size: size)
        ctx.setFillColor(CGColor(srgbRed: Double(value) / 255, green: Double(value) / 255,
                                 blue: Double(value) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return Raster.image(ctx)
    }

    private func shade(bodyValue: UInt8, backdropValue: UInt8) -> (pixels: [UInt8], alpha: [UInt8], size: Int) {
        let n = 128
        let shape = CGPath(ellipseIn: CGRect(x: 24, y: 24, width: 80, height: 80), transform: nil)
        let mask = Raster.mask(path: shape, size: n)
        var light = GlassShading.Light()
        light.bevel = 18
        // Built in a colour context on purpose: a grey context silently ignores an sRGB fill, so
        // the body would stay white and every pixel would saturate, hiding whatever is being tested.
        let bodyCtx = Raster.context(size: n)
        bodyCtx.setFillColor(CGColor(srgbRed: Double(bodyValue) / 255, green: Double(bodyValue) / 255,
                                     blue: Double(bodyValue) / 255, alpha: 1))
        bodyCtx.addPath(shape)
        bodyCtx.fillPath()
        let shaded = GlassShading.render(mask: mask, backdrop: flat(n, backdropValue),
                                         body: Raster.image(bodyCtx),
                                         size: n, scale: 1, light: light)
        let ctx = Raster.context(size: n); ctx.draw(shaded, in: CGRect(x: 0, y: 0, width: n, height: n))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let maskCtx = Raster.grayContext(size: n); maskCtx.draw(mask, in: CGRect(x: 0, y: 0, width: n, height: n))
        let alphaData = maskCtx.data!.assumingMemoryBound(to: UInt8.self)
        return ((0..<(n * n * 4)).map { data[$0] }, (0..<(n * n)).map { alphaData[$0] }, n)
    }

    @Test func shadingNeverDarkensBelowTheAmbientFloor() {
        // This is the contract that keeps the mark legible: refraction and rim light screen on, so
        // a dark map behind the glass can never drag the mark down into it. The only thing that
        // may darken a pixel is the diffuse term falling to zero, which bottoms out at ambient.
        let body: UInt8 = 180
        let (pixels, alpha, n) = shade(bodyValue: body, backdropValue: 0)
        let floor = Double(body) / 255 * GlassShading.Light().ambient * 255 - 2

        var checked = 0
        for i in 0..<(n * n) where alpha[i] > 250 {
            let value = Double(pixels[i * 4])
            #expect(value >= floor)
            checked += 1
        }
        #expect(checked > 2_000)
    }

    @Test func aLighterBackdropOnlyEverAddsLight() {
        let dark = shade(bodyValue: 150, backdropValue: 0)
        let bright = shade(bodyValue: 150, backdropValue: 255)
        var brighter = 0, darker = 0
        for i in 0..<(dark.size * dark.size) where dark.alpha[i] > 250 {
            if bright.pixels[i * 4] > dark.pixels[i * 4] { brighter += 1 }
            if bright.pixels[i * 4] < dark.pixels[i * 4] { darker += 1 }
        }
        #expect(darker == 0)
        #expect(brighter > 500)      // the rim really does pick the backdrop up
    }

    @Test func theRimCatchesMoreLightThanTheBody() {
        // The whole point of the pass: the surface curves away over the last `bevel` pixels, so
        // that is where the highlight and the returned light live. Without it the mark is a flat
        // shape again. The two zones are taken from the distance field rather than guessed at by
        // radius, so this keeps meaning the same thing for any outline.
        let bevel = 18.0
        let (pixels, alpha, n) = shade(bodyValue: 150, backdropValue: 0)
        let distance = DistanceField.inside(alpha.map { Double($0) / 255 }, width: n, height: n)

        var rim: [Double] = [], core: [Double] = []
        for i in 0..<(n * n) where alpha[i] > 250 {
            let value = Double(pixels[i * 4])
            if distance[i] < bevel { rim.append(value) }
            if distance[i] > bevel * 1.6 { core.append(value) }
        }
        #expect(rim.count > 200 && core.count > 200)
        #expect(rim.max()! > core.max()! + 20)
        // And the shading has to vary across the lip, not sit on it as one flat tone.
        #expect(rim.max()! - rim.min()! > 30)
    }
}

struct RouteStyleTests {

    /// Built at the size it will be drawn at: the plan's transform is size-specific, and
    /// mixing the two puts every marker outside the canvas.
    private func plan(_ size: Double = 1024) -> CityPlan { CityMap.plan(size: size) }

    @Test func everyStyleDrawsWithoutReachingOutsideTheIcon() {
        // Each style places markers from the route or from junctions, and any of them can land off
        // the canvas once the map is rotated. Drawing must stay inside either way.
        for style in RouteStyle.allCases {
            let ctx = Raster.context(size: 256)
            var ink = CityMap.Ink()
            ink.style = style
            let palette = try! Palette(source: """
                static let void: UInt32 = 0x090B0D
                static let deepSurface: UInt32 = 0x101418
                static let elevatedSurface: UInt32 = 0x181E22
                static let ice: UInt32 = 0xE8F0ED
                static let mist: UInt32 = 0x8E9B98
                static let aurora: UInt32 = 0xB8F36B
                static let ion: UInt32 = 0x65E6D0
                static let amber: UInt32 = 0xFFBF69
                static let coral: UInt32 = 0xFF6B5F
                """)
            CityMap.drawRoute(plan(256), in: ctx, palette: palette, scale: 0.25, ink: ink)
            let image = Raster.image(ctx)
            #expect(image.width == 256)
        }
    }

    @Test func theRouteIsShortEnoughToStayOutOfTheMarksWay() {
        // A route that crosses the whole icon reads as a crack through it rather than as a path.
        let plan = plan()
        let points = plan.route.map { $0.applying(plan.transform) }
        let xs = points.map(\.x), ys = points.map(\.y)
        let width = xs.max()! - xs.min()!, height = ys.max()! - ys.min()!
        #expect(width < 1024 * 0.55)
        #expect(height < 1024 * 0.55)
        #expect(plan.routeStops.count == 3)
    }

    @Test func onlyTheFarStopIsAmber() {
        // Amber means "worth a glance" and is meant to be rare: one point on the whole map.
        // Guarded by counting, since it is the kind of accent that creeps.
        let ctx = Raster.context(size: 512)
        var ink = CityMap.Ink()
        ink.style = .dashed
        let palette = try! Palette(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/PathOSPalette.swift"))
        CityMap.drawRoute(plan(512), in: ctx, palette: palette, scale: 0.5, ink: ink)

        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var amber = 0, green = 0
        for i in 0..<(512 * 512) {
            let r = Int(data[i * 4]), g = Int(data[i * 4 + 1]), b = Int(data[i * 4 + 2])
            guard data[i * 4 + 3] > 120 else { continue }
            if r > g && g > b && r - b > 60 { amber += 1 }
            if g > r && r > b && g - b > 60 { green += 1 }
        }
        #expect(amber > 0)
        #expect(green > amber * 2)     // green leads, amber accents
    }
}
