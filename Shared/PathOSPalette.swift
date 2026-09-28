import Foundation
import SwiftUI

/// The PathOS colour system. Shared with the widget extension so the Lock Screen and Dynamic Island match the app.
nonisolated enum PathOSPalette {
    static let void: UInt32 = 0x090B0D
    static let deepSurface: UInt32 = 0x101418
    static let elevatedSurface: UInt32 = 0x181E22
    static let ice: UInt32 = 0xE8F0ED
    static let mist: UInt32 = 0x8E9B98
    static let aurora: UInt32 = 0xB8F36B
    static let ion: UInt32 = 0x65E6D0
    static let amber: UInt32 = 0xFFBF69
    static let coral: UInt32 = 0xFF4438

    static func color(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// WCAG 2.x relative luminance of an sRGB hex colour.
    static func relativeLuminance(_ hex: UInt32) -> Double {
        func linear(_ channel: UInt32) -> Double {
            let value = Double(channel & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(hex >> 16) + 0.7152 * linear(hex >> 8) + 0.0722 * linear(hex)
    }

    /// A stretch of your route by how held up it is, 1 to 3: amber when it's slow, coral when it's
    /// stopped, and halfway between for the step between. Worth a glance to urgent, as those two
    /// mean everywhere else.
    static func traffic(level: Int) -> UInt32 {
        switch level {
        case ...1: amber
        case 2: blend(amber, coral, 0.5)
        default: coral
        }
    }

    /// A colour part of the way from one of the palette's to another: only for a scale that is a
    /// degree rather than a kind.
    static func blend(_ from: UInt32, _ to: UInt32, _ amount: Double) -> UInt32 {
        let towards = min(1, max(0, amount))
        func channel(_ shift: UInt32) -> UInt32 {
            let start = Double((from >> shift) & 0xFF)
            let end = Double((to >> shift) & 0xFF)
            return UInt32((start + (end - start) * towards).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }

    static func contrastRatio(_ first: UInt32, _ second: UInt32) -> Double {
        let (lighter, darker) = (max(relativeLuminance(first), relativeLuminance(second)), min(relativeLuminance(first), relativeLuminance(second)))
        return (lighter + 0.05) / (darker + 0.05)
    }
}

extension ShapeStyle where Self == Color {
    nonisolated static var void: Color { PathOSPalette.color(PathOSPalette.void) }
    nonisolated static var deepSurface: Color { PathOSPalette.color(PathOSPalette.deepSurface) }
    nonisolated static var elevatedSurface: Color { PathOSPalette.color(PathOSPalette.elevatedSurface) }
    nonisolated static var ice: Color { PathOSPalette.color(PathOSPalette.ice) }
    nonisolated static var mist: Color { PathOSPalette.color(PathOSPalette.mist) }
    nonisolated static var aurora: Color { PathOSPalette.color(PathOSPalette.aurora) }
    nonisolated static var ion: Color { PathOSPalette.color(PathOSPalette.ion) }
    nonisolated static var amber: Color { PathOSPalette.color(PathOSPalette.amber) }
    nonisolated static var coral: Color { PathOSPalette.color(PathOSPalette.coral) }
}

/// What a colour *means*. Components take a role, never a raw colour, so green always means you
/// and cyan always means the world.
nonisolated enum SignalRole: String, CaseIterable, Codable, Sendable {
    /// Things that originate from the user: location, route, arrow, saved memory, the active action.
    case you
    /// Things PathOS discovers: places, events, transit, weather, AI signals.
    case world
    /// Worth a glance, not dangerous.
    case attention
    /// Something is broken or urgent.
    case critical

    var hex: UInt32 {
        switch self {
        case .you: PathOSPalette.aurora
        case .world: PathOSPalette.ion
        case .attention: PathOSPalette.amber
        case .critical: PathOSPalette.coral
        }
    }

    var color: Color { PathOSPalette.color(hex) }

    /// The faint atmospheric field behind a signal.
    var wash: Color { color.opacity(0.08) }

    /// Spoken before a signal's name so VoiceOver users get the meaning colour carries.
    var spokenPrefix: String {
        switch self {
        case .you: "Yours"
        case .world: "Nearby"
        case .attention: "Heads up"
        case .critical: "Urgent"
        }
    }
}

extension PathOSActivityAttributes.Mode {
    nonisolated var role: SignalRole {
        switch self {
        case .compass, .commute, .spatialNote, .journey, .trip: .you
        case .exitCheck: .attention
        case .venue: .world
        }
    }
}
