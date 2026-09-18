import Foundation
import Testing
@testable import PathOS

struct ScanHeuristicsTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-15T10:00:00+05:30")!

    @Test func receiptUsesGrandTotal() {
        let result = ScanHeuristics.analyze(
            "CAFE COFFEE DAY\nCappuccino 180.00\nGST 9.00\nGrand Total ₹ 1,189.00",
            now: now
        )
        #expect(result.kind == .receipt)
        #expect(result.amount == 1189)
        #expect(result.title == "CAFE COFFEE DAY")
    }

    @Test func parkingPillarAndLevel() {
        let result = ScanHeuristics.analyze("Phoenix Mall Parking\nLevel B2\nPillar C-14", now: now)
        #expect(result.kind == .parking)
        #expect(result.parkingLabel == "B2 · C-14")
    }

    @Test func eventPosterWithDate() {
        let result = ScanHeuristics.analyze(
            "STAND-UP NIGHT\nLive at Phoenix Arena\n21 September 2026, 8:00 PM",
            now: now
        )
        #expect(result.kind == .event)
        #expect(result.title == "STAND-UP NIGHT")
        #expect(result.eventDate != nil)
    }

    @Test func plainTextIsNote() {
        #expect(ScanHeuristics.analyze("Locker code 4471", now: now).kind == .note)
    }
}
