import Foundation

/// What an auto, a bike taxi or a cab costs for a given distance.
///
/// Bengaluru's auto fare is set by the city, so it can be worked out. App fares can't: they move
/// with demand, so every figure here is a range, and each mode says where its numbers come from.
/// Nothing in PathOS ever calls one of these a price.
nonisolated struct RoadFareRate: Hashable, Sendable, Decodable {
    var id: String
    var name: String
    /// Covers the first `baseKm`.
    var base: Double
    var baseKm: Double
    var perKm: Double
    var minimum: Double
    var nightMultiplier: Double
    var nightFrom: String
    var nightTo: String
    /// How far the real fare tends to sit either side of the estimate.
    var spread: Double
    var note: String
}

nonisolated struct RoadFareData: Sendable, Decodable {
    var modes: [RoadFareRate]
    var sources: [MetroSource]
    var generated: String
}

/// A fare as PathOS is willing to state it: a range, never a price.
nonisolated struct FareEstimate: Hashable, Sendable {
    var low: Int
    var high: Int
    /// The city sets this one, so the meter should agree.
    var isRegulated: Bool

    /// "about ₹90" when the range is tight, "₹90–130" when it isn't.
    var text: String {
        low == high || Double(high - low) / Double(max(1, low)) < 0.12
            ? "about ₹\(low)"
            : .range("₹\(low)", "\(high)")
    }
}

nonisolated enum RoadFares {
    static let data: RoadFareData = {
        guard let url = Bundle.main.url(forResource: "road-fares", withExtension: "json"),
              let bytes = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RoadFareData.self, from: bytes) else {
            preconditionFailure("road-fares.json is missing or unreadable.")
        }
        return decoded
    }()

    static func rate(_ id: String) -> RoadFareRate? {
        data.modes.first { $0.id == id }
    }

    /// The fare for a distance, at a time of day. Distances are road distances where Apple Maps
    /// gave one; a straight line under-reads, and the estimate is low to that extent.
    static func estimate(_ rate: RoadFareRate, distanceMeters: Double, at date: Date, calendar: Calendar = .current) -> FareEstimate {
        let km = max(0, distanceMeters / 1_000)
        let metered = rate.base + max(0, km - rate.baseKm) * rate.perKm
        let night = isNight(date, rate: rate, calendar: calendar) ? rate.nightMultiplier : 1
        let middle = max(rate.minimum, metered) * night
        return FareEstimate(
            low: Int((middle * (1 - rate.spread / 2) / 5).rounded() * 5),
            high: Int((middle * (1 + rate.spread / 2) / 5).rounded() * 5),
            isRegulated: rate.spread <= 0.15
        )
    }

    static func isNight(_ date: Date, rate: RoadFareRate, calendar: Calendar = .current) -> Bool {
        guard let from = minutes(rate.nightFrom), let to = minutes(rate.nightTo) else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        // The night rate runs across midnight.
        return from > to ? (minute >= from || minute < to) : (minute >= from && minute < to)
    }

    private static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }
}
