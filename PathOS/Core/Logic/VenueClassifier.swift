import CoreLocation
import Foundation

nonisolated enum VenueKind: String, Codable, CaseIterable, Sendable {
    case home
    case work
    case transit
    case shopping
    case dining
    case outdoors
    case entertainment
    case unknown

    var label: String {
        switch self {
        case .home: "Home"
        case .work: "Office"
        case .transit: "Transit hub"
        case .shopping: "Shopping"
        case .dining: "Dining"
        case .outdoors: "Outdoors"
        case .entertainment: "Entertainment"
        case .unknown: "On the move"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .work: "briefcase.fill"
        case .transit: "tram.fill"
        case .shopping: "bag.fill"
        case .dining: "fork.knife"
        case .outdoors: "leaf.fill"
        case .entertainment: "theatermasks.fill"
        case .unknown: "location.fill"
        }
    }
}

nonisolated enum POIGroup: String, Codable, Sendable {
    case transit
    case shopping
    case dining
    case outdoors
    case entertainment
    case other
}

nonisolated struct VenueContext: Equatable, Sendable {
    var kind: VenueKind
    var name: String?

    static let unknown = VenueContext(kind: .unknown, name: nil)
}

nonisolated struct PlaceFence: Sendable {
    var kind: PlaceKind
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double
}

nonisolated struct NearbyPOI: Sendable {
    var group: POIGroup
    var name: String
    var distanceMeters: Double
}

nonisolated enum VenueClassifier {
    /// A POI counts as "where you are" only if it is this close.
    static let poiMatchRadius = 60.0

    static func classify(location: CLLocationCoordinate2D, places: [PlaceFence], nearby: [NearbyPOI]) -> VenueContext {
        let containing = places
            .map { place in
                (place, GeoMath.distance(from: location, to: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)))
            }
            .filter { $0.1 <= $0.0.radius }
            .sorted { $0.1 < $1.1 }

        if let match = containing.first {
            switch match.0.kind {
            case .home: return VenueContext(kind: .home, name: match.0.name)
            case .work: return VenueContext(kind: .work, name: match.0.name)
            case .other: break
            }
        }

        let closest = nearby
            .filter { $0.distanceMeters <= poiMatchRadius && $0.group != .other }
            .min { $0.distanceMeters < $1.distanceMeters }

        guard let poi = closest else {
            return VenueContext(kind: .unknown, name: containing.first?.0.name)
        }
        return VenueContext(kind: venueKind(for: poi.group), name: poi.name)
    }

    static func venueKind(for group: POIGroup) -> VenueKind {
        switch group {
        case .transit: .transit
        case .shopping: .shopping
        case .dining: .dining
        case .outdoors: .outdoors
        case .entertainment: .entertainment
        case .other: .unknown
        }
    }
}
