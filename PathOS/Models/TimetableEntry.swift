import Foundation
import SwiftData

/// One recurring class: the same subject, on the same weekday, at the same time, every week.
@Model
final class TimetableEntry {
    var id: UUID = UUID()
    var subject: String = ""
    /// 1 = Sunday … 7 = Saturday, matching `Calendar`.
    var weekday: Int = 2
    /// Minutes since midnight.
    var startMinutes: Int = 540
    var endMinutes: Int = 600
    var room: String?
    var teacher: String?
    var isActive: Bool = true
    var createdAt: Date = Date()

    init(subject: String, weekday: Int, startMinutes: Int, endMinutes: Int, room: String? = nil, teacher: String? = nil) {
        self.subject = subject
        self.weekday = weekday
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.room = room
        self.teacher = teacher
    }
}

/// A day the timetable doesn't apply as written: a holiday, a cancelled class, or a class moved
/// for just that day. Without one, the timetable runs every week, which is what a college term looks like.
@Model
final class TimetableException {
    var id: UUID = UUID()
    /// Midnight of the affected day.
    var dayStart: Date = Date()
    var reason: String = "No classes"
    /// nil means the whole day is off; otherwise just this class.
    var entryID: UUID?
    /// Set when the class is moved rather than cancelled: its times on this one day.
    var startMinutesOverride: Int?
    var endMinutesOverride: Int?
    /// Set when the class meets somewhere else on this one day.
    var roomOverride: String?
    var createdAt: Date = Date()

    init(
        dayStart: Date,
        reason: String = "No classes",
        entryID: UUID? = nil,
        startMinutesOverride: Int? = nil,
        endMinutesOverride: Int? = nil,
        roomOverride: String? = nil
    ) {
        self.dayStart = dayStart
        self.reason = reason
        self.entryID = entryID
        self.startMinutesOverride = startMinutesOverride
        self.endMinutesOverride = endMinutesOverride
        self.roomOverride = roomOverride
    }
}
