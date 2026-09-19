import PhotosUI
import SwiftData
import SwiftUI

/// Import a timetable once — a photo of it or pasted text — then it runs every week.
/// You confirm what the model read before anything is saved, and you can edit any class after.
struct TimetableSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\TimetableEntry.weekday), SortDescriptor(\TimetableEntry.startMinutes)])
    private var saved: [TimetableEntry]

    @State private var sourceText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var isReading = false
    @State private var draft: [TimetableEntry] = []
    @State private var editing: TimetableEntry?
    /// Elective groups you've answered in this import.
    @State private var settledElectives: Set<[String]> = []

    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        NavigationStack {
            Form {
                if draft.isEmpty {
                    importSection
                    if !saved.isEmpty {
                        savedSections
                    }
                } else {
                    electiveSections
                    draftSections
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle(draft.isEmpty ? "Timetable" : "Check the classes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(draft.isEmpty ? "Done" : "Discard") {
                        if draft.isEmpty { dismiss() } else { draft = [] }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if draft.isEmpty {
                        Button("Add class") { editing = TimetableEntry(subject: "", weekday: 2, startMinutes: 9 * 60, endMinutes: 10 * 60) }
                    } else {
                        Button("Save \(draft.count)") { saveDraft() }
                    }
                }
            }
            #if DEBUG
            .task {
                // `-PathOSTimetableImage /path/to/photo.jpg` imports a photo without the picker.
                guard let path = UserDefaults.standard.string(forKey: "PathOSTimetableImage"),
                      let image = UIImage(contentsOfFile: path) else { return }
                isReading = true
                settledElectives = []
                draft = await state.timetable.readTimetable(from: image)
                isReading = false
                // `-PathOSTimetableAutoSave YES` saves it too, for screenshots of Day.
                if UserDefaults.standard.bool(forKey: "PathOSTimetableAutoSave"), !draft.isEmpty {
                    saveDraft()
                }
            }
            #endif
            .sheet(item: $editing) { entry in
                ClassEditor(entry: entry) { saveEdited(entry) }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        isReading = true
                        settledElectives = []
                        draft = await state.timetable.readTimetable(from: image)
                        isReading = false
                    }
                    photoItem = nil
                }
            }
        }
    }

    // MARK: Sections

    private var importSection: some View {
        Section {
            TextEditor(text: $sourceText)
                .frame(minHeight: 90)
                .foregroundStyle(.ice)
                .overlay(alignment: .topLeading) {
                    if sourceText.isEmpty {
                        Text("Paste your timetable, or pick a photo of it…")
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
                Task {
                    isReading = true
                    settledElectives = []
                    draft = await state.timetable.readTimetable(from: sourceText)
                    isReading = false
                }
            }

            if let summary = state.timetable.lastImportSummary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.mist)
            }
        } header: {
            InstrumentLabel(saved.isEmpty ? "Import your timetable" : "Replace your timetable")
        } footer: {
            Text("Reading happens on your iPhone. Your classes then show in Day, with a reminder \(TimetableService.reminderMinutesBefore) minutes before each one.")
        }
    }

    private var savedSections: some View {
        ForEach(Self.weekdayOrder, id: \.self) { weekday in
            let classes = saved.filter { $0.weekday == weekday }
            if !classes.isEmpty {
                Section {
                    ForEach(classes) { entry in
                        Button {
                            editing = entry
                        } label: {
                            ClassRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            state.timetable.delete(classes[index])
                        }
                    }
                } header: {
                    InstrumentLabel(Self.weekdayName(weekday))
                }
            }
        }
    }

    /// Electives taught in the same slot: you take one, so the others shouldn't fill your week.
    private var electiveSections: some View {
        ForEach(openElectives, id: \.self) { group in
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(ListFormatter.localizedString(byJoining: group)) are taught at the same time. Which do you take?")
                        .font(.subheadline)
                        .foregroundStyle(.ice)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { electiveButtons(group) }
                        VStack(alignment: .leading, spacing: 8) { electiveButtons(group) }
                    }
                    Button("Keep them all") {
                        settledElectives.insert(group)
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.mist)
                }
                .padding(.vertical, 4)
            } header: {
                InstrumentLabel("Electives")
            }
        }
    }

    @ViewBuilder
    private func electiveButtons(_ group: [String]) -> some View {
        ForEach(group, id: \.self) { subject in
            Button(subject) {
                withAnimation(PathMotion.control) {
                    draft.removeAll { group.contains($0.subject) && $0.subject != subject }
                    settledElectives.insert(group)
                }
            }
            .buttonStyle(.bordered)
            .font(.subheadline.weight(.semibold))
        }
    }

    private var openElectives: [[String]] {
        state.timetable.electives.filter { group in
            !settledElectives.contains(group) && group.allSatisfy { subject in draft.contains { $0.subject == subject } }
        }
    }

    private var draftSections: some View {
        ForEach(Self.weekdayOrder, id: \.self) { weekday in
            let classes = draft.filter { $0.weekday == weekday }
            if !classes.isEmpty {
                Section {
                    // Anything read wrong can be put right before saving: tap a class to edit it.
                    ForEach(classes) { entry in
                        Button {
                            editing = entry
                        } label: {
                            ClassRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { classes[$0].id }
                        draft.removeAll { ids.contains($0.id) }
                    }
                } header: {
                    InstrumentLabel(Self.weekdayName(weekday))
                }
            }
        }
    }

    // MARK: Actions

    private func saveDraft() {
        state.timetable.replaceAll(with: draft)
        state.showToast("Timetable saved · \(draft.count) classes")
        state.haptics.success()
        draft = []
        dismiss()
    }

    private func saveEdited(_ entry: TimetableEntry) {
        if draft.contains(where: { $0.id == entry.id }) {
            // A draft class may have moved day or time; keep the list in order.
            draft.sort { ($0.weekday, $0.startMinutes) < ($1.weekday, $1.startMinutes) }
        } else if entry.modelContext == nil {
            state.timetable.add(entry)
        } else {
            state.timetable.refreshReminders()
        }
    }

    static func weekdayName(_ weekday: Int) -> String {
        Calendar.current.weekdaySymbols[max(0, min(6, weekday - 1))]
    }
}

private struct ClassRow: View {
    let entry: TimetableEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Start above end, as in Day, so a long room or teacher never pushes the time off.
            TimeSpan(start: TimetableRoutine.timeText(minutes: entry.startMinutes),
                     end: TimetableRoutine.timeText(minutes: entry.endMinutes))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.subject.isEmpty ? "Untitled class" : entry.subject)
                    .font(.headline)
                    .foregroundStyle(.ice)
                    .lineLimit(1)
                let details = [entry.room, entry.teacher].compactMap { $0 }.joined(separator: " · ")
                if !details.isEmpty {
                    Text(details)
                        .font(.footnote)
                        .foregroundStyle(.mist)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Add or fix one class.
private struct ClassEditor: View {
    let entry: TimetableEntry
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    // A copy of the class, applied only on Save, so Cancel leaves it as it was.
    @State private var subject = ""
    @State private var weekday = 2
    @State private var room = ""
    @State private var teacher = ""
    @State private var startTime = Date()
    @State private var endTime = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Subject", text: $subject)
                    Picker("Day", selection: $weekday) {
                        ForEach(TimetableSheet.weekdayOrderForPicker, id: \.self) { weekday in
                            Text(TimetableSheet.weekdayName(weekday)).tag(weekday)
                        }
                    }
                    DatePicker("Starts", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: $endTime, displayedComponents: .hourAndMinute)
                } header: {
                    InstrumentLabel("Class")
                }

                Section {
                    TextField("Room or block", text: $room)
                    TextField("Teacher", text: $teacher)
                } header: {
                    InstrumentLabel("Details")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle(entry.subject.isEmpty ? "New class" : "Edit class")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        entry.subject = subject.trimmingCharacters(in: .whitespaces)
                        entry.weekday = weekday
                        entry.room = room.trimmingCharacters(in: .whitespaces).nilIfEmpty
                        entry.teacher = teacher.trimmingCharacters(in: .whitespaces).nilIfEmpty
                        entry.startMinutes = minutes(from: startTime)
                        entry.endMinutes = max(minutes(from: endTime), minutes(from: startTime) + 5)
                        onSave()
                        dismiss()
                    }
                    .disabled(subject.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task {
                subject = entry.subject
                weekday = entry.weekday
                room = entry.room ?? ""
                teacher = entry.teacher ?? ""
                startTime = date(fromMinutes: entry.startMinutes)
                endTime = date(fromMinutes: entry.endMinutes)
            }
        }
    }

    private func minutes(from date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func date(fromMinutes minutes: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(minutes) * 60)
    }
}

extension TimetableSheet {
    static let weekdayOrderForPicker = [2, 3, 4, 5, 6, 7, 1]
}
