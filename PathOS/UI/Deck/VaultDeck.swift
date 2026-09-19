import CoreLocation
import PhotosUI
import SwiftData
import SwiftUI

/// Vault: everything that came from you — memories, places, scans and spending.
struct VaultDeck: View {
    @Environment(AppState.self) private var state
    @Environment(ScanFlowModel.self) private var scanFlow
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SpatialNote.createdAt, order: .reverse) private var notes: [SpatialNote]
    @Query(sort: \SavedPlace.createdAt) private var places: [SavedPlace]
    @Query(sort: \ScanRecord.createdAt, order: .reverse) private var records: [ScanRecord]
    @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]

    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    actions
                    memoriesSection
                    placesSection
                    if !records.isEmpty {
                        scansSection
                    }
                    expensesSection
                    geofenceMeter
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .deckScroll()
            .task(id: state.focusedNoteID) {
                guard let id = state.focusedNoteID else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
                try? await Task.sleep(for: .seconds(4))
                state.focusedNoteID = nil
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    scanFlow.process(image, state: state)
                }
                photoItem = nil
            }
        }
    }

    // MARK: Sections

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                state.isAddingNote = true
            } label: {
                Label("Save this spot", systemImage: "bookmark.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .pathPrimaryAction()

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Scan photo", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .pathSecondaryAction()
        }
    }

    private var memoriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: "Memories", trailing: notes.isEmpty ? nil : "\(notes.count)")
            if notes.isEmpty {
                EmptyState(
                    symbol: "bookmark",
                    title: "Nothing saved yet",
                    message: "Save a parking pillar, locker code or anything tied to a place. It resurfaces when you come back.",
                    role: .you
                )
            } else {
                GroupedRows(notes) { note in
                    MemoryRow(note: note, isFocused: state.focusedNoteID == note.id)
                        .id(note.id)
                }
            }
        }
    }

    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: "Places")
            ContentTile(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array([PlaceKind.home, .work].enumerated()), id: \.element) { index, kind in
                        if index > 0 {
                            RowDivider()
                        }
                        PlaceRow(kind: kind, place: places.first { $0.kind == kind })
                    }
                }
            }
        }
    }

    private var scansSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: "Recent scans")
            GroupedRows(Array(records.prefix(8))) { record in
                HStack(spacing: 14) {
                    SignalGlyph(symbol: record.kind.symbol)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.title)
                            .font(.headline)
                            .foregroundStyle(.ice)
                            .lineLimit(1)
                        Text(record.summary)
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                            .lineLimit(2)
                        InstrumentLabel("\(record.kind.label) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        modelContext.delete(record)
                        try? modelContext.save()
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var expensesSection: some View {
        let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? .distantPast
        let thisMonth = expenses.filter { $0.date >= monthStart }
        if !thisMonth.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                DeckSectionHeader(title: "This month")
                ContentTile {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(thisMonth.reduce(0) { $0 + $1.amount }, format: .currency(code: "INR"))
                            .font(.pathDisplay)
                            .foregroundStyle(.ice)
                        let byCategory = Dictionary(grouping: thisMonth, by: \.category)
                            .map { ($0.key, $0.value.reduce(0) { $0 + $1.amount }) }
                            .sorted { $0.1 > $1.1 }
                        ForEach(byCategory.prefix(4), id: \.0) { category, total in
                            HStack {
                                Label(category.label, systemImage: category.symbol)
                                    .foregroundStyle(.mist)
                                Spacer()
                                Text(total, format: .currency(code: "INR"))
                                    .monospacedDigit()
                                    .foregroundStyle(.ice)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    private var geofenceMeter: some View {
        let used = state.geofences.monitoredIDs.count
        let total = GeofenceMonitor.maxRegions
        return VStack(alignment: .leading, spacing: 8) {
            DeckSectionHeader(title: "Geofence slots", trailing: "\(used) / \(total)")
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.elevatedSurface)
                    Capsule()
                        .fill(Color.ice.opacity(0.55))
                        .frame(width: proxy.size.width * CGFloat(used) / CGFloat(max(total, 1)))
                }
            }
            .frame(height: 6)
            .padding(.horizontal, 4)
            Text("Home and Work always get a slot; the rest go to your closest memories.")
                .font(.caption)
                .foregroundStyle(.mist)
                .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(used) of \(total) geofence slots in use")
    }
}

private struct MemoryRow: View {
    let note: SpatialNote
    let isFocused: Bool

    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 14) {
            if let data = note.photoData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                SignalGlyph(symbol: "bookmark.fill", role: .you, size: 44)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(note.title)
                    .font(.headline)
                    .foregroundStyle(.ice)
                    .lineLimit(2)
                if !note.body.isEmpty {
                    Text(note.body)
                        .font(.subheadline)
                        .foregroundStyle(.mist)
                        .lineLimit(2)
                }
                InstrumentLabel(detail)
                if !note.tags.isEmpty {
                    Text(note.tags.joined(separator: " · "))
                        .font(.pathInstrument)
                        .foregroundStyle(.aurora)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button {
                state.startCompass(to: CompassTarget(id: note.geofenceID, name: note.title, latitude: note.latitude, longitude: note.longitude))
            } label: {
                Image(systemName: "location.north.line.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.aurora)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Point me to \(note.title)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(isFocused ? Color.aurora.opacity(0.08) : .clear)
        .contentShape(.rect)
        .onTapGesture {
            state.selectedSignalID = note.geofenceID
        }
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await state.vault.delete(note) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var detail: String {
        let saved = note.createdAt.formatted(date: .abbreviated, time: .omitted)
        guard let here = state.location.location else { return saved }
        let distance = here.distance(from: CLLocation(latitude: note.latitude, longitude: note.longitude))
        return "\(GeoMath.formatDistance(distance)) away · \(saved)"
    }
}

private struct PlaceRow: View {
    let kind: PlaceKind
    let place: SavedPlace?

    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 14) {
            SignalGlyph(symbol: kind.symbol, role: place == nil ? nil : .you)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.label)
                    .font(.headline)
                    .foregroundStyle(.ice)
                InstrumentLabel(place.map { "\(Int($0.radius)) m geofence" } ?? "Not set")
            }
            Spacer(minLength: 0)
            Button(place == nil ? "Set here" : "Move here") {
                Task {
                    if await state.setPlaceHere(kind) {
                        state.showToast("\(kind.label) saved")
                    } else {
                        state.showToast("Couldn't get your location", role: .attention, symbol: "location.slash.fill")
                    }
                }
            }
            .font(.subheadline.weight(.semibold))
            .pathSecondaryAction()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contextMenu {
            if let place {
                Button("Remove", systemImage: "trash", role: .destructive) {
                    Task { await state.vault.delete(place) }
                }
            }
        }
    }
}

/// Rows on one graphite tile, separated by hairlines — the deck's equivalent of an inset grouped list.
struct GroupedRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row

    init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.row = row
    }

    var body: some View {
        ContentTile(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        RowDivider()
                    }
                    row(item)
                }
            }
        }
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Hairline.style)
            .frame(height: 1)
            .padding(.leading, 72)
    }
}
