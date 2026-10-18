import CoreMotion
import Foundation
import Observation

@Observable
final class BarometerManager {
    private(set) var isRunning = false
    private(set) var stationPressureHPa: Double?
    private(set) var seaLevelPressureHPa: Double?
    /// How high you are, when it's known to within `AltitudeEstimate.usable`.
    private(set) var altitude: AltitudeEstimate.Reading?
    private(set) var trend: PressureTrend = .insufficientData

    var absoluteAltitudeMeters: Double? { altitude?.metres }

    var isAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    #if DEBUG
    /// The simulator has no altimeter; this gives screenshots something to show.
    func seedDemoAltitude() {
        altitude = AltitudeEstimate.Reading(metres: 901, accuracy: 6)
    }
    #endif

    @ObservationIgnored private let altimeter = CMAltimeter()
    @ObservationIgnored private var detector: PressureTrendDetector
    @ObservationIgnored private var lastPersisted = Date.distantPast
    @ObservationIgnored private var altitudeSamples: [AltitudeEstimate.Sample] = []

    private static let storageKey = "pathos.pressureDetector"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(PressureTrendDetector.self, from: data) {
            detector = saved
        } else {
            detector = PressureTrendDetector()
        }
        detector.prune(now: Date())
        trend = detector.assess()
    }

    func start() {
        guard isAvailable, !isRunning else { return }
        isRunning = true

        if CMAltimeter.isAbsoluteAltitudeAvailable() {
            altimeter.startAbsoluteAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                let sample = AltitudeEstimate.Sample(metres: data.altitude, accuracy: data.accuracy, at: Date())
                MainActor.assumeIsolated {
                    self?.record(sample)
                }
            }
        }

        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let kiloPascals = data?.pressure.doubleValue else { return }
            MainActor.assumeIsolated {
                self?.record(stationKPa: kiloPascals)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        altimeter.stopRelativeAltitudeUpdates()
        altimeter.stopAbsoluteAltitudeUpdates()
        isRunning = false
        persist()
    }

    /// Used by background refresh: collect a few readings, then stop again.
    func sampleBriefly(for duration: Duration = .seconds(20)) async {
        let wasRunning = isRunning
        start()
        try? await Task.sleep(for: duration)
        if !wasRunning {
            stop()
        }
    }

    /// GPS's own altitude and how sure it is, from each fix: another opinion beside the
    /// barometer's, taken when it's the sharper of the two.
    func recordGPS(altitude metres: Double, verticalAccuracy: Double, at date: Date) {
        guard verticalAccuracy > 0 else { return }
        record(AltitudeEstimate.Sample(metres: metres, accuracy: verticalAccuracy, at: date))
    }

    private func record(_ sample: AltitudeEstimate.Sample) {
        altitudeSamples = AltitudeEstimate.adding(sample, to: altitudeSamples)
        let best = AltitudeEstimate.best(altitudeSamples, now: sample.at)
        // Whole metres: anything finer is noise, and redrawing for it is waste.
        func whole(_ reading: AltitudeEstimate.Reading?) -> AltitudeEstimate.Reading? {
            reading.map { AltitudeEstimate.Reading(metres: $0.metres.rounded(), accuracy: $0.accuracy.rounded()) }
        }
        if whole(best) != whole(altitude) {
            altitude = best
        }
    }

    private func record(stationKPa: Double) {
        let station = stationKPa * 10
        stationPressureHPa = station

        let seaLevel: Double
        if CMAltimeter.isAbsoluteAltitudeAvailable() {
            // Mixing corrected and uncorrected readings would fake a huge pressure jump.
            guard let altitude = absoluteAltitudeMeters else { return }
            seaLevel = PressureTrendDetector.seaLevelPressure(stationHPa: station, altitudeMeters: altitude)
        } else {
            seaLevel = station
        }
        seaLevelPressureHPa = seaLevel

        detector.add(PressureSample(date: Date(), hPa: seaLevel))
        trend = detector.assess()

        if Date().timeIntervalSince(lastPersisted) > 120 {
            persist()
        }
    }

    private func persist() {
        lastPersisted = Date()
        if let data = try? JSONEncoder().encode(detector) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
