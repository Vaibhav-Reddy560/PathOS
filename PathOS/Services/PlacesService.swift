import CoreLocation
import MapKit
import Observation

nonisolated struct PlaceSummary: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var categoryName: String
    var group: POIGroup
    var symbol: String
    var latitude: Double
    var longitude: Double
    var distanceMeters: Double
    var phone: String?
    var url: URL?
    /// Street and area, for a search result.
    var address: String? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var walkMinutes: Int { GeoMath.walkingMinutes(forDistance: distanceMeters) }
}

nonisolated struct WalkingRoute: Sendable {
    var coordinates: [CLLocationCoordinate2D]
    var distanceMeters: Double
    var minutes: Int
}

nonisolated enum RadarCategory: String, CaseIterable, Identifiable, Sendable {
    case all
    case food
    case nightlife
    case culture
    case outdoors
    case transit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "Everything"
        case .food: "Food & Coffee"
        case .nightlife: "Nightlife"
        case .culture: "Shows & Culture"
        case .outdoors: "Outdoors"
        case .transit: "Transit"
        }
    }

    var symbol: String {
        switch self {
        case .all: "sparkles"
        case .food: "cup.and.saucer.fill"
        case .nightlife: "wineglass.fill"
        case .culture: "theatermasks.fill"
        case .outdoors: "tree.fill"
        case .transit: "tram.fill"
        }
    }

    /// What Radar scans for this category: Everything is each of the others, scanned on its own,
    /// since one combined search comes back as a single short list that some categories miss.
    var scanned: [RadarCategory] {
        self == .all ? [.food, .nightlife, .culture, .outdoors] : [self]
    }

    var poiCategories: [MKPointOfInterestCategory] {
        switch self {
        case .all: Self.food.poiCategories + Self.nightlife.poiCategories + Self.culture.poiCategories + Self.outdoors.poiCategories
        case .food: [.cafe, .restaurant, .bakery]
        case .nightlife: [.nightlife, .brewery, .winery]
        case .culture: [.theater, .movieTheater, .museum, .stadium]
        case .outdoors: [.park, .nationalPark, .beach]
        case .transit: [.publicTransport]
        }
    }
}

@Observable
final class PlacesService {
    /// Browse a category around a location (no text query).
    func browse(_ category: RadarCategory, near location: CLLocation, radius: CLLocationDistance = 1_500) async throws -> [PlaceSummary] {
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: category.poiCategories)
        let response = try await MKLocalSearch(request: request).start()
        return Self.summarize(response.mapItems, from: location)
    }

    /// Free-text search ("filter coffee", "rooftop bar") near a location.
    func search(_ query: String, near location: CLLocation, radius: CLLocationDistance = 2_000) async throws -> [PlaceSummary] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest
        request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        let response = try await MKLocalSearch(request: request).start()
        return Self.summarize(response.mapItems, from: location).filter { $0.distanceMeters <= radius * 1.5 }
    }

    /// Anything Apple Maps knows by that name or address, in its order of relevance: places and
    /// addresses, looked for around you first but not only there.
    func find(_ query: String, near location: CLLocation?) async throws -> [PlaceSummary] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let location {
            request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.map { item in
            let coordinate = item.location.coordinate
            let description = Self.describe(item.pointOfInterestCategory)
            return PlaceSummary(
                id: item.identifier?.rawValue ?? "\(item.name ?? "place")@\(coordinate.latitude),\(coordinate.longitude)",
                name: item.name ?? item.address?.shortAddress ?? "Unnamed place",
                categoryName: item.pointOfInterestCategory == nil ? "Address" : description.name,
                group: description.group,
                symbol: item.pointOfInterestCategory == nil ? "mappin.and.ellipse" : description.symbol,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                distanceMeters: location.map { $0.distance(from: item.location) } ?? 0,
                phone: item.phoneNumber,
                url: item.url,
                address: item.address?.shortAddress
            )
        }
    }

    /// Very close POIs, used to work out what kind of venue you're standing in.
    func nearbyPOIs(around location: CLLocation) async -> [NearbyPOI] {
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: 150)
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        return Self.summarize(response.mapItems, from: location).map {
            NearbyPOI(group: $0.group, name: $0.name, distanceMeters: $0.distanceMeters)
        }
    }

    func nearestTransitStation(to location: CLLocation) async -> PlaceSummary? {
        try? await browse(.transit, near: location, radius: 2_000).first
    }

    /// Travel time in minutes, or nil where Apple Maps has no route (transit coverage varies in India).
    func eta(to destination: CLLocationCoordinate2D, from origin: CLLocation, transport: MKDirectionsTransportType) async -> Int? {
        await hop(to: destination, from: origin, transport: transport)?.minutes
    }

    /// How long a hop takes and how far it runs by that mode. The distance is the route's, not a
    /// straight line, which is what a fare is worked out from.
    func hop(to destination: CLLocationCoordinate2D, from origin: CLLocation,
             transport: MKDirectionsTransportType) async -> (minutes: Int, distanceMeters: Double)? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: origin, address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = transport
        guard let response = try? await MKDirections(request: request).calculateETA() else { return nil }
        return (Int((response.expectedTravelTime / 60).rounded(.up)), response.distance)
    }

    /// A route with its turns, for following a leg on the map. Apple Maps has no two-wheeler
    /// mode, so a scooter or a bike taxi follows the car's route, which is the same road.
    func directions(to destination: CLLocationCoordinate2D, from origin: CLLocation,
                    byRoad: Bool) async -> NavRoute? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: origin, address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = byRoad ? .automobile : .walking
        guard let route = try? await MKDirections(request: request).calculate().routes.first else { return nil }
        return NavRoute(
            coordinates: Self.coordinates(of: route.polyline),
            steps: route.steps.compactMap { step in
                let shape = Self.coordinates(of: step.polyline)
                guard shape.count > 1 else { return nil }
                return StepGuide.Step(instruction: step.instructions, coordinates: shape, distanceMeters: step.distance)
            },
            minutes: max(1, Int((route.expectedTravelTime / 60).rounded())),
            distanceMeters: route.distance,
            byRoad: byRoad
        )
    }

    static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates
    }

    /// Walking route for the green guidance line, or nil where Apple Maps has no route.
    func walkingRoute(to destination: CLLocationCoordinate2D, from origin: CLLocation) async -> WalkingRoute? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: origin, address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = .walking
        guard let route = try? await MKDirections(request: request).calculate().routes.first else { return nil }

        let polyline = route.polyline
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return WalkingRoute(
            coordinates: coordinates,
            distanceMeters: route.distance,
            minutes: max(1, Int((route.expectedTravelTime / 60).rounded(.up)))
        )
    }

    func openInMaps(_ place: PlaceSummary) {
        let item = MKMapItem(location: CLLocation(latitude: place.latitude, longitude: place.longitude), address: nil)
        item.name = place.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    static func summarize(_ items: [MKMapItem], from origin: CLLocation) -> [PlaceSummary] {
        items
            .map { item -> PlaceSummary in
                let location = item.location
                let description = describe(item.pointOfInterestCategory)
                return PlaceSummary(
                    id: item.identifier?.rawValue ?? "\(item.name ?? "place")@\(location.coordinate.latitude),\(location.coordinate.longitude)",
                    name: item.name ?? "Unnamed place",
                    categoryName: description.name,
                    group: description.group,
                    symbol: description.symbol,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    distanceMeters: origin.distance(from: location),
                    phone: item.phoneNumber,
                    url: item.url
                )
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    static func describe(_ category: MKPointOfInterestCategory?) -> (name: String, group: POIGroup, symbol: String) {
        guard let category else { return ("Place", .other, "mappin") }
        switch category {
        case .cafe: return ("Café", .dining, "cup.and.saucer.fill")
        case .restaurant: return ("Restaurant", .dining, "fork.knife")
        case .bakery: return ("Bakery", .dining, "birthday.cake.fill")
        case .brewery, .winery: return ("Bar", .entertainment, "wineglass.fill")
        case .nightlife: return ("Nightlife", .entertainment, "music.note")
        case .theater: return ("Theatre", .entertainment, "theatermasks.fill")
        case .movieTheater: return ("Cinema", .entertainment, "film.fill")
        case .museum: return ("Museum", .entertainment, "building.columns.fill")
        case .stadium: return ("Stadium", .entertainment, "sportscourt.fill")
        case .park, .nationalPark, .beach: return ("Park", .outdoors, "tree.fill")
        case .publicTransport: return ("Transit", .transit, "tram.fill")
        case .airport: return ("Airport", .transit, "airplane")
        case .store: return ("Store", .shopping, "bag.fill")
        case .university: return ("College", .other, "building.columns")
        case .school: return ("School", .other, "book.fill")
        case .library: return ("Library", .other, "books.vertical.fill")
        case .hospital: return ("Hospital", .other, "cross.case.fill")
        case .hotel: return ("Hotel", .other, "bed.double.fill")
        case .fitnessCenter: return ("Gym", .other, "figure.run")
        default: return ("Place", .other, "mappin")
        }
    }
}

/// A route to follow on the map: its shape, its turns, and how long it should take.
nonisolated struct NavRoute: Sendable {
    var coordinates: [CLLocationCoordinate2D]
    var steps: [StepGuide.Step]
    var minutes: Int
    var distanceMeters: Double
    /// By road, as against on foot: the map leans in closer and tilts for a road leg.
    var byRoad: Bool
}
