import CoreLocation
import MapKit
import Observation

/// Apple's full record for a place — address, phone, website — plus its Look Around scene.
/// Radar already stores Apple's own identifier in `PlaceSummary.id`, so any place can be
/// looked up again on demand instead of being fetched up front.
@Observable
final class PlaceDetailsService {
    private(set) var items: [String: MKMapItem] = [:]
    private(set) var scenes: [String: MKLookAroundScene] = [:]
    /// Ids we've finished with, so a place without Look Around isn't requested forever.
    @ObservationIgnored private var resolved: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []

    func item(for id: String) -> MKMapItem? { items[id] }
    func scene(for id: String) -> MKLookAroundScene? { scenes[id] }

    func load(id: String, coordinate: CLLocationCoordinate2D, name: String) async {
        guard !resolved.contains(id), !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer {
            inFlight.remove(id)
            resolved.insert(id)
        }

        let item = await mapItem(id: id, coordinate: coordinate, name: name)
        items[id] = item
        scenes[id] = await lookAround(for: item, coordinate: coordinate)
    }

    /// Apple's record when the signal came from Maps, otherwise a plain item at the coordinate
    /// (memories and saved places aren't in Apple's database).
    private func mapItem(id: String, coordinate: CLLocationCoordinate2D, name: String) async -> MKMapItem {
        if let rawValue = Self.appleIdentifier(from: id),
           let identifier = MKMapItem.Identifier(rawValue: rawValue),
           let item = try? await MKMapItemRequest(mapItemIdentifier: identifier).mapItem {
            return item
        }
        let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        item.name = name
        return item
    }

    private func lookAround(for item: MKMapItem, coordinate: CLLocationCoordinate2D) async -> MKLookAroundScene? {
        if let scene = try? await MKLookAroundSceneRequest(mapItem: item).scene {
            return scene
        }
        return try? await MKLookAroundSceneRequest(coordinate: coordinate).scene
    }

    /// `place:I1234…` and `venue:I1234…` → `I1234…`. Radar's fallback ids (`name@lat,lng`),
    /// scanned events and our own saved places (UUIDs) aren't Apple identifiers.
    static func appleIdentifier(from id: String) -> String? {
        let prefixes = ["place:", "venue:"]
        guard let prefix = prefixes.first(where: { id.hasPrefix($0) }) else { return nil }
        let rawValue = String(id.dropFirst(prefix.count))
        guard !rawValue.isEmpty, !rawValue.contains("@"), UUID(uuidString: rawValue) == nil else { return nil }
        return rawValue
    }
}
