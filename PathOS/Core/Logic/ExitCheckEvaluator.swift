import Foundation

nonisolated struct ExitAdvice: Equatable, Sendable {
    nonisolated enum Severity: Int, Comparable, Sendable {
        case medium = 1
        case high = 2

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var headline: String
    var detail: String
    var symbol: String
    var severity: Severity
}

/// Decides whether leaving home/work warrants an umbrella warning.
nonisolated enum ExitCheckEvaluator {
    static let rainChanceThreshold = 50

    /// `expectedRainMM` is the forecast's wettest hour in the next two, when known; `observation`
    /// is a weather station's report near you. Only a station that reported rain makes it
    /// "raining nearby": a model's guess at the current hour once said so all evening while it
    /// stayed dry. A forecast of mere drops doesn't call for an umbrella either.
    static func evaluate(
        trend: PressureTrend,
        rainChanceNext2h: Int?,
        expectedRainMM: Double? = nil,
        observation: WeatherObservation? = nil
    ) -> ExitAdvice? {
        let chance = rainChanceNext2h ?? 0
        let rainingNearby = observation?.isRaining == true ? observation : nil
        let rainLikely = WeatherReading.isRainLikely(chance: chance, expectedMM: expectedRainMM ?? WeatherReading.measurableRainMM)

        if let rainingNearby {
            let distance = GeoMath.formatDistance(rainingNearby.distanceMeters)
            let time = rainingNearby.observedAt.formatted(date: .omitted, time: .shortened)
            return ExitAdvice(
                headline: "Raining nearby — take an umbrella",
                detail: "\(rainingNearby.station), \(distance) away, reported rain at \(time)."
                    + (trend.isRapidDrop ? " Pressure is dropping fast too." : ""),
                symbol: "cloud.rain.fill",
                severity: trend.isRapidDrop ? .high : .medium
            )
        }

        switch (trend.isRapidDrop, rainLikely) {
        case (true, true):
            return ExitAdvice(
                headline: "Rain likely — take an umbrella",
                detail: "Pressure is dropping fast and there's a \(chance)% chance of rain in the next 2 hours.",
                symbol: "umbrella.fill",
                severity: .high
            )
        case (true, false):
            return ExitAdvice(
                headline: "Pressure dropping fast — take an umbrella",
                detail: "Your barometer shows a rapid drop. The weather may turn soon.",
                symbol: "barometer",
                severity: .medium
            )
        case (false, true):
            return ExitAdvice(
                headline: "Rain likely — take an umbrella",
                detail: "There's a \(chance)% chance of rain in the next 2 hours.",
                symbol: "cloud.rain.fill",
                severity: .medium
            )
        case (false, false):
            return nil
        }
    }
}
