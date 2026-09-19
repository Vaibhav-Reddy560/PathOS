import CoreGraphics
import Foundation

/// Composites the icon.
///
/// Every layer derives from the supplied SVG path or from the palette — nothing is measured
/// against the current logo. Replace `PathOS_Logo.svg` and the whole stack re-forms around the
/// new shape: the shadow, the glass edge, the inner shading and the bloom are all masks built
/// from the path at run time.
public struct IconRenderer {

    public struct Settings: Sendable {
        public var size = 1024
        /// The logo's longer dimension, as a fraction of the icon.
        public var logoScale = 0.68
        /// One dial for the whole map layer.
        public var mapIntensity = 1.0
        /// How far the map's ground is lifted off Void. At zero the tile is nearly black, which
        /// reads as a hole punched in the wallpaper rather than as an object sitting on it.
        public var groundLift = 0.58
        /// 0 keeps the ground teal, 1 cools it all the way to blue.
        public var groundCool = 0.88
        /// How dark the mark's shaded face goes, as a fraction of Ion.
        public var markShade = 0.74
        /// How far in from the outline the glass rolls off, at 1024.
        public var glassBevel = 7.0
        public var routeStyle: RouteStyle = .dashed
        public var seed = CityMap.defaultSeed
        public init() {}
    }

    public static func render(logo: SVGDocument, palette: Palette, settings: Settings = Settings()) -> CGImage {
        let size = settings.size
        let s = Double(size)
        let k = s / 1024                       // every constant below is authored at 1024
        let ctx = Raster.context(size: size)
        let full = CGRect(x: 0, y: 0, width: s, height: s)

        let logoPath = place(logo, in: s, scale: settings.logoScale)
        let logoMask = Raster.mask(path: logoPath, size: size, fillRule: logo.fillRule)
        let outsideLogo = Raster.inverted(logoMask)

        drawBackdrop(in: ctx, logoMask: logoMask, palette: palette, settings: settings)

        // The backdrop the glass will refract, captured before anything is drawn on top of it.
        let backdrop = Raster.image(ctx)

        // 6 — the logo sits above the map, so it casts onto it
        shadow(ctx, mask: logoMask, size: size, offset: CGPoint(x: 0, y: -26 * k), blur: 44 * k, alpha: 0.78)
        shadow(ctx, mask: logoMask, size: size, offset: CGPoint(x: 0, y: -6 * k), blur: 9 * k, alpha: 0.70)
        // An occlusion ring hugging the whole outline, not just the lit side. Where the mark
        // happens to cross a lit road or a green pool, this is what keeps the two apart — and it
        // works outside the mark, so it costs the glass nothing.
        shadow(ctx, mask: logoMask, size: size, offset: .zero, blur: 5 * k, alpha: 0.55)

        // 7–10 — the mark itself, lit as glass
        ctx.draw(litMark(logo: logo, path: logoPath, mask: logoMask, backdrop: backdrop,
                         palette: palette, settings: settings), in: full)

        // 11 — a halo rather than a neon glow. The broad sweep of gloss that used to sit here is
        // gone: the shading pass computes real highlights from the surface, and a flat wash over
        // the top only cancels them out.
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        Raster.clipped(ctx, to: Raster.blurred(logoMask, radius: 30 * k)) { inner in
            Raster.clipped(inner, to: outsideLogo) { halo in
                halo.setFillColor(palette.ion.cg(0.10))
                halo.fill(full)
            }
        }
        ctx.restoreGState()

        // 12 — the icon's own surface
        Raster.clipped(ctx, to: Raster.linearMask(size: size, from: CGPoint(x: 0, y: s),
                                                  to: CGPoint(x: 0.78 * s, y: 0.18 * s),
                                                  stops: [(0, 1), (1, 0)])) { inner in
            inner.setFillColor(CGColor(gray: 1, alpha: 0.060))
            inner.fill(full)
        }

        // 13 — rim light. Soft on purpose: iOS masks the icon with its own squircle, and a hard
        // line drawn a few pixels from where that mask lands looks like a box someone drew.
        let lit = edgeBand(size: size, depth: 16 * k, softness: 9 * k)
        ctx.saveGState()
        Raster.clipped(ctx, to: Raster.linearMask(size: size, from: CGPoint(x: 0, y: s), to: CGPoint(x: 0, y: 0.34 * s),
                                                  stops: [(0, 1), (1, 0)])) { inner in
            Raster.clipped(inner, to: lit) { band in
                band.setFillColor(CGColor(gray: 1, alpha: 0.20))
                band.fill(full)
            }
        }
        Raster.clipped(ctx, to: Raster.linearMask(size: size, from: CGPoint(x: 0, y: 0.30 * s), to: CGPoint(x: 0, y: 0),
                                                  stops: [(0, 0), (1, 1)])) { inner in
            Raster.clipped(inner, to: edgeBand(size: size, depth: 13 * k, softness: 7 * k)) { band in
                band.setFillColor(CGColor(gray: 0, alpha: 0.22))
                band.fill(full)
            }
        }
        ctx.restoreGState()

        return Raster.image(ctx)
    }

    // MARK: Stages

    /// Stages 1–5: the ground, the city, the route and the depth, drawn onto `ctx`.
    private static func drawBackdrop(in ctx: CGContext, logoMask: CGImage, palette: Palette, settings: Settings) {
        let size = settings.size
        let s = Double(size)
        let k = s / 1024
        let full = CGRect(x: 0, y: 0, width: s, height: s)

        // 1 — base. The ground carries the app's own hue rather than being neutral black, so the
        // tile has a colour of its own the way every icon on the home screen does.
        let lift = settings.groundLift
        // Built from Ion rather than from the grey surfaces: mixing a hue into near-neutral grey
        // gives low chroma, and low chroma at icon size just reads as mud.
        let hue = palette.ion.mixed(with: palette.ionCool, settings.groundCool)
        let ground = hue.scaled(0.16 + 0.34 * lift)
        let deep = hue.scaled(0.05 + 0.10 * lift).mixed(with: palette.void, 0.45)
        ctx.setFillColor(deep.cg())
        ctx.fill(full)

        // 2 — atmosphere: light falls from the upper left, so the ground is brightest there
        field(ctx, color: ground, alpha: 1.0, center: CGPoint(x: 0.34 * s, y: 0.78 * s), radius: 1.02 * s)
        field(ctx, color: ground.mixed(with: palette.ice, 0.10), alpha: 0.55,
              center: CGPoint(x: 0.30 * s, y: 0.82 * s), radius: 0.46 * s)
        field(ctx, color: palette.ion, alpha: 0.05, center: CGPoint(x: 0.70 * s, y: 0.24 * s), radius: 0.70 * s)

        // 3 — the city
        let plan = CityMap.plan(size: s, seed: settings.seed)
        var ink = CityMap.Ink()
        ink.intensity = settings.mapIntensity
        ink.style = settings.routeStyle
        CityMap.draw(plan, in: ctx, palette: palette, scale: k, ink: ink)

        // 4a — the route, kept clear of the mark so a bright stop can never touch its outline.
        // Boosting the blurred silhouette before inverting turns a soft falloff into a hard
        // exclusion zone with a soft outer edge: nothing green gets within ~30px of the mark, but
        // the route still fades in rather than stopping at a line.
        let nearMark = Raster.blurred(logoMask, radius: 34 * k)
        let clearOfMark = Raster.inverted(Raster.combine(nearMark, nearMark) { value, _ in
            UInt8(min(255, Int(value) * 6))
        })
        // A marker is a solid object and needs more room than a dashed line does: set well inside
        // the rounded shape iOS masks the icon to — not the square edge of the file — and further
        // from the mark, so it never looks crowded against either.
        let insideIcon = Raster.mask(size: size) { inner in
            inner.addPath(Squircle.path(size: s, inset: 82 * k))
            inner.fillPath()
        }
        let farFromMark = Raster.blurred(logoMask, radius: 60 * k)
        let markerRoom = Raster.combine(
            insideIcon,
            Raster.inverted(Raster.combine(farFromMark, farFromMark) { value, _ in
                UInt8(min(255, Int(value) * 6))
            })
        ) { inside, away in min(inside, away) }

        CityMap.drawRoute(plan, in: ctx, palette: palette, scale: k, ink: ink,
                          clearance: clearOfMark, markerClearance: markerRoom)

        // 4 — the route through the city. The soft green pools that used to sit here are gone:
        // a blur of colour reads as a smudge at icon size, where a line with stops on it reads as
        // a path. Only a faint cool wash is left, to keep the map from being evenly lit.
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        field(ctx, color: palette.ion, alpha: 0.06, center: CGPoint(x: 0.30 * s, y: 0.72 * s), radius: 0.34 * s)
        ctx.restoreGState()

        // 5 — depth: the edges soften and darken, so the centre reads first
        let mapSoftened = Raster.blurred(Raster.image(ctx), radius: 4 * k)
        Raster.clipped(ctx, to: Raster.radialMask(size: size, center: CGPoint(x: s / 2, y: s / 2),
                                                  radius: 0.74 * s, stops: [(0, 0), (0.76, 0), (1, 1)])) { inner in
            inner.draw(mapSoftened, in: full)
        }
        vignette(ctx, size: s, strength: 0.34)
    }

    /// Stages 7–10: the mark's colour, lit as glass over `backdrop`. Transparent everywhere else.
    private static func litMark(logo: SVGDocument, path logoPath: CGPath, mask logoMask: CGImage,
                                backdrop: CGImage, palette: Palette, settings: Settings) -> CGImage {
        let size = settings.size
        let k = Double(size) / 1024

        // 7 — the mark's colour, drawn on its own so the lighting below can modulate it
        let bounds = logoPath.boundingBoxOfPath
        let bodyCtx = Raster.context(size: size)
        bodyCtx.addPath(logoPath)
        logo.fillRule == .evenOdd ? bodyCtx.clip(using: .evenOdd) : bodyCtx.clip()
        // Along the mark's own diagonal, not across it. Running the ramp across the limbs shades
        // each one light-to-dark over its width, which reads as an inflated tube; running it along
        // them leaves the faces flat and lets the colour travel the length of the figure.
        // Straight up the mark, bottom to top, spanning its full height: the three stops are a
        // vertical ramp, and the shape reaches both extremes at its own top and bottom.
        gradient(bodyCtx,
                 from: CGPoint(x: bounds.midX, y: bounds.minY),
                 to: CGPoint(x: bounds.midX, y: bounds.maxY),
                 stops: palette.markRamp(shade: settings.markShade).map { (CGFloat($0.0), $0.1.cg()) })

        // 8–10 — light it as glass: a bevelled rim that catches a sharp highlight, throws light
        // back at grazing angles, and bends the map behind it. All derived from the outline, so it
        // re-forms around whatever SVG is dropped in.
        var light = GlassShading.Light()
        light.bevel = settings.glassBevel
        return GlassShading.render(mask: logoMask, backdrop: backdrop, body: Raster.image(bodyCtx),
                                   size: size, scale: k, light: light)
    }

    /// The mark on its own, lit exactly as it is in the icon but with no tile, shadow or halo:
    /// for the launch screen, where it stands on the app's own background. Cropped to the mark.
    public static func renderMark(logo: SVGDocument, palette: Palette, settings: Settings = Settings()) -> CGImage {
        let size = settings.size
        let ctx = Raster.context(size: size)
        let logoPath = place(logo, in: Double(size), scale: settings.logoScale)
        let logoMask = Raster.mask(path: logoPath, size: size, fillRule: logo.fillRule)
        drawBackdrop(in: ctx, logoMask: logoMask, palette: palette, settings: settings)
        let mark = litMark(logo: logo, path: logoPath, mask: logoMask, backdrop: Raster.image(ctx),
                           palette: palette, settings: settings)

        // Path space is y-up; image rows run top-down.
        let bounds = logoPath.boundingBoxOfPath.insetBy(dx: -3, dy: -3).integral
        let crop = CGRect(x: bounds.minX, y: Double(size) - bounds.maxY, width: bounds.width, height: bounds.height)
            .intersection(CGRect(x: 0, y: 0, width: size, height: size))
        return mark.cropping(to: crop) ?? mark
    }

    // MARK: Placing the mark

    /// SVG space is y-down and arbitrarily sized; the icon is y-up and square. The mark is fitted
    /// by its drawn bounds, not its viewBox, so padding in the file doesn't shrink it.
    public static func place(_ logo: SVGDocument, in size: Double, scale logoScale: Double) -> CGPath {
        let bounds = logo.bounds
        let factor = size * logoScale / max(bounds.width, bounds.height)
        var transform = CGAffineTransform(translationX: size / 2, y: size / 2)
            .scaledBy(x: factor, y: -factor)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        return logo.path.copy(using: &transform) ?? logo.path
    }

    /// A soft band just inside the icon's outline — the shape, minus a shrunken copy, blurred.
    private static func edgeBand(size: Int, depth: Double, softness: Double) -> CGImage {
        let s = Double(size)
        let outer = Raster.mask(size: size) { $0.addPath(Squircle.path(size: s)); $0.fillPath() }
        let inner = Raster.mask(size: size) { $0.addPath(Squircle.path(size: s, inset: depth)); $0.fillPath() }
        let band = Raster.combine(outer, inner) { UInt8(max(0, Int($0) - Int($1))) }
        return Raster.blurred(band, radius: softness)
    }

    // MARK: Pieces

    private static func field(_ ctx: CGContext, color: Swatch, alpha: Double, center: CGPoint, radius: Double) {
        let colors = [color.cg(alpha), color.cg(0)] as CFArray
        let gradient = CGGradient(colorsSpace: Raster.colorSpace, colors: colors, locations: [0, 1])!
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
    }

    private static func gradient(_ ctx: CGContext, from: CGPoint, to: CGPoint, stops: [(CGFloat, CGColor)]) {
        let gradient = CGGradient(colorsSpace: Raster.colorSpace,
                                  colors: stops.map(\.1) as CFArray,
                                  locations: stops.map(\.0))!
        ctx.drawLinearGradient(gradient, start: from, end: to,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func vignette(_ ctx: CGContext, size: Double, strength: Double) {
        let colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: strength)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0.45, 1])!
        let center = CGPoint(x: size / 2, y: size / 2)
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: size * 0.78, options: [.drawsAfterEndLocation])
    }

    private static func shadow(_ ctx: CGContext, mask: CGImage, size: Int,
                               offset: CGPoint, blur: Double, alpha: Double) {
        let shifted = Raster.mask(size: size) { inner in
            inner.translateBy(x: offset.x, y: offset.y)
            inner.draw(mask, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        Raster.clipped(ctx, to: Raster.blurred(shifted, radius: blur)) { inner in
            inner.setFillColor(CGColor(gray: 0, alpha: alpha))
            inner.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    /// A band of light or shade hugging one side of the shape from the inside: the shape, minus a
    /// blurred copy of itself pushed the other way.
    private static func band(_ ctx: CGContext, inside path: CGPath, fillRule: CGPathFillRule, size: Int,
                             from offset: CGPoint, blur: Double, color: CGColor, alpha: Double) {
        let pushed = Raster.blurred(Raster.mask(path: path, size: size, fillRule: fillRule, offset: offset), radius: blur)
        ctx.saveGState()
        ctx.addPath(path)
        fillRule == .evenOdd ? ctx.clip(using: .evenOdd) : ctx.clip()
        Raster.clipped(ctx, to: Raster.inverted(pushed)) { inner in
            inner.setFillColor(color.copy(alpha: alpha)!)
            inner.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
        ctx.restoreGState()
    }

    /// A stroke that only shows on the inside of the outline, faded across the icon by `mask`.
    private static func edge(_ ctx: CGContext, path: CGPath, fillRule: CGPathFillRule, size: Int,
                             width: Double, color: CGColor, mask: CGImage) {
        ctx.saveGState()
        ctx.addPath(path)
        fillRule == .evenOdd ? ctx.clip(using: .evenOdd) : ctx.clip()
        Raster.clipped(ctx, to: mask) { inner in
            inner.addPath(path)
            inner.setStrokeColor(color)
            inner.setLineWidth(width * 2)   // half falls outside the clip, leaving `width` inside
            inner.strokePath()
        }
        ctx.restoreGState()
    }
}
