// swift-tools-version: 6.0
import PackageDescription

// The app icon generator. Deliberately outside the app's `sources:` in project.yml, so it never
// compiles into PathOS — run it by hand when the logo or the palette changes.
let package = Package(
    name: "IconForge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "IconForge", dependencies: ["IconForgeCore"], path: "Sources/IconForge"),
        .target(name: "IconForgeCore", path: "Sources/IconForgeCore"),
        .testTarget(name: "IconForgeTests", dependencies: ["IconForgeCore"], path: "Tests/IconForgeTests"),
    ]
)
