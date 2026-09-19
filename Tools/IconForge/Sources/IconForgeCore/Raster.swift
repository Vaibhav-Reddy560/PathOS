import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Drawing surfaces and the effects built on top of them.
///
/// The blur is a hand-rolled triple box blur rather than Core Image: it runs on the CPU with no
/// GPU involved, so the same input always produces the same bytes. A Core Image blur can differ
/// between machines and between GPU and software renderers, which would make the icon unstable.
public enum Raster {

    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Surfaces

    public static func context(size: Int) -> CGContext {
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.interpolationQuality = .high
        ctx.setAllowsAntialiasing(true)
        return ctx
    }

    /// A DeviceGray surface, which is the only thing `CGContext.clip(to:mask:)` accepts.
    public static func grayContext(size: Int, white: Double = 0) -> CGContext {
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: white, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx
    }

    public static func image(_ ctx: CGContext) -> CGImage { ctx.makeImage()! }

    // MARK: Masks

    /// White where the path covers, black elsewhere. Every shape-derived effect starts here.
    public static func mask(size: Int, _ body: (CGContext) -> Void) -> CGImage {
        let ctx = grayContext(size: size)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        body(ctx)
        return image(ctx)
    }

    public static func mask(path: CGPath, size: Int, fillRule: CGPathFillRule = .winding,
                            offset: CGPoint = .zero) -> CGImage {
        mask(size: size) { ctx in
            ctx.translateBy(x: offset.x, y: offset.y)
            ctx.addPath(path)
            fillRule == .evenOdd ? ctx.fillPath(using: .evenOdd) : ctx.fillPath()
        }
    }

    /// A linear ramp, for fading an effect across the icon — a rim light that dies out halfway
    /// down, an edge highlight that only lives on the upper left.
    public static func linearMask(size: Int, from: CGPoint, to: CGPoint,
                                  stops: [(Double, Double)] = [(0, 1), (1, 0)]) -> CGImage {
        let ctx = grayContext(size: size)
        let colors = stops.map { CGColor(gray: $0.1, alpha: 1) } as CFArray
        let locations = stops.map { CGFloat($0.0) }
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: locations)!
        ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        return image(ctx)
    }

    public static func radialMask(size: Int, center: CGPoint, radius: Double,
                                  stops: [(Double, Double)] = [(0, 1), (1, 0)]) -> CGImage {
        let ctx = grayContext(size: size)
        let colors = stops.map { CGColor(gray: $0.1, alpha: 1) } as CFArray
        let locations = stops.map { CGFloat($0.0) }
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: locations)!
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                               endRadius: radius, options: [.drawsAfterEndLocation])
        return image(ctx)
    }

    /// Runs `body` with drawing confined to `mask` — white passes, black blocks.
    public static func clipped(_ ctx: CGContext, to mask: CGImage, _ body: (CGContext) -> Void) {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height), mask: mask)
        body(ctx)
        ctx.restoreGState()
    }

    /// Flips a mask, so "inside the shape" becomes "everywhere but the shape". Two clips in a row
    /// intersect, so an inverted mask is how an effect gets confined to a band just inside an edge.
    public static func inverted(_ gray: CGImage) -> CGImage {
        let size = gray.width
        let ctx = grayContext(size: size)
        ctx.draw(gray, in: CGRect(x: 0, y: 0, width: size, height: size))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(size * size) { data[i] = 255 - data[i] }
        return image(ctx)
    }

    /// Per-pixel arithmetic on two masks, for building a band out of two shapes.
    public static func combine(_ first: CGImage, _ second: CGImage,
                               _ operation: (UInt8, UInt8) -> UInt8) -> CGImage {
        let size = first.width
        let a = grayContext(size: size), b = grayContext(size: size)
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        a.draw(first, in: rect); b.draw(second, in: rect)
        let lhs = a.data!.assumingMemoryBound(to: UInt8.self)
        let rhs = b.data!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(size * size) { lhs[i] = operation(lhs[i], rhs[i]) }
        return image(a)
    }

    // MARK: Blur

    public static func blurred(_ source: CGImage, radius: Double) -> CGImage {
        guard radius >= 0.5 else { return source }
        let isGray = source.bitsPerPixel == 8
        return isGray ? blurredGray(source, radius: radius) : blurredColor(source, radius: radius)
    }

    private static func blurredGray(_ source: CGImage, radius: Double) -> CGImage {
        let size = source.width
        let ctx = grayContext(size: size)
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
        var buffer = [UInt8](repeating: 0, count: size * size)
        memcpy(&buffer, ctx.data!, size * size)
        blur(&buffer, width: size, height: size, channels: 1, radius: radius)
        let out = grayContext(size: size)
        memcpy(out.data!, buffer, size * size)
        return image(out)
    }

    private static func blurredColor(_ source: CGImage, radius: Double) -> CGImage {
        let size = source.width
        let ctx = context(size: size)
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
        let count = size * size * 4
        var buffer = [UInt8](repeating: 0, count: count)
        memcpy(&buffer, ctx.data!, count)
        blur(&buffer, width: size, height: size, channels: 4, radius: radius)
        let out = context(size: size)
        memcpy(out.data!, buffer, count)
        return image(out)
    }

    /// Three box passes approximate a Gaussian closely enough for artwork, and are exactly
    /// reproducible. Box widths follow the standard sigma-matching formula.
    static func blur(_ buffer: inout [UInt8], width: Int, height: Int, channels: Int, radius: Double) {
        let sigma = radius / 2
        guard sigma > 0.2 else { return }
        for boxRadius in boxRadii(sigma: sigma, passes: 3) where boxRadius > 0 {
            boxPass(&buffer, width: width, height: height, channels: channels, radius: boxRadius, horizontal: true)
            boxPass(&buffer, width: width, height: height, channels: channels, radius: boxRadius, horizontal: false)
        }
    }

    static func boxRadii(sigma: Double, passes: Int) -> [Int] {
        let ideal = ((12 * sigma * sigma / Double(passes)) + 1).squareRoot()
        var lower = Int(ideal.rounded(.down))
        if lower % 2 == 0 { lower -= 1 }
        let upper = lower + 2
        let idealCount = (12 * sigma * sigma - Double(passes * lower * lower)
                          - Double(4 * passes * lower) - Double(3 * passes)) / Double(-4 * lower - 4)
        let count = Int(idealCount.rounded())
        return (0..<passes).map { (($0 < count ? lower : upper) - 1) / 2 }
    }

    private static func boxPass(_ buffer: inout [UInt8], width: Int, height: Int, channels: Int,
                                radius: Int, horizontal: Bool) {
        let lineCount = horizontal ? height : width
        let lineLength = horizontal ? width : height
        let strideWithin = horizontal ? channels : width * channels
        let strideBetween = horizontal ? width * channels : channels
        let window = Double(radius * 2 + 1)

        buffer.withUnsafeMutableBufferPointer { raw in
            var scratch = [UInt8](repeating: 0, count: lineLength * channels)
            for line in 0..<lineCount {
                let base = line * strideBetween
                for channel in 0..<channels {
                    // Seed the running sum with the clamped edge, so edges don't darken.
                    var sum = Double(raw[base + channel]) * Double(radius + 1)
                    for i in 0...radius {
                        sum += Double(raw[base + min(i, lineLength - 1) * strideWithin + channel])
                    }
                    for i in 0..<lineLength {
                        let leaving = raw[base + max(0, i - radius - 1) * strideWithin + channel]
                        let entering = raw[base + min(lineLength - 1, i + radius) * strideWithin + channel]
                        scratch[i * channels + channel] = UInt8(max(0, min(255, (sum / window).rounded())))
                        sum += Double(entering) - Double(leaving)
                    }
                }
                for i in 0..<lineLength {
                    for channel in 0..<channels {
                        raw[base + i * strideWithin + channel] = scratch[i * channels + channel]
                    }
                }
            }
        }
    }

    // MARK: Output

    /// Drops the alpha channel. An iOS app icon must be fully opaque — the system supplies the
    /// rounded mask, and an icon that ships one of its own is rejected.
    public static func opaque(_ source: CGImage) -> CGImage {
        let size = source.width
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
        return image(ctx)
    }

    /// Opaque unless asked otherwise: the app icon must not carry alpha, but the launch icon has to.
    public static func writePNG(_ image: CGImage, to url: URL, keepingAlpha: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw RasterError.cannotWrite(url.path)
        }
        CGImageDestinationAddImage(destination, keepingAlpha ? image : opaque(image), nil)
        guard CGImageDestinationFinalize(destination) else { throw RasterError.cannotWrite(url.path) }
    }

    public static func resized(_ source: CGImage, to size: Int) -> CGImage {
        let ctx = context(size: size)
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
        return image(ctx)
    }

    /// For shapes that aren't square, like the mark on its own.
    public static func resized(_ source: CGImage, width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return image(ctx)
    }
}

public enum RasterError: Error, CustomStringConvertible {
    case cannotWrite(String)
    public var description: String {
        switch self { case .cannotWrite(let path): "Can't write the icon to \(path)." }
    }
}
