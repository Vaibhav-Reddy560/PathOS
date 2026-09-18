import CoreLocation
import Foundation

/// A place or event surfaced by Radar.
nonisolated struct RadarItem: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    /// Set when Apple Intelligence picked this item, with its one-line reason.
    var reason: String?
    var symbol: String
    var latitude: Double?
    var longitude: Double?
    var distanceMeters: Double?
    var start: Date?
    var isEvent: Bool
}

/// Which families of signals are drawn on the map.
nonisolated struct MapLayers: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let rings = MapLayers(rawValue: 1 << 0)
    static let places = MapLayers(rawValue: 1 << 1)
    static let events = MapLayers(rawValue: 1 << 2)
    static let memories = MapLayers(rawValue: 1 << 3)
    static let transit = MapLayers(rawValue: 1 << 4)

    static let all: MapLayers = [.rings, .places, .events, .memories, .transit]
}

/// Anything PathOS draws on the map, already carrying what its colour means.
nonisolated struct WorldSignal: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: String, Sendable {
        case memory
        case home
        case work
        case place
        case event
        case assistantPick
        case transitStop

        var spokenName: String {
            switch self {
            case .memory: "saved spot"
            case .home: "home"
            case .work: "work"
            case .place: "place"
            case .event: "event"
            case .assistantPick: "suggested place"
            case .transitStop: "stop"
            }
        }
    }

    var id: String
    var kind: Kind
    var role: SignalRole
    var title: String
    var subtitle: String
    var symbol: String
    var latitude: Double
    var longitude: Double
    /// Geofence radius for memories and saved places, drawn as a faint ring.
    var radius: Double?
    var distanceMeters: Double?
    var start: Date?
    var reason: String?
    /// Picked by Apple Intelligence or named in an assistant answer.
    var isHighlighted = false

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var accessibilityLabel: String {
        var parts = ["\(role.spokenPrefix) \(kind.spokenName), \(title)"]
        if let distanceMeters {
            parts.append("\(GeoMath.formatDistance(distanceMeters)), \(GeoMath.walkingMinutes(forDistance: distanceMeters)) minute walk")
        }
        if let start {
            parts.append("starts \(start.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: ", ")
    }
}

/// A bus stop or metro station near you, for the map's transit layer.
nonisolated struct TransitStopInput: Hashable, Sendable {
    nonisolated enum Kind: String, Sendable {
        case bus
        case metro
    }

    var kind: Kind
    var name: String
    var subtitle: String
    var latitude: Double
    var longitude: Double
    var distanceMeters: Double

    /// "bus:Indiranagar 100 Feet Road", "metro:Indiranagar".
    var id: String { "\(kind.rawValue):\(name)" }
}

nonisolated struct MemoryInput: Sendable {
    var id: UUID
    var title: String
    var body: String
    var latitude: Double
    var longitude: Double
    var radius: Double
}

nonisolated struct SavedPlaceInput: Sendable {
    var id: UUID
    var kind: PlaceKind
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double
}

/// Turns app data into map signals. Green is only ever things that come from you; cyan is the world.
nonisolated enum WorldSignalBuilder {
    static let maxWorldSignals = 24
    static let maxTransitSignals = 10
    /// World signals closer than this are where you already are: they'd bury your dot, and the
    /// instrument strip already names the venue. AI and assistant picks are still shown.
    static let hereRadius = 35.0
    /// Events starting this soon ask for attention (amber).
    static let eventSoonWindow: TimeInterval = 60 * 60

    static func build(
        memories: [MemoryInput],
        places: [SavedPlaceInput],
        radar: [RadarItem],
        assistantPlaces: [PlaceSummary],
        transit: [TransitStopInput] = [],
        origin: CLLocationCoordinate2D?,
        layers: MapLayers = .all,
        now: Date = Date()
    ) -> [WorldSignal] {
        var world: [WorldSignal] = []
        var seen = Set<String>()

        for item in radar {
            guard let latitude = item.latitude, let longitude = item.longitude, seen.insert(item.id).inserted else { continue }
            let isEvent = item.isEvent || item.start != nil
            guard layers.contains(isEvent ? .events : .places) else { continue }
            world.append(WorldSignal(
                id: item.id,
                kind: isEvent ? .event : .place,
                role: isEvent ? eventRole(start: item.start, now: now) : .world,
                title: item.title,
                subtitle: item.subtitle,
                symbol: item.symbol,
                latitude: latitude,
                longitude: longitude,
                distanceMeters: item.distanceMeters,
                start: item.start,
                reason: item.reason,
                isHighlighted: item.reason != nil
            ))
        }

        if layers.contains(.places) {
            for place in assistantPlaces {
                let id = "place:\(place.id)"
                if let index = world.firstIndex(where: { $0.id == id }) {
                    world[index].isHighlighted = true
                    continue
                }
                guard seen.insert(id).inserted else { continue }
                world.append(WorldSignal(
                    id: id,
                    kind: .assistantPick,
                    role: .world,
                    title: place.name,
                    subtitle: place.categoryName,
                    symbol: place.symbol,
                    latitude: place.latitude,
                    longitude: place.longitude,
                    distanceMeters: place.distanceMeters,
                    isHighlighted: true
                ))
            }
        }

        world.removeAll { !$0.isHighlighted && ($0.distanceMeters ?? .infinity) < hereRadius }

        // Keep the map calm: highlighted signals always stay, then the nearest.
        world.sort { first, second in
            if first.isHighlighted != second.isHighlighted { return first.isHighlighted }
            return (first.distanceMeters ?? .infinity) < (second.distanceMeters ?? .infinity)
        }
        world = Array(world.prefix(maxWorldSignals))

        // Stops sit under everything else: useful to find, never worth burying a place for.
        if layers.contains(.transit) {
            let stops = transit.filter { seen.insert($0.id).inserted }.sorted { $0.distanceMeters < $1.distanceMeters }.prefix(maxTransitSignals)
            world = stops.map { stop in
                WorldSignal(
                    id: stop.id,
                    kind: .transitStop,
                    role: .world,
                    title: stop.name,
                    subtitle: stop.subtitle,
                    symbol: stop.kind == .metro ? "tram.fill" : "bus.fill",
                    latitude: stop.latitude,
                    longitude: stop.longitude,
                    distanceMeters: stop.distanceMeters
                )
            } + world
        }

        var yours: [WorldSignal] = []
        if layers.contains(.memories) {
            for place in places where place.kind != .other {
                yours.append(WorldSignal(
                    id: "place:\(place.id.uuidString)",
                    kind: place.kind == .home ? .home : .work,
                    role: .you,
                    title: place.name,
                    subtitle: place.kind.label,
                    symbol: place.kind.symbol,
                    latitude: place.latitude,
                    longitude: place.longitude,
                    radius: place.radius,
                    distanceMeters: distance(from: origin, to: place.latitude, place.longitude)
                ))
            }
            for memory in memories {
                yours.append(WorldSignal(
                    id: "note:\(memory.id.uuidString)",
                    kind: .memory,
                    role: .you,
                    title: memory.title,
                    subtitle: memory.body,
                    symbol: "mappin.and.ellipse",
                    latitude: memory.latitude,
                    longitude: memory.longitude,
                    radius: memory.radius,
                    distanceMeters: distance(from: origin, to: memory.latitude, memory.longitude)
                ))
            }
        }

        // Yours last so they draw on top of world signals.
        return world + yours
    }

    static func eventRole(start: Date?, now: Date) -> SignalRole {
        guard let start else { return .world }
        let untilStart = start.timeIntervalSince(now)
        return untilStart >= 0 && untilStart <= eventSoonWindow ? .attention : .world
    }

    private static func distance(from origin: CLLocationCoordinate2D?, to latitude: Double, _ longitude: Double) -> Double? {
        guard let origin else { return nil }
        return GeoMath.distance(from: origin, to: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
    }
}
