import SwiftUI

/// "IOT, ITSMF and KDD are all on Wed, Thu and Fri at 1:05 PM. Which do you take?"
///
/// Asked wherever your week shows, until it's answered: saved as printed, every elective in a slot
/// fills your day and reminds you of classes you don't go to.
struct ElectiveQuestion: View {
    let group: [String]
    let when: String
    let choose: (String) -> Void
    let keepAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SignalGlyph(symbol: "arrow.triangle.branch", role: .attention, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Which do you take?")
                        .font(.headline)
                        .foregroundStyle(.ice)
                    Text("\(ListFormatter.localizedString(byJoining: group)) are all on \(when). Pick yours and the others leave your week.")
                        .font(.subheadline)
                        .foregroundStyle(.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            FlowLayout(spacing: 8) {
                ForEach(group, id: \.self) { subject in
                    Button {
                        withAnimation(PathMotion.control) { choose(subject) }
                    } label: {
                        Text(subject)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 32)
                    }
                    .pathPrimaryAction()
                }
            }
            Button("I take them all") {
                withAnimation(PathMotion.control) { keepAll() }
            }
            .buttonStyle(.borderless)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.mist)
        }
    }
}
