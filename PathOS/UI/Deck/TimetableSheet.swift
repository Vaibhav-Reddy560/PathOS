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
    /// Answered elective questions; watched so an answer takes its question away at once.
    @AppStorage(TimetableService.settledClashesKey) private var settledClashes = ""

    @State private var sourceText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var isReading = false
    @State private var draft: [TimetableEntry] = []
    @State private var editing: TimetableEntry?
    /// Elective groups you've answered in this import.
    @State private var settledElectives: Set<[String]> = []
    @State private var isConfirmingClashes = false

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
            .navigationTitle(draft.isEmpty ? "Weekly schedule" : "Check the sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(draft.isEmpty ? "Done" : "Discard") {
                        if draft.isEmpty { dismiss() } else { draft = [] }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if draft.isEmpty {
                        Button("Add session") { editing = TimetableEntry(subject: "", weekday: 2, startMinutes: 9 * 60, endMinutes: 10 * 60) }
                    } else {
                        Button("Save \(draft.count)") {
                            // Unanswered electives would all fill the week: ask before saving them.
                            if openElectives.isEmpty { saveDraft() } else { isConfirmingClashes = true }
                        }
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
            .confirmationDialog("Some sessions are at the same time", isPresented: $isConfirmingClashes, titleVisibility: .visible) {
                Button("Choose my electives first") {}
                Button("Save them all") { saveDraft() }
            } message: {
                Text(openElectives.map { ListFormatter.localizedString(byJoining: $0) }.joined(separator: "; ")
                     + ". If you take only one of each, choose it at the top, and the others won't fill your week or remind you.")
            }
            .sheet(item: $editing) { entry in
                SessionEditor(entry: entry) { edited, copies in
                    saveEdited(edited, copies: copies)
                } onDelete: {
                    if draft.contains(where: { $0.id == entry.id }) {
                        draft.removeAll { $0.id == entry.id }
                    } else {
                        state.timetable.delete(entry)
                    }
                }
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
                        Text("Paste your schedule, or pick a photo of it…")
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
            InstrumentLabel(saved.isEmpty ? "Import your weekly schedule" : "Replace your weekly schedule")
        } footer: {
            Text("Reading happens on your iPhone. Each session then shows in Day, at your Work place, with a reminder \(TimetableService.reminderMinutesBefore) minutes before each one.")
        }
    }

    @ViewBuilder
    private var savedSections: some View {
        // Electives saved as printed: asked here as well as in Day, until answered.
        ForEach(savedClashes, id: \.self) { group in
            Section {
                ElectiveQuestion(
                    group: group,
                    when: TimetableClashes.when(group, in: saved.map(TimetableService.slot)),
                    choose: { kept in
                        state.timetable.keep(kept, of: group)
                        state.showToast("\(kept) kept · the others are off your week")
                    },
                    keepAll: { state.timetable.keepAll(group) }
                )
                .padding(.vertical, 4)
            } header: {
                InstrumentLabel("Electives")
            }
        }
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

    /// What the reader saw as electives, and anything else in the draft taught at the same time:
    /// however the schedule was read, a slot with several subjects in it is asked about.
    private var openElectives: [[String]] {
        let read = state.timetable.electives.filter { group in
            group.allSatisfy { subject in draft.contains { $0.subject == subject } }
        }
        let clashing = TimetableClashes.groups(in: draft.map(TimetableService.slot))
        var groups: [[String]] = []
        for group in read + clashing where !groups.contains(where: { Set($0).isSuperset(of: group) }) {
            groups.removeAll { Set(group).isSuperset(of: $0) }
            groups.append(group)
        }
        return groups.filter { !settledElectives.contains($0) }
    }

    private var savedClashes: [[String]] {
        let settled = TimetableService.settledClashKeys(from: settledClashes)
        return TimetableClashes.groups(in: saved.map(TimetableService.slot))
            .filter { !settled.contains(TimetableClashes.key($0)) }
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
        state.showToast("Weekly schedule saved · \(draft.count) sessions")
        state.haptics.success()
        draft = []
        dismiss()
    }

    private func saveEdited(_ entry: TimetableEntry, copies: [TimetableEntry]) {
        if draft.contains(where: { $0.id == entry.id }) {
            // A draft class may have moved day or time; keep the list in order.
            draft += copies
            draft.sort { ($0.weekday, $0.startMinutes) < ($1.weekday, $1.startMinutes) }
            return
        }
        if entry.modelContext == nil {
            state.timetable.add(entry)
        } else {
            state.timetable.saveChanges()
        }
        for copy in copies {
            state.timetable.add(copy)
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
                Text(entry.subject.isEmpty ? "Untitled session" : entry.subject)
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

extension TimetableSheet {
    static let weekdayOrderForPicker = [2, 3, 4, 5, 6, 7, 1]
}
