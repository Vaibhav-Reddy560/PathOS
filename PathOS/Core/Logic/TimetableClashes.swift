import Foundation

/// Sessions of your weekly schedule taught at the same time, of which you take one: electives.
///
/// A timetable lists every elective offered in a slot ("KDD", "IOT", "ITSMF" at 1:05 on Wednesday,
/// Thursday and Friday); saved as it is, all three fill your week and remind you of two classes you
/// don't go to. This finds them in whatever you have, however it was imported, so PathOS can ask
/// which one is yours.
nonisolated enum TimetableClashes {
    /// Subjects that share a slot somewhere in the week, grouped: a subject clashing with another
    /// on one day and a third on another is one choice, not two. Each group is sorted by name.
    static func groups(in slots: [TimetableSlot]) -> [[String]] {
        let active = slots.filter(\.isActive)
        // Subjects sharing each exact slot. Only different subjects clash: the same subject in
        // two rooms at once is one class.
        var together: [String: Set<String>] = [:]
        for slot in active {
            together["\(slot.weekday)|\(slot.startMinutes)|\(slot.endMinutes)", default: []].insert(slot.subject)
        }
        var groups: [Set<String>] = []
        for subjects in together.values where subjects.count > 1 {
            // Merge with every group it touches.
            let touching = groups.indices.filter { !groups[$0].isDisjoint(with: subjects) }
            var merged = subjects
            for index in touching.reversed() {
                merged.formUnion(groups.remove(at: index))
            }
            groups.append(merged)
        }
        return groups
            .map { $0.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
            .sorted { $0.joined() < $1.joined() }
    }

    /// When they meet, for the question: "Wed, Thu and Fri at 1:05 PM".
    static func when(_ group: [String], in slots: [TimetableSlot], calendar: Calendar = .current) -> String {
        let shared = slots.filter { group.contains($0.subject) && $0.isActive }
        let days = Set(shared.map(\.weekday)).sorted { order($0) < order($1) }
        let names = days.map { calendar.shortWeekdaySymbols[max(0, min(6, $0 - 1))] }
        let starts = Set(shared.map(\.startMinutes))
        let time = starts.count == 1 ? " at \(TimetableRoutine.timeText(minutes: starts.first!))" : ""
        return ListFormatter.localizedString(byJoining: names) + time
    }

    /// The week from Monday, as a timetable reads.
    private static func order(_ weekday: Int) -> Int { (weekday + 5) % 7 }

    /// Everything to remove when you choose `kept` from `group`: the others, every day they meet.
    static func toRemove(keeping kept: String, of group: [String], from slots: [TimetableSlot]) -> [UUID] {
        slots.filter { group.contains($0.subject) && $0.subject != kept }.map(\.id)
    }

    /// A stable name for a group, so "keep them all" is remembered.
    static func key(_ group: [String]) -> String {
        group.map { $0.lowercased() }.sorted().joined(separator: "|")
    }
}
