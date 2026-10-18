import Foundation
import SwiftData

/// A holiday on your calendar — a public one, or your college's — and whether it's a day off
/// for you, once you've said.
@Model
final class Holiday {
    var id: UUID = UUID()
    /// Midnight of the day it falls on.
    var dayStart: Date = Date()
    var name: String = ""
    var kindRaw: String = Holidays.Kind.karnataka.rawValue
    /// Nil until you've said: a day off for you, or a day like any other.
    var isOff: Bool?
    var answeredAt: Date?

    init(dayStart: Date, name: String, kind: Holidays.Kind) {
        self.dayStart = dayStart
        self.name = name
        kindRaw = kind.rawValue
    }

    var kind: Holidays.Kind {
        Holidays.Kind(rawValue: kindRaw) ?? .own
    }

    var entry: Holidays.Entry {
        Holidays.Entry(id: id, day: dayStart, name: name, kind: kind, isOff: isOff)
    }
}
