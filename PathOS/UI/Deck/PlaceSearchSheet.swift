import CoreLocation
import SwiftUI

/// Searching Apple Maps for a place and picking one, wherever a place has to be chosen: an
/// event's location, Home or Work. It shows what it found — name, kind, address and how far —
/// so the right one of five similarly named places can be picked rather than guessed at.
struct PlaceSearchSheet: View {
    var title = "Find a place"
    var initialQuery = ""
    var onPick: (PlaceSummary) -> Void

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PlaceSummary] = []
    @State private var isSearching = false
    @State private var problem: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field
                    if isSearching && results.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().tint(.ion)
                            Text("Searching…").font(.subheadline).foregroundStyle(.mist)
                        }
                    } else if let problem {
                        Text(problem).font(.subheadline).foregroundStyle(.amber)
                    } else if results.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty, !isSearching {
                        Text("Nothing found for “\(query)”.").font(.subheadline).foregroundStyle(.mist)
                    }
                    ForEach(results) { place in
                        Button {
                            onPick(place)
                            dismiss()
                        } label: {
                            row(place)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Color.deepSurface)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            query = initialQuery
            isFocused = initialQuery.isEmpty
            if !initialQuery.isEmpty { await search() }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(.mist)
            TextField("Places and addresses", text: $query)
                .font(.body)
                .foregroundStyle(.ice)
                .focused($isFocused)
                .submitLabel(.search)
                .onSubmit { Task { await search() } }
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.mist)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(_ place: PlaceSummary) -> some View {
        HStack(spacing: 12) {
            SignalGlyph(symbol: place.symbol, role: .world, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.ice)
                    .lineLimit(2)
                Text([place.categoryName, place.address, GeoMath.formatDistance(place.distanceMeters) + " away"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.mist)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(.aurora)
        }
        .padding(12)
        .background(Color.elevatedSurface.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(.rect)
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count > 1 else {
            results = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await state.places.find(text, near: state.location.location)
            problem = nil
        } catch {
            results = []
            problem = "Apple Maps couldn't search just now."
        }
    }
}
