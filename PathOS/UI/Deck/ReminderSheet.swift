import PhotosUI
import SwiftUI

/// Add reminders, or change one.
///
/// One form for one or many: type a reminder, or paste a message or pick a photo of a list and
/// the on-device reader turns it into as many as it finds, each shown here to fix before saving.
/// A reminder is a thing and a day, and a time only if it needs one.
struct ReminderSheet: View {
    let request: ReminderSheetRequest

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var drafts: [Checklist.Draft] = []
    @State private var notes = ""
    @State private var origin: EventOrigin = .manual

    @State private var sourceText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var isReading = false
    @State private var readNote: String?

    private var editing: Reminder? {
        request.editing.flatMap(state.reminders.reminder(id:))
    }

    private var day: Date {
        Calendar.current.startOfDay(for: request.day ?? Date())
    }

    private var ready: [Checklist.Draft] {
        drafts.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                if editing == nil {
                    captureSection
                }
                ForEach($drafts) { $draft in
                    DraftSection(draft: $draft, isOnlyOne: drafts.count == 1) {
                        withAnimation(PathMotion.control) {
                            drafts.removeAll { $0.id == draft.id }
                        }
                    }
                }
                if let editing {
                    Section {
                        TextField("Notes", text: $notes, axis: .vertical)
                            .lineLimit(2...5)
                    }
                    Section {
                        Button("Delete reminder", systemImage: "trash", role: .destructive) {
                            state.reminders.delete(editing)
                            dismiss()
                        }
                    }
                } else {
                    Section {
                        Button {
                            withAnimation(PathMotion.control) {
                                drafts.append(Checklist.Draft(title: "", day: drafts.last?.day ?? day))
                            }
                        } label: {
                            Label("Another reminder", systemImage: "plus")
                                .foregroundStyle(.aurora)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle(editing == nil ? "New reminder" : "Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ready.count > 1 ? "Save \(ready.count)" : "Save", action: save)
                        .disabled(ready.isEmpty)
                }
            }
            .onAppear(perform: load)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        await read(image: image)
                    }
                    photoItem = nil
                }
            }
        }
    }

    // MARK: Sections

    private var captureSection: some View {
        Section {
            TextEditor(text: $sourceText)
                .frame(minHeight: 80)
                .foregroundStyle(.ice)
                .overlay(alignment: .topLeading) {
                    if sourceText.isEmpty {
                        Text("Paste a list, a message or notes…")
                            .font(.body)
                            .foregroundStyle(.mist)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }

            ImportActions(
                photoTitle: "Photo",
                photoItem: $photoItem,
                isReading: isReading,
                canRead: !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                sourceText = UIPasteboard.general.string ?? sourceText
            } read: {
                Task { await read(text: sourceText) }
            }

            if let readNote {
                Text(readNote)
                    .font(.footnote)
                    .foregroundStyle(.mist)
            }
        } header: {
            InstrumentLabel("Capture")
        } footer: {
            Text("Reading happens on your iPhone. Nothing is saved until you tap Save.")
        }
    }

    // MARK: Reading

    private func read(text: String) async {
        isReading = true
        defer { isReading = false }
        let read = await state.snap.readTasks(text: text, on: day)
        accept(read.drafts, usedAI: read.usedAI)
    }

    private func read(image: UIImage) async {
        isReading = true
        defer { isReading = false }
        guard let read = try? await state.snap.readTasks(image: image, on: day) else {
            readNote = "No readable text in that image."
            return
        }
        sourceText = read.text
        accept(read.drafts, usedAI: read.usedAI)
    }

    /// What was read takes the place of the empty form, and goes after anything already typed.
    private func accept(_ read: [Checklist.Draft], usedAI: Bool) {
        guard !read.isEmpty else {
            readNote = "Nothing to do found in that."
            return
        }
        withAnimation(PathMotion.control) {
            drafts = drafts.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty } + read
        }
        origin = .captured
        let timed = read.filter { $0.dueAt != nil }.count
        let count = read.count == 1 ? "1 thing to do" : "\(read.count) things to do"
        let times = timed == 0 ? "" : timed == read.count ? ", each with a time" : ", \(timed) with a time"
        readNote = "Found \(count)\(times)\(usedAI ? ", read by Apple Intelligence" : ""). Check them before saving."
    }

    // MARK: Loading and saving

    private func load() {
        guard drafts.isEmpty else { return }
        if let editing {
            drafts = [Checklist.Draft(title: editing.title, day: editing.day, dueAt: editing.dueAt, isDone: editing.isDone)]
            notes = editing.notes
            origin = editing.origin
        } else {
            drafts = [Checklist.Draft(title: "", day: day)]
        }
    }

    private func save() {
        if let editing, let draft = ready.first {
            let oldDay = editing.day
            editing.title = draft.title.trimmingCharacters(in: .whitespaces)
            editing.day = Calendar.current.startOfDay(for: draft.day)
            editing.dueAt = draft.dueAt
            editing.notes = notes
            state.reminders.save(editing, movedFrom: oldDay)
            state.showToast("Reminder updated")
        } else {
            let cleaned = ready.map { draft in
                var draft = draft
                draft.title = draft.title.trimmingCharacters(in: .whitespaces)
                return draft
            }
            state.reminders.add(cleaned, origin: origin)
            state.showToast(cleaned.count == 1 ? "Reminder added" : "\(cleaned.count) reminders added",
                            symbol: "checklist")
        }
        state.haptics.success()
        dismiss()
    }
}

/// One reminder in the form: what, which day, and a time only if it's switched on.
private struct DraftSection: View {
    @Binding var draft: Checklist.Draft
    let isOnlyOne: Bool
    let remove: () -> Void

    var body: some View {
        Section {
            TextField("What needs doing?", text: $draft.title)
            DatePicker("Day", selection: dayBinding, displayedComponents: .date)
            Toggle("At a time", isOn: hasTimeBinding)
                .tint(.aurora)
            if let dueAt = draft.dueAt {
                DatePicker("Time", selection: timeBinding(dueAt), displayedComponents: .hourAndMinute)
            }
            if !isOnlyOne {
                Button("Remove", systemImage: "minus.circle", role: .destructive, action: remove)
            }
        } footer: {
            if draft.dueAt == nil {
                Text("Without a time, it's on your list for the day and comes up with the others that morning.")
            }
        }
    }

    /// Changing the day keeps the time, on the new day.
    private var dayBinding: Binding<Date> {
        Binding {
            draft.day
        } set: { newDay in
            let start = Calendar.current.startOfDay(for: newDay)
            if let dueAt = draft.dueAt {
                draft.dueAt = start.addingTimeInterval(dueAt.timeIntervalSince(draft.day))
            }
            draft.day = start
        }
    }

    /// Switched on, the time starts at the next whole hour — or nine, on a day that isn't today.
    private var hasTimeBinding: Binding<Bool> {
        Binding {
            draft.dueAt != nil
        } set: { isOn in
            guard isOn else {
                draft.dueAt = nil
                return
            }
            let calendar = Calendar.current
            let now = Date()
            if calendar.isDate(draft.day, inSameDayAs: now) {
                let hour = min(23, calendar.component(.hour, from: now) + 1)
                draft.dueAt = draft.day.addingTimeInterval(Double(hour) * 3_600)
            } else {
                draft.dueAt = draft.day.addingTimeInterval(9 * 3_600)
            }
        }
    }

    private func timeBinding(_ current: Date) -> Binding<Date> {
        Binding {
            current
        } set: { picked in
            let calendar = Calendar.current
            let parts = calendar.dateComponents([.hour, .minute], from: picked)
            draft.dueAt = draft.day.addingTimeInterval(Double((parts.hour ?? 0) * 3_600 + (parts.minute ?? 0) * 60))
        }
    }
}
