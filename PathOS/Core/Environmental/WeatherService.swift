import CoreLocation
import Foundation
import Observation

nonisolated struct WeatherSnapshot: Equatable, Sendable {
    var temperatureC: Double
    /// WMO code for what's happening: from a station's report where one is near, else the forecast.
    var weatherCode: Int
    /// The middle forecast model's chance of rain in the next 2 hours. See `WeatherReading`.
    var rainChanceNext2h: Int
    /// The middle model's wettest hour in the next 2, in millimetres.
    var expectedRainMM: Double = 0
    /// How many forecast models expect measurable rain in the next 2 hours, of how many.
    var modelsExpectingRain: Int = 0
    var modelCount: Int = 0
    /// A weather station near you and what it last reported.
    var observation: WeatherObservation?
    var fetchedAt: Date
    var latitude: Double
    var longitude: Double

    /// Rain reported by a station nearby, which is what "raining nearby" means.
    var isRainingNearby: Bool { observation?.isRaining == true }

    /// Worth an umbrella: raining nearby, or even odds of enough rain to wet you.
    var isRainLikely: Bool {
        isRainingNearby || WeatherReading.isRainLikely(chance: rainChanceNext2h, expectedMM: expectedRainMM)
    }

    /// WMO weather interpretation codes.
    var symbol: String {
        switch weatherCode {
        case 0: "sun.max.fill"
        case 1, 2: "cloud.sun.fill"
        case 3: "cloud.fill"
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
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67, 80...82: "Rain"
        case 71...77, 85, 86: "Snow"
        case 95...99: "Thunderstorm"
        default: "Cloudy"
        }
    }
}

/// The forecast from three models through Open-Meteo, and the nearest station's report from
/// aviation weather (METAR). Both free, no key. Confirms what the barometer suspects.
@Observable
final class WeatherService {
    private(set) var snapshot: WeatherSnapshot?
    private(set) var lastError: String?

    #if DEBUG
    /// Fills the readouts for simulator screenshots, where there is no forecast to fetch.
    func seedDemoSnapshot() {
        snapshot = WeatherSnapshot(
            temperatureC: 22, weatherCode: 61, rainChanceNext2h: 71, expectedRainMM: 1.2,
            modelsExpectingRain: 3, modelCount: 3, fetchedAt: Date(), latitude: 12.9752, longitude: 77.6068
        )
    }
    #endif

    private static let cacheLifetime: TimeInterval = 15 * 60
    private static let cacheDistanceMeters = 2_000.0
    /// ECMWF's, America's and Germany's global models: the three with rain probabilities worldwide.
    nonisolated static let models = ["ecmwf_ifs025", "gfs_seamless", "icon_seamless"]

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

        async let forecast = Self.forecast(near: location.coordinate)
        async let observation = Self.observation(near: location)
        do {
            let fresh = WeatherReading.snapshot(
                models: try await forecast,
                observation: await observation,
                now: Date(),
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

    /// The next three hours from each model.
    private nonisolated static func forecast(near coordinate: CLLocationCoordinate2D) async throws -> [WeatherReading.ModelHours] {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "hourly", value: "precipitation_probability,precipitation,temperature_2m,weather_code"),
            URLQueryItem(name: "models", value: models.joined(separator: ",")),
            URLQueryItem(name: "forecast_hours", value: String(WeatherReading.hoursAhead)),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let hourly = try JSONDecoder().decode(OpenMeteoModels.self, from: data).hourly
        func series(_ name: String, _ model: String) -> [Double?] { hourly["\(name)_\(model)"] ?? [] }
        return models.map { model in
            WeatherReading.ModelHours(
                name: model,
                probability: series("precipitation_probability", model).map { $0.map { Int($0.rounded()) } },
                precipitation: series("precipitation", model),
                temperature: series("temperature_2m", model),
                weatherCode: series("weather_code", model).map { $0.map { Int($0) } }
            )
        }
        .filter { !$0.temperature.isEmpty }
    }

    /// The nearest station that has reported recently, within a few tens of kilometres. Nil when
    /// there isn't one, or it can't be reached: the forecast stands alone then.
    private nonisolated static func observation(near location: CLLocation) async -> WeatherObservation? {
        let reach = 0.3
        let latitude = location.coordinate.latitude, longitude = location.coordinate.longitude
        let box = [latitude - reach, longitude - reach, latitude + reach, longitude + reach]
            .map { String(format: "%.2f", $0) }.joined(separator: ",")
        guard let url = URL(string: "https://aviationweather.gov/api/data/metar?bbox=\(box)&format=json"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reports = try? JSONDecoder().decode([METARReport].self, from: data) else { return nil }
        return reports
            .compactMap { report -> WeatherObservation? in
                guard let lat = report.lat, let lon = report.lon, let time = report.obsTime else { return nil }
                return WeatherObservation(
                    station: WeatherReading.stationName(report.name ?? report.icaoId),
                    distanceMeters: location.distance(from: CLLocation(latitude: lat, longitude: lon)),
                    observedAt: Date(timeIntervalSince1970: time),
                    temperatureC: report.temp,
                    presentWeather: report.wxString,
                    cloudCover: report.cover
                )
            }
            .min { $0.distanceMeters < $1.distanceMeters }
    }
}

/// Open-Meteo's hourly block with several models: each series is named after its variable and
/// model, as in "precipitation_ecmwf_ifs025".
nonisolated private struct OpenMeteoModels: Decodable {
    let hourly: [String: [Double?]]

    private enum CodingKeys: String, CodingKey { case hourly }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let block = try decoder.container(keyedBy: CodingKeys.self).nestedContainer(keyedBy: Key.self, forKey: .hourly)
        var hourly: [String: [Double?]] = [:]
        for key in block.allKeys where key.stringValue != "time" {
            hourly[key.stringValue] = try? block.decode([Double?].self, forKey: key)
        }
        self.hourly = hourly
    }
}

nonisolated private struct METARReport: Decodable {
    let icaoId: String
    let name: String?
    let lat: Double?
    let lon: Double?
    /// Seconds since 1970.
    let obsTime: Double?
    let temp: Double?
    let wxString: String?
    let cover: String?
}
