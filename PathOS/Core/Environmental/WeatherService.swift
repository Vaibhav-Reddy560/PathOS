import CoreLocation
import Foundation
import Observation

nonisolated struct WeatherSnapshot: Equatable, Sendable {
    var temperatureC: Double
    var weatherCode: Int
    var precipitationNowMM: Double
    /// Highest hourly precipitation probability over the current and next 2 hours.
    var rainChanceNext2h: Int
    var fetchedAt: Date
    var latitude: Double
    var longitude: Double

    /// WMO weather interpretation codes.
    var symbol: String {
        switch weatherCode {
        case 0: "sun.max.fill"
        case 1...3: "cloud.sun.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    var summary: String {
        switch weatherCode {
        case 0: "Clear"
        case 1...3: "Partly cloudy"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67, 80...82: "Rain"
        case 71...77, 85, 86: "Snow"
        case 95...99: "Thunderstorm"
        default: "Cloudy"
        }
    }
}

/// Open-Meteo forecast: free, no API key. Confirms what the barometer suspects.
@Observable
final class WeatherService {
    private(set) var snapshot: WeatherSnapshot?
    private(set) var lastError: String?

    #if DEBUG
    /// Fills the readouts for simulator screenshots, where there is no forecast to fetch.
    func seedDemoSnapshot() {
        snapshot = WeatherSnapshot(
            temperatureC: 22, weatherCode: 61, precipitationNowMM: 0.2, rainChanceNext2h: 71,
            fetchedAt: Date(), latitude: 12.9752, longitude: 77.6068
        )
    }
    #endif

    private static let cacheLifetime: TimeInterval = 15 * 60
    private static let cacheDistanceMeters = 2_000.0

    @discardableResult
    func refresh(for location: CLLocation, force: Bool = false) async -> WeatherSnapshot? {
        if !force, let snapshot,
           Date().timeIntervalSince(snapshot.fetchedAt) < Self.cacheLifetime,
           GeoMath.distance(
               from: location.coordinate,
               to: CLLocationCoordinate2D(latitude: snapshot.latitude, longitude: snapshot.longitude)
           ) < Self.cacheDistanceMeters {
            return snapshot
        }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", location.coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,precipitation,weather_code"),
            URLQueryItem(name: "hourly", value: "precipitation_probability"),
            URLQueryItem(name: "forecast_hours", value: "3"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]

        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            let chances = decoded.hourly?.precipitation_probability.prefix(3).compactMap { $0 } ?? []
            let fresh = WeatherSnapshot(
                temperatureC: decoded.current.temperature_2m,
                weatherCode: decoded.current.weather_code,
                precipitationNowMM: decoded.current.precipitation,
                rainChanceNext2h: chances.max() ?? 0,
                fetchedAt: Date(),
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            snapshot = fresh
            lastError = nil
            return fresh
        } catch {
            lastError = error.localizedDescription
            return snapshot
        }
    }
}

nonisolated private struct OpenMeteoResponse: Decodable {
    nonisolated struct Current: Decodable {
        let temperature_2m: Double
        let precipitation: Double
        let weather_code: Int
    }

    nonisolated struct Hourly: Decodable {
        let precipitation_probability: [Int?]
    }

    let current: Current
    let hourly: Hourly?
}
