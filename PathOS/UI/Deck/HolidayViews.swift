import SwiftUI

/// A holiday coming up that you haven't said about: is it a day off for you? Asked once, in the
/// month before it; the answer can be changed in Settings → Overview.
struct HolidayQuestion: View {
    let holiday: Holiday

    @Environment(AppState.self) private var state

    var body: some View {
        ContentTile {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sun.max.fill")
                        .font(.title3)
                        .foregroundStyle(.ion)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(holiday.name) · \(holiday.dayStart.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.ice)
                        Text("\(holiday.kind.label). A day off for you?")
                            .font(.footnote)
                            .foregroundStyle(.mist)
                    }
                }
                HStack(spacing: 8) {
                    Button {
                        answer(true)
                    } label: {
                        OneLineButtonLabel(title: "Day off", symbol: "checkmark")
                    }
                    .pathPrimaryAction()
                    Button {
                        answer(false)
                    } label: {
                        OneLineButtonLabel(title: "Not for me", symbol: "xmark")
                    }
                    .pathSecondaryAction()
                }
            }
        }
    }

    private func answer(_ isOff: Bool) {
        let name = holiday.name
        withAnimation(PathMotion.control) {
            state.holidays.answer(holiday, isOff: isOff)
        }
        state.showToast(isOff ? "\(name) is a day off · no sessions or reminders" : "\(name) is a day like any other",
                        symbol: isOff ? "sun.max.fill" : "checkmark.circle.fill")
    }
}

/// A holiday on the day you're looking at, and what you said about it.
struct HolidayLine: View {
    let holiday: Holiday

    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max.fill")
                .foregroundStyle(.ion)
            VStack(alignment: .leading, spacing: 1) {
                Text(holiday.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ice)
                Text([holiday.kind.label, verdict].joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.mist)
            }
            Spacer(minLength: 0)
            Menu {
                Button("A day off for me", systemImage: "sun.max") { state.holidays.answer(holiday, isOff: true) }
                Button("Not a day off for me", systemImage: "briefcase") { state.holidays.answer(holiday, isOff: false) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.mist)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Change whether \(holiday.name) is a day off")
        }
        .padding(.horizontal, 4)
    }

    private var verdict: String {
        switch holiday.isOff {
        case true?: "A day off for you"
        case false?: "Not a day off for you"
        case nil: "Not answered yet"
        }
    }
}

/// Something to remember about the day, written on it or ahead of it. Left for a day still to
/// come, it's brought up at half past eight that morning.
struct DayNoteField: View {
    let day: Date

    @Environment(AppState.self) private var state
    @State private var text = ""
    @State private var loadedFor: Date?
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "note.text")
                .foregroundStyle(text.isEmpty ? .mist : .aurora)
            TextField(Calendar.current.startOfDay(for: day) > Calendar.current.startOfDay(for: Date())
                      ? "Note for the day — it comes up that morning" : "Note for the day",
                      text: $text, axis: .vertical)
                .font(.subheadline)
                .foregroundStyle(.ice)
                .lineLimit(1...5)
                .focused($isEditing)
                .submitLabel(.done)
                .onSubmit { save() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.elevatedSurface.opacity(0.72), in: .rect(cornerRadius: 16, style: .continuous))
        .onAppear(perform: load)
        .onChange(of: day) { old, _ in
            save(for: old)
            load()
        }
        .onChange(of: isEditing) { _, editing in
            if !editing { save() }
        }
        .onDisappear { save() }
    }

    private func load() {
        text = state.note(on: day)
        loadedFor = day
    }

    private func save(for date: Date? = nil) {
        guard let target = date ?? loadedFor else { return }
        state.setNote(text, on: target)
    }
}
