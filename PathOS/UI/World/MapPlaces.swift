import MapKit
import SwiftUI

/// Apple Maps' own places, as each of the two maps wants them.
///
/// The browsing map is SwiftUI's `Map` and the navigation map is `MKMapView`, and they take
/// different types that both spell `.excludingAll` — which is why this is two properties and not
/// one.
extension POIDisplay {
    /// For `MKStandardMapConfiguration`.
    var filter: MKPointOfInterestFilter {
        if showsEverything { return .includingAll }
        guard !groups.isEmpty else { return .excludingAll }
        return MKPointOfInterestFilter(including: categoryList)
    }

    /// For `.mapStyle(.standard(pointsOfInterest:))`.
    var categories: PointOfInterestCategories {
        if showsEverything { return .all }
        guard !groups.isEmpty else { return .excludingAll }
        return .including(categoryList)
    }

    private var categoryList: [MKPointOfInterestCategory] {
        POIGroups.each.filter { groups.contains($0) }.flatMap(\.poiCategories)
    }
}

extension POIGroups {
    /// What Apple Maps calls the places in this group.
    var poiCategories: [MKPointOfInterestCategory] {
        switch self {
        case .food: [.cafe, .restaurant, .bakery, .foodMarket, .brewery, .winery, .nightlife]
        case .shops: [.store, .pharmacy]
        case .fuel: [.gasStation, .evCharger, .parking, .carRental]
        case .transit: [.publicTransport, .airport]
        case .culture: [.theater, .movieTheater, .museum, .stadium, .library, .aquarium, .zoo, .amusementPark]
        case .outdoors: [.park, .nationalPark, .beach, .campground]
        case .services: [.bank, .atm, .postOffice, .hospital, .police, .fireStation, .restroom,
                         .laundry, .hotel, .school, .university, .fitnessCenter]
        default: []
        }
    }
}
