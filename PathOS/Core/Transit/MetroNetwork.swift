import CoreLocation
import Foundation

/// One station on one line, where the trains actually stop.
nonisolated struct MetroStation: Hashable, Sendable, Decodable {
    var name: String
    var lat: Double
    var lon: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// When a line runs and how often, as BMRCL publishes it.
nonisolated struct MetroServiceHours: Hashable, Sendable, Decodable {
    /// "monday", "weekday" (Tuesday to Saturday) and "sunday" → "HH:mm".
    var firstTrain: [String: String]
    /// The last trains leave the ends of the line around this time.
    var lastTrain: String
    var headwayPeak: Int
    var headwayOffPeak: Int
}

/// A metro line and its stations, in order from one terminus to the other.
nonisolated struct MetroLine: Identifiable, Hashable, Sendable, Decodable {
    var id: String
    var name: String
    var service: MetroServiceHours
    var stops: [MetroStation]

    private enum CodingKeys: String, CodingKey {
        case id, name, service
        case stops = "stations"
    }

    var stations: [String] { stops.map(\.name) }

    var termini: String { "\(stations.first ?? "") ↔ \(stations.last ?? "")" }

    /// The terminus a train is heading for, which is how platforms are signed.
    func terminus(from index: Int, to destination: Int) -> String {
        (destination >= index ? stations.last : stations.first) ?? ""
    }
}

nonisolated struct MetroFareSlab: Hashable, Sendable, Decodable {
    var upToStations: Int
    var fare: Int
}

nonisolated struct MetroFares: Hashable, Sendable, Decodable {
    var effective: String
    var basis: String
    var slabs: [MetroFareSlab]
    var sameStation: Int
    var smartCardDiscountPeak: Double
    var smartCardDiscountOffPeak: Double
}

nonisolated struct MetroSource: Hashable, Sendable, Decodable {
    var what: String
    var url: String
    var licence: String
    var retrieved: String
}

nonisolated struct MetroData: Sendable, Decodable {
    nonisolated struct Interchange: Hashable, Sendable, Decodable {
        var station: String
        var walkMinutes: Int
    }

    nonisolated struct PeakHours: Hashable, Sendable, Decodable {
        var days: String
        var windows: [[String]]
    }

    var lines: [MetroLine]
    var interchanges: [Interchange]
    var peakHours: PeakHours
    var fares: MetroFares
    var sources: [MetroSource]
    var generated: String
}

/// Namma Metro's operating network, bundled with the app.
///
/// Built by `Tools/TransitData/build.py`: station names and order from Wikipedia, coordinates from
/// OpenStreetMap, timings and fares as published — see `sources`. BMRCL publishes no real-time
/// feed, so PathOS never claims to know where a train is: it tracks *you* and estimates the rest.
nonisolated enum MetroNetwork {
    static let data: MetroData = {
        guard let url = Bundle.main.url(forResource: "metro", withExtension: "json"),
              let bytes = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(MetroData.self, from: bytes) else {
            preconditionFailure("metro.json is missing or unreadable. Run Tools/TransitData/build.py metro.")
        }
        return decoded
    }()

    static var lines: [MetroLine] { data.lines }

    static func line(id: String) -> MetroLine? {
        lines.first { $0.id == id }
    }

    /// Stations served by more than one line, for change-here hints.
    static func interchangeLines(for station: String) -> [MetroLine] {
        lines.filter { $0.stations.contains(station) }
    }

    /// Minutes to walk between platforms when changing lines here. A PathOS estimate.
    static func interchangeWalkMinutes(at station: String) -> Int {
        data.interchanges.first { $0.station == station }?.walkMinutes ?? 5
    }

    /// Every station once, alphabetically, for search.
    static var allStations: [String] {
        Array(Set(lines.flatMap(\.stations))).sorted()
    }

    static func stop(named name: String) -> MetroStation? {
        lines.lazy.flatMap(\.stops).first { $0.name == name }
    }

    /// The station nearest a point, if one is within `radius`.
    static func nearestStation(to coordinate: CLLocationCoordinate2D, within radius: Double = 1_500) -> MetroStation? {
        lines.flatMap(\.stops)
            .map { ($0, GeoMath.distance(from: coordinate, to: $0.coordinate)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }

    /// Stations worth listing from here, nearest first: every one within a walk, and never fewer
    /// than the nearest `atLeast`, however far, so there's always a way onto the metro. Past
    /// `limit` you're in another city, and none are.
    static func nearbyStations(
        to coordinate: CLLocationCoordinate2D,
        walkable: Double = 900,
        atLeast: Int = 3,
        limit: Double = 40_000
    ) -> [(station: MetroStation, distance: Double)] {
        var seen = Set<String>()
        // A station on two lines is listed under both; the nearest platform stands for it.
        let stations = lines.flatMap(\.stops)
            .map { (station: $0, distance: GeoMath.distance(from: coordinate, to: $0.coordinate)) }
            .sorted { $0.distance < $1.distance }
            .filter { $0.distance <= limit && seen.insert($0.station.name).inserted }
        return stations.enumerated()
            .filter { $0.offset < atLeast || $0.element.distance <= walkable }
            .map(\.element)
    }

    /// Names people actually say, for matching a trip leg typed as "MG Road to Majestic".
    static let aliases: [String: String] = [
        "mg road": "Mahatma Gandhi Road",
        "majestic": "Nadaprabhu Kempegowda Station, Majestic",
        "kempegowda": "Nadaprabhu Kempegowda Station, Majestic",
        "kr puram": "Krishnarajapura (K.R.Pura)",
        "k r puram": "Krishnarajapura (K.R.Pura)",
        "vidhana soudha": "Dr. B.R. Ambedkar Station, Vidhana Soudha",
        "central college": "Sir M. Visvesvaraya Station, Central College",
        "city railway station": "Krantivira Sangolli Rayanna Railway Station",
        "ksr railway station": "Krantivira Sangolli Rayanna Railway Station",
        "ksr bengaluru": "Krantivira Sangolli Rayanna Railway Station",
        "hosahalli": "Sri Balagangadharanatha Swamiji Station, Hosahalli",
        "mysore road": "Mysuru Road",
        "rv road": "Rashtreeya Vidyalaya Road",
        "jp nagar": "Jaya Prakash Nagar",
        "kr market": "Krishna Rajendra Market",
        "silk board": "Central Silk Board",
        "yeshwantpur": "Yeshwanthpur",
        "sampige road": "Mantri Square Sampige Road",
        "bommasandra": "Delta Electronics Bommasandra",
    ]

    /// The station a typed name means, if it's clear which one.
    static func station(matching text: String) -> String? {
        let key = text.lowercased()
            .replacingOccurrences(of: "metro station", with: "")
            .replacingOccurrences(of: "metro", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !key.isEmpty else { return nil }
        if let alias = aliases[key] { return alias }
        if let exact = allStations.first(where: { $0.lowercased() == key }) { return exact }
        let containing = allStations.filter { $0.lowercased().contains(key) }
        return containing.count == 1 ? containing[0] : nil
    }
}
