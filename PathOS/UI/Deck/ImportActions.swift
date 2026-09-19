import PhotosUI
import SwiftUI

/// The buttons under a paste box: where the text comes from, then reading it.
///
/// The two sources sit side by side and "Read it" spans the row below. Three buttons in one row
/// left each too narrow for its label, which wrapped mid-word ("Pho-to", "Past e").
struct ImportActions: View {
    /// "Photo" for a timetable, "Screenshot" for an event.
    var photoTitle: String
    @Binding var photoItem: PhotosPickerItem?
    var isReading: Bool
    var canRead: Bool
    var paste: () -> Void
    var read: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            // Stacked instead when the text is too large for the two to share a row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { sources }
                VStack(spacing: 10) { sources }
            }

            Button(action: read) {
                HStack(spacing: 8) {
                    if isReading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "apple.intelligence")
                    }
                    Text(isReading ? "Reading…" : "Read it")
                        .lineLimit(1)
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(ReadButtonStyle(isEnabled: isEnabled))
            .disabled(!isEnabled)
        }
        // Buttons in a list row share one tap unless each has its own style.
        .buttonBorderShape(.capsule)
    }

    private var isEnabled: Bool { canRead && !isReading }

    @ViewBuilder
    private var sources: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            OneLineButtonLabel(title: photoTitle, symbol: "photo")
        }
        .buttonStyle(SourceButtonStyle(isEnabled: !isReading))
        .disabled(isReading)

        Button(action: paste) {
            OneLineButtonLabel(title: "Paste", symbol: "doc.on.clipboard")
        }
        .buttonStyle(SourceButtonStyle(isEnabled: !isReading))
        .disabled(isReading)
    }
}

/// Void on Aurora while it can be tapped; muted while waiting for text, rather than the
/// near-black iOS fades a disabled prominent button to.
private struct ReadButtonStyle: ButtonStyle {
    var isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(isEnabled ? Color.void : Color.mist)
            .background(isEnabled ? Color.aurora : Color.mist.opacity(0.16), in: .capsule)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(.capsule)
    }
}

/// Photo and Paste: a soft Aurora tint, muted while a read is under way rather than the
/// near-black iOS fades a disabled tinted button to.
struct SourceButtonStyle: ButtonStyle {
    var isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(isEnabled ? Color.aurora : Color.mist)
            .background((isEnabled ? Color.aurora : Color.mist).opacity(0.16), in: .capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(.capsule)
    }
}
