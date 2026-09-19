import SwiftUI

/// Content sits on solid graphite; glass is reserved for the control layer floating over the map.
struct ContentTile<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.elevatedSurface.opacity(0.72), in: .rect(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Hairline.style, lineWidth: 1)
            }
    }
}

/// Section header inside the deck.
struct DeckSectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        // The trailing note is optional detail; drop it rather than wrap the title.
        ViewThatFits(in: .horizontal) {
            HStack {
                InstrumentLabel(title)
                    .fixedSize()
                Spacer()
                if let trailing {
                    InstrumentLabel(trailing)
                        .fixedSize()
                }
            }
            HStack {
                InstrumentLabel(title)
                Spacer()
            }
        }
        .padding(.horizontal, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 1 px separators and outlines. Stronger when the user turns on Increase Contrast.
nonisolated struct Hairline: ShapeStyle {
    static let style = Hairline()

    func resolve(in environment: EnvironmentValues) -> Color {
        Color.ice.opacity(environment.colorSchemeContrast == .increased ? 0.2 : 0.06)
    }
}

extension View {
    /// The one primary action on a screen: prominent glass tinted Aurora with Void text (15:1 contrast).
    func pathPrimaryAction() -> some View {
        buttonStyle(.glassProminent)
            .tint(.aurora)
            .foregroundStyle(Color.void)
    }

    /// Secondary actions: plain glass with Ice text.
    func pathSecondaryAction() -> some View {
        buttonStyle(.glass)
            .foregroundStyle(Color.ice)
    }
}

/// A start and end time stacked in a column: "11:15 AM" over "to 12:10 PM". The "to" says which
/// is which, and the column is wide enough, at any text size, that neither wraps.
struct TimeSpan: View {
    var start: String
    var end: String?
    var isDone = false

    @ScaledMetric(relativeTo: .subheadline) private var width: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(start)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(isDone ? .mist : .ice)
            if let end {
                Text("to \(end)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.mist)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(end.map { "\(start) to \($0)" } ?? start)
    }
}

/// An icon and a one-line title, filling its button. Built outside the main actor, as the photo
/// picker asks for its label there.
nonisolated struct OneLineButtonLabel: View {
    var title: String
    var symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(title)
                .lineLimit(1)
        }
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 36)
    }
}
