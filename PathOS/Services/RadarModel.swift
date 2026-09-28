import CoreLocation
import Foundation
import Observation

/// Builds the "vibe stream": nearby places + events, ranked on-device when AI is available.
/// Owned by the world view so the map and the Radar deck share one set of results.
///
/// An area is scanned once and kept for three days (`RadarCache`), with Apple Intelligence's
/// ordering made at the same time. Switching category only regroups what's known: it never scans
/// or re-orders. Only a new area, a stale scan or a pull to refresh does.
@Observable
final class RadarModel {
    private(set) var items: [RadarItem] = []
    /// Scanning with Apple Maps and ordering what was found: only for an area that's new, stale,
    /// or asked for again.
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var rankedByAI = false
    /// When the places shown were found.
    private(set) var scannedAt: Date?
    var category: RadarCategory = .all

    /// How far around you a scan looks.
    static let searchRadius: CLLocationDistance = 1_500

    @ObservationIgnored private var cache = RadarCache.load(named: "radar")
    /// Scans under way, so switching category mid-scan waits for it rather than starting another,
    /// and a scan finishes even if you've moved on.
    @ObservationIgnored private var inFlight: [RadarCategory: Task<[PlaceSummary]?, Never>] = [:]
    @ObservationIgnored private var ordering: Task<Void, Never>?

    func refresh(state: AppState, force: Bool = false) async {
        guard let here = await state.location.currentLocation() else {
            errorMessage = "Allow location access to see what's around you."
            return
        }
        errorMessage = nil
        let category = self.category
        let now = Date()

        let missing = category.scanned.filter { force || cache.places(for: $0, near: here, now: now) == nil }
        if !missing.isEmpty {
            isLoading = true
            let scans = missing.map { ($0, scan($0, near: here, state: state)) }
            for (scanned, task) in scans {
                if let places = await task.value {
                    cache.store(places, for: scanned, near: here, now: now)
                }
                inFlight[scanned] = nil
            }
            // The ordering belongs to the scan: made once here and kept with the places.
            if category != .transit {
                await order(near: here, state: state, now: now).value
            }
            cache.save(named: "radar")
            isLoading = !inFlight.isEmpty
        }
        guard !Task.isCancelled, category == self.category else { return }

        if category == .transit {
            await state.transit.refreshNearby(location: here)
            items = transitItems(near: here, state: state, now: now)
            scannedAt = cache.places(for: .transit, near: here, now: now)?.savedAt
            rankedByAI = false
            return
        }

        let pool = await pool(for: category, near: here, state: state, now: now)
        scannedAt = category.scanned.compactMap { cache.places(for: $0, near: here, now: now)?.savedAt }.min()
        if let ranking = cache.ranking(near: here, now: now) {
            items = Self.apply(ranking, to: pool)
            rankedByAI = true
        } else {
            items = Self.plainOrder(pool)
            rankedByAI = false
        }
    }

    private func scan(_ category: RadarCategory, near here: CLLocation, state: AppState) -> Task<[PlaceSummary]?, Never> {
        if let task = inFlight[category] { return task }
        let radius = Self.searchRadius
        // Not tied to the view's task, so switching category doesn't cancel a scan halfway.
        let task = Task { try? await state.places.browse(category, near: here, radius: radius) }
        inFlight[category] = task
        return task
    }

    /// Orders everything known around here in one pass, so every category reads from the same
    /// ordering instead of asking again each time you switch.
    private func order(near here: CLLocation, state: AppState, now: Date) -> Task<Void, Never> {
        if let ordering { return ordering }
        let task = Task {
            defer { self.ordering = nil }
            guard state.ai.isAvailable else { return }
            let pool = await pool(for: .all, near: here, state: state, now: now)
            guard pool.count > 1,
                  let picks = try? await state.ai.vibeStream(
                      candidates: pool.map { VibeCandidate(id: $0.id, line: Self.describe($0)) },
                      situation: state.situationSummary()
                  ),
                  !picks.isEmpty else { return }
            cache.store(
                ranking: picks.map(\.itemID),
                reasons: Dictionary(picks.map { ($0.itemID, "\($0.headline) — \($0.reason)") }, uniquingKeysWith: { first, _ in first }),
                near: here,
                now: now
            )
        }
        ordering = task
        return task
    }

    /// What's known around here for a category, nearest first; Everything gives each of its
    /// categories a share so none drowns, and adds events that have a place.
    private func pool(for category: RadarCategory, near here: CLLocation, state: AppState, now: Date) async -> [RadarItem] {
        var seen = Set<String>()
        var places: [PlaceSummary] = []
        let share = category.scanned.count > 1 ? 10 : 25
        for scanned in category.scanned {
            guard let known = cache.places(for: scanned, near: here, now: now) else { continue }
            let nearby = known.places
                .filter { $0.distanceMeters <= Self.searchRadius }
                .sorted { $0.distanceMeters < $1.distanceMeters }
            var taken = 0
            for place in nearby where taken < share && seen.insert(place.id).inserted {
                places.append(place)
                taken += 1
            }
        }

        let includeEvents = category == .all || category == .culture
        if includeEvents {
            await state.events.refresh(near: here)
        }
        // Only events with a place to go to. Online ones, and anything else without a location,
        // belong to your Day, not to what's around you.
        let events = includeEvents ? state.events.events.filter(Self.isPhysical).prefix(10).map(Self.item(from:)) : []
        var ids = Set<String>()
        return (events + places.map(Self.item(from:))).filter { ids.insert($0.id).inserted }
    }

    // MARK: Transit

    /// Stops by kind. PathOS's own metro and bus data knows which is which; Apple Maps only says
    /// "transit", so its stops are told apart by name, and only kept when PathOS doesn't already
    /// have them.
    private func transitItems(near here: CLLocation, state: AppState, now: Date) -> [RadarItem] {
        let own = state.transit.nearbyStops.map { stop in
            RadarItem(
                id: stop.id,
                title: stop.name,
                subtitle: stop.kind == .metro
                    ? (stop.subtitle.isEmpty ? "Metro station" : "Metro station · \(stop.subtitle)")
                    : stop.subtitle,
                symbol: stop.kind == .metro ? "tram.fill" : "bus.fill",
                latitude: stop.latitude,
                longitude: stop.longitude,
                distanceMeters: stop.distanceMeters,
                isEvent: false,
                section: stop.kind == .metro ? TransitKind.metro.section : TransitKind.bus.section
            )
        }
        let ownNames = own.map { TransitKind.plainName($0.title) }
        let fromMaps = (cache.places(for: .transit, near: here, now: now)?.places ?? [])
            .filter { $0.distanceMeters <= Self.searchRadius }
            .filter { place in
                let name = TransitKind.plainName(place.name)
                return !ownNames.contains { !$0.isEmpty && (name.contains($0) || $0.contains(name)) }
            }
            .map { place in
                let kind = TransitKind(name: place.name)
                return RadarItem(
                    id: "place:\(place.id)",
                    title: place.name,
                    subtitle: kind.label,
                    symbol: kind.symbol,
                    latitude: place.latitude,
                    longitude: place.longitude,
                    distanceMeters: place.distanceMeters,
                    isEvent: false,
                    section: kind.section
                )
            }
        let order = TransitKind.allCases.map(\.section)
        return (own + fromMaps).sorted { first, second in
            let a = order.firstIndex(of: first.section ?? "") ?? order.count
            let b = order.firstIndex(of: second.section ?? "") ?? order.count
            if a != b { return a < b }
            return (first.distanceMeters ?? .infinity) < (second.distanceMeters ?? .infinity)
        }
    }

    /// Something happening out there that you could walk to. Your own plans — events you added,
    /// your weekly schedule, trips, your calendar — are Day's, and mail you haven't added isn't
    /// a plan of anyone's yet: Radar is what's around you, not what you've already got on.
    static func isPhysical(_ event: LocalEvent) -> Bool {
        event.latitude != nil && event.longitude != nil && event.source == .scanned
    }

    private static func apply(_ ranking: RadarCache.Ranking, to pool: [RadarItem]) -> [RadarItem] {
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ranked = ranking.order.compactMap { id -> RadarItem? in
            guard var item = byID[id] else { return nil }
            item.reason = ranking.reasons[id]
            return item
        }
        let rankedIDs = Set(ranked.map(\.id))
        ranked += plainOrder(pool.filter { !rankedIDs.contains($0.id) })
        return ranked
    }

    private static func plainOrder(_ pool: [RadarItem]) -> [RadarItem] {
        pool.sorted { first, second in
            switch (first.start, second.start) {
            case let (a?, b?): a < b
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): (first.distanceMeters ?? .infinity) < (second.distanceMeters ?? .infinity)
            }
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
            // All day has no time to show or count down to.
            start: event.isAllDay ? nil : event.start,
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
