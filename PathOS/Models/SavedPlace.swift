import CoreLocation
import Foundation
import SwiftData

nonisolated enum PlaceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case home
    case work
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: "Home"
        case .work: "Work"
        case .other: "Place"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .work: "briefcase.fill"
        case .other: "mappin.circle.fill"
        }
    }
}

@Model
final class SavedPlace {
    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = PlaceKind.other.rawValue
    var latitude: Double = 0
    var longitude: Double = 0
    var radius: Double = 120
    var createdAt: Date = Date()

    init(name: String, kind: PlaceKind, coordinate: CLLocationCoordinate2D, radius: Double = 120) {
        self.name = name
        self.kindRaw = kind.rawValue
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.radius = radius
    }

    var kind: PlaceKind {
        get { PlaceKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var geofenceID: String { "place:\(id.uuidString)" }
}
