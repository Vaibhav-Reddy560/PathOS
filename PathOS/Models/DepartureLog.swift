import Foundation
import SwiftData

/// One observed departure from a saved place; feeds the routine learner.
@Model
final class DepartureLog {
    var id: UUID = UUID()
    var placeKindRaw: String = PlaceKind.home.rawValue
    var date: Date = Date()
    /// 1 = Sunday … 7 = Saturday (Calendar convention).
    var weekday: Int = 1
    var minutesSinceMidnight: Int = 0

    init(placeKind: PlaceKind, date: Date = Date(), calendar: Calendar = .current) {
        self.placeKindRaw = placeKind.rawValue
        self.date = date
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        self.weekday = parts.weekday ?? 1
        self.minutesSinceMidnight = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    var placeKind: PlaceKind { PlaceKind(rawValue: placeKindRaw) ?? .home }
}
