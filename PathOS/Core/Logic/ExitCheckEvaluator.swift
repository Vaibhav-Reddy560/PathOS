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
    static let rainingNowThresholdMM = 0.2

    static func evaluate(trend: PressureTrend, rainChanceNext2h: Int?, precipitationNowMM: Double?) -> ExitAdvice? {
        let chance = rainChanceNext2h ?? 0
        let rainingNow = (precipitationNowMM ?? 0) >= rainingNowThresholdMM
        let rainLikely = chance >= rainChanceThreshold || rainingNow

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
                detail: rainingNow
                    ? "It's raining nearby right now."
                    : "There's a \(chance)% chance of rain in the next 2 hours.",
                symbol: "cloud.rain.fill",
                severity: .medium
            )
        case (false, false):
            return nil
        }
    }
}
