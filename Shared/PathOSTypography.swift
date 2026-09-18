import SwiftUI

/// SF Pro through text styles only, so everything follows Dynamic Type.
/// No expanded widths, no uppercasing, no letter tracking: at caption sizes those read
/// as a different, cramped typeface.
extension Font {
    /// Guidance distance and other hero numbers.
    static let pathDisplay = Font.system(.largeTitle, weight: .semibold).monospacedDigit()
    /// Instrument readouts: temperature, ETA, pressure.
    static let pathMetric = Font.system(.title3, weight: .semibold).monospacedDigit()
    static let pathTitle = Font.system(.title2, weight: .semibold)
    /// Section headers, captions and secondary lines.
    static let pathInstrument = Font.system(.footnote, weight: .medium)
    /// The unit beside a number: °C, %, hPa, min.
    static let pathUnit = Font.system(.subheadline, weight: .semibold)
    /// The peek strip. Venue and readouts share one size so the line reads as a single
    /// instrument rather than a headline with numbers shouting over it.
    static let pathStrip = Font.system(.headline, weight: .semibold).monospacedDigit()
    /// The unit beside a strip readout.
    static let pathStripUnit = Font.system(.footnote, weight: .semibold)
}

/// Small caption used for section headers, units and map labels.
struct InstrumentLabel: View {
    let text: String
    var role: SignalRole?

    init(_ text: String, role: SignalRole? = nil) {
        self.text = text
        self.role = role
    }

    var body: some View {
        Text(text)
            .font(.pathInstrument)
            .minimumScaleFactor(0.85)
            .foregroundStyle(role?.color ?? .mist)
    }
}

/// A number and its unit sharing one baseline, e.g. `23 °C`. Concatenated `Text` rather than
/// two views, so the unit can never drift off the number's baseline.
struct MetricText: View {
    let value: String
    var unit: String?
    var role: SignalRole?
    var valueFont: Font = .pathMetric
    var unitFont: Font = .pathUnit

    var body: some View {
        Text(styled)
    }

    /// One string with two runs, so the unit sits on the number's baseline.
    private var styled: AttributedString {
        var number = AttributedString(value)
        number.font = valueFont
        number.foregroundColor = .ice
        guard let unit else { return number }

        // Percent and degree signs sit tight against the number; words like min and dB don't.
        let separator = unit.hasPrefix("%") || unit.hasPrefix("°") ? "" : " "
        var suffix = AttributedString(separator + unit)
        suffix.font = unitFont
        suffix.foregroundColor = role?.color ?? .mist
        number.append(suffix)
        return number
    }
}
