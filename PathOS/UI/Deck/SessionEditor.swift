import SwiftUI

/// Add or fix a session of your weekly schedule.
///
/// Opened from a day, it can change just that day — the lab moved to the afternoon this week —
/// or every week from now on. Times are to the minute, the length is shown as you set them, and a
/// new session can be put on several weekdays at once.
struct SessionEditor: View {
    let entry: TimetableEntry
    /// The day it was opened from, for a change to that day alone. Nil from the weekly list.
    var occurrence: ClassSession? = nil
    /// The session as saved, and any copies made on other weekdays.
    let onSave: (TimetableEntry, [TimetableEntry]) -> Void
    var onDelete: (() -> Void)? = nil

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private enum Scope: Hashable {
        case thisDay
        case everyWeek
    }

    @State private var scope: Scope = .everyWeek
    // A copy, applied only on Save, so Cancel leaves it as it was.
    @State private var subject = ""
    @State private var weekday = 2
    @State private var room = ""
    @State private var teacher = ""
    @State private var notes = ""
    @State private var startTime = Date()
    @State private var endTime = Date()
    @State private var alsoOn: Set<Int> = []
    @State private var isConfirmingDelete = false

    private var isNew: Bool { entry.subject.isEmpty && entry.modelContext == nil }

    var body: some View {
        NavigationStack {
            Form {
                if let occurrence {
                    Section {
                        Picker("Change", selection: $scope) {
                            Text("Only \(occurrence.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))").tag(Scope.thisDay)
                            Text("Every \(TimetableSheet.weekdayName(entry.weekday))").tag(Scope.everyWeek)
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text(scope == .thisDay
                             ? "Just this day: the time or room it moved to. Every other week stays as it is."
                             : "From now on, every week.")
                    }
                }

                Section {
                    TextField("Name", text: $subject)
                        .disabled(scope == .thisDay)
                    if scope == .everyWeek {
                        Picker("Day", selection: $weekday) {
                            ForEach(TimetableSheet.weekdayOrderForPicker, id: \.self) { weekday in
                                Text(TimetableSheet.weekdayName(weekday)).tag(weekday)
                            }
                        }
                    }
                    DatePicker("Starts", selection: startBinding, displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: $endTime, displayedComponents: .hourAndMinute)
                    lengthRow
                } header: {
                    InstrumentLabel("Session")
                }

                Section {
                    TextField("Room or area", text: $room)
                    if scope == .everyWeek {
                        TextField("With (teacher, lead…)", text: $teacher)
                        TextField("Notes", text: $notes, axis: .vertical)
                            .lineLimit(2...5)
                    }
                } header: {
                    InstrumentLabel("Details")
                }

                if isNew {
                    alsoOnSection
                }

                if !isNew {
                    Section {
                        if let occurrence {
                            Button("Skip it on \(occurrence.start.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))", systemImage: "xmark.circle") {
                                state.timetable.cancelOnce(entryID: entry.id, on: occurrence.start)
                                state.showToast("Skipped · \(entry.subject)")
                                dismiss()
                            }
                        }
                        if onDelete != nil || entry.modelContext != nil {
                            Button("Delete from every week", systemImage: "trash", role: .destructive) {
                                isConfirmingDelete = true
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle(isNew ? "New session" : "Edit session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(subject.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete \(entry.subject) from every \(TimetableSheet.weekdayName(entry.weekday))?",
                                isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let onDelete {
                        onDelete()
                    } else {
                        state.timetable.delete(entry)
                    }
                    dismiss()
                }
            }
            .task { load() }
        }
    }

    /// How long it is, and the lengths sessions usually are, one tap each.
    private var lengthRow: some View {
        let minutes = length
        return VStack(alignment: .leading, spacing: 8) {
            Text(minutes > 0 ? "Lasts \(Self.lengthText(minutes))" : "Ends before it starts")
                .font(.footnote)
                .foregroundStyle(minutes > 0 ? Color.mist : Color.amber)
            FlowLayout(spacing: 8) {
                ForEach([50, 55, 60, 90, 110, 120, 180], id: \.self) { option in
                    Button(Self.lengthText(option)) {
                        endTime = startTime.addingTimeInterval(Double(option) * 60)
                    }
                    .buttonStyle(SourceButtonStyle(isEnabled: true))
                    .font(.footnote.weight(.semibold))
                    .accessibilityLabel("Make it \(Self.lengthText(option))")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var alsoOnSection: some View {
        Section {
            FlowLayout(spacing: 8) {
                ForEach(TimetableSheet.weekdayOrderForPicker.filter { $0 != weekday }, id: \.self) { day in
                    let isOn = alsoOn.contains(day)
                    Button {
                        if isOn { alsoOn.remove(day) } else { alsoOn.insert(day) }
                    } label: {
                        Text(Calendar.current.shortWeekdaySymbols[day - 1])
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isOn ? Color.void : .ice)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 34)
                            .background(isOn ? Color.aurora : Color.elevatedSurface, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        } header: {
            InstrumentLabel("Also on")
        } footer: {
            Text("The same session, at the same time, on each day picked.")
        }
    }

    /// The end follows the start, keeping the length, when you move the start.
    private var startBinding: Binding<Date> {
        Binding {
            startTime
        } set: { moved in
            endTime = endTime.addingTimeInterval(moved.timeIntervalSince(startTime))
            startTime = moved
        }
    }

    private var length: Int {
        minutes(from: endTime) - minutes(from: startTime)
    }

    static func lengthText(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        return hours == 0 ? "\(rest) min" : rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    // MARK: Actions

    private func load() {
        subject = entry.subject
        weekday = entry.weekday
        room = occurrence?.room ?? entry.room ?? ""
        teacher = entry.teacher ?? ""
        notes = entry.notes ?? ""
        if let occurrence {
            let calendar = Calendar.current
            startTime = date(fromMinutes: calendar.component(.hour, from: occurrence.start) * 60 + calendar.component(.minute, from: occurrence.start))
            endTime = date(fromMinutes: calendar.component(.hour, from: occurrence.end) * 60 + calendar.component(.minute, from: occurrence.end))
        } else {
            startTime = date(fromMinutes: entry.startMinutes)
            endTime = date(fromMinutes: entry.endMinutes)
        }
    }

    private func save() {
        let start = minutes(from: startTime)
        let end = max(minutes(from: endTime), start + 5)
        let trimmedRoom = room.trimmingCharacters(in: .whitespaces).nilIfEmpty

        if scope == .thisDay, let occurrence {
            state.timetable.moveOnce(entryID: entry.id, on: occurrence.start, startMinutes: start, endMinutes: end,
                                     room: trimmedRoom == entry.room ? nil : trimmedRoom)
            state.showToast("Changed for \(occurrence.start.formatted(.dateTime.weekday(.wide)))")
            dismiss()
            return
        }

        entry.subject = subject.trimmingCharacters(in: .whitespaces)
        entry.weekday = weekday
        entry.room = trimmedRoom
        entry.teacher = teacher.trimmingCharacters(in: .whitespaces).nilIfEmpty
        entry.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        entry.startMinutes = start
        entry.endMinutes = end
        let copies = alsoOn.sorted().map { day in
            let copy = TimetableEntry(subject: entry.subject, weekday: day, startMinutes: start, endMinutes: end,
                                      room: entry.room, teacher: entry.teacher)
            copy.notes = entry.notes
            return copy
        }
        onSave(entry, copies)
        dismiss()
    }

    private func minutes(from date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func date(fromMinutes minutes: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(minutes) * 60)
    }
}
