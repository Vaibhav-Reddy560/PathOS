import CoreLocation
import Foundation
import Observation
import SwiftData

/// Spatial notes and saved places, and which of them iOS is watching as geofences.
@Observable
final class SpatialVaultService {
    static let resurfaceCooldown: TimeInterval = 30 * 60
    static let minimumRadius = 50.0

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let geofences: GeofenceMonitor

    init(context: ModelContext, geofences: GeofenceMonitor) {
        self.context = context
        self.geofences = geofences
    }

    // MARK: Notes

    @discardableResult
    func saveNote(
        title: String,
        body: String,
        at coordinate: CLLocationCoordinate2D,
        radius: Double = 80,
        photoData: Data? = nil,
        extraPhotos: [Data] = [],
        tags: [String] = []
    ) -> SpatialNote {
        let note = SpatialNote(
            title: title,
            body: body,
            coordinate: coordinate,
            radius: max(radius, Self.minimumRadius),
            photoData: photoData
        )
        note.tags = tags
        note.lastSurfacedAt = Date()
        context.insert(note)
        for data in extraPhotos {
            let photo = NotePhoto(data: data)
            photo.note = note
            context.insert(photo)
        }
        save()
        return note
    }

    func delete(_ note: SpatialNote) async {
        await geofences.remove(id: note.geofenceID)
        context.delete(note)
        save()
    }

    func activeNotes() -> [SpatialNote] {
        let descriptor = FetchDescriptor<SpatialNote>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func notes(near location: CLLocation, within meters: Double) -> [SpatialNote] {
        activeNotes()
            .filter { location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= max(meters, $0.radius) }
    }

    func note(forGeofenceID id: String) -> SpatialNote? {
        guard id.hasPrefix("note:"), let uuid = UUID(uuidString: String(id.dropFirst(5))) else { return nil }
        let descriptor = FetchDescriptor<SpatialNote>(predicate: #Predicate { $0.id == uuid })
        return try? context.fetch(descriptor).first
    }

    func note(withID uuid: UUID) -> SpatialNote? {
        let descriptor = FetchDescriptor<SpatialNote>(predicate: #Predicate { $0.id == uuid })
        return try? context.fetch(descriptor).first
    }

    func shouldSurface(_ note: SpatialNote, now: Date = Date()) -> Bool {
        guard let last = note.lastSurfacedAt else { return true }
        return now.timeIntervalSince(last) >= Self.resurfaceCooldown
    }

    func markSurfaced(_ note: SpatialNote) {
        note.lastSurfacedAt = Date()
        save()
    }

    // MARK: Places

    func allPlaces() -> [SavedPlace] {
        (try? context.fetch(FetchDescriptor<SavedPlace>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    func place(ofKind kind: PlaceKind) -> SavedPlace? {
        allPlaces().first { $0.kind == kind }
    }

    func place(forGeofenceID id: String) -> SavedPlace? {
        guard id.hasPrefix("place:"), let uuid = UUID(uuidString: String(id.dropFirst(6))) else { return nil }
        return allPlaces().first { $0.id == uuid }
    }

    /// Home and Work are unique; setting them again moves the existing place.
    @discardableResult
    func setPlace(_ kind: PlaceKind, name: String, at coordinate: CLLocationCoordinate2D, radius: Double = 120) -> SavedPlace {
        if kind != .other, let existing = place(ofKind: kind) {
            existing.name = name
            existing.latitude = coordinate.latitude
            existing.longitude = coordinate.longitude
            existing.radius = radius
            save()
            return existing
        }
        let place = SavedPlace(name: name, kind: kind, coordinate: coordinate, radius: radius)
        context.insert(place)
        save()
        return place
    }

    func delete(_ place: SavedPlace) async {
        await geofences.remove(id: place.geofenceID)
        context.delete(place)
        save()
    }

    // MARK: Geofences

    /// Saved places always get a slot; the remaining slots go to the closest notes.
    func syncGeofences(userLocation: CLLocation?) async {
        func isInside(_ latitude: Double, _ longitude: Double, _ radius: Double) -> Bool {
            guard let userLocation else { return false }
            return userLocation.distance(from: CLLocation(latitude: latitude, longitude: longitude)) <= radius
        }

        let places = allPlaces().sorted { $0.kind.rawValue < $1.kind.rawValue }
        var regions = places.map {
            GeofenceRegion(id: $0.geofenceID, latitude: $0.latitude, longitude: $0.longitude, radius: $0.radius,
                           userIsInside: isInside($0.latitude, $0.longitude, $0.radius))
        }

        var notes = activeNotes()
        if let userLocation {
            notes.sort {
                userLocation.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                    < userLocation.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
            }
        }
        let freeSlots = max(0, GeofenceMonitor.maxRegions - regions.count)
        regions += notes.prefix(freeSlots).map {
            GeofenceRegion(id: $0.geofenceID, latitude: $0.latitude, longitude: $0.longitude, radius: $0.radius,
                           userIsInside: isInside($0.latitude, $0.longitude, $0.radius))
        }

        await geofences.sync(regions)
    }

    private func save() {
        try? context.save()
    }
}
