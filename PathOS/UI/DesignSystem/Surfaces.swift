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
