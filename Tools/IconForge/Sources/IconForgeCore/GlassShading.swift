import CoreGraphics
import Foundation

/// Lights the mark as a piece of glass rather than painting a gradient on it.
///
/// A gradient can only vary along one line, so it reads as a flat shape with a wash over it. Glass
/// reads as glass because of what happens at its *edges*: the surface curves away there, so it
/// catches a sharp highlight, throws light back at you from the rim, and bends whatever is behind
/// it. All three follow from knowing how far each pixel is from the outline, so that is what this
/// computes first — the shape's distance field — and everything else is derived from it.
///
/// None of it is specific to the current logo: replace the SVG and the bevel, the highlights and
/// the refraction re-form around whatever outline arrives.
public enum GlassShading {

    public struct Light {
        /// Pointing at the light, in image space: x right, y down, z out of the screen.
        public var direction: (x: Double, y: Double, z: Double) = (-0.46, -0.60, 0.66)
        /// How far in from the outline the surface rolls off. Small on purpose: a wide bevel
        /// spreads the curvature across the body and reads as a soft inflated shape, where glass
        /// is flat across its face and turns hard right at the edge.
        public var bevel: Double = 7
        /// How much the surface tilts within that rim.
        public var relief: Double = 3.2
        public var ambient: Double = 0.88
        public var diffuse: Double = 0.18
        public var specular: Double = 0.66
        public var shininess: Double = 36
        /// Light returned from the rim — the single strongest cue that something is glass.
        public var fresnel: Double = 0.62
        /// How far the rim bends what is behind it, in pixels.
        public var refraction: Double = 22
        /// A hard bright line hugging the outline itself, a couple of pixels wide. This is the
        /// cue that actually says "glass" — a cut edge catches light along its whole length.
        public var edgeLight: Double = 0.55
        public var edgeWidth: Double = 2.4
        /// How far apart the colour channels bend. Blue refracts hardest through real glass, and
        /// the faint colour fringe that leaves at the rim is a large part of why glass looks wet.
        public var dispersion: Double = 0.16

        public init() {}
    }

    /// The shaded glass, ready to be drawn over the mark's flat colour and clipped to its outline.
    ///
    /// - Parameters:
    ///   - mask: the mark's silhouette.
    ///   - backdrop: what sits behind the mark, for the rim to bend.
    ///   - body: the mark already filled with its colour ramp, which the lighting modulates
    ///     rather than replaces — the hue travel across the mark has to survive being lit.
    public static func render(mask: CGImage, backdrop: CGImage, body: CGImage,
                              size: Int, scale: Double, light: Light = Light()) -> CGImage {
        let n = size
        let alpha = gray(mask, size: n)
        let (back, _) = rgba(backdrop, size: n)
        let (front, _) = rgba(body, size: n)

        let bevel = light.bevel * scale
        let distance = DistanceField.inside(alpha, width: n, height: n)

        // A rounded lip: flat across the body, curving away over the last `bevel` pixels.
        var height = [Double](repeating: 0, count: n * n)
        for i in 0..<(n * n) {
            let d = min(distance[i] / bevel, 1)
            height[i] = (1 - (1 - d) * (1 - d)).squareRoot()
        }
        // The distance field steps whole pixels at a time, and taking its slope multiplies that
        // step into visible stairs down every highlight. Smooth the surface, not the shading.
        smooth(&height, width: n, height: n, radius: max(1, Int((1.6 * scale).rounded())))

        let length = (light.direction.x * light.direction.x + light.direction.y * light.direction.y
                      + light.direction.z * light.direction.z).squareRoot()
        let lx = light.direction.x / length, ly = light.direction.y / length, lz = light.direction.z / length

        var out = [UInt8](repeating: 0, count: n * n * 4)
        for y in 1..<(n - 1) {
            for x in 1..<(n - 1) {
                let i = y * n + x
                guard alpha[i] > 0.004 else { continue }

                // Surface normal from the slope of the lip. The height rise has to be scaled by
                // the run it happens over, or a lip spread across 34 pixels reads as a 1-degree
                // tilt — a flat shape with a wash on it, which is exactly what this replaces.
                let dx = (height[i + 1] - height[i - 1]) * 0.5 * light.relief * bevel
                let dy = (height[i + n] - height[i - n]) * 0.5 * light.relief * bevel
                let inverse = 1 / (dx * dx + dy * dy + 1).squareRoot()
                let nx = -dx * inverse, ny = -dy * inverse, nz = inverse

                let lambert = max(0, nx * lx + ny * ly + nz * lz)
                // Blinn-Phong with the viewer straight on, so the halfway vector is cheap.
                let hz = lz + 1
                let hLength = (lx * lx + ly * ly + hz * hz).squareRoot()
                let specular = pow(max(0, (nx * lx + ny * ly + nz * hz) / hLength), light.shininess) * light.specular
                // Grazing angles return the most light, which is what rims a glass edge. The
                // fourth power keeps it hugging the outline instead of washing over the body.
                let rim = pow(1 - nz, 4) * light.fresnel
                // The cut edge itself: a sharp line right at the outline, falling off within a
                // few pixels. Brightest where it faces the light but present the whole way round,
                // the way a real glass edge is.
                let fromEdge = distance[i] / (light.edgeWidth * scale)
                let facing = 0.55 + 0.45 * max(0, nx * lx + ny * ly)
                let edge = exp(-fromEdge * fromEdge) * light.edgeLight * facing

                // The rim bends what is behind it, and only there: the flat body shows it straight.
                let bend = light.refraction * scale * (1 - height[i])
                let bodyAlpha = Double(front[i * 4 + 3]) / 255
                let lit = light.ambient + light.diffuse * lambert

                var channels = [0.0, 0.0, 0.0]
                for c in 0..<3 {
                    // Each channel bends by a slightly different amount, so the rim carries a
                    // faint colour fringe rather than a grey smear.
                    let spread = 1 + light.dispersion * (Double(c) - 1)
                    let sx = min(n - 1, max(0, x + Int((nx * bend * spread).rounded())))
                    let sy = min(n - 1, max(0, y + Int((ny * bend * spread).rounded())))
                    let behind = Double(back[(sy * n + sx) * 4 + c]) / 255

                    // The body is premultiplied; undo that to get its actual colour.
                    let tint = bodyAlpha > 0.004 ? Double(front[i * 4 + c]) / 255 / bodyAlpha : 0
                    // Refraction and rim light screen on, so the glass only ever gains light —
                    // a dark ground must not be able to drag the mark down into it.
                    var value = lit * tint
                    value = value + (1 - value) * behind * (rim * 0.75 + 0.14)
                    value = value + (1 - value) * (specular + rim * 0.40)
                    // Added rather than screened: screening onto an already-bright body moves it
                    // almost nowhere, which is why the edge kept coming out soft instead of cut.
                    value += edge
                    channels[c] = min(1, max(0, value))
                }

                let a = alpha[i]
                out[i * 4] = UInt8(channels[0] * a * 255)
                out[i * 4 + 1] = UInt8(channels[1] * a * 255)
                out[i * 4 + 2] = UInt8(channels[2] * a * 255)
                out[i * 4 + 3] = UInt8(a * 255)
            }
        }

        let ctx = Raster.context(size: n)
        memcpy(ctx.data!, out, out.count)
        return Raster.image(ctx)
    }

    /// Separable box blur over the height field, three passes for a near-Gaussian falloff.
    static func smooth(_ values: inout [Double], width: Int, height: Int, radius: Int) {
        guard radius > 0 else { return }
        let window = Double(radius * 2 + 1)
        var scratch = [Double](repeating: 0, count: max(width, height))
        for _ in 0..<3 {
            for y in 0..<height {
                var sum = values[y * width] * Double(radius)
                for i in 0...radius { sum += values[y * width + min(i, width - 1)] }
                for x in 0..<width {
                    scratch[x] = sum / window
                    sum += values[y * width + min(width - 1, x + radius + 1)]
                        - values[y * width + max(0, x - radius)]
                }
                for x in 0..<width { values[y * width + x] = scratch[x] }
            }
            for x in 0..<width {
                var sum = values[x] * Double(radius)
                for i in 0...radius { sum += values[min(i, height - 1) * width + x] }
                for y in 0..<height {
                    scratch[y] = sum / window
                    sum += values[min(height - 1, y + radius + 1) * width + x]
                        - values[max(0, y - radius) * width + x]
                }
                for y in 0..<height { values[y * width + x] = scratch[y] }
            }
        }
    }

    // MARK: Buffers

    static func gray(_ image: CGImage, size: Int) -> [Double] {
        let ctx = Raster.grayContext(size: size)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<(size * size)).map { Double(data[$0]) / 255 }
    }

    static func rgba(_ image: CGImage, size: Int) -> ([UInt8], Int) {
        let ctx = Raster.context(size: size)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return ((0..<(size * size * 4)).map { data[$0] }, size)
    }
}

/// Exact Euclidean distance to the outline, by Felzenszwalb and Huttenlocher's method: the squared
/// distance transform is separable, so it runs one dimension at a time in linear time.
public enum DistanceField {

    public static func inside(_ alpha: [Double], width: Int, height: Int) -> [Double] {
        let infinity = Double(width * height) * 4
        // Seeds are everything outside the shape; distance grows inward from there.
        var squared = alpha.map { $0 > 0.5 ? infinity : 0.0 }

        var column = [Double](repeating: 0, count: max(width, height))
        for y in 0..<height {
            for x in 0..<width { column[x] = squared[y * width + x] }
            let transformed = transform(Array(column[0..<width]))
            for x in 0..<width { squared[y * width + x] = transformed[x] }
        }
        for x in 0..<width {
            for y in 0..<height { column[y] = squared[y * width + x] }
            let transformed = transform(Array(column[0..<height]))
            for y in 0..<height { squared[y * width + x] = transformed[y] }
        }
        return squared.map { $0.squareRoot() }
    }

    /// One-dimensional squared distance transform: the lower envelope of the parabolas rooted at
    /// each sample.
    static func transform(_ f: [Double]) -> [Double] {
        let n = f.count
        guard n > 0 else { return [] }
        var v = [Int](repeating: 0, count: n)          // which parabola is lowest where
        var z = [Double](repeating: 0, count: n + 1)   // where the lowest one changes
        var k = 0
        z[0] = -.infinity
        z[1] = .infinity

        for q in 1..<n {
            var s = intersection(f, q, v[k])
            while s <= z[k] {
                k -= 1
                s = intersection(f, q, v[k])
            }
            k += 1
            v[k] = q
            z[k] = s
            z[k + 1] = .infinity
        }

        var result = [Double](repeating: 0, count: n)
        k = 0
        for q in 0..<n {
            while z[k + 1] < Double(q) { k += 1 }
            let d = Double(q - v[k])
            result[q] = d * d + f[v[k]]
        }
        return result
    }

    private static func intersection(_ f: [Double], _ q: Int, _ p: Int) -> Double {
        let qd = Double(q), pd = Double(p)
        return ((f[q] + qd * qd) - (f[p] + pd * pd)) / (2 * qd - 2 * pd)
    }
}
