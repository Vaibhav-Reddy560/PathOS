import SwiftUI

/// The glass mark from the app icon, at any height. Drawn from the launch screen's image, which
/// IconForge renders from the same pass as the icon.
struct PathOSMark: View {
    var height: CGFloat

    var body: some View {
        Image("LaunchMark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

/// The mark and the name together, sized to sit in a line of headline text, as the launch screen
/// shows them and the island rests on them.
struct PathOSWordmark: View {
    @ScaledMetric(relativeTo: .headline) private var markHeight: CGFloat = 20

    var body: some View {
        HStack(spacing: 8) {
            PathOSMark(height: markHeight)
            Text("PathOS")
                .font(.headline)
                .foregroundStyle(.ice)
        }
    }
}
