import CoreLocation
import PhotosUI
import SwiftUI

/// Add or edit an event. New events can start from text you paste or a screenshot you pick:
/// the on-device model reads the time and place out of it, and you confirm before anything is saved.
struct EventSheet: View {
    let request: EventSheetRequest

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var notes = ""
    @State private var start = EventSheet.defaultStart()
    @State private var durationMinutes = 60
    @State private var isAllDay = false
    @State private var placeName = ""
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var tags: Set<String> = []
    @State private var customTag = ""
    @State private var reminderMinutes = 15
    @State private var origin: EventOrigin = .manual

    @State private var sourceText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var isReading = false
    @State private var readNote: String?
    @State private var isLocating = false

    static let presetTags = ["Class", "Work", "Friends", "Travel", "Food", "Health", "Errand"]
    static let reminderChoices = [0, 5, 15, 30, 60]

    private var editingEvent: PathEvent? {
        guard let id = request.editing else { return nil }
        return state.eventStore.all().first { $0.id == id }
    }

    private var mailSuggestion: MailSuggestion? {
        request.mailSuggestion.flatMap { state.mail.suggestion(id: $0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let suggestion = mailSuggestion {
                    mailSourceSection(suggestion)
                } else if editingEvent == nil {
                    captureSection
                }
                detailsSection
                whenSection
                whereSection
                tagsSection
                remindSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle(editingEvent == nil ? "New event" : "Edit event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task { load() }
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
                .frame(minHeight: 90)
                .foregroundStyle(.ice)
                .overlay(alignment: .topLeading) {
                    if sourceText.isEmpty {
                        Text("Paste a message, invite or poster text…")
                            .font(.body)
                            .foregroundStyle(.mist)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }

            ImportActions(
                photoTitle: "Screenshot",
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

    private func mailSourceSection(_ suggestion: MailSuggestion) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.subject.isEmpty ? "(No subject)" : suggestion.subject)
                        .foregroundStyle(.ice)
                        .lineLimit(2)
                    Text(suggestion.senderName)
                        .font(.footnote)
                        .foregroundStyle(.mist)
                }
            } icon: {
                Image(systemName: "envelope")
                    .foregroundStyle(.ion)
            }
        } header: {
            InstrumentLabel("From your mail")
        } footer: {
            Text(suggestion.usedAI
                 ? "Read by Apple Intelligence on your iPhone. Check the details below."
                 : "Read with on-device rules. Check the details below.")
        }
    }

    private var detailsSection: some View {
        Section {
            TextField("What is it?", text: $title)
            TextField("Notes", text: $notes, axis: .vertical)
                .lineLimit(2...5)
        } header: {
            InstrumentLabel("Event")
        }
    }

    private var whenSection: some View {
        Section {
            Toggle("All day", isOn: $isAllDay)
            DatePicker("Starts", selection: $start, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
            if !isAllDay {
                Picker("Lasts", selection: $durationMinutes) {
                    Text("30 min").tag(30)
                    Text("1 hour").tag(60)
                    Text("90 min").tag(90)
                    Text("2 hours").tag(120)
                    Text("3 hours").tag(180)
                    Text("All evening").tag(300)
                }
            }
        } header: {
            InstrumentLabel("When")
        }
    }

    private var whereSection: some View {
        Section {
            TextField("Place", text: $placeName)
            // Side by side while both labels fit on one line; stacked at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { placeButtons }
                VStack(spacing: 10) { placeButtons }
            }

            if coordinate != nil {
                Label("Pinned on the map", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.aurora)
            }
        } header: {
            InstrumentLabel("Where")
        } footer: {
            Text("With a place pinned, PathOS can point you there and show the event on the map.")
        }
    }

    @ViewBuilder
    private var placeButtons: some View {
        Button {
            Task { await useCurrentLocation() }
        } label: {
            OneLineButtonLabel(title: "I'm here", symbol: "location.fill")
        }
        .buttonStyle(SourceButtonStyle(isEnabled: true))

        Button {
            Task { await findOnMap() }
        } label: {
            OneLineButtonLabel(title: isLocating ? "Finding…" : "Find on map", symbol: "map")
        }
        .buttonStyle(SourceButtonStyle(isEnabled: !placeName.trimmingCharacters(in: .whitespaces).isEmpty && !isLocating))
        .disabled(placeName.trimmingCharacters(in: .whitespaces).isEmpty || isLocating)
    }

    private var tagsSection: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Self.presetTags, id: \.self) { tag in
                        let isOn = tags.contains(tag)
                        Button {
                            if isOn { tags.remove(tag) } else { tags.insert(tag) }
                        } label: {
                            Text(tag)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(isOn ? Color.void : .ice)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 34)
                                .background(isOn ? Color.ion : Color.elevatedSurface, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)

            HStack {
                TextField("Your own tag", text: $customTag)
                Button("Add") {
                    let tag = customTag.trimmingCharacters(in: .whitespaces)
                    guard !tag.isEmpty else { return }
                    tags.insert(tag)
                    customTag = ""
                }
                .disabled(customTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !tags.isEmpty {
                Text(tags.sorted().joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.ion)
            }
        } header: {
            InstrumentLabel("Tags")
        }
    }

    private var remindSection: some View {
        Section {
            Picker("Remind me", selection: $reminderMinutes) {
                ForEach(Self.reminderChoices, id: \.self) { minutes in
                    Text(minutes == 0 ? "At the time" : "\(minutes) min before").tag(minutes)
                }
            }
            if let error = state.eventStore.lastCalendarError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.amber)
            }
        } header: {
            InstrumentLabel("Reminder")
        } footer: {
            Text("PathOS keeps the full record and also writes the event to your Apple Calendar.")
        }
    }

    // MARK: Actions

    private func load() {
        if let event = editingEvent {
            title = event.title
            notes = event.notes
            start = event.start
            durationMinutes = max(15, Int(event.end.timeIntervalSince(event.start) / 60))
            isAllDay = event.isAllDay
            placeName = event.placeName ?? ""
            coordinate = event.coordinate
            tags = Set(event.tags)
            reminderMinutes = event.reminderMinutesBefore
            origin = event.origin
        } else if let suggestion = mailSuggestion {
            load(suggestion)
        } else if let text = request.text, !text.isEmpty {
            sourceText = text
        }
    }

    private func load(_ suggestion: MailSuggestion) {
        title = suggestion.title
        notes = MailService.notes(for: suggestion)
        if let date = suggestion.start {
            start = date
        }
        isAllDay = suggestion.isAllDay
        if let end = suggestion.endsAt, let date = suggestion.start {
            // The picker only offers set lengths; an unmatched value would leave it blank.
            let minutes = Int(end.timeIntervalSince(date) / 60)
            durationMinutes = [30, 60, 90, 120, 180, 300].min { abs($0 - minutes) < abs($1 - minutes) } ?? 60
        }
        placeName = suggestion.placeName ?? ""
        if suggestion.kind == .task {
            tags = ["Task"]
            reminderMinutes = 60
        }
        origin = .mail
        if let place = suggestion.placeName, !MailTriage.isOnline(place) {
            Task { await findOnMap() }
        }
    }

    private func read(text: String) async {
        isReading = true
        defer { isReading = false }
        apply(draft: await state.snap.analyze(text: text))
    }

    private func read(image: UIImage) async {
        isReading = true
        defer { isReading = false }
        guard let draft = try? await state.snap.analyze(image: image) else {
            readNote = "No readable text in that image."
            return
        }
        sourceText = draft.rawText
        apply(draft: draft)
    }

    private func apply(draft: ScanDraft) {
        if !draft.title.isEmpty { title = draft.title }
        if notes.isEmpty { notes = draft.summary }
        if let date = draft.eventStart { start = date }
        if let venue = draft.venue, !venue.isEmpty { placeName = venue }
        origin = .captured
        readNote = draft.usedAI
            ? "Read by Apple Intelligence on your iPhone. Check the details below."
            : "Read with on-device rules. Check the details below."
        if !placeName.isEmpty {
            Task { await findOnMap() }
        }
    }

    private func useCurrentLocation() async {
        guard let here = await state.location.currentLocation() else {
            readNote = "Couldn't get your location."
            return
        }
        coordinate = here.coordinate
        if placeName.isEmpty {
            placeName = state.context.venue.name ?? "Here"
        }
    }

    /// Looks the typed place up in Apple Maps so the event gets real coordinates.
    private func findOnMap() async {
        isLocating = true
        defer { isLocating = false }
        guard let here = await state.location.currentLocation() else { return }
        let matches = (try? await state.places.search(placeName, near: here, radius: 20_000)) ?? []
        guard let best = matches.first else {
            readNote = "Couldn't find “\(placeName)” on the map. The event still saves without a pin."
            return
        }
        coordinate = best.coordinate
        placeName = best.name
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let end = isAllDay ? Calendar.current.startOfDay(for: start).addingTimeInterval(86_399) : start.addingTimeInterval(Double(durationMinutes) * 60)

        let event = editingEvent ?? PathEvent(title: trimmed, start: start)
        event.title = trimmed
        event.notes = notes
        event.start = start
        event.endsAt = end
        event.isAllDay = isAllDay
        event.placeName = placeName.isEmpty ? nil : placeName
        event.latitude = coordinate?.latitude
        event.longitude = coordinate?.longitude
        event.tags = tags.sorted()
        event.reminderMinutesBefore = reminderMinutes
        event.origin = origin

        state.eventStore.save(event)
        if let id = request.mailSuggestion {
            state.mail.markAdded(id: id, eventID: event.id)
        }
        state.haptics.success()
        state.showToast(editingEvent == nil ? "Event saved" : "Event updated")
        dismiss()
    }

    /// The next half hour, so a new event doesn't start in the past.
    static func defaultStart(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let minutes = calendar.component(.minute, from: now)
        let rounded = calendar.date(bySetting: .minute, value: minutes < 30 ? 30 : 0, of: now) ?? now
        return rounded > now ? rounded : rounded.addingTimeInterval(3_600)
    }
}
