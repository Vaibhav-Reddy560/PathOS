import CoreLocation
import Foundation
import Observation

/// Builds the "vibe stream": nearby places + events, ranked on-device when AI is available.
/// Owned by the world view so the map and the Radar deck share one set of results.
@Observable
final class RadarModel {
    private(set) var items: [RadarItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var rankedByAI = false
    var category: RadarCategory = .all

    func refresh(state: AppState) async {
        isLoading = true
        defer { isLoading = false }

        guard let here = await state.location.currentLocation() else {
            errorMessage = "Allow location access to see what's around you."
            return
        }
        errorMessage = nil

        let places = (try? await state.places.browse(category, near: here, radius: 1_500)) ?? []
        let includeEvents = category == .all || category == .culture
        if includeEvents {
            await state.events.refresh(near: here)
        }

        var seen = Set<String>()
        let pool = ((includeEvents ? state.events.events.prefix(10).map(Self.item(from:)) : [])
            + places.prefix(20).map(Self.item(from:)))
            .filter { seen.insert($0.id).inserted }

        if state.ai.isAvailable, pool.count > 1,
           let picks = try? await state.ai.vibeStream(
               candidates: pool.map { VibeCandidate(id: $0.id, line: Self.describe($0)) },
               situation: state.situationSummary()
           ),
           !picks.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })
            var ranked = picks.compactMap { pick -> RadarItem? in
                guard var item = byID[pick.itemID] else { return nil }
                item.reason = "\(pick.headline) — \(pick.reason)"
                return item
            }
            let pickedIDs = Set(ranked.map(\.id))
            ranked += pool.filter { !pickedIDs.contains($0.id) }
            items = ranked
            rankedByAI = true
        } else {
            items = pool.sorted { first, second in
                switch (first.start, second.start) {
                case let (a?, b?): a < b
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): (first.distanceMeters ?? .infinity) < (second.distanceMeters ?? .infinity)
                }
            }
            rankedByAI = false
        }
    }

    private static func item(from place: PlaceSummary) -> RadarItem {
        RadarItem(
            id: "place:\(place.id)",
            title: place.name,
            subtitle: place.categoryName,
            symbol: place.symbol,
            latitude: place.latitude,
            longitude: place.longitude,
            distanceMeters: place.distanceMeters,
            isEvent: false
        )
    }

    private static func item(from event: LocalEvent) -> RadarItem {
        RadarItem(
            id: event.id,
            title: event.title,
            subtitle: event.subtitle,
            symbol: event.symbol,
            latitude: event.latitude,
            longitude: event.longitude,
            distanceMeters: event.distanceMeters,
            start: event.start,
            isEvent: event.source.isEvent
        )
    }

    private static func describe(_ item: RadarItem) -> String {
        var parts = [item.title, item.subtitle]
        if let distance = item.distanceMeters {
            parts.append("\(GeoMath.walkingMinutes(forDistance: distance)) min walk")
        }
        if let start = item.start {
            parts.append("starts \(start.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " | ")
    }
}

/// Changes when the category changes or you move roughly 250 m, so Radar refreshes on its own.
nonisolated struct RadarRefreshKey: Hashable, Sendable {
    var category: RadarCategory
    var latitudeCell: Int?
    var longitudeCell: Int?

    static let cellDegrees = 0.0025

    init(category: RadarCategory, location: CLLocationCoordinate2D?) {
        self.category = category
        latitudeCell = location.map { Int(($0.latitude / Self.cellDegrees).rounded()) }
        longitudeCell = location.map { Int(($0.longitude / Self.cellDegrees).rounded()) }
    }
}
