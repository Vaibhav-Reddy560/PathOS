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

    /// Anything Apple Maps knows by that name or address. One search returns a couple of dozen
    /// at most, so it asks three times — around you, across the city, and anywhere — and merges
    /// them: the closest first, then the rest of the city, then further afield, each in Apple
    /// Maps' own order of relevance. A search for "coffee" lists the cafés around you, not just
    /// the handful one search found.
    func find(_ query: String, near location: CLLocation?) async throws -> [PlaceSummary] {
        guard let location else { return try await findOnce(query, region: nil, from: nil) }
        async let near = try? findOnce(query, region: MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 8_000, longitudinalMeters: 8_000), from: location)
        async let city = try? findOnce(query, region: MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000), from: location)
        async let anywhere = try? findOnce(query, region: nil, from: location)
        let batches = await [near, city, anywhere]
        guard batches.contains(where: { $0 != nil }) else {
            // All three failed: that's the network, and worth saying.
            return try await findOnce(query, region: nil, from: location)
        }
        return Self.merge(batches.compactMap { $0 })
    }

    /// Each place once, whichever search found it first, keeping the searches' order.
    nonisolated static func merge(_ batches: [[PlaceSummary]]) -> [PlaceSummary] {
        var seen = Set<String>()
        var merged: [PlaceSummary] = []
        for batch in batches {
            for place in batch {
                // The same place can come back under two identifiers; its name and spot say so.
                let spot = "\(place.name.lowercased())@\((place.latitude * 2_000).rounded()),\((place.longitude * 2_000).rounded())"
                guard seen.insert(place.id).inserted, seen.insert(spot).inserted else { continue }
                merged.append(place)
            }
        }
        return merged
    }

    private func findOnce(_ query: String, region: MKCoordinateRegion?, from location: CLLocation?) async throws -> [PlaceSummary] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address, .physicalFeature]
        if let region {
            request.region = region
        }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.map { Self.summary(of: $0, from: location) }
    }

    /// A place Apple Maps found, as PathOS lists it.
    static func summary(of item: MKMapItem, from location: CLLocation?) -> PlaceSummary {
        let coordinate = item.location.coordinate
        let description = describe(item.pointOfInterestCategory)
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
        // Leaving now: Apple Maps times a road hop by the traffic on it now, not an average day.
        request.departureDate = Date()
        guard let response = try? await MKDirections(request: request).calculateETA() else { return nil }
        return (Int((response.expectedTravelTime / 60).rounded(.up)), response.distance)
    }

    /// A route with its turns, for following a leg on the map. Apple Maps has no two-wheeler
    /// mode, so a scooter or a bike taxi follows the car's route, which is the same road.
    func directions(to destination: CLLocationCoordinate2D, from origin: CLLocation,
                    byRoad: Bool) async -> NavRoute? {
        await routes(to: destination, from: origin, byRoad: byRoad).first
    }

    /// Every way Apple Maps offers, quickest first, timed for the traffic right now.
    ///
    /// Moving, the route is asked for from a little ahead of you in the direction you're going,
    /// then joined back to where you are: Apple Maps knows nothing of which way you face, and a
    /// route from exactly where you stand on a divided road often began with a U-turn.
    func routes(to destination: CLLocationCoordinate2D, from origin: CLLocation, byRoad: Bool) async -> [NavRoute] {
        let request = MKDirections.Request()
        var start = origin
        if byRoad, origin.speed >= 3, origin.course >= 0, origin.courseAccuracy >= 0, origin.courseAccuracy < 45 {
            let ahead = GeoMath.coordinate(origin.coordinate, metres: min(120, origin.speed * 6), bearing: origin.course)
            start = CLLocation(latitude: ahead.latitude, longitude: ahead.longitude)
        }
        request.source = MKMapItem(location: start, address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = byRoad ? .automobile : .walking
        // Now, so the times are for the traffic on the roads now, and the other ways too.
        request.departureDate = Date()
        request.requestsAlternateRoutes = byRoad
        guard let found = try? await MKDirections(request: request).calculate().routes else { return [] }
        let joined = start.coordinate.latitude == origin.coordinate.latitude ? nil : origin.coordinate
        return found
            .sorted { $0.expectedTravelTime < $1.expectedTravelTime }
            .map { route in
                var steps = route.steps.compactMap { step -> StepGuide.Step? in
                    let shape = Self.coordinates(of: step.polyline)
                    guard shape.count > 1 else { return nil }
                    return StepGuide.Step(instruction: step.instructions, coordinates: shape, distanceMeters: step.distance)
                }
                var coordinates = Self.coordinates(of: route.polyline)
                var distance = route.distance
                if let joined, let first = coordinates.first {
                    let bridge = GeoMath.distance(from: joined, to: first)
                    coordinates.insert(joined, at: 0)
                    distance += bridge
                    if !steps.isEmpty {
                        steps[0].coordinates.insert(joined, at: 0)
                        steps[0].distanceMeters += bridge
                    }
                }
                return NavRoute(
                    coordinates: coordinates,
                    steps: steps,
                    minutes: max(1, Int((route.expectedTravelTime / 60).rounded())),
                    distanceMeters: distance,
                    byRoad: byRoad,
                    seconds: route.expectedTravelTime,
                    name: route.name,
                    fetchedAt: Date()
                )
            }
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
    /// The whole route's time, for the traffic when it was asked for.
    var seconds: TimeInterval = 0
    /// Apple Maps' name for it: the main road it takes, "Bannerghatta Road".
    var name: String = ""
    var fetchedAt: Date = Date()

    /// The time still to go from `match`, at this route's own pace: its traffic, not a guess.
    func secondsRemaining(from match: RouteProgress.Match) -> TimeInterval {
        let total = seconds > 0 ? seconds : Double(minutes) * 60
        return total * (1 - match.fraction)
    }
}
