import PDFKit
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// What your days have added up to: what you went to and what you missed, the holidays and days
/// off you took, what you got done. Anything PathOS got wrong is put right here — "I was there",
/// or a holiday that was or wasn't a day off for you.
struct OverviewView: View {
    @Environment(AppState.self) private var state
    @Query(sort: \Holiday.dayStart) private var holidays: [Holiday]
    @Query(sort: \RideRecord.at, order: .reverse) private var rides: [RideRecord]
    @AppStorage("pathos.overviewSpan") private var span: Overview.Span = .month
    @State private var summary = Overview.Summary()
    @State private var isImporting = false

    var body: some View {
        Form {
            Section {
                Picker("Span", selection: $span) {
                    ForEach(Overview.Span.allCases) { span in
                        Text(span.title).tag(span)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                LabeledContent("Went to", value: wentTo)
                LabeledContent("Missed", value: "\(summary.missed.count)")
                LabeledContent("Holidays off", value: "\(summary.holidaysTaken)")
                LabeledContent("Other days off", value: "\(summary.otherDaysOff)")
                LabeledContent("Tasks done", value: "\(summary.tasksDone)")
                LabeledContent("Travelled", value: GeoMath.formatDistance(summary.distanceMeters))
            } header: {
                InstrumentLabel(span.title)
            } footer: {
                Text("Sessions, events and your calendar's own entries. Anything PathOS didn't see you miss counts as went: the app being closed is no proof you weren't there.")
            }

            Section {
                if summary.missed.isEmpty {
                    Text("Nothing missed.")
                        .foregroundStyle(.mist)
                }
                ForEach(summary.missed) { missed in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(missed.title)
                                .foregroundStyle(.ice)
                            Text(missed.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                                .font(.footnote)
                                .foregroundStyle(.mist)
                        }
                        Spacer(minLength: 8)
                        Button("I was there") {
                            state.setAttendance(missed.id, attended: true, on: missed.dayStart)
                            refresh()
                        }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                        .foregroundStyle(.aurora)
                    }
                }
            } header: {
                InstrumentLabel("Missed")
            }

            Section {
                if summary.daysOff.isEmpty {
                    Text("No days off.")
                        .foregroundStyle(.mist)
                }
                ForEach(summary.daysOff) { off in
                    LabeledContent(off.reason, value: off.dayStart.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                }
            } header: {
                InstrumentLabel("Days off")
            }

            ridesSection

            holidaySection(title: "Holidays coming up", holidays: upcoming)
            holidaySection(title: "Holidays gone by", holidays: past)

            Section {
                Button("Add your college's calendar", systemImage: "calendar.badge.plus") { isImporting = true }
            } footer: {
                Text(sourceNote)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.deepSurface)
        .navigationTitle("Overview")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .onChange(of: span) { _, _ in refresh() }
        .onChange(of: state.holidays.version) { _, _ in refresh() }
        .sheet(isPresented: $isImporting, onDismiss: refresh) {
            HolidayImportSheet()
        }
    }

    /// Rides in the span, from their receipts: what each service cost you, and the latest few.
    @ViewBuilder
    private var ridesSection: some View {
        let start = span.start(now: Date()) ?? .distantPast
        let inSpan = rides.filter { $0.at >= start }
        Section {
            if inSpan.isEmpty {
                Text("No ride receipts yet. Uber, Ola, Rapido and Namma Yatri receipts in your Gmail are kept here.")
                    .foregroundStyle(.mist)
            } else {
                let byService = Dictionary(grouping: inSpan, by: \.service)
                ForEach(byService.keys.sorted { $0.name < $1.name }, id: \.self) { service in
                    let list = byService[service] ?? []
                    let spent = list.compactMap(\.fare).reduce(0, +)
                    LabeledContent(service.name, value: "₹\(Int(spent.rounded())) · \(list.count) \(list.count == 1 ? "ride" : "rides")")
                }
                ForEach(inSpan.prefix(5)) { ride in
                    VStack(alignment: .leading, spacing: 2) {
                        Text([ride.service.name, ride.fare.map { "₹\(Int($0.rounded()))" },
                              ride.distanceKm.map { String(format: "%.1f km", $0) }].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.ice)
                        Text([ride.at.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()),
                              ride.drop?.components(separatedBy: ",").first.map { "to \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.mist)
                    }
                }
            }
        } header: {
            InstrumentLabel("Rides")
        } footer: {
            if let learned = state.rideFares {
                Text("Your last \(learned.rides) rides cost \(Int((learned.factor * 100).rounded()))% of PathOS's estimate for the same distance. Ways to get somewhere say so beside their fares.")
            }
        }
    }

    private var wentTo: String {
        guard let share = summary.attendance else { return "\(summary.attended)" }
        return "\(summary.attended) · \(Int((share * 100).rounded()))%"
    }

    private var upcoming: [Holiday] {
        let today = Calendar.current.startOfDay(for: Date())
        return holidays.filter { $0.dayStart >= today }
    }

    /// Gone by this year, newest first: where an unanswered one is put right after the fact.
    private var past: [Holiday] {
        let today = Calendar.current.startOfDay(for: Date())
        let yearStart = Calendar.current.dateInterval(of: .year, for: today)?.start ?? today
        return holidays.filter { $0.dayStart < today && $0.dayStart >= yearStart }.reversed()
    }

    @ViewBuilder
    private func holidaySection(title: String, holidays: [Holiday]) -> some View {
        if !holidays.isEmpty {
            Section {
                ForEach(holidays) { holiday in
                    HolidayAnswerRow(holiday: holiday)
                }
                .onDelete { offsets in
                    for index in offsets where holidays[index].kind == .college || holidays[index].kind == .own {
                        state.holidays.delete(holidays[index])
                    }
                }
            } header: {
                InstrumentLabel(title)
            }
        }
    }

    private var sourceNote: String {
        let official = Holidays.bundled.sources.first.map { "Public holidays: \($0.notification)." } ?? ""
        return "\(official) Next year's list comes with PathOS once the state publishes it, usually in November. A college's own calendar — a photo, a PDF or pasted text — is read on your iPhone, and you check it before anything is saved."
    }

    private func refresh() {
        summary = state.overview(span)
    }
}

/// One holiday, and whether it was — or will be — a day off for you.
private struct HolidayAnswerRow: View {
    let holiday: Holiday

    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(holiday.name)
                    .foregroundStyle(.ice)
                Text("\(holiday.dayStart.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) · \(holiday.kind.label)")
                    .font(.footnote)
                    .foregroundStyle(.mist)
            }
            Spacer(minLength: 8)
            Picker("Day off?", selection: Binding(
                get: { holiday.isOff },
                set: { answer in
                    if let answer { state.holidays.answer(holiday, isOff: answer) }
                }
            )) {
                if holiday.isOff == nil {
                    // Still to come, it's asked about in the month before; gone by, it's yours to say.
                    Text(holiday.dayStart >= Calendar.current.startOfDay(for: Date()) ? "Ask me" : "Not said").tag(Bool?.none)
                }
                Text("Day off").tag(Bool?.some(true))
                Text("Not off").tag(Bool?.some(false))
            }
            .labelsHidden()
            .tint(holiday.isOff == true ? .aurora : .mist)
        }
    }
}

/// Your college's academic calendar, read for its holidays: a photo, a PDF or pasted text. Rules
/// read what's written one holiday to a line; Apple Intelligence reads the rest, such as a grid
/// of months. Nothing is kept until you've checked the list.
struct HolidayImportSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var isPickingFile = false
    @State private var isReading = false
    @State private var rows: [Draft] = []
    @State private var note: String?

    /// A holiday read from the calendar, which you can untick before saving.
    struct Draft: Identifiable {
        var id = UUID()
        var row: HolidayListReader.Row
        var isKept = true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 110)
                        .foregroundStyle(.ice)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Paste your college's calendar, or read it from a photo or a PDF…")
                                    .foregroundStyle(.mist)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                    ImportActions(photoTitle: "Photo", photoItem: $photoItem, isReading: isReading,
                                  canRead: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        text = UIPasteboard.general.string ?? text
                    } read: {
                        Task { await read(text) }
                    }
                    Button("Read a PDF", systemImage: "doc.richtext") { isPickingFile = true }
                        .disabled(isReading)
                    if let note {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.mist)
                    }
                } header: {
                    InstrumentLabel("Your college's calendar")
                } footer: {
                    Text("Read on your iPhone. Nothing is saved until you tap Save.")
                }

                if !rows.isEmpty {
                    Section {
                        ForEach($rows) { $draft in
                            Toggle(isOn: $draft.isKept) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(draft.row.name)
                                        .foregroundStyle(.ice)
                                    Text(draft.row.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))
                                        .font(.footnote)
                                        .foregroundStyle(.mist)
                                }
                            }
                            .tint(.aurora)
                        }
                    } header: {
                        InstrumentLabel("Found \(rows.count)")
                    } footer: {
                        Text("Each is asked about in the month before it: a day off for you, or not. Ones already on PathOS's list aren't added twice.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle("College calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!rows.contains(where: \.isKept))
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        await read(images: [image])
                    }
                    photoItem = nil
                }
            }
            .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result else { return }
                Task { await read(pdf: url) }
            }
        }
    }

    private func read(images: [UIImage]) async {
        isReading = true
        var pages: [String] = []
        for image in images {
            if let result = try? await OCRParser.recognizeText(in: image), !result.isEmpty {
                pages.append(result.fullText)
            }
        }
        isReading = false
        guard !pages.isEmpty else {
            note = "No readable text in that."
            return
        }
        text = pages.joined(separator: "\n")
        await read(text)
    }

    /// A PDF's own text where it has one; a scanned one is read page by page as pictures.
    private func read(pdf url: URL) async {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url) else {
            note = "That PDF couldn't be opened."
            return
        }
        let ownText = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        if ownText.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 {
            text = ownText
            await read(ownText)
            return
        }
        let images = (0..<min(document.pageCount, 6)).compactMap { index -> UIImage? in
            guard let page = document.page(at: index) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            return page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
        }
        await read(images: images)
    }

    private func read(_ source: String) async {
        isReading = true
        defer { isReading = false }
        var found = HolidayListReader.rows(in: source, today: Date())
        var usedAI = false
        if state.ai.isAvailable, let read = try? await state.ai.extractHolidays(from: source), read.count > found.count {
            found = read
            usedAI = true
        }
        guard !found.isEmpty else {
            note = "No holidays found in that. Each needs a date, like “20.10.2026 Mahanavami”."
            return
        }
        rows = found.sorted { $0.day < $1.day }.map { Draft(row: $0) }
        note = "Found \(found.count)\(usedAI ? ", read by Apple Intelligence" : ""). Untick any that aren't holidays."
    }

    private func save() {
        let added = state.holidays.add(rows.filter(\.isKept).map(\.row), kind: .college)
        state.showToast(added == 0 ? "Those were already on your calendar" : "\(added) college \(added == 1 ? "holiday" : "holidays") added",
                        symbol: "sun.max.fill")
        dismiss()
    }
}
