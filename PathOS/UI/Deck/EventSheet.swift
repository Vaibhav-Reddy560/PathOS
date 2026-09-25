import CoreLocation
import PhotosUI
import SwiftUI

/// Add or edit an event, or several at once. New events can start from text you paste or a
/// screenshot you pick: the on-device reader takes the times and places out of it, and you
/// confirm before anything is saved.
///
/// Several at once is for a programme: a festival over three days, a conference agenda, a fest.
/// The same capture reads every session in it, or one event can be repeated across a run of days.
struct EventSheet: View {
    let request: EventSheetRequest

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private enum Entry: String, CaseIterable, Identifiable {
        case one
        case several

        var id: String { rawValue }
        var title: String { self == .one ? "One event" : "Several" }
    }

    @State private var entry: Entry = .one

    @State private var title = ""
    @State private var notes = ""
    @State private var start = EventSheet.defaultStart()
    @State private var end = EventSheet.defaultStart().addingTimeInterval(3_600)
    @State private var isAllDay = false
    /// Opened from a day, the date is already known; this reveals the picker to change it.
    @State private var isChangingDay = false
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
    @State private var isSearchingPlace = false
    @State private var isLocating = false

    // Several at once.
    @State private var batch: [EventListReader.Item] = []
    @State private var editingItem: EventListReader.Item?
    @State private var repeatTitle = ""
    @State private var repeatFrom = Calendar.current.startOfDay(for: Date())
    @State private var repeatTo = Calendar.current.startOfDay(for: Date()).addingTimeInterval(2 * 86_400)
    @State private var repeatStart = EventSheet.defaultStart()
    @State private var repeatEnd = EventSheet.defaultStart().addingTimeInterval(3_600)
    @State private var isSaving = false

    static let presetTags = ["Class", "Work", "Friends", "Travel", "Food", "Health", "Errand"]
    static let reminderChoices = [0, 5, 15, 30, 60]

    private var editingEvent: PathEvent? {
        guard let id = request.editing else { return nil }
        return state.eventStore.all().first { $0.id == id }
    }

    private var mailSuggestion: MailSuggestion? {
        request.mailSuggestion.flatMap { state.mail.suggestion(id: $0) }
    }

    /// Several at once is for adding, from nothing or from a message; an edit is one event.
    private var offersSeveral: Bool {
        editingEvent == nil && mailSuggestion == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if offersSeveral {
                    Section {
                        Picker("Add", selection: $entry) {
                            ForEach(Entry.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }

                if let suggestion = mailSuggestion {
                    mailSourceSection(suggestion)
                } else if editingEvent == nil {
                    captureSection
                }

                if entry == .one {
                    detailsSection
                    whenSection
                    whereSection
                    tagsSection
                } else {
                    batchSection
                    repeatSection
                    whereSection
                }
                remindSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if entry == .one {
                        Button("Save", action: save)
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        Button(batch.count > 1 ? "Save \(batch.count)" : "Save") {
                            Task { await saveBatch() }
                        }
                        .disabled(batch.isEmpty || isSaving)
                    }
                }
            }
            .sheet(isPresented: $isSearchingPlace) {
                PlaceSearchSheet(title: entry == .one ? "Where is it?" : "Where are they?", initialQuery: placeName) { place in
                    placeName = place.name
                    coordinate = place.coordinate
                }
            }
            .sheet(item: $editingItem) { item in
                BatchItemEditor(item: item) { edited in
                    if let index = batch.firstIndex(where: { $0.id == edited.id }) {
                        batch[index] = edited
                        batch.sort { $0.start < $1.start }
                    }
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

    /// Moving the start takes the end with it, keeping the length, as Calendar does. Only when
    /// you move it: loading an event sets both as they are.
    private var startBinding: Binding<Date> {
        Binding {
            start
        } set: { moved in
            end = end.addingTimeInterval(moved.timeIntervalSince(start))
            start = moved
        }
    }

    /// The day is already in the form below, so the title doesn't repeat it.
    private var navigationTitle: String {
        if editingEvent != nil { return "Edit event" }
        return entry == .one ? "New event" : "New events"
    }

    // MARK: Sections

    private var captureSection: some View {
        Section {
            TextEditor(text: $sourceText)
                .frame(minHeight: 90)
                .foregroundStyle(.ice)
                .overlay(alignment: .topLeading) {
                    if sourceText.isEmpty {
                        Text(entry == .one
                             ? "Paste a message, invite or poster text…"
                             : "Paste a programme or agenda: a festival's days, a conference's sessions…")
                            .font(.body)
                            .foregroundStyle(.mist)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }

            ImportActions(
                photoTitle: entry == .one ? "Screenshot" : "Photo",
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

    /// Opened from a day, only the times are asked for: the day is the one you were looking at,
    /// shown so it can still be changed.
    private var whenSection: some View {
        Section {
            Toggle("All day", isOn: $isAllDay)
            if isDayFixed {
                HStack {
                    Text("Day")
                    Spacer()
                    Button {
                        withAnimation(PathMotion.control) { isChangingDay = true }
                    } label: {
                        Text(start.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .foregroundStyle(.ion)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Changes the day")
                }
            } else {
                DatePicker("Day", selection: startBinding, displayedComponents: .date)
            }
            if !isAllDay {
                DatePicker("Starts", selection: startBinding, displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: endBinding, displayedComponents: .hourAndMinute)
                Text(durationText)
                    .font(.footnote)
                    .foregroundStyle(.mist)
            }
        } header: {
            InstrumentLabel("When")
        }
    }

    private var isDayFixed: Bool {
        request.day != nil && editingEvent == nil && !isChangingDay
    }

    /// The end is picked as a time; one earlier than the start means it runs past midnight.
    private var endBinding: Binding<Date> {
        Binding {
            end
        } set: { picked in
            let calendar = Calendar.current
            let parts = calendar.dateComponents([.hour, .minute], from: picked)
            var candidate = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: start) ?? picked
            if candidate <= start {
                candidate = candidate.addingTimeInterval(86_400)
            }
            end = candidate
        }
    }

    private var durationText: String {
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        let hours = minutes / 60, rest = minutes % 60
        let length = hours == 0 ? "\(rest) min" : rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
        let overnight = Calendar.current.isDate(end, inSameDayAs: start) ? "" : ", ending the next day"
        return "Lasts \(length)\(overnight)."
    }

    private var whereSection: some View {
        Section {
            TextField(entry == .one ? "Place" : "Place for all of them", text: $placeName)
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
            Text(entry == .one
                 ? "With a place pinned, PathOS can point you there and show the event on the map."
                 : "The venue for the whole programme. A hall or stage an event names is kept alongside it.")
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
            isSearchingPlace = true
        } label: {
            OneLineButtonLabel(title: "Search", symbol: "magnifyingglass")
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
            Picker(entry == .one ? "Remind me" : "Remind me of each", selection: $reminderMinutes) {
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

    // MARK: Several at once

    /// What was read, a day at a time, each one open to fix before saving.
    @ViewBuilder
    private var batchSection: some View {
        if batch.isEmpty {
            Section {
                Text("Read a programme above, or repeat one event across several days below. Everything read is listed here to check before it's saved.")
                    .font(.subheadline)
                    .foregroundStyle(.mist)
            } header: {
                InstrumentLabel("Events")
            }
        } else {
            ForEach(batchDays, id: \.self) { day in
                Section {
                    ForEach(batch.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }) { item in
                        Button {
                            editingItem = item
                        } label: {
                            BatchRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let shown = batch.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
                        let ids = Set(offsets.map { shown[$0].id })
                        batch.removeAll { ids.contains($0.id) }
                    }
                } header: {
                    InstrumentLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                }
            }
            Section {
                Button("Add another", systemImage: "plus") {
                    let last = batch.last
                    let begins = last?.end ?? (request.day ?? Date())
                    let item = EventListReader.Item(title: "", start: begins, end: begins.addingTimeInterval(3_600))
                    batch.append(item)
                    editingItem = item
                }
                Button("Clear the list", systemImage: "trash", role: .destructive) {
                    withAnimation(PathMotion.control) { batch = [] }
                }
            }
        }
    }

    private var batchDays: [Date] {
        Array(Set(batch.map { Calendar.current.startOfDay(for: $0.start) })).sorted()
    }

    /// The same event on each of a run of days: a festival's daily show, a week-long workshop.
    private var repeatSection: some View {
        Section {
            TextField("What is it?", text: $repeatTitle)
            DatePicker("From", selection: $repeatFrom, displayedComponents: .date)
            DatePicker("To", selection: $repeatTo, in: repeatFrom..., displayedComponents: .date)
            DatePicker("Starts", selection: $repeatStart, displayedComponents: .hourAndMinute)
            DatePicker("Ends", selection: $repeatEnd, displayedComponents: .hourAndMinute)
            Button {
                withAnimation(PathMotion.control) { addRepeats() }
            } label: {
                Label(repeatDays.count == 1 ? "Add it" : "Add it on \(repeatDays.count) days", systemImage: "calendar.badge.plus")
            }
            .disabled(repeatTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            InstrumentLabel("Every day, for a few days")
        }
    }

    private var repeatDays: [Date] {
        let calendar = Calendar.current
        var days: [Date] = []
        var day = calendar.startOfDay(for: repeatFrom)
        let last = calendar.startOfDay(for: max(repeatTo, repeatFrom))
        while day <= last, days.count < 31 {
            days.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? last.addingTimeInterval(1)
        }
        return days
    }

    private func addRepeats() {
        let calendar = Calendar.current
        let from = calendar.dateComponents([.hour, .minute], from: repeatStart)
        let to = calendar.dateComponents([.hour, .minute], from: repeatEnd)
        let title = repeatTitle.trimmingCharacters(in: .whitespaces)
        for day in repeatDays {
            guard let begins = calendar.date(bySettingHour: from.hour ?? 9, minute: from.minute ?? 0, second: 0, of: day),
                  var ends = calendar.date(bySettingHour: to.hour ?? 10, minute: to.minute ?? 0, second: 0, of: day) else { continue }
            if ends <= begins { ends = ends.addingTimeInterval(86_400) }
            batch.append(EventListReader.Item(title: title, start: begins, end: ends))
        }
        batch.sort { $0.start < $1.start }
        repeatTitle = ""
    }

    // MARK: Actions

    private func load() {
        if let event = editingEvent {
            title = event.title
            notes = event.notes
            start = event.start
            end = event.end > event.start ? event.end : event.start.addingTimeInterval(3_600)
            isAllDay = event.isAllDay
            placeName = event.placeName ?? ""
            coordinate = event.coordinate
            tags = Set(event.tags)
            reminderMinutes = event.reminderMinutesBefore
            origin = event.origin
        } else if let suggestion = mailSuggestion {
            load(suggestion)
        } else {
            if let day = request.day {
                start = Self.defaultStart(on: day)
                end = start.addingTimeInterval(3_600)
                repeatFrom = Calendar.current.startOfDay(for: day)
                repeatTo = repeatFrom.addingTimeInterval(2 * 86_400)
            }
            if let text = request.text, !text.isEmpty {
                sourceText = text
                // Pasted text with several times in it is a programme, not one event.
                if EventListReader.items(in: text, now: request.day ?? Date()).count >= 2 {
                    entry = .several
                }
            }
        }
    }

    private func load(_ suggestion: MailSuggestion) {
        title = suggestion.title
        notes = MailService.notes(for: suggestion)
        if let date = suggestion.start {
            start = date
        }
        isAllDay = suggestion.isAllDay
        if let ends = suggestion.endsAt, ends > start {
            end = ends
        } else {
            end = start.addingTimeInterval(3_600)
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
        if entry == .several {
            let read = await state.snap.readEvents(text: text, on: request.day)
            accept(read.items, usedAI: read.usedAI)
        } else {
            apply(draft: await state.snap.analyze(text: text))
        }
    }

    private func read(image: UIImage) async {
        isReading = true
        defer { isReading = false }
        if entry == .several {
            guard let read = try? await state.snap.readEvents(image: image, on: request.day) else {
                readNote = "No readable text in that image."
                return
            }
            sourceText = read.text
            accept(read.items, usedAI: read.usedAI)
            return
        }
        guard let draft = try? await state.snap.analyze(image: image) else {
            readNote = "No readable text in that image."
            return
        }
        sourceText = draft.rawText
        apply(draft: draft)
    }

    private func accept(_ items: [EventListReader.Item], usedAI: Bool) {
        guard !items.isEmpty else {
            readNote = "No times found in that. Each event needs a time, like “10:00 AM Inauguration”."
            return
        }
        withAnimation(PathMotion.control) {
            batch = (batch + items).sorted { $0.start < $1.start }
        }
        let days = Set(items.map { Calendar.current.startOfDay(for: $0.start) }).count
        readNote = "Found \(items.count) events over \(days) \(days == 1 ? "day" : "days")\(usedAI ? ", read by Apple Intelligence" : ""). Tap one to fix it before saving."
        // One venue for the whole programme, when every event names the same one.
        let places = Set(items.compactMap(\.place))
        if placeName.isEmpty, places.count == 1, let only = places.first, items.allSatisfy({ $0.place != nil }) {
            placeName = only
            Task { await findOnMap() }
        }
    }

    private func apply(draft: ScanDraft) {
        if !draft.title.isEmpty { title = draft.title }
        if notes.isEmpty { notes = draft.summary }
        if let date = draft.eventStart {
            start = date
            end = date.addingTimeInterval(3_600)
        }
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
        let ends = isAllDay ? Calendar.current.startOfDay(for: start).addingTimeInterval(86_399) : max(end, start.addingTimeInterval(5 * 60))

        let event = editingEvent ?? PathEvent(title: trimmed, start: start)
        event.title = trimmed
        event.notes = notes
        event.start = start
        event.endsAt = ends
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

    /// Every event in the list, each with the venue, and the hall or stage it names beside it.
    private func saveBatch() async {
        isSaving = true
        defer { isSaving = false }
        let venue = placeName.trimmingCharacters(in: .whitespaces)
        // A programme without one venue: each place it names is looked up once.
        var pins: [String: CLLocationCoordinate2D] = [:]
        if coordinate == nil, let here = await state.location.currentLocation() {
            for place in Set(batch.compactMap(\.place)).prefix(6) {
                if let found = try? await state.places.search(place, near: here, radius: 30_000).first {
                    pins[place] = found.coordinate
                }
            }
        }
        let named = batch.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        for item in named {
            let place: String? = switch (item.place, venue.isEmpty) {
            case let (own?, false) where own != venue: "\(own) · \(venue)"
            case let (own?, _): own
            case (nil, false): venue
            case (nil, true): nil
            }
            let pin = coordinate ?? item.place.flatMap { pins[$0] }
            let event = PathEvent(
                title: item.title.trimmingCharacters(in: .whitespaces),
                start: item.start,
                endsAt: max(item.end, item.start.addingTimeInterval(5 * 60)),
                notes: "",
                placeName: place,
                coordinate: pin,
                tags: [],
                origin: sourceText.isEmpty ? .manual : .captured,
                reminderMinutesBefore: reminderMinutes
            )
            state.eventStore.save(event)
        }
        state.haptics.success()
        state.showToast(named.count == 1 ? "Event saved" : "\(named.count) events saved")
        dismiss()
    }

    /// The next half hour, so a new event doesn't start in the past.
    static func defaultStart(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let minutes = calendar.component(.minute, from: now)
        let rounded = calendar.date(bySetting: .minute, value: minutes < 30 ? 30 : 0, of: now) ?? now
        return rounded > now ? rounded : rounded.addingTimeInterval(3_600)
    }

    /// On another day, the morning; today, the next half hour.
    static func defaultStart(on day: Date, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        if calendar.isDate(day, inSameDayAs: now) { return defaultStart(now: now) }
        return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
    }
}

/// One event of several, as it will be saved.
private struct BatchRow: View {
    let item: EventListReader.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TimeSpan(start: item.start.formatted(date: .omitted, time: .shortened),
                     end: item.end.formatted(date: .omitted, time: .shortened))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(.headline)
                    .foregroundStyle(item.title.isEmpty ? .mist : .ice)
                    .lineLimit(2)
                if let place = item.place {
                    Text(place)
                        .font(.footnote)
                        .foregroundStyle(.mist)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Fixes one event of several: its name, day, times and place.
private struct BatchItemEditor: View {
    let item: EventListReader.Item
    let onSave: (EventListReader.Item) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var place = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What is it?", text: $title)
                    DatePicker("Starts", selection: Binding {
                        start
                    } set: { moved in
                        end = end.addingTimeInterval(moved.timeIntervalSince(start))
                        start = moved
                    })
                    DatePicker("Ends", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                    TextField("Hall, stage or room", text: $place)
                } header: {
                    InstrumentLabel("Event")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle(item.title.isEmpty ? "New event" : "Edit event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        var edited = item
                        edited.title = title.trimmingCharacters(in: .whitespaces)
                        edited.start = start
                        edited.end = max(end, start.addingTimeInterval(5 * 60))
                        edited.place = place.trimmingCharacters(in: .whitespaces).nilIfEmpty
                        onSave(edited)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task {
                title = item.title
                start = item.start
                end = item.end
                place = item.place ?? ""
            }
        }
        .presentationDetents([.medium, .large])
    }
}
