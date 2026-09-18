import CoreGraphics
import Foundation
import IconForgeCore

// The repo root, from this file's location, so the tool works from any working directory:
// <root>/Tools/IconForge/Sources/IconForge/main.swift
let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()    // IconForge
    .deletingLastPathComponent()    // Sources
    .deletingLastPathComponent()    // IconForge
    .deletingLastPathComponent()    // Tools
    .deletingLastPathComponent()    // root

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: "--\(name)"),
          index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

let svgURL = argument("svg").map { URL(fileURLWithPath: $0) }
    ?? root.appendingPathComponent("PathOS_Logo.svg")
let paletteURL = argument("palette").map { URL(fileURLWithPath: $0) }
    ?? root.appendingPathComponent("Shared/PathOSPalette.swift")
let outputURL = argument("out").map { URL(fileURLWithPath: $0) }
    ?? root.appendingPathComponent("PathOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let previewsURL = argument("previews").map { URL(fileURLWithPath: $0) }

var settings = IconRenderer.Settings()
if let size = argument("size").flatMap(Int.init) { settings.size = size }
if let scale = argument("logo-scale").flatMap(Double.init) { settings.logoScale = scale }
if let map = argument("map-intensity").flatMap(Double.init) { settings.mapIntensity = map }
if let lift = argument("ground-lift").flatMap(Double.init) { settings.groundLift = lift }
if let cool = argument("ground-cool").flatMap(Double.init) { settings.groundCool = cool }
if let shade = argument("mark-shade").flatMap(Double.init) { settings.markShade = shade }
if let bevel = argument("glass-bevel").flatMap(Double.init) { settings.glassBevel = bevel }
if let style = argument("route-style").flatMap(RouteStyle.init(rawValue:)) { settings.routeStyle = style }
if let seed = argument("seed").flatMap({ UInt64($0) }) { settings.seed = seed }

do {
    let logo = try SVGParser.parse(contentsOf: svgURL)
    let palette = try Palette(contentsOf: paletteURL)

    let bounds = logo.bounds
    print("logo    \(svgURL.lastPathComponent): \(logo.elementCount) element(s), "
          + "\(String(format: "%.0f x %.0f", bounds.width, bounds.height)), "
          + "\(logo.fillRule == .evenOdd ? "even-odd" : "nonzero") fill")

    // The mark's silhouette on its own, for measuring how well it separates from the ground.
    if let maskPath = argument("mask") {
        let placed = IconRenderer.place(logo, in: Double(settings.size), scale: settings.logoScale)
        let mask = Raster.mask(path: placed, size: settings.size, fillRule: logo.fillRule)
        try Raster.writePNG(mask, to: URL(fileURLWithPath: maskPath))
        print("mask    \(settings.size)px -> \(maskPath)")
    }

    let icon = IconRenderer.render(logo: logo, palette: palette, settings: settings)
    try Raster.writePNG(icon, to: outputURL)
    print("icon    \(settings.size)px -> \(outputURL.path)")

    // Home-screen sizes, so the mark can be checked where it actually gets looked at.
    if let previewsURL {
        for size in [180, 120, 87, 60, 40] {
            try Raster.writePNG(Raster.resized(icon, to: size),
                                to: previewsURL.appendingPathComponent("icon-\(size).png"))
        }
        print("preview 180/120/87/60/40 -> \(previewsURL.path)")
    }
} catch {
    FileHandle.standardError.write(Data("IconForge failed: \(error)\n".utf8))
    exit(1)
}
