import EventKit
import EventKitUI
import SwiftUI

/// The deck page shown while a scan is being read, or once it has become an editable draft.
struct ScanReviewView: View {
    @Environment(AppState.self) private var state
    @Environment(ScanFlowModel.self) private var flow

    var body: some View {
        @Bindable var flow = flow

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    InstrumentLabel("Snap to action")
                    Spacer()
                    Button {
                        flow.cancel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.ice)
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Close scan")
                }

                if flow.isAnalyzing {
                    ContentTile {
                        HStack(spacing: 14) {
                            ProgressView()
                                .tint(.ion)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reading and understanding…")
                                    .font(.headline)
                                    .foregroundStyle(.ice)
                                Text("Text is read on your iPhone. Nothing leaves the device.")
                                    .font(.subheadline)
                                    .foregroundStyle(.mist)
                            }
                        }
                    }
                } else if let error = flow.errorMessage {
                    ContentTile {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 14) {
                                SignalGlyph(symbol: "text.magnifyingglass", role: .attention)
                                Text(error)
                                    .font(.subheadline)
                                    .foregroundStyle(.ice)
                            }
                            Button {
                                flow.cancel()
                                state.beginScan()
                            } label: {
                                Label("Try again", systemImage: "camera.viewfinder")
                                    .frame(maxWidth: .infinity, minHeight: 32)
                            }
                            .pathSecondaryAction()
                        }
                    }
                } else if let draft = Binding($flow.draft) {
                    DraftEditor(draft: draft)
                    actions(for: draft.wrappedValue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .deckScroll()
    }

    @ViewBuilder
    private func actions(for draft: ScanDraft) -> some View {
        VStack(spacing: 10) {
            switch draft.kind {
            case .event:
                Button {
                    flow.addToCalendar(state: state)
                } label: {
                    Label("Add to Calendar", systemImage: "calendar.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .pathPrimaryAction()
            case .receipt:
                Button {
                    flow.logExpense(state: state)
                } label: {
                    Label("Log expense", systemImage: "indianrupeesign.circle")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .pathPrimaryAction()
            case .parking, .note:
                Button {
                    Task { await flow.pinToThisSpot(state: state) }
                } label: {
                    Label("Pin to this spot", systemImage: "mappin.and.ellipse")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .pathPrimaryAction()
            }

            Button {
                flow.justSave(state: state)
            } label: {
                Label("Just save", systemImage: "tray.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .pathSecondaryAction()
        }
    }
}

private struct DraftEditor: View {
    @Binding var draft: ScanDraft

    var body: some View {
        ContentTile {
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text(draft.usedAI ? "Understood by Apple Intelligence" : "Read with on-device rules")
                } icon: {
                    Image(systemName: draft.usedAI ? "apple.intelligence" : "text.magnifyingglass")
                        .foregroundStyle(.ion)
                }
                .font(.caption)
                .foregroundStyle(.mist)

                Picker("Type", selection: $draft.kind) {
                    ForEach(ScanKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Title", text: $draft.title)
                    .font(.headline)
                    .pathField()

                switch draft.kind {
                case .event:
                    DatePicker(
                        "Starts",
                        selection: Binding(get: { draft.eventStart ?? Date() }, set: { draft.eventStart = $0 })
                    )
                    .foregroundStyle(.ice)
                    TextField("Venue", text: Binding(get: { draft.venue ?? "" }, set: { draft.venue = $0.isEmpty ? nil : $0 }))
                        .pathField()
                case .receipt:
                    HStack(spacing: 10) {
                        Text("₹")
                            .font(.pathMetric)
                            .foregroundStyle(.mist)
                        TextField("Amount", value: Binding(get: { draft.amount ?? 0 }, set: { draft.amount = $0 }), format: .number)
                            .font(.pathMetric)
                            .keyboardType(.decimalPad)
                            .pathField()
                    }
                    Picker("Category", selection: $draft.category) {
                        ForEach(ExpenseCategory.allCases) { category in
                            Label(category.label, systemImage: category.symbol).tag(category)
                        }
                    }
                    .foregroundStyle(.ice)
                case .parking:
                    TextField("Level / pillar / slot", text: Binding(get: { draft.parkingLabel ?? "" }, set: { draft.parkingLabel = $0 }))
                        .pathField()
                case .note:
                    EmptyView()
                }

                Text(draft.summary)
                    .font(.subheadline)
                    .foregroundStyle(.mist)
            }
        }
    }
}

extension View {
    /// Text input on a Deep Surface well.
    func pathField() -> some View {
        foregroundStyle(.ice)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.deepSurface, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Hairline.style, lineWidth: 1)
            }
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
struct EventEditor: UIViewControllerRepresentable {
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
