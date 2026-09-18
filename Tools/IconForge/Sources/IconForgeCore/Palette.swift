import CoreGraphics
import Foundation

public struct Swatch: Equatable, Sendable {
    public var red: Double, green: Double, blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }

    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// Hue, saturation and lightness. Mixing toward white is not the same as lightening: it drops
    /// saturation too, and a ramp built that way fades to grey instead of staying a colour.
    public var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let high = max(red, green, blue), low = min(red, green, blue)
        let lightness = (high + low) / 2
        guard high > low else { return (0, 0, lightness) }
        let span = high - low
        let saturation = lightness > 0.5 ? span / (2 - high - low) : span / (high + low)
        var hue: Double
        if high == red { hue = (green - blue) / span + (green < blue ? 6 : 0) }
        else if high == green { hue = (blue - red) / span + 2 }
        else { hue = (red - green) / span + 4 }
        return (hue * 60, saturation, lightness)
    }

    public init(hue: Double, saturation: Double, lightness: Double) {
        let h = ((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360
        guard saturation > 0 else { self.init(red: lightness, green: lightness, blue: lightness); return }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func channel(_ offset: Double) -> Double {
            var t = h + offset
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        self.init(red: channel(1.0 / 3), green: channel(0), blue: channel(-1.0 / 3))
    }

    /// Same colour, moved along the lightness axis with its saturation intact.
    public func lightness(_ value: Double) -> Swatch {
        let current = hsl
        return Swatch(hue: current.hue, saturation: current.saturation, lightness: value)
    }

    public func cg(_ alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// Blend toward another colour. Used to derive the logo's lighter and deeper teals from Ion,
    /// so a palette change carries through instead of leaving a hardcoded colour behind.
    public func mixed(with other: Swatch, _ amount: Double) -> Swatch {
        let t = max(0, min(1, amount))
        return Swatch(red: red + (other.red - red) * t,
                      green: green + (other.green - green) * t,
                      blue: blue + (other.blue - blue) * t)
    }

    public func scaled(_ factor: Double) -> Swatch {
        Swatch(red: max(0, min(1, red * factor)),
               green: max(0, min(1, green * factor)),
               blue: max(0, min(1, blue * factor)))
    }
}

public enum PaletteError: Error, CustomStringConvertible {
    case unreadable(String)
    case missing([String], String)

    public var description: String {
        switch self {
        case .unreadable(let path):
            "Can't read the palette at \(path)."
        case .missing(let names, let path):
            "\(path) no longer defines \(names.joined(separator: ", ")). The icon takes every colour "
            + "from the palette, so add them back or update IconForge to match."
        }
    }
}

/// The app's colours, read from `Shared/PathOSPalette.swift` at run time rather than copied here.
///
/// The icon and the app can't drift apart: if a constant is renamed or removed this throws instead
/// of quietly baking a stale colour into the artwork.
public struct Palette: Sendable {
    public let void: Swatch
    public let deepSurface: Swatch
    public let elevatedSurface: Swatch
    public let ice: Swatch
    public let mist: Swatch
    public let aurora: Swatch
    public let ion: Swatch
    public let amber: Swatch
    public let coral: Swatch

    public static let requiredNames = [
        "void", "deepSurface", "elevatedSurface", "ice", "mist", "aurora", "ion", "amber", "coral",
    ]

    public init(contentsOf url: URL) throws {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw PaletteError.unreadable(url.path)
        }
        try self.init(source: source, origin: url.lastPathComponent)
    }

    public init(source: String, origin: String = "the palette") throws {
        var found: [String: Swatch] = [:]
        let pattern = /static\s+let\s+(\w+)\s*:\s*UInt32\s*=\s*0x([0-9A-Fa-f]{6})/
        for match in source.matches(of: pattern) {
            guard let hex = UInt32(match.2, radix: 16) else { continue }
            found[String(match.1)] = Swatch(hex: hex)
        }
        let missing = Self.requiredNames.filter { found[$0] == nil }
        guard missing.isEmpty else { throw PaletteError.missing(missing, origin) }

        void = found["void"]!
        deepSurface = found["deepSurface"]!
        elevatedSurface = found["elevatedSurface"]!
        ice = found["ice"]!
        mist = found["mist"]!
        aurora = found["aurora"]!
        ion = found["ion"]!
        amber = found["amber"]!
        coral = found["coral"]!
    }

    // MARK: Derived

    /// The mark's colours: Ion's own hue and saturation, moved along the lightness axis.
    ///
    /// Every stop stays vivid. Lightening by mixing toward Ice washes the teal out until the mark
    /// is a pale grey shape, and dipping into dark teal reads as shadow rather than colour — both
    /// leave the mark looking like one flat tone. The hue drifts a little across the ramp, cyan at
    /// the lit end toward green-teal at the deep end, which is what keeps it alive.
    private var tealHue: Double { ion.hsl.hue }
    /// Pushed well up: at high lightness a colour needs a lot of saturation to still read
    /// as a colour rather than a tint.
    private var tealSaturation: Double { min(1, ion.hsl.saturation * 1.26) }

    private func teal(lightness: Double, hueShift: Double = 0) -> Swatch {
        Swatch(hue: tealHue + hueShift, saturation: tealSaturation, lightness: lightness)
    }

    /// Kept well clear of the top of the range. The lighting adds specular and edge light on top
    /// of these, and a body that already sits near white clips the green channel — which is what
    /// flattens the whole mark into one pale tone no matter how the ramp is built.
    public var markLight: Swatch { teal(lightness: 0.845, hueShift: 17) }
    public var markMid: Swatch { teal(lightness: 0.715, hueShift: 6) }
    /// The deepest tone still sits above Ion's own lightness — the ramp travels light, not dark.
    public func markDeep(_ shade: Double) -> Swatch { teal(lightness: 0.595 - 0.34 * (1 - shade), hueShift: -8) }

    public func markRamp(shade: Double) -> [(Double, Swatch)] {
        [(0.00, markLight),
         (0.34, markMid),
         (0.70, teal(lightness: 0.595, hueShift: -3)),
         (1.00, markDeep(shade))]
    }

    public var ionCool: Swatch { Swatch(red: ion.red * 0.32, green: ion.green * 0.56, blue: ion.blue) }
}
