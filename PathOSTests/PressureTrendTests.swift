import Foundation
import Testing
@testable import PathOS

struct PressureTrendTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func detector(minutes: Int, pressure: (Int) -> Double) -> PressureTrendDetector {
        var detector = PressureTrendDetector()
        for minute in 0...minutes {
            detector.add(PressureSample(date: start.addingTimeInterval(Double(minute) * 60), hPa: pressure(minute)))
        }
        return detector
    }

    private var threeHoursLater: Date { start.addingTimeInterval(180 * 60) }

    @Test func constantPressureIsSteady() {
        #expect(detector(minutes: 180) { _ in 1010 }.assess(now: threeHoursLater) == .steady)
    }

    @Test func dropOver3HoursIsRapid() {
        let trend = detector(minutes: 180) { 1010 - Double($0) * 0.01 }.assess(now: threeHoursLater)
        #expect(trend.isRapidDrop)
    }

    @Test func sharpDropInLastHourIsRapid() {
        let trend = detector(minutes: 180) { minute in
            minute < 120 ? 1010 : 1010 - Double(minute - 120) * (0.8 / 60)
        }.assess(now: threeHoursLater)
        #expect(trend.isRapidDrop)
    }

    @Test func slowDeclineIsFallingNotRapid() {
        let trend = detector(minutes: 180) { 1010 - Double($0) * (0.3 / 60) }.assess(now: threeHoursLater)
        guard case .falling = trend else {
            Issue.record("Expected falling, got \(trend)")
            return
        }
    }

    @Test func shortHistoryIsInsufficient() {
        #expect(detector(minutes: 20) { _ in 1010 }.assess(now: start.addingTimeInterval(1200)) == .insufficientData)
    }

    @Test func seaLevelCorrection() {
        #expect(PressureTrendDetector.seaLevelPressure(stationHPa: 1000, altitudeMeters: 0) == 1000)
        #expect(abs(PressureTrendDetector.seaLevelPressure(stationHPa: 1000, altitudeMeters: 100) - 1011.9) < 0.3)
    }
}
