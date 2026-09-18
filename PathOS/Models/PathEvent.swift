import CoreLocation
import Foundation
import SwiftData

/// Where an event came from, so the Day log can show how PathOS learned about it.
nonisolated enum EventOrigin: String, Codable, CaseIterable, Sendable {
    case manual
    case captured
    case scan
    case timetable
    case mail
    case assistant

    var label: String {
        switch self {
        case .manual: "Added by you"
        case .captured: "From text you shared"
        case .scan: "From a scan"
        case .timetable: "From your timetable"
        case .mail: "From your Gmail"
        case .assistant: "Asked of PathOS"
        }
    }

    var symbol: String {
        switch self {
        case .manual: "calendar"
        case .captured: "text.viewfinder"
        case .scan: "camera.viewfinder"
        case .timetable: "graduationcap"
        case .mail: "envelope"
        case .assistant: "apple.intelligence"
        }
    }
}

/// Something happening at a time and, usually, a place. PathOS keeps the full record —
/// the Apple Calendar copy is a mirror, so nothing is lost if it's deleted there.
@Model
final class PathEvent {
    var id: UUID = UUID()
    var title: String = ""
    var notes: String = ""
    var start: Date = Date()
    var endsAt: Date?
    var isAllDay: Bool = false
    var placeName: String?
    var latitude: Double?
    var longitude: Double?
    var tags: [String] = []
    @Attribute(.externalStorage) var photoData: Data?
    var originRaw: String = EventOrigin.manual.rawValue
    /// Identifier of the mirrored Apple Calendar event, when one was written.
    var calendarEventID: String?
    var reminderMinutesBefore: Int = 15
    var createdAt: Date = Date()

    init(
        title: String,
        start: Date,
        endsAt: Date? = nil,
        notes: String = "",
        placeName: String? = nil,
        coordinate: CLLocationCoordinate2D? = nil,
        tags: [String] = [],
        origin: EventOrigin = .manual,
        reminderMinutesBefore: Int = 15,
        photoData: Data? = nil
    ) {
        self.title = title
        self.start = start
        self.endsAt = endsAt
        self.notes = notes
        self.placeName = placeName
        latitude = coordinate?.latitude
        longitude = coordinate?.longitude
        self.tags = tags
        originRaw = origin.rawValue
        self.reminderMinutesBefore = reminderMinutesBefore
        self.photoData = photoData
    }

    var origin: EventOrigin {
        get { EventOrigin(rawValue: originRaw) ?? .manual }
        set { originRaw = newValue.rawValue }
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var end: Date { endsAt ?? start.addingTimeInterval(3_600) }

    var notificationID: String { "pathos.event.\(id.uuidString)" }
}

/// One day's record: how far you travelled and what PathOS saw, kept so past days
/// can be looked back on.
@Model
final class DayLog {
    /// Midnight of the day this covers.
    var dayStart: Date = Date()
    var distanceMeters: Double = 0
    var placeVisits: Int = 0
    var firstSeenAt: Date?
    var lastSeenAt: Date?

    init(dayStart: Date) {
        self.dayStart = dayStart
    }
}
