import CoreLocation
import Foundation

/// Places Radar found around you, kept for a few days per area.
///
/// Cafés and parks don't move in three days, so Radar scans an area once and reuses what it
/// found while you're anywhere near it. Only a new area, a stale scan or a pull to refresh scans
/// again.
nonisolated struct RadarCache: Codable, Sendable {
    nonisolated struct Entry: Codable, Sendable {
        var category: String
        var latitude: Double
        var longitude: Double
        var savedAt: Date
        var places: [PlaceSummary]
    }

    /// Apple Intelligence's ordering of what was found in an area, made once when it was scanned.
    nonisolated struct Ranking: Codable, Sendable {
        var latitude: Double
        var longitude: Double
        var savedAt: Date
        /// Item ids, best first.
        var order: [String]
        /// One line on why, by item id.
        var reasons: [String: String]
    }

    /// How long a scan is trusted.
    static let freshFor: TimeInterval = 3 * 86_400
    /// A scan covers 1.5 km around where it was made, so it still serves you this far from there.
    static let reuseWithin: CLLocationDistance = 400
    /// The most recent scans kept.
    static let capacity = 80

    private(set) var entries: [Entry] = []
    private(set) var rankings: [Ranking] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case entries
        case rankings
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([Entry].self, forKey: .entries)
        // Caches saved before orderings were kept have none.
        rankings = try container.decodeIfPresent([Ranking].self, forKey: .rankings) ?? []
    }

    /// The places from a fresh scan of this category near you, their distances measured from
    /// where you are now, and when it was made. Nil when there's none and it's time to scan.
    func places(for category: RadarCategory, near location: CLLocation, now: Date) -> (places: [PlaceSummary], savedAt: Date)? {
        let nearest = entries
            .filter { $0.category == category.rawValue && now.timeIntervalSince($0.savedAt) < Self.freshFor }
            .map { entry in (entry, location.distance(from: CLLocation(latitude: entry.latitude, longitude: entry.longitude))) }
            .filter { $0.1 <= Self.reuseWithin }
            .min { $0.1 < $1.1 }?.0
        guard let nearest else { return nil }
        let places = nearest.places.map { place in
            var measured = place
            measured.distanceMeters = location.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
            return measured
        }
        return (places, nearest.savedAt)
    }

    /// The ordering made when this area was last scanned, if it's still fresh.
    func ranking(near location: CLLocation, now: Date) -> Ranking? {
        rankings
            .filter { now.timeIntervalSince($0.savedAt) < Self.freshFor }
            .map { ranking in (ranking, location.distance(from: CLLocation(latitude: ranking.latitude, longitude: ranking.longitude))) }
            .filter { $0.1 <= Self.reuseWithin }
            .min { $0.1 < $1.1 }?.0
    }

    mutating func store(ranking order: [String], reasons: [String: String], near location: CLLocation, now: Date) {
        rankings.removeAll { ranking in
            now.timeIntervalSince(ranking.savedAt) >= Self.freshFor
                || location.distance(from: CLLocation(latitude: ranking.latitude, longitude: ranking.longitude)) <= Self.reuseWithin
        }
        rankings.append(Ranking(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                savedAt: now, order: order, reasons: reasons))
        if rankings.count > Self.capacity {
            rankings = Array(rankings.sorted { $0.savedAt > $1.savedAt }.prefix(Self.capacity))
        }
    }

    /// Keeps a scan, replacing any of the same category that it now covers, and drops stale ones.
    mutating func store(_ places: [PlaceSummary], for category: RadarCategory, near location: CLLocation, now: Date) {
        entries.removeAll { entry in
            now.timeIntervalSince(entry.savedAt) >= Self.freshFor
                || (entry.category == category.rawValue
                    && location.distance(from: CLLocation(latitude: entry.latitude, longitude: entry.longitude)) <= Self.reuseWithin)
        }
        entries.append(Entry(category: category.rawValue, latitude: location.coordinate.latitude,
                             longitude: location.coordinate.longitude, savedAt: now, places: places))
        if entries.count > Self.capacity {
            entries = Array(entries.sorted { $0.savedAt > $1.savedAt }.prefix(Self.capacity))
        }
    }
}

extension RadarCache {
    private static func url(named name: String) -> URL? {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return folder.appending(path: "\(name)-cache.json")
    }

    /// What was saved under this name, or an empty cache.
    static func load(named name: String) -> RadarCache {
        guard let url = url(named: name), let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(RadarCache.self, from: data) else { return RadarCache() }
        return cache
    }

    func save(named name: String) {
        guard let url = Self.url(named: name), let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// What kind of stop a transit place is, told from its name: Apple Maps files metro stations,
/// bus stops and railway stations alike under "public transport".
nonisolated enum TransitKind: CaseIterable, Sendable {
    case metro
    case bus
    case rail
    case auto
    case other

    init(name: String) {
        let lower = name.lowercased()
        if lower.contains("metro") || lower.contains("namma") {
            self = .metro
        } else if ["railway", "train", "junction", "rail station", "halt"].contains(where: lower.contains) {
            self = .rail
        } else if ["auto", "taxi", "cab", "rickshaw"].contains(where: lower.contains) {
            // "Auto Stand" is where autos wait, not a bus stop.
            self = .auto
        } else if ["bus", "bmtc", "depot"].contains(where: lower.contains) {
            self = .bus
        } else {
            self = .other
        }
    }

    var section: String {
        switch self {
        case .metro: "Metro stations"
        case .bus: "Bus stops"
        case .rail: "Train stations"
        case .auto: "Auto & taxi stands"
        case .other: "Other stops"
        }
    }

    var label: String {
        switch self {
        case .metro: "Metro station"
        case .bus: "Bus stop"
        case .rail: "Railway station"
        case .auto: "Auto stand"
        case .other: "Transit stop"
        }
    }

    var symbol: String {
        switch self {
        case .metro: "tram.fill"
        case .bus: "bus.fill"
        case .rail: "train.side.front.car"
        case .auto: "car.side.fill"
        case .other: "mappin.and.ellipse"
        }
    }

    /// "Indiranagar Metro Station" → "indiranagar", to match against PathOS's own station names.
    static func plainName(_ name: String) -> String {
        var plain = name.lowercased()
        for word in ["metro station", "metro", "bus stop", "bus stand", "station", "stop"] {
            plain = plain.replacingOccurrences(of: word, with: "")
        }
        return plain.filter { $0.isLetter || $0.isNumber }
    }
}
