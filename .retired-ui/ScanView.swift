import EventKit
import EventKitUI
import PhotosUI
import SwiftData
import SwiftUI

struct ScanView: View {
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScanRecord.createdAt, order: .reverse) private var records: [ScanRecord]
    @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]

    @State private var isScannerPresented = false
    @State private var photoItem: PhotosPickerItem?
    @State private var capturedImage: UIImage?
    @State private var draft: ScanDraft?
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var confirmation: String?
    @State private var eventToAdd: EventDraft?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                captureButtons

                if isAnalyzing {
                    ProgressView("Reading and understanding…")
                        .frame(maxWidth: .infinity)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let confirmation {
                    Label(confirmation, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.mint)
                }

                if let binding = Binding($draft) {
                    DraftEditor(draft: binding)
                    actions(for: binding.wrappedValue)
                }

                expenseSummary
                history
            }
            .padding()
        }
        .background(AmbientBackground())
        .navigationTitle("Snap to Action")
        .fullScreenCover(isPresented: $isScannerPresented) {
            ScannerSheet { image in process(image) }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    process(image)
                }
                photoItem = nil
            }
        }
        .sheet(item: $eventToAdd) { event in
            EventEditor(draft: event) { saved in
                eventToAdd = nil
                if saved {
                    confirmation = "Added to Calendar."
                    state.haptics.success()
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Sections

    private var captureButtons: some View {
        HStack(spacing: 12) {
            if ScannerController.isSupported {
                Button {
                    isScannerPresented = true
                } label: {
                    Label("Camera", systemImage: "camera.viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Photo", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glass)
        }
    }

    @ViewBuilder
    private func actions(for draft: ScanDraft) -> some View {
        VStack(spacing: 10) {
            switch draft.kind {
            case .event:
                Button {
                    eventToAdd = EventDraft(
                        title: draft.title,
                        start: draft.eventStart ?? Date().addingTimeInterval(3_600),
                        location: draft.venue,
                        notes: draft.summary
                    )
                    state.snap.saveRecord(draft, at: state.location.location)
                } label: {
                    Label("Add to Calendar", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            case .receipt:
                Button {
                    if state.snap.saveExpense(draft) != nil {
                        state.snap.saveRecord(draft, at: state.location.location)
                        finish("Expense logged.")
                    } else {
                        errorMessage = "Enter the amount first."
                    }
                } label: {
                    Label("Log expense", systemImage: "indianrupeesign.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            case .parking, .note:
                Button {
                    Task { await saveAsSpatialNote(draft) }
                } label: {
                    Label("Pin to this spot", systemImage: "mappin.and.ellipse").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }

            Button {
                state.snap.saveRecord(draft, at: state.location.location)
                finish("Saved to history.")
            } label: {
                Label("Just save", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
    }

    @ViewBuilder
    private var expenseSummary: some View {
        let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? .distantPast
        let thisMonth = expenses.filter { $0.date >= monthStart }
        if !thisMonth.isEmpty {
            GlassSection(title: "This month", symbol: "indianrupeesign.circle.fill") {
                Text(thisMonth.reduce(0) { $0 + $1.amount }, format: .currency(code: "INR"))
                    .font(.title2.bold())
                let byCategory = Dictionary(grouping: thisMonth, by: \.category)
                    .map { ($0.key, $0.value.reduce(0) { $0 + $1.amount }) }
                    .sorted { $0.1 > $1.1 }
                ForEach(byCategory.prefix(4), id: \.0) { category, total in
                    HStack {
                        Label(category.label, systemImage: category.symbol)
                        Spacer()
                        Text(total, format: .currency(code: "INR"))
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private var history: some View {
        if !records.isEmpty {
            Text("Recent scans")
                .font(.headline)
                .padding(.top, 4)
            ForEach(records.prefix(12)) { record in
                SpatialCardView(
                    symbol: record.kind.symbol,
                    tint: .orange,
                    title: record.title,
                    subtitle: record.summary,
                    detail: record.createdAt.formatted(date: .abbreviated, time: .shortened)
                )
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        modelContext.delete(record)
                        try? modelContext.save()
                    }
                }
            }
        } else if draft == nil && !isAnalyzing {
            ContentUnavailableView(
                "Scan the world",
                systemImage: "text.viewfinder",
                description: Text("Point at an event poster, a bill, or a parking pillar sign. PathOS turns it into a calendar event, an expense, or a spot you can find again.")
            )
        }
    }

    // MARK: Actions

    private func process(_ image: UIImage) {
        capturedImage = image
        draft = nil
        errorMessage = nil
        confirmation = nil
        isAnalyzing = true
        Task {
            defer { isAnalyzing = false }
            do {
                draft = try await state.snap.analyze(image: image)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveAsSpatialNote(_ draft: ScanDraft) async {
        guard let here = await state.location.currentLocation() else {
            errorMessage = "Couldn't get your location."
            return
        }
        let photo = capturedImage?.jpegData(compressionQuality: 0.5)
        state.vault.saveNote(
            title: draft.title,
            body: draft.parkingLabel ?? draft.summary,
            at: here.coordinate,
            photoData: photo
        )
        state.snap.saveRecord(draft, at: here)
        await state.vault.syncGeofences(userLocation: here)
        finish("Pinned. PathOS will bring it back when you return.")
    }

    private func finish(_ message: String) {
        confirmation = message
        draft = nil
        capturedImage = nil
        state.haptics.success()
    }
}

private struct DraftEditor: View {
    @Binding var draft: ScanDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(draft.usedAI ? "Understood by Apple Intelligence" : "Read with on-device rules", systemImage: draft.usedAI ? "apple.intelligence" : "text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Picker("Type", selection: $draft.kind) {
                ForEach(ScanKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            TextField("Title", text: $draft.title)
                .font(.headline)
                .textFieldStyle(.roundedBorder)

            switch draft.kind {
            case .event:
                DatePicker(
                    "Starts",
                    selection: Binding(get: { draft.eventStart ?? Date() }, set: { draft.eventStart = $0 })
                )
                TextField("Venue", text: Binding(get: { draft.venue ?? "" }, set: { draft.venue = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
            case .receipt:
                HStack {
                    Text("₹")
                    TextField("Amount", value: Binding(get: { draft.amount ?? 0 }, set: { draft.amount = $0 }), format: .number)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                }
                Picker("Category", selection: $draft.category) {
                    ForEach(ExpenseCategory.allCases) { category in
                        Label(category.label, systemImage: category.symbol).tag(category)
                    }
                }
            case .parking:
                TextField("Level / pillar / slot", text: Binding(get: { draft.parkingLabel ?? "" }, set: { draft.parkingLabel = $0 }))
                    .textFieldStyle(.roundedBorder)
            case .note:
                EmptyView()
            }

            Text(draft.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

nonisolated struct EventDraft: Identifiable, Sendable {
    var id = UUID()
    var title: String
    var start: Date
    var location: String?
    var notes: String
}

/// System event editor. Runs out-of-process, so no calendar permission prompt is needed.
private struct EventEditor: UIViewControllerRepresentable {
    let draft: EventDraft
    let onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.start.addingTimeInterval(2 * 3_600)
        event.location = draft.location
        event.notes = draft.notes

        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, @preconcurrency EKEventEditViewDelegate {
        let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onFinish(action == .saved)
        }
    }
}
