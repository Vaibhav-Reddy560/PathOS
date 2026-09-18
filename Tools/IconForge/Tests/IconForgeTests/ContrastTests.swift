import CoreGraphics
import Foundation
import Testing
@testable import IconForgeCore

/// How well the mark separates from what's behind it, measured along its own outline.
///
/// This is the property that decides whether the icon still reads on a dim screen or at
/// home-screen size, and it is easy to lose: the treatments that make the mark look like glass all
/// work by darkening it, and the places they darken most are its edges.
///
/// Measured at the size the icon actually ships at. Sampling a half-size render probes a different
/// distance relative to the artwork and quietly answers a different question.
struct MarkLegibilityTests {

    private struct Measurement {
        var plain: [Double]
        var veiled: [Double]
        /// How far the mark's colour travels from its 5th to its 95th percentile, as a distance
        /// in sRGB. Luminance alone is the wrong axis here: a saturated teal keeps its green
        /// channel near maximum however light or deep it is, so a ramp can travel a long way in
        /// colour while barely moving in brightness.
        var markColourTravel: Double
        /// How far its hue travels over the same span, in degrees.
        var markHueTravel: Double
    }

    /// One render, shared by every test in this suite — at 1024 it is far too slow to repeat.
    private static let measured = measure()

    private static func luminance(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Double {
        func channel(_ value: UInt8) -> Double {
            let v = Double(value) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// `veil` models a dim screen in ambient light: reflected light lands on both the mark and the
    /// ground, lifting the darker of the two proportionally more and closing the gap.
    private static func hue(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Double {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let high = max(r, g, b), low = min(r, g, b)
        guard high > low else { return 0 }
        let span = high - low
        let value: Double
        if high == r { value = (g - b) / span + (g < b ? 6 : 0) }
        else if high == g { value = (b - r) / span + 2 }
        else { value = (r - g) / span + 4 }
        return value * 60
    }

    private static func contrast(_ first: Double, _ second: Double, veil: Double) -> Double {
        let a = first + veil, b = second + veil
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func measure() -> Measurement {
        let n = 1024
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let logo = try! SVGParser.parse(contentsOf: root.appendingPathComponent("PathOS_Logo.svg"))
        let palette = try! Palette(contentsOf: root.appendingPathComponent("Shared/PathOSPalette.swift"))

        var settings = IconRenderer.Settings()
        settings.size = n
        let icon = IconRenderer.render(logo: logo, palette: palette, settings: settings)
        let mark = Raster.mask(path: IconRenderer.place(logo, in: Double(n), scale: settings.logoScale),
                               size: n, fillRule: logo.fillRule)

        let rect = CGRect(x: 0, y: 0, width: n, height: n)
        let iconCtx = Raster.context(size: n); iconCtx.draw(icon, in: rect)
        let maskCtx = Raster.grayContext(size: n); maskCtx.draw(mark, in: rect)
        let pixels = iconCtx.data!.assumingMemoryBound(to: UInt8.self)
        let alpha = maskCtx.data!.assumingMemoryBound(to: UInt8.self)

        func brightness(_ x: Int, _ y: Int) -> Double {
            let i = (y * n + x) * 4
            return luminance(pixels[i], pixels[i + 1], pixels[i + 2])
        }

        var plain: [Double] = [], veiled: [Double] = [], hues: [Double] = []
        var reds: [Double] = [], greens: [Double] = [], blues: [Double] = []
        for i in 0..<(n * n) where alpha[i] > 240 {
            reds.append(Double(pixels[i * 4]))
            greens.append(Double(pixels[i * 4 + 1]))
            blues.append(Double(pixels[i * 4 + 2]))
            hues.append(hue(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2]))
        }

        // Step along the outline's own normal, so each pair straddles the edge rather than
        // sampling whatever happens to be nearby.
        for y in 6..<(n - 6) {
            for x in 6..<(n - 6) {
                let gx = Double(alpha[y * n + x + 1]) - Double(alpha[y * n + x - 1])
                let gy = Double(alpha[(y + 1) * n + x]) - Double(alpha[(y - 1) * n + x])
                let magnitude = (gx * gx + gy * gy).squareRoot()
                guard magnitude > 40 else { continue }

                let insideX = Int((Double(x) + gx / magnitude * 3).rounded())
                let insideY = Int((Double(y) + gy / magnitude * 3).rounded())
                let outsideX = Int((Double(x) - gx / magnitude * 3.5).rounded())
                let outsideY = Int((Double(y) - gy / magnitude * 3.5).rounded())
                guard (0..<n).contains(insideX), (0..<n).contains(insideY),
                      (0..<n).contains(outsideX), (0..<n).contains(outsideY),
                      alpha[insideY * n + insideX] > 230,      // solidly on the mark
                      alpha[outsideY * n + outsideX] < 25      // solidly on the ground
                else { continue }

                let onMark = brightness(insideX, insideY), onGround = brightness(outsideX, outsideY)
                plain.append(contrast(onMark, onGround, veil: 0))
                veiled.append(contrast(onMark, onGround, veil: 0.02))
            }
        }
        hues.sort()
        func spread(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count * 19 / 20] - sorted[sorted.count / 20]
        }
        let travel = (pow(spread(reds), 2) + pow(spread(greens), 2) + pow(spread(blues), 2)).squareRoot()
        return Measurement(plain: plain.sorted(), veiled: veiled.sorted(),
                           markColourTravel: travel,
                           markHueTravel: hues[hues.count * 19 / 20] - hues[hues.count / 20])
    }

    @Test func theOutlineClearsTheGraphicalContrastThreshold() {
        let ratios = Self.measured.plain
        #expect(ratios.count > 4_000)
        // WCAG 1.4.11 asks 3:1 for a graphical object to be distinguishable.
        #expect(ratios.first! >= 3.0)
        #expect(ratios[ratios.count / 2] >= 5.0)
    }

    @Test func itStillHoldsOnADimScreenInAmbientLight() {
        // Reflected light lifts the dark ground more than the bright mark, so this is the case
        // that actually fails first — not the one that looks worst in a bright preview.
        let ratios = Self.measured.veiled
        #expect(ratios.first! >= 3.0)
        #expect(ratios[ratios.count / 20] >= 4.0)      // 5th percentile
        #expect(ratios[ratios.count / 2] >= 5.0)
    }

    @Test func theMarkVariesEnoughToReadAsAGradient() {
        // The mark looked like one solid colour when its ramp only moved in lightness through pale
        // tints. Distance in sRGB is what catches that, and it catches it whichever way the ramp
        // travels: the current stops hold hue at Ion's and move lightness and chroma instead, so a
        // hue-travel check would fail a design that is plainly a gradient. Roughly a fifth of the
        // way across sRGB from one end of the mark to the other.
        #expect(Self.measured.markColourTravel > 85)
    }
}
