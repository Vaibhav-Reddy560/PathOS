import CoreLocation
import UIKit

nonisolated enum CabProvider: String, CaseIterable, Identifiable, Sendable {
    case uber
    case ola
    case rapido

    var id: String { rawValue }

    var name: String {
        switch self {
        case .uber: "Uber"
        case .ola: "Ola"
        case .rapido: "Rapido"
        }
    }

    var symbol: String {
        switch self {
        case .uber: "car.fill"
        case .ola: "car.side.fill"
        case .rapido: "scooter"
        }
    }

    /// Deep link into the installed app with the drop pre-filled where the app supports it.
    func appURL(drop: CLLocationCoordinate2D?, pickup: CLLocationCoordinate2D?) -> URL? {
        switch self {
        case .uber:
            var components = URLComponents(string: "uber://")!
            components.queryItems = [URLQueryItem(name: "action", value: "setPickup"), URLQueryItem(name: "pickup", value: "my_location")]
                + Self.uberDropItems(drop)
            return components.url
        case .ola:
            var components = URLComponents(string: "olacabs://app/launch")!
            var items: [URLQueryItem] = []
            if let pickup {
                items += [URLQueryItem(name: "lat", value: Self.format(pickup.latitude)), URLQueryItem(name: "lng", value: Self.format(pickup.longitude))]
            }
            if let drop {
                items += [URLQueryItem(name: "drop_lat", value: Self.format(drop.latitude)), URLQueryItem(name: "drop_lng", value: Self.format(drop.longitude))]
            }
            components.queryItems = items.isEmpty ? nil : items
            return components.url
        case .rapido:
            // Rapido has no documented deep-link parameters; just open the app.
            return URL(string: "rapido://")
        }
    }

    /// Used when the app isn't installed.
    func fallbackURL(drop: CLLocationCoordinate2D?) -> URL? {
        switch self {
        case .uber:
            var components = URLComponents(string: "https://m.uber.com/ul/")!
            components.queryItems = [URLQueryItem(name: "action", value: "setPickup"), URLQueryItem(name: "pickup", value: "my_location")]
                + Self.uberDropItems(drop)
            return components.url
        case .ola:
            return URL(string: "https://book.olacabs.com/")
        case .rapido:
            return URL(string: "itms-apps://search.itunes.apple.com/WebObjects/MZSearch.woa/wa/search?media=software&term=Rapido")
        }
    }

    private static func uberDropItems(_ drop: CLLocationCoordinate2D?) -> [URLQueryItem] {
        guard let drop else { return [] }
        return [
            URLQueryItem(name: "dropoff[latitude]", value: format(drop.latitude)),
            URLQueryItem(name: "dropoff[longitude]", value: format(drop.longitude)),
        ]
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}

enum CabLauncher {
    static func open(_ provider: CabProvider, drop: CLLocationCoordinate2D?, pickup: CLLocationCoordinate2D?) {
        if let appURL = provider.appURL(drop: drop, pickup: pickup), UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else if let fallback = provider.fallbackURL(drop: drop) {
            UIApplication.shared.open(fallback)
        }
    }

    /// `pathos://cab?provider=ola&lat=…&lng=…` — lets Live Activity buttons launch cabs via the app.
    static func link(for provider: CabProvider, drop: CLLocationCoordinate2D?) -> URL? {
        var components = URLComponents(string: "pathos://cab")!
        var items = [URLQueryItem(name: "provider", value: provider.rawValue)]
        if let drop {
            items += [URLQueryItem(name: "lat", value: String(drop.latitude)), URLQueryItem(name: "lng", value: String(drop.longitude))]
        }
        components.queryItems = items
        return components.url
    }
}
