#!/usr/bin/env swift
import AppKit

// Puts each screenshot inside an iPhone, for the README.
//
//   1. Drop full-resolution screenshots into docs/screens/raw/, named after the slot they fill:
//      now.png, day.png, radar.png, around.png, ways.png, driving.png, mail.png, vault.png
//   2. Run:  swift Tools/Screens/frame.swift
//   3. It writes docs/screens/<slot>.png, each screenshot inside the iPhone.
//
// Nothing is compressed. Each screenshot is drawn into the frame pixel for pixel, at the size it
// was captured at, and written as a lossless PNG; the README shows it smaller by width alone.
//
// A slot with no screenshot yet gets a placeholder in the same frame, so the README always looks
// finished and a picture can be added later without touching the Markdown.

let palette = (
    void: NSColor(srgbRed: 0.035, green: 0.043, blue: 0.051, alpha: 1),      // #090B0D
    deep: NSColor(srgbRed: 0.063, green: 0.078, blue: 0.094, alpha: 1),      // #101418
    ice: NSColor(srgbRed: 0.910, green: 0.941, blue: 0.929, alpha: 1),       // #E8F0ED
    mist: NSColor(srgbRed: 0.557, green: 0.608, blue: 0.596, alpha: 1),      // #8E9B98
    aurora: NSColor(srgbRed: 0.722, green: 0.953, blue: 0.420, alpha: 1),    // #B8F36B
    ion: NSColor(srgbRed: 0.396, green: 0.902, blue: 0.816, alpha: 1)        // #65E6D0
)

/// The screen, in points. Everything else is measured from it. The proportions are an iPhone
/// 16 Plus screenshot's (1290 x 2796), so a capture fills it with nothing cropped.
let screen = NSSize(width: 320, height: 320 * 2796 / 1290)
/// The black surround, and the metal rail around that.
let bezel: CGFloat = 9
let rail: CGFloat = 4
/// Clear space around the phone, which holds the shadow and keeps two of these apart on a page.
let margin: CGFloat = 34
/// What a phone screenshot is wide, when there's none to measure.
let defaultCaptureWidth: CGFloat = 1290
let slots = ["now", "day", "radar", "around", "ways", "driving", "mail", "vault"]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let rawFolder = root.appendingPathComponent("docs/screens/raw")
let outFolder = root.appendingPathComponent("docs/screens")
try? FileManager.default.createDirectory(at: rawFolder, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)

/// A rounded rectangle with Apple's continuous corners, not a circular arc: the difference is
/// most of what makes a drawn iPhone look drawn.
func squircle(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(cgPath: CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
}

/// A capture's size in pixels, not points: a PNG's resolution setting says what a point is, and
/// it's the pixels that decide how sharp it stays.
func pixelWidth(of url: URL) -> CGFloat? {
    guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else { return nil }
    return CGFloat(rep.pixelsWide)
}

/// Whether a capture already shows the camera island. iPhone draws it into a screenshot only
/// while it has something to show (the orange microphone dot, an activity), and otherwise leaves
/// the screen under it, which on a framed phone would read as a hole in the glass.
func showsIsland(_ shot: NSImage) -> Bool {
    guard let rep = shot.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
          let colour = rep.colorAt(x: rep.pixelsWide / 2, y: Int(Double(rep.pixelsHigh) * 0.032))?
              .usingColorSpace(.sRGB) else { return false }
    // The island is true black; nothing PathOS draws is.
    return colour.redComponent + colour.greenComponent + colour.blueComponent < 0.06
}

/// Every capture is drawn at the size the widest one was taken at, so the frames match and none
/// is scaled down: the screen area comes out exactly as many pixels wide as the screenshot.
let captureWidth: CGFloat = slots
    .compactMap { pixelWidth(of: rawFolder.appendingPathComponent("\($0).png")) }
    .max() ?? defaultCaptureWidth
let scale: CGFloat = captureWidth / screen.width

func frame(_ shot: NSImage?, slot: String) -> NSBitmapImageRep? {
    let bodySize = NSSize(width: screen.width + (bezel + rail) * 2, height: screen.height + (bezel + rail) * 2)
    let size = NSSize(width: bodySize.width + margin * 2, height: bodySize.height + margin * 2)
    let pixels = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    // Drawn straight into a bitmap of exactly that many pixels. An image drawn on screen is made
    // at the display's own density, which on a Retina Mac silently doubled or halved the result.
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    bitmap.size = pixels
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: scale, y: scale)

    let bodyRect = NSRect(x: margin, y: margin, width: bodySize.width, height: bodySize.height)
    let bodyRadius: CGFloat = 58
    let body = squircle(bodyRect, radius: bodyRadius)

    // The side buttons sit under the body, so only the part that stands proud of it shows.
    let buttonColour = NSColor(srgbRed: 0.35, green: 0.38, blue: 0.40, alpha: 1)
    buttonColour.setFill()
    for (y, height) in [(bodyRect.maxY - 214, CGFloat(64)), (bodyRect.maxY - 300, CGFloat(64))] {
        squircle(NSRect(x: bodyRect.minX - 2.5, y: y, width: 6, height: height), radius: 3).fill()
    }
    squircle(NSRect(x: bodyRect.minX - 2.5, y: bodyRect.maxY - 150, width: 6, height: 34), radius: 3).fill()
    squircle(NSRect(x: bodyRect.maxX - 3.5, y: bodyRect.maxY - 268, width: 6, height: 92), radius: 3).fill()

    // The rail: brushed metal, brightest where the light catches its edges.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    // A shadow is measured in pixels however the drawing is scaled, so it's scaled by hand.
    shadow.shadowBlurRadius = 26 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.set()
    NSColor.black.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    let metal = NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.42, green: 0.45, blue: 0.47, alpha: 1), 0.0),
        (NSColor(srgbRed: 0.24, green: 0.27, blue: 0.29, alpha: 1), 0.16),
        (NSColor(srgbRed: 0.52, green: 0.55, blue: 0.57, alpha: 1), 0.5),
        (NSColor(srgbRed: 0.22, green: 0.25, blue: 0.27, alpha: 1), 0.86),
        (NSColor(srgbRed: 0.40, green: 0.43, blue: 0.45, alpha: 1), 1.0))
    metal?.draw(in: body, angle: 0)

    // Inside the rail, the black the screen floats in.
    let bezelRect = bodyRect.insetBy(dx: rail, dy: rail)
    NSColor(srgbRed: 0.02, green: 0.02, blue: 0.025, alpha: 1).setFill()
    squircle(bezelRect, radius: bodyRadius - rail).fill()

    let screenRect = NSRect(x: bodyRect.minX + rail + bezel, y: bodyRect.minY + rail + bezel,
                            width: screen.width, height: screen.height)
    let screenPath = squircle(screenRect, radius: bodyRadius - rail - bezel)

    if let shot {
        NSGraphicsContext.saveGraphicsState()
        screenPath.addClip()
        // Filled to the screen, keeping the capture's proportions.
        let ratio = max(screenRect.width / shot.size.width, screenRect.height / shot.size.height)
        let drawn = NSSize(width: shot.size.width * ratio, height: shot.size.height * ratio)
        shot.draw(in: NSRect(x: screenRect.midX - drawn.width / 2,
                             y: screenRect.midY - drawn.height / 2,
                             width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
    } else {
        palette.void.setFill()
        screenPath.fill()

        // Waiting for a picture: said plainly, in the app's own colours.
        let dashed = squircle(screenRect.insetBy(dx: 26, dy: 26), radius: 26)
        dashed.setLineDash([9, 8], count: 2, phase: 0)
        dashed.lineWidth = 1.5
        palette.mist.withAlphaComponent(0.45).setStroke()
        dashed.stroke()

        let title = NSAttributedString(string: "Screenshot", attributes: [
            .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
            .foregroundColor: palette.ice.withAlphaComponent(0.85),
        ])
        let path = NSAttributedString(string: "docs/screens/raw/\(slot).png", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: palette.ion,
        ])
        title.draw(at: NSPoint(x: screenRect.midX - title.size().width / 2, y: screenRect.midY + 6))
        path.draw(at: NSPoint(x: screenRect.midX - path.size().width / 2, y: screenRect.midY - 22))

        palette.aurora.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: screenRect.midX - 4, y: screenRect.midY - 54, width: 8, height: 8)).fill()
    }

    // The island, unless the capture already has its own.
    if shot.map(showsIsland) != true {
        NSColor.black.setFill()
        squircle(NSRect(x: screenRect.midX - 47, y: screenRect.maxY - 36, width: 94, height: 27), radius: 13.5).fill()
    }

    // A sheen across the glass, the one thing that stops a drawn screen looking printed.
    NSGraphicsContext.saveGraphicsState()
    screenPath.addClip()
    let sheen = NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.10), 0.0),
        (NSColor.white.withAlphaComponent(0.03), 0.28),
        (NSColor.clear, 0.45))
    sheen?.draw(in: screenRect, angle: -62)
    NSGraphicsContext.restoreGraphicsState()

    // The hairline where the rail meets the glass.
    NSColor.white.withAlphaComponent(0.22).setStroke()
    let edge = squircle(bezelRect, radius: bodyRadius - rail)
    edge.lineWidth = 1
    edge.stroke()

    return bitmap
}

var framed = 0, placeholders = 0
for slot in slots {
    let source = rawFolder.appendingPathComponent("\(slot).png")
    let shot = FileManager.default.fileExists(atPath: source.path) ? NSImage(contentsOf: source) : nil
    guard let image = frame(shot, slot: slot),
          let data = image.representation(using: .png, properties: [:]) else { continue }
    try? data.write(to: outFolder.appendingPathComponent("\(slot).png"))
    shot == nil ? (placeholders += 1) : (framed += 1)
    print("\(slot): \(shot == nil ? "placeholder" : "framed")")
}
print("\(framed) framed, \(placeholders) waiting for a screenshot")
