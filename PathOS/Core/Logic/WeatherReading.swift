import Foundation

/// What a weather station near you last reported: its METAR, as aviation weather services publish
/// it. Real observations, where the forecast is a model's guess for a 10–25 km square.
nonisolated struct WeatherObservation: Equatable, Sendable {
    /// "HAL Airport".
    var station: String
    var distanceMeters: Double
    var observedAt: Date
    var temperatureC: Double?
    /// METAR present weather, such as "-TSRA" (light thunderstorm with rain). Nil when nothing is
    /// happening.
    var presentWeather: String?
    /// The most cloud reported: "FEW", "SCT", "BKN", "OVC", or "CLR".
    var cloudCover: String?

    var isRaining: Bool { WeatherReading.isRain(presentWeather) }
}

/// Turns forecasts and observations into what PathOS says about the weather.
///
/// It used to repeat one model's most pessimistic hour, and to say it was raining nearby whenever
/// that model's own estimate of the current hour had any rain in it. On 19 September 2026 in
/// south Bengaluru that meant 89% and "raining nearby right now" all evening, and it never rained
/// there. The models disagreed: ECMWF 89% and 2 mm an hour, GFS 71% and a trace, ICON 53% and
/// none. HAL Airport, 8 km away, did report a passing light thunderstorm.
///
/// So the chance of rain is now the middle of three models, not the worst of one; rain only
/// counts as likely when the models also expect a measurable amount; and "raining nearby" only
/// comes from a station that reported rain.
nonisolated enum WeatherReading {
    /// One model's next few hours, the current hour first.
    nonisolated struct ModelHours: Equatable, Sendable {
        var name: String
        var probability: [Int?]
        /// Millimetres in each hour.
        var precipitation: [Double?]
        var temperature: [Double?]
        var weatherCode: [Int?]
    }

    /// Less than this in an hour is a few drops at most.
    static let measurableRainMM = 0.2
    /// A station's report counts for this long…
    static let observationLifetime: TimeInterval = 90 * 60
    /// …and this far away.
    static let observationRange = 20_000.0
    /// The current hour and the two after it.
    static let hoursAhead = 3

    /// The middle model's chance of rain in the next two hours, each model taken at its highest.
    static func chanceOfRain(_ models: [ModelHours]) -> Int {
        median(models.compactMap { $0.probability.prefix(hoursAhead).compactMap { $0 }.max() }) ?? 0
    }

    /// The middle model's wettest hour in the next two, in millimetres.
    static func expectedRain(_ models: [ModelHours]) -> Double {
        median(models.compactMap { $0.precipitation.prefix(hoursAhead).compactMap { $0 }.max() }) ?? 0
    }

    /// How many models expect measurable rain in the next two hours.
    static func modelsExpectingRain(_ models: [ModelHours]) -> Int {
        models.filter { ($0.precipitation.prefix(hoursAhead).compactMap { $0 }.max() ?? 0) >= measurableRainMM }.count
    }

    /// Rain is likely when the models put it at even odds or better and expect enough to wet you.
    static func isRainLikely(chance: Int, expectedMM: Double) -> Bool {
        chance >= ExitCheckEvaluator.rainChanceThreshold && expectedMM >= measurableRainMM
    }

    /// A report worth using: recent, and near enough to say something about where you are.
    static func usable(_ observation: WeatherObservation?, now: Date) -> WeatherObservation? {
        guard let observation, observation.distanceMeters <= observationRange,
              now.timeIntervalSince(observation.observedAt) <= observationLifetime else { return nil }
        return observation
    }

    // MARK: METAR

    /// Whether present weather means rain, drizzle or hail at the station. "VC" is the vicinity,
    /// not the station, and a thunderstorm alone brings no rain.
    static func isRain(_ presentWeather: String?) -> Bool {
        guard let presentWeather else { return false }
        return presentWeather.split(separator: " ").contains { token in
            !token.hasPrefix("VC") && ["RA", "DZ", "GR", "GS", "UP"].contains { token.contains($0) }
        }
    }

    /// The WMO code for what a station reports, so a report can stand in for the model's guess.
    static func weatherCode(for observation: WeatherObservation) -> Int {
        let tokens = (observation.presentWeather ?? "").split(separator: " ").filter { !$0.hasPrefix("VC") }.map(String.init)
        if tokens.contains(where: { $0.contains("TS") }) && observation.isRaining { return 95 }
        if let rain = tokens.first(where: { $0.contains("RA") }) {
            if rain.contains("SH") { return 80 }
            return rain.hasPrefix("-") ? 61 : rain.hasPrefix("+") ? 65 : 63
        }
        if tokens.contains(where: { $0.contains("DZ") }) { return 51 }
        if tokens.contains(where: { $0.contains("FG") || $0.contains("BR") }) { return 45 }
        return switch observation.cloudCover {
        case "FEW": 1
        case "SCT": 2
        case "BKN", "OVC", "OVX": 3
        default: 0
        }
    }

    /// "Bangaluru/Hal Arpt, KA, IN" → "Hal Airport".
    static func stationName(_ raw: String) -> String {
        let place = raw.split(separator: ",").first.map(String.init) ?? raw
        let name = place.split(separator: "/").last.map(String.init) ?? place
        return name
            .replacingOccurrences(of: "Arpt", with: "Airport")
            .replacingOccurrences(of: "Intl", with: "International")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Putting it together

    static func snapshot(
        models: [ModelHours],
        observation: WeatherObservation?,
        now: Date,
        latitude: Double,
        longitude: Double
    ) -> WeatherSnapshot {
        let observed = usable(observation, now: now)
        let chance = chanceOfRain(models)
        let expected = expectedRain(models)

        // What's happening now: the station's report where there is one; otherwise the forecast,
        // and only wet where the models agree it's raining this hour.
        var code: Int
        if let observed {
            code = weatherCode(for: observed)
        } else {
            code = models.first?.weatherCode.first.flatMap { $0 } ?? 3
            let wetNow = median(models.compactMap { $0.precipitation.first.flatMap { $0 } }) ?? 0
            if isWetCode(code) && wetNow < measurableRainMM {
                code = 3
            }
        }
        let modelTemperature = median(models.compactMap { $0.temperature.first.flatMap { $0 } }) ?? 0

        return WeatherSnapshot(
            temperatureC: observed?.temperatureC ?? modelTemperature,
            weatherCode: code,
            rainChanceNext2h: chance,
            expectedRainMM: expected,
            modelsExpectingRain: modelsExpectingRain(models),
            modelCount: models.count,
            observation: observed,
            fetchedAt: now,
            latitude: latitude,
            longitude: longitude
        )
    }

    static func isWetCode(_ code: Int) -> Bool {
        (51...67).contains(code) || (80...82).contains(code) || (95...99).contains(code)
    }

    private static func median<T: Comparable & Numeric>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        // The lower middle of an even count: with two models, the less alarming one.
        return sorted[(sorted.count - 1) / 2]
    }
}
