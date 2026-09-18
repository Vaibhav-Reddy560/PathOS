import CoreGraphics
import Foundation
import Testing
@testable import IconForgeCore

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

/// The icon takes every colour from the app, so the two can't drift apart without someone noticing.
struct PaletteTests {

    @Test func readsTheAppsOwnPalette() throws {
        let palette = try Palette(contentsOf: repoRoot().appendingPathComponent("Shared/PathOSPalette.swift"))
        #expect(palette.ion == Swatch(hex: 0x65E6D0))
        #expect(palette.aurora == Swatch(hex: 0xB8F36B))
        #expect(palette.void == Swatch(hex: 0x090B0D))
    }

    @Test func aRenamedColourIsLoudRatherThanSilent() {
        let source = "static let void: UInt32 = 0x090B0D\nstatic let ice: UInt32 = 0xE8F0ED"
        #expect(throws: PaletteError.self) { try Palette(source: source) }
    }

    @Test func theMarksFacesAreDerivedFromIon() throws {
        let palette = try Palette(contentsOf: repoRoot().appendingPathComponent("Shared/PathOSPalette.swift"))
        // Lit face lighter than Ion, shaded face darker — and every face still teal, not grey.
        // Compared by luminance, not by a single channel: the ramp is more saturated than Ion, so
        // its deep face can hold a higher green while still being the darker colour.
        func lum(_ c: Swatch) -> Double { 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue }
        #expect(lum(palette.markLight) > lum(palette.ion))
        #expect(lum(palette.markDeep(0.66)) < lum(palette.markLight))
        for face in [palette.markLight, palette.markMid, palette.markDeep(0.66)] {
            #expect(face.green > face.red && face.blue > face.red)
        }
    }

    @Test func theGroundHasAHueOfItsOwn() throws {
        let palette = try Palette(contentsOf: repoRoot().appendingPathComponent("Shared/PathOSPalette.swift"))
        // Cooled Ion has to be clearly bluer than Ion, or the ground and the mark read as one mass.
        #expect(palette.ionCool.blue > palette.ionCool.green)
        #expect(palette.ion.green > palette.ion.blue)
    }

    @Test func theMarkOutContrastsTheGround() throws {
        // The reason the first icon looked dull: a near-black ground and a mid-tone mark. Whatever
        // else changes, the mark has to stay far brighter than the ground it sits on.
        let palette = try Palette(contentsOf: repoRoot().appendingPathComponent("Shared/PathOSPalette.swift"))
        func luminance(_ c: Swatch) -> Double { 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue }
        let ground = palette.ion.mixed(with: palette.ionCool, 0.88).scaled(0.16 + 0.34 * 0.58)
        #expect(luminance(palette.markLight) > luminance(ground) * 3.5)
        #expect(luminance(palette.markDeep(0.66)) > luminance(ground) * 1.8)
    }
}

struct CityMapTests {

    private func fingerprint(_ plan: CityPlan) -> [Double] {
        plan.streets.flatMap { $0.points.map { Double($0.x) } } + plan.junctions.map { Double($0.y) }
    }

    @Test func theSameSeedAlwaysDrawsTheSameCity() {
        #expect(fingerprint(CityMap.plan(size: 1024)) == fingerprint(CityMap.plan(size: 1024)))
    }

    @Test func differentSeedsDrawDifferentCities() {
        #expect(fingerprint(CityMap.plan(size: 1024, seed: 1)) != fingerprint(CityMap.plan(size: 1024, seed: 2)))
    }

    @Test func theGridStaysAGrid() {
        // The deformation must never fold a road back on itself, or blocks stop being enclosed.
        // Every road should advance monotonically along its own axis.
        let plan = CityMap.plan(size: 1024)
        for street in plan.streets.prefix(12) {
            let xs = street.points.map(\.x), ys = street.points.map(\.y)
            let movesInX = abs(xs.last! - xs.first!) > abs(ys.last! - ys.first!)
            let values = movesInX ? xs : ys
            #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
        }
    }

    @Test func thereAreRoadsOfEveryRankAndBlocksToFillThem() {
        let plan = CityMap.plan(size: 1024)
        #expect(Set(plan.streets.map(\.rank)) == [0, 1, 2])
        #expect(plan.blocks.count > 60)
        #expect(plan.junctions.count > 10)
        #expect(plan.blocks.allSatisfy { $0.count == 4 })
    }
}

struct RasterTests {

    @Test func blurringAFlatFieldChangesNothing() {
        // Edge clamping matters: without it a blur darkens the border of the whole icon.
        let flat = Raster.mask(size: 64) { $0.fill(CGRect(x: 0, y: 0, width: 64, height: 64)) }
        let blurred = Raster.blurred(flat, radius: 12)
        let ctx = Raster.grayContext(size: 64)
        ctx.draw(blurred, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        #expect((0..<(64 * 64)).allSatisfy { data[$0] > 250 })
    }

    @Test func blurringIsReproducible() {
        let source = Raster.mask(path: CGPath(ellipseIn: CGRect(x: 20, y: 20, width: 80, height: 80), transform: nil), size: 128)
        #expect(bytes(Raster.blurred(source, radius: 9)) == bytes(Raster.blurred(source, radius: 9)))
    }

    @Test func invertingTwiceGivesBackTheOriginal() {
        let source = Raster.mask(path: CGPath(ellipseIn: CGRect(x: 10, y: 10, width: 40, height: 40), transform: nil), size: 64)
        #expect(bytes(Raster.inverted(Raster.inverted(source))) == bytes(source))
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        let size = image.width
        let ctx = Raster.grayContext(size: size)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<(size * size)).map { data[$0] }
    }
}

struct IconRendererTests {

    private func logo() throws -> SVGDocument {
        try SVGParser.parse(contentsOf: repoRoot().appendingPathComponent("PathOS_Logo.svg"))
    }

    private func palette() throws -> Palette {
        try Palette(contentsOf: repoRoot().appendingPathComponent("Shared/PathOSPalette.swift"))
    }

    @Test func theMarkIsCentredAndSizedByItsDrawnBounds() throws {
        let placed = IconRenderer.place(try logo(), in: 1000, scale: 0.6)
        let bounds = placed.boundingBoxOfPath
        #expect(abs(bounds.midX - 500) < 0.5)
        #expect(abs(bounds.midY - 500) < 0.5)
        // The logo is wider than it is tall, so width is what 0.6 applies to.
        #expect(abs(bounds.width - 600) < 1)
        #expect(bounds.height < bounds.width)
    }

    @Test func aTallMarkIsScaledByItsHeightInstead() throws {
        // Whatever replaces the logo, it has to fit — the longer side is what's constrained.
        let tall = try SVGParser.parse(data: Data(#"<svg viewBox="0 0 100 100"><rect x="40" y="0" width="20" height="100"/></svg>"#.utf8))
        let bounds = IconRenderer.place(tall, in: 1000, scale: 0.6).boundingBoxOfPath
        #expect(abs(bounds.height - 600) < 1)
        #expect(abs(bounds.width - 120) < 1)
    }

    @Test func theIconIsFullBleedAndOpaque() throws {
        // iOS applies the rounded mask itself, so the artwork must reach every corner.
        var settings = IconRenderer.Settings()
        settings.size = 128
        let icon = IconRenderer.render(logo: try logo(), palette: try palette(), settings: settings)
        #expect(icon.width == 128 && icon.height == 128)

        let ctx = Raster.context(size: 128)
        ctx.draw(icon, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let corners = [0, 127, 127 * 128, 127 * 128 + 127]
        #expect(corners.allSatisfy { data[$0 * 4 + 3] == 255 })
    }

    @Test func theMarkIsTealAndTheBackgroundIsNot() throws {
        var settings = IconRenderer.Settings()
        settings.size = 256
        let icon = IconRenderer.render(logo: try logo(), palette: try palette(), settings: settings)
        let ctx = Raster.context(size: 256)
        ctx.draw(icon, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = ((255 - y) * 256 + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }
        // The centre sits on the mark: bright, and green-blue rather than neutral.
        let centre = pixel(128, 128)
        #expect(centre.1 > 120)
        #expect(centre.1 > centre.0 + 30 && centre.2 > centre.0 + 20)
        // A corner is map, not mark: dark.
        let corner = pixel(8, 8)
        #expect(corner.0 < 70 && corner.1 < 70)
    }

    @Test func renderingIsReproducible() throws {
        var settings = IconRenderer.Settings()
        settings.size = 96
        let logo = try logo(), palette = try palette()
        func bytes() -> [UInt8] {
            let icon = IconRenderer.render(logo: logo, palette: palette, settings: settings)
            let ctx = Raster.context(size: 96)
            ctx.draw(icon, in: CGRect(x: 0, y: 0, width: 96, height: 96))
            let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<(96 * 96 * 4)).map { data[$0] }
        }
        #expect(bytes() == bytes())
    }
}
