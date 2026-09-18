import CoreLocation
import Foundation
import SwiftData

/// A note pinned to a physical spot (parking pillar, locker code…) that resurfaces when you return.
@Model
final class SpatialNote {
    var id: UUID = UUID()
    var title: String = ""
    var body: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var radius: Double = 60
    /// The first photo, kept for thumbnails and Lock Screen previews.
    @Attribute(.externalStorage) var photoData: Data?
    @Relationship(deleteRule: .cascade, inverse: \NotePhoto.note) var photos: [NotePhoto] = []
    /// What kind of place this is, for you: preset or your own words.
    var tags: [String] = []
    var createdAt: Date = Date()
    var lastSurfacedAt: Date?
    var isActive: Bool = true

    init(title: String, body: String, coordinate: CLLocationCoordinate2D, radius: Double = 60, photoData: Data? = nil) {
        self.title = title
        self.body = body
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.radius = radius
        self.photoData = photoData
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var geofenceID: String { "note:\(id.uuidString)" }

    /// Every photo, newest last, with the original single photo first.
    var allPhotoData: [Data] {
        (photoData.map { [$0] } ?? []) + photos.sorted { $0.createdAt < $1.createdAt }.map(\.data)
    }
}

/// An extra photo attached to a memory.
@Model
final class NotePhoto {
    var id: UUID = UUID()
    @Attribute(.externalStorage) var data: Data = Data()
    var createdAt: Date = Date()
    var note: SpatialNote?

    init(data: Data) {
        self.data = data
    }
}

/// Starting points for tagging a place; you can always type your own.
nonisolated enum PlaceTagPresets {
    static let all = ["Parking", "Home", "Work", "Study", "Food", "Shop", "Friend's place", "Transit"]
}
