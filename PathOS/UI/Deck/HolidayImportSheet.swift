import PDFKit
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
                        symbol: Holidays.Kind.college.symbol)
        dismiss()
    }
}
