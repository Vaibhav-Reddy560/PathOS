#!/usr/bin/env swift
import AppKit

// Puts each screenshot inside an iPhone, for the README.
//
//   1. Drop full-resolution screenshots into docs/screens/raw/, named after the slot they fill:
//      map.png, now.png, ways.png, driving.png, mail.png
//   2. Run:  swift Tools/Screens/frame.swift
//   3. It writes docs/screens/<slot>.png, framed and sized for the README.
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

/// The screen, in points. Everything else is measured from it.
let screen = NSSize(width: 320, height: 692)
let bezel: CGFloat = 11
let scale: CGFloat = 1.6
let slots = ["map", "now", "ways", "driving", "mail"]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let rawFolder = root.appendingPathComponent("docs/screens/raw")
let outFolder = root.appendingPathComponent("docs/screens")
try? FileManager.default.createDirectory(at: rawFolder, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)

func frame(_ shot: NSImage?, slot: String) -> NSImage {
    let size = NSSize(width: screen.width + bezel * 2, height: screen.height + bezel * 2)
    let image = NSImage(size: NSSize(width: size.width * scale, height: size.height * scale))
    image.lockFocus()
    guard let context = NSGraphicsContext.current else { image.unlockFocus(); return image }
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: scale, y: scale)

    // The body sits a shade above the screen it holds, so the phone reads as an object rather
    // than a black rectangle on a dark page.
    let body = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 52, yRadius: 52)
    NSColor(srgbRed: 0.106, green: 0.129, blue: 0.149, alpha: 1).setFill()
    body.fill()
    palette.mist.withAlphaComponent(0.5).setStroke()
    body.lineWidth = 2
    body.stroke()

    let screenRect = NSRect(x: bezel, y: bezel, width: screen.width, height: screen.height)
    let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 42, yRadius: 42)

    if let shot {
        NSGraphicsContext.saveGraphicsState()
        screenPath.addClip()
        // Filled to the screen, keeping the phone's proportions.
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
        let dashed = NSBezierPath(roundedRect: screenRect.insetBy(dx: 26, dy: 26), xRadius: 24, yRadius: 24)
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

        // A pulse of the route's green, so even an empty frame belongs to PathOS.
        palette.aurora.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: screenRect.midX - 4, y: screenRect.midY - 54, width: 8, height: 8)).fill()
    }

    // The island, drawn over whatever is behind it.
    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: size.width / 2 - 47, y: size.height - bezel - 30, width: 94, height: 27),
                 xRadius: 14, yRadius: 14).fill()

    image.unlockFocus()
    return image
}

var framed = 0, placeholders = 0
for slot in slots {
    let source = rawFolder.appendingPathComponent("\(slot).png")
    let shot = FileManager.default.fileExists(atPath: source.path) ? NSImage(contentsOf: source) : nil
    let image = frame(shot, slot: slot)
    guard let tiff = image.tiffRepresentation,
          let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
    try? data.write(to: outFolder.appendingPathComponent("\(slot).png"))
    shot == nil ? (placeholders += 1) : (framed += 1)
    print("\(slot): \(shot == nil ? "placeholder" : "framed")")
}
print("\(framed) framed, \(placeholders) waiting for a screenshot")
