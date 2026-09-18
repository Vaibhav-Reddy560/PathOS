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
            .sheet(item: $editing) { entry in
                ClassEditor(entry: entry) { saveEdited(entry) }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        isReading = true
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

            HStack(spacing: 10) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Photo", systemImage: "photo")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)

                Button {
                    sourceText = UIPasteboard.general.string ?? sourceText
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        isReading = true
                        draft = await state.timetable.readTimetable(from: sourceText)
                        isReading = false
                    }
                } label: {
                    Label(isReading ? "Reading…" : "Read it", systemImage: "apple.intelligence")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sourceText.trimmingCharacters(in: .whitespaces).isEmpty || isReading)
            }
            .labelStyle(.titleAndIcon)

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

    private var draftSections: some View {
        ForEach(Self.weekdayOrder, id: \.self) { weekday in
            let classes = draft.filter { $0.weekday == weekday }
            if !classes.isEmpty {
                Section {
                    ForEach(classes) { entry in
                        ClassRow(entry: entry)
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
        if entry.modelContext == nil, !draft.contains(where: { $0.id == entry.id }) {
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
        HStack(spacing: 12) {
            Text(TimetableRoutine.timeText(minutes: entry.startMinutes))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.ice)
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.subject.isEmpty ? "Untitled class" : entry.subject)
                    .font(.headline)
                    .foregroundStyle(.ice)
                    .lineLimit(1)
                Text([entry.room, entry.teacher].compactMap { $0 }.joined(separator: " · ")
                     + " · until \(TimetableRoutine.timeText(minutes: entry.endMinutes))")
                    .font(.footnote)
                    .foregroundStyle(.mist)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Add or fix one class.
private struct ClassEditor: View {
    @Bindable var entry: TimetableEntry
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var startTime = Date()
    @State private var endTime = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Subject", text: $entry.subject)
                    Picker("Day", selection: $entry.weekday) {
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
                    TextField("Room or block", text: Binding(get: { entry.room ?? "" }, set: { entry.room = $0.nilIfEmpty }))
                    TextField("Teacher", text: Binding(get: { entry.teacher ?? "" }, set: { entry.teacher = $0.nilIfEmpty }))
                } header: {
                    InstrumentLabel("Details")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle(entry.subject.isEmpty ? "New class" : entry.subject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        entry.startMinutes = minutes(from: startTime)
                        entry.endMinutes = max(minutes(from: endTime), minutes(from: startTime) + 5)
                        onSave()
                        dismiss()
                    }
                    .disabled(entry.subject.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task {
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
