import SwiftUI

/// The standard PathOS glass card: icon, title, secondary lines and an optional accessory.
struct SpatialCardView<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String?
    var detail: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.15), in: .rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
            accessory()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

extension SpatialCardView where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: String, subtitle: String? = nil, detail: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle, detail: detail) { EmptyView() }
    }
}

/// Glass section container used for grouped content.
struct GlassSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

struct StatusChip: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
    }
}

struct AmbientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.03, green: 0.06, blue: 0.14), Color(red: 0.04, green: 0.22, blue: 0.28)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
