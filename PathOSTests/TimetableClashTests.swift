import Foundation
import Testing
@testable import PathOS

/// Electives saved as they were printed: three subjects in one slot, of which you take one.
struct TimetableClashTests {
    private func slot(_ subject: String, _ weekday: Int, _ start: Int, _ end: Int, active: Bool = true) -> TimetableSlot {
        TimetableSlot(id: UUID(), subject: subject, weekday: weekday, startMinutes: start, endMinutes: end, isActive: active)
    }

    /// The user's own week: KDD, IOT and ITSMF at 1:05 on Wednesday, Thursday and Friday.
    private var week: [TimetableSlot] {
        [slot("DEL", 4, 675, 730), slot("SML", 4, 730, 785)]
            + [4, 5, 6].flatMap { day in [slot("KDD", day, 785, 840), slot("IOT", day, 785, 840), slot("ITSMF", day, 785, 840)] }
            + [slot("DAV", 5, 675, 730)]
    }

    @Test func electivesAreFoundAcrossTheWeek() {
        #expect(TimetableClashes.groups(in: week) == [["IOT", "ITSMF", "KDD"]])
    }

    @Test func choosingOneRemovesTheOthersEveryDay() {
        let slots = week
        let removed = Set(TimetableClashes.toRemove(keeping: "IOT", of: ["IOT", "ITSMF", "KDD"], from: slots))
        let left = slots.filter { !removed.contains($0.id) }
        #expect(left.filter { $0.startMinutes == 785 }.map(\.subject) == ["IOT", "IOT", "IOT"])
        #expect(left.count == slots.count - 6)
    }

    /// Two subjects clashing on one day and one of them with a third on another day is one choice.
    @Test func overlappingPairsMerge() {
        let slots = [slot("A", 2, 540, 600), slot("B", 2, 540, 600), slot("B", 3, 540, 600), slot("C", 3, 540, 600)]
        #expect(TimetableClashes.groups(in: slots) == [["A", "B", "C"]])
    }

    /// The same subject listed twice in a slot, or back-to-back sessions, aren't a choice.
    @Test func nothingElseIsAClash() {
        let slots = [slot("Lab", 2, 540, 660), slot("Lab", 2, 540, 660), slot("Maths", 2, 660, 720),
                     slot("Old", 3, 540, 600, active: false), slot("New", 3, 540, 600)]
        #expect(TimetableClashes.groups(in: slots).isEmpty)
    }

    @Test func itSaysWhenTheyMeet() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        let when = TimetableClashes.when(["IOT", "ITSMF", "KDD"], in: week, calendar: calendar)
        #expect(when.hasPrefix("Wed, Thu, and Fri at") || when.hasPrefix("Wed, Thu and Fri at"))
    }
}
