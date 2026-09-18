import CoreMotion
import Foundation
import Observation

@Observable
final class BarometerManager {
    private(set) var isRunning = false
    private(set) var stationPressureHPa: Double?
    private(set) var seaLevelPressureHPa: Double?
    private(set) var absoluteAltitudeMeters: Double?
    private(set) var trend: PressureTrend = .insufficientData

    var isAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    #if DEBUG
    /// The simulator has no altimeter; this gives screenshots something to show.
    func seedDemoAltitude() {
        absoluteAltitudeMeters = 901
    }
    #endif

    @ObservationIgnored private let altimeter = CMAltimeter()
    @ObservationIgnored private var detector: PressureTrendDetector
    @ObservationIgnored private var lastPersisted = Date.distantPast

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
                guard let altitude = data?.altitude else { return }
                MainActor.assumeIsolated {
                    self?.absoluteAltitudeMeters = altitude
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
