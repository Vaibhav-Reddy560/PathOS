import Foundation

/// Everything PathOS holds about you, in one file you can keep anywhere.
///
/// The app's own storage lives inside its container on the phone: it survives being reinstalled
/// over the top, which is what happens every seven days with a free Apple ID, and it's carried in
/// an iPhone backup. It does *not* survive the app being deleted. This is the copy that does —
/// written as plain JSON so it can be read years from now, by PathOS or by anything else.
nonisolated struct BackupArchive: Codable, Equatable {
    /// Raised only when an older file can no longer be read as-is.
    static let currentVersion = 1

    var version = currentVersion
    var createdAt = Date()
    /// Which build wrote it, for when something looks wrong later.
    var appVersion: String = ""

    var places: [Place] = []
    var notes: [Note] = []
    var photos: [Photo] = []
    var events: [Event] = []
    var sessions: [Session] = []
    var exceptions: [Exception] = []
    var trips: [Trip] = []
    var legs: [Leg] = []
    var mail: [Mail] = []
    var scans: [Scan] = []
    var expenses: [Expense] = []
    var departures: [Departure] = []
    var days: [Day] = []
    /// Preferences that aren't worth a model of their own: priority senders, the preferred cab.
    var settings: [String: String] = [:]
    var settingLists: [String: [String]] = [:]

    // MARK: What's in it

    nonisolated struct Place: Codable, Equatable {
        var id: UUID
        var name: String
        var kindRaw: String
        var latitude: Double
        var longitude: Double
        var radius: Double
        var createdAt: Date
    }

    nonisolated struct Note: Codable, Equatable {
        var id: UUID
        var title: String
        var body: String
        var latitude: Double
        var longitude: Double
        var radius: Double
        var photoData: Data?
        var tags: [String]
        var createdAt: Date
        var lastSurfacedAt: Date?
        var isActive: Bool
    }

    /// The extra photos on a note, kept beside it rather than inside it.
    nonisolated struct Photo: Codable, Equatable {
        var id: UUID
        var noteID: UUID?
        var data: Data
        var createdAt: Date
    }

    nonisolated struct Event: Codable, Equatable {
        var id: UUID
        var title: String
        var notes: String
        var start: Date
        var endsAt: Date?
        var isAllDay: Bool
        var placeName: String?
        var latitude: Double?
        var longitude: Double?
        var tags: [String]
        var photoData: Data?
        var originRaw: String
        var calendarEventID: String?
        var reminderMinutesBefore: Int
        var createdAt: Date
    }

    nonisolated struct Session: Codable, Equatable {
        var id: UUID
        var subject: String
        var weekday: Int
        var startMinutes: Int
        var endMinutes: Int
        var room: String?
        var teacher: String?
        /// Added after the first backups, which simply don't have it.
        var notes: String? = nil
        var isActive: Bool
        var createdAt: Date
    }

    nonisolated struct Exception: Codable, Equatable {
        var id: UUID
        var dayStart: Date
        var reason: String
        var entryID: UUID?
        var startMinutesOverride: Int?
        var endMinutesOverride: Int?
        var roomOverride: String?
        var createdAt: Date
    }

    nonisolated struct Trip: Codable, Equatable {
        var id: UUID
        var name: String
        var notes: String
        var startDate: Date
        var endDate: Date
        var createdAt: Date
    }

    nonisolated struct Leg: Codable, Equatable {
        var id: UUID
        var tripID: UUID?
        var modeRaw: String
        var origin: String
        var destination: String
        var departure: Date
        var arrival: Date?
        var notes: String
        var originLatitude: Double?
        var originLongitude: Double?
        var destinationLatitude: Double?
        var destinationLongitude: Double?
    }

    nonisolated struct Mail: Codable, Equatable {
        var id: UUID
        var messageID: String
        var senderName: String
        var senderAddress: String
        var subject: String
        var receivedAt: Date
        var kindRaw: String
        var title: String
        var summary: String
        var start: Date?
        var endsAt: Date?
        var isAllDay: Bool
        var placeName: String?
        var usedAI: Bool
        var statusRaw: String
        var eventID: UUID?
        var account: String?
        var threadID: String?
        var createdAt: Date
    }

    nonisolated struct Scan: Codable, Equatable {
        var id: UUID
        var kindRaw: String
        var title: String
        var summary: String
        var rawText: String
        var createdAt: Date
        var eventStart: Date?
        var venueName: String?
        var latitude: Double?
        var longitude: Double?
    }

    nonisolated struct Expense: Codable, Equatable {
        var id: UUID
        var merchant: String
        var amount: Double
        var currencyCode: String
        var categoryRaw: String
        var date: Date
        var note: String
    }

    nonisolated struct Departure: Codable, Equatable {
        var id: UUID
        var placeKindRaw: String
        var date: Date
        var weekday: Int
        var minutesSinceMidnight: Int
    }

    nonisolated struct Day: Codable, Equatable {
        var dayStart: Date
        var distanceMeters: Double
        var placeVisits: Int
        var firstSeenAt: Date?
        var lastSeenAt: Date?
        /// Added after the first backups, which simply don't have them.
        var attendedIDs: [String] = []
        var missedIDs: [String] = []
    }

    // MARK: Reading and writing

    /// ISO-8601 down to the millisecond: readable by anything, and near enough exact. The plain
    /// ISO-8601 strategy rounds to the whole second, which would shuffle the order of things
    /// saved in the same breath.
    /// A formatter each time: they are cheap next to writing a file, and sharing one across
    /// threads is not safe.
    private static func dateFormat(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }

    static func encode(_ archive: BackupArchive) throws -> Data {
        let format = dateFormat(fractional: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(format.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(archive)
    }

    static func decode(_ data: Data) throws -> BackupArchive {
        let format = dateFormat(fractional: true)
        let plainFormat = dateFormat(fractional: false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // Older files, and anything hand-written, may have no fractional part.
            guard let date = format.date(from: text) ?? plainFormat.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Not a date PathOS can read: \(text)"))
            }
            return date
        }
        let archive = try decoder.decode(BackupArchive.self, from: data)
        guard archive.version <= currentVersion else { throw BackupError.tooNew(archive.version) }
        return archive
    }

    /// "18 places, 42 notes, 7 photos, 96 events…" — what you'd be putting back.
    var summary: String {
        let counts: [(Int, String, String)] = [
            (places.count, "place", "places"),
            (notes.count, "memory", "memories"),
            (photos.count + notes.filter { $0.photoData != nil }.count + events.filter { $0.photoData != nil }.count, "photo", "photos"),
            (events.count, "event", "events"),
            (sessions.count, "session", "sessions"),
            (trips.count, "trip", "trips"),
            (mail.count, "mail item", "mail items"),
            (expenses.count, "expense", "expenses"),
        ]
        let parts = counts.filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        return parts.isEmpty ? "Nothing saved yet" : parts.joined(separator: ", ")
    }

    /// Nothing in it worth writing to a file.
    var isEmpty: Bool {
        places.isEmpty && notes.isEmpty && events.isEmpty && sessions.isEmpty
            && trips.isEmpty && mail.isEmpty && scans.isEmpty && expenses.isEmpty
    }
}

nonisolated enum BackupError: LocalizedError {
    case tooNew(Int)

    var errorDescription: String? {
        switch self {
        case .tooNew(let version):
            "This backup was written by a newer PathOS (version \(version)). Update the app, then restore it."
        }
    }
}
