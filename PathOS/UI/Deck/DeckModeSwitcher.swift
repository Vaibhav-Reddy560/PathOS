import SwiftUI

extension AppTab {
    var title: String {
        switch self {
        case .now: "Now"
        case .day: "Day"
        case .radar: "Radar"
        case .vault: "Vault"
        case .search: "Search"
        }
    }

    var symbol: String {
        switch self {
        case .now: "location.viewfinder"
        case .day: "calendar"
        case .radar: "dot.radiowaves.left.and.right"
        case .vault: "bookmark"
        case .search: "magnifyingglass"
        }
    }
}

/// Now · Radar · Vault. The selected pill is glass; the glass morphs between pills.
struct DeckModeSwitcher: View {
    @Binding var selection: AppTab

    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let modes: [AppTab] = [.now, .day, .radar, .vault, .search]

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(Self.modes, id: \.self) { mode in
                    let isSelected = selection == mode
                    Button {
                        withAnimation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion)) {
                            selection = mode
                        }
                    } label: {
                        // At accessibility sizes the titles would wrap letter by letter; icons carry
                        // the mode and VoiceOver still reads the title.
                        // Only the selected mode spells its name; four titles at once crowd the row.
                        Label(mode.title, systemImage: mode.symbol)
                            .labelStyle(isSelected && !dynamicTypeSize.isAccessibilitySize ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? .ice : .mist)
                            .padding(.horizontal, DeckLayout.switcherButtonPadding)
                            .frame(minHeight: 42)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(isSelected ? .regular.interactive() : .identity, in: .capsule)
                    .glassEffectID(mode, in: glass)
                    .accessibilityLabel(mode.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }
}

/// Lets the label style switch at runtime with Dynamic Type.
struct AnyLabelStyle: LabelStyle {
    private let render: (Configuration) -> AnyView

    init(_ style: some LabelStyle) {
        render = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        render(configuration)
    }
}
