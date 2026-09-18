import CoreLocation
import SwiftUI

struct RadarView: View {
    @Environment(AppState.self) private var state
    @Environment(RadarModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                categoryPicker

                if model.rankedByAI {
                    Label("Ranked on-device by Apple Intelligence", systemImage: "apple.intelligence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = model.errorMessage {
                    ContentUnavailableView("Radar needs your location", systemImage: "location.slash", description: Text(error))
                } else if model.isLoading && model.items.isEmpty {
                    ProgressView("Scanning around you…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if model.items.isEmpty {
                    ContentUnavailableView("Nothing found nearby", systemImage: "dot.radiowaves.left.and.right", description: Text("Pull to refresh or try another category."))
                }

                ForEach(model.items) { item in
                    RadarItemCard(item: item)
                }

                Text("Events come from nearby venues on Apple Maps and posters you scan.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }
            .padding()
        }
        .background(AmbientBackground())
        .navigationTitle("Radar")
        .refreshable { await model.refresh(state: state) }
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RadarCategory.allCases) { category in
                    Button {
                        model.category = category
                    } label: {
                        Label(category.label, systemImage: category.symbol)
                            .font(.subheadline.weight(model.category == category ? .semibold : .regular))
                    }
                    .buttonStyle(.glass)
                    .tint(model.category == category ? .mint : nil)
                }
            }
        }
    }
}

private struct RadarItemCard: View {
    let item: RadarItem
    @Environment(AppState.self) private var state

    var body: some View {
        SpatialCardView(
            symbol: item.symbol,
            tint: item.isEvent ? .orange : .mint,
            title: item.title,
            subtitle: item.reason ?? item.subtitle,
            detail: detail
        ) {
            if let target {
                Button {
                    state.startCompass(to: target)
                } label: {
                    Image(systemName: "location.north.line.fill")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Point me to \(item.title)")
            }
        }
        .contextMenu {
            if let target {
                ForEach(CabProvider.allCases) { provider in
                    Button("Book \(provider.name)", systemImage: provider.symbol) {
                        CabLauncher.open(provider, drop: target.coordinate, pickup: state.location.location?.coordinate)
                    }
                }
            }
        }
    }

    private var target: CompassTarget? {
        guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
        return CompassTarget(id: item.id, name: item.title, latitude: latitude, longitude: longitude)
    }

    private var detail: String? {
        var parts: [String] = []
        if let distance = item.distanceMeters {
            parts.append("\(GeoMath.formatDistance(distance)) · \(GeoMath.walkingMinutes(forDistance: distance)) min walk")
        }
        if let start = item.start {
            parts.append(start.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
