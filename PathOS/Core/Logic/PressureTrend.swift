import Foundation

nonisolated struct PressureSample: Codable, Hashable, Sendable {
    var date: Date
    /// Sea-level-corrected pressure in hPa.
    var hPa: Double
}

nonisolated enum PressureTrend: Equatable, Sendable {
    case insufficientData
    case steady
    case rising(hPaPerHour: Double)
    case falling(hPaPerHour: Double)
    case rapidDrop(dropHPa: Double, overHours: Double)

    var isRapidDrop: Bool {
        if case .rapidDrop = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .insufficientData: "Collecting pressure data…"
        case .steady: "Pressure steady"
        case .rising(let rate): String(format: "Rising %.1f hPa/h", rate)
        case .falling(let rate): String(format: "Falling %.1f hPa/h", abs(rate))
        case .rapidDrop(let drop, let hours): String(format: "Dropping fast: −%.1f hPa in %.1f h", drop, hours)
        }
    }

    var symbol: String {
        switch self {
        case .insufficientData: "hourglass"
        case .steady: "equal.circle"
        case .rising: "arrow.up.right.circle"
        case .falling: "arrow.down.right.circle"
        case .rapidDrop: "exclamationmark.triangle.fill"
        }
    }
}

/// Rolling 3-hour window of sea-level pressure with a rain-risk detector.
nonisolated struct PressureTrendDetector: Codable, Sendable {
    static let window: TimeInterval = 3 * 3600
    static let minimumSpan: TimeInterval = 30 * 60
    static let rapidDropWindowHPa = 1.5
    static let rapidDropHourHPa = 0.6
    static let slopeThresholdHPaPerHour = 0.2
    /// Readings within this span at each end are averaged to damp sensor noise.
    static let edgeSpan: TimeInterval = 10 * 60
    /// CMAltimeter reports about once a second; one reading per 30 s is plenty.
    static let minimumSampleSpacing: TimeInterval = 30

    private(set) var samples: [PressureSample] = []

    mutating func add(_ sample: PressureSample) {
        if let last = samples.last, sample.date.timeIntervalSince(last.date) < Self.minimumSampleSpacing {
            return
        }
        samples.append(sample)
        prune(now: sample.date)
    }

    mutating func prune(now: Date) {
        samples.removeAll { now.timeIntervalSince($0.date) > Self.window }
    }

    func assess(now: Date = Date()) -> PressureTrend {
        let recent = samples.filter { now.timeIntervalSince($0.date) <= Self.window }
        guard let first = recent.first, let last = recent.last else { return .insufficientData }
        let span = last.date.timeIntervalSince(first.date)
        guard span >= Self.minimumSpan else { return .insufficientData }

        let windowChange = Self.average(recent, from: last.date.addingTimeInterval(-Self.edgeSpan), to: last.date)
            - Self.average(recent, from: first.date, to: first.date.addingTimeInterval(Self.edgeSpan))
        let spanHours = span / 3600
        if -windowChange >= Self.rapidDropWindowHPa {
            return .rapidDrop(dropHPa: -windowChange, overHours: spanHours)
        }

        let lastHour = recent.filter { now.timeIntervalSince($0.date) <= 3600 }
        if let hourFirst = lastHour.first, let hourLast = lastHour.last {
            let hourSpan = hourLast.date.timeIntervalSince(hourFirst.date)
            if hourSpan >= 45 * 60 {
                let hourChange = Self.average(lastHour, from: hourLast.date.addingTimeInterval(-Self.edgeSpan), to: hourLast.date)
                    - Self.average(lastHour, from: hourFirst.date, to: hourFirst.date.addingTimeInterval(Self.edgeSpan))
                if -hourChange >= Self.rapidDropHourHPa {
                    return .rapidDrop(dropHPa: -hourChange, overHours: hourSpan / 3600)
                }
            }
        }

        let rate = windowChange / spanHours
        if rate <= -Self.slopeThresholdHPaPerHour { return .falling(hPaPerHour: rate) }
        if rate >= Self.slopeThresholdHPaPerHour { return .rising(hPaPerHour: rate) }
        return .steady
    }

    /// Converts station pressure to sea level so walking up stairs doesn't look like weather.
    static func seaLevelPressure(stationHPa: Double, altitudeMeters: Double) -> Double {
        stationHPa / pow(1 - altitudeMeters / 44_330, 5.255)
    }

    private static func average(_ samples: [PressureSample], from start: Date, to end: Date) -> Double {
        let values = samples.filter { $0.date >= start && $0.date <= end }.map(\.hPa)
        guard !values.isEmpty else { return samples.first?.hPa ?? 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
