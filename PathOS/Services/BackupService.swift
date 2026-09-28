import Foundation
import Observation
import SwiftData

/// Writes everything PathOS holds to a file, and puts it back.
///
/// PathOS's own storage already survives the seven-day reinstall — installing over the app keeps
/// its container, and an iPhone backup carries it — but nothing survives the app being deleted.
/// A backup file does, so one is written automatically every few days into the app's Documents
/// folder, which is visible in **Files → On My iPhone → PathOS**, and can be saved anywhere.
@Observable
final class BackupService {
    private(set) var lastBackupAt: Date?
    private(set) var lastError: String?

    @ObservationIgnored private let context: ModelContext
    /// How often a copy is written without being asked.
    private let interval: TimeInterval = 2 * 24 * 3_600
    /// Kept on the phone; older ones are cleared out.
    private let keep = 3

    init(context: ModelContext) {
        self.context = context
        lastBackupAt = UserDefaults.standard.object(forKey: "pathos.lastBackup") as? Date
    }

    // MARK: Making one

    /// Everything in the store, as plain data.
    func archive() -> BackupArchive {
        var archive = BackupArchive()
        archive.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

        archive.places = fetch(SavedPlace.self).map {
            .init(id: $0.id, name: $0.name, kindRaw: $0.kindRaw, latitude: $0.latitude,
                  longitude: $0.longitude, radius: $0.radius, createdAt: $0.createdAt)
        }
        archive.notes = fetch(SpatialNote.self).map {
            .init(id: $0.id, title: $0.title, body: $0.body, latitude: $0.latitude, longitude: $0.longitude,
                  radius: $0.radius, photoData: $0.photoData, tags: $0.tags, createdAt: $0.createdAt,
                  lastSurfacedAt: $0.lastSurfacedAt, isActive: $0.isActive)
        }
        archive.photos = fetch(NotePhoto.self).map {
            .init(id: $0.id, noteID: $0.note?.id, data: $0.data, createdAt: $0.createdAt)
        }
        archive.events = fetch(PathEvent.self).map {
            .init(id: $0.id, title: $0.title, notes: $0.notes, start: $0.start, endsAt: $0.endsAt,
                  isAllDay: $0.isAllDay, placeName: $0.placeName, latitude: $0.latitude, longitude: $0.longitude,
                  tags: $0.tags, photoData: $0.photoData, originRaw: $0.originRaw,
                  calendarEventID: $0.calendarEventID, reminderMinutesBefore: $0.reminderMinutesBefore,
                  createdAt: $0.createdAt)
        }
        archive.sessions = fetch(TimetableEntry.self).map {
            .init(id: $0.id, subject: $0.subject, weekday: $0.weekday, startMinutes: $0.startMinutes,
                  endMinutes: $0.endMinutes, room: $0.room, teacher: $0.teacher, notes: $0.notes, isActive: $0.isActive,
                  createdAt: $0.createdAt)
        }
        archive.exceptions = fetch(TimetableException.self).map {
            .init(id: $0.id, dayStart: $0.dayStart, reason: $0.reason, entryID: $0.entryID,
                  startMinutesOverride: $0.startMinutesOverride, endMinutesOverride: $0.endMinutesOverride,
                  roomOverride: $0.roomOverride, createdAt: $0.createdAt)
        }
        archive.trips = fetch(Trip.self).map {
            .init(id: $0.id, name: $0.name, notes: $0.notes, startDate: $0.startDate,
                  endDate: $0.endDate, createdAt: $0.createdAt)
        }
        archive.legs = fetch(TripLeg.self).map {
            .init(id: $0.id, tripID: $0.trip?.id, modeRaw: $0.modeRaw, origin: $0.origin,
                  destination: $0.destination, departure: $0.departure, arrival: $0.arrival, notes: $0.notes,
                  originLatitude: $0.originLatitude, originLongitude: $0.originLongitude,
                  destinationLatitude: $0.destinationLatitude, destinationLongitude: $0.destinationLongitude)
        }
        archive.mail = fetch(MailSuggestion.self).map {
            .init(id: $0.id, messageID: $0.messageID, senderName: $0.senderName, senderAddress: $0.senderAddress,
                  subject: $0.subject, receivedAt: $0.receivedAt, kindRaw: $0.kindRaw, title: $0.title,
                  summary: $0.summary, start: $0.start, endsAt: $0.endsAt, isAllDay: $0.isAllDay,
                  placeName: $0.placeName, usedAI: $0.usedAI, statusRaw: $0.statusRaw, eventID: $0.eventID,
                  account: $0.account, threadID: $0.threadID, createdAt: $0.createdAt)
        }
        archive.scans = fetch(ScanRecord.self).map {
            .init(id: $0.id, kindRaw: $0.kindRaw, title: $0.title, summary: $0.summary, rawText: $0.rawText,
                  createdAt: $0.createdAt, eventStart: $0.eventStart, venueName: $0.venueName,
                  latitude: $0.latitude, longitude: $0.longitude)
        }
        archive.expenses = fetch(Expense.self).map {
            .init(id: $0.id, merchant: $0.merchant, amount: $0.amount, currencyCode: $0.currencyCode,
                  categoryRaw: $0.categoryRaw, date: $0.date, note: $0.note)
        }
        archive.departures = fetch(DepartureLog.self).map {
            .init(id: $0.id, placeKindRaw: $0.placeKindRaw, date: $0.date, weekday: $0.weekday,
                  minutesSinceMidnight: $0.minutesSinceMidnight)
        }
        archive.days = fetch(DayLog.self).map {
            .init(dayStart: $0.dayStart, distanceMeters: $0.distanceMeters, placeVisits: $0.placeVisits,
                  firstSeenAt: $0.firstSeenAt, lastSeenAt: $0.lastSeenAt,
                  attendedIDs: $0.attendedIDs, missedIDs: $0.missedIDs, completions: $0.completions)
        }
        archive.reminders = fetch(Reminder.self).map {
            .init(id: $0.id, title: $0.title, notes: $0.notes, day: $0.day, dueAt: $0.dueAt,
                  completedAt: $0.completedAt, originRaw: $0.originRaw, createdAt: $0.createdAt)
        }
        archive.settings = Self.savedSettings
        archive.settingLists = Self.savedSettingLists
        return archive
    }

    /// Writes a backup and returns where it went.
    @discardableResult
    func write(to folder: URL? = nil) throws -> URL {
        let archive = archive()
        let data = try BackupArchive.encode(archive)
        let directory = folder ?? Self.documents
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.filename(at: archive.createdAt))
        try data.write(to: url, options: .atomic)
        lastBackupAt = archive.createdAt
        UserDefaults.standard.set(archive.createdAt, forKey: "pathos.lastBackup")
        tidy(in: directory)
        return url
    }

    /// Writes one if it's been a few days, unless there's nothing to save yet.
    func writeIfDue(now: Date = Date()) {
        guard !archive().isEmpty else { return }
        if let lastBackupAt, now.timeIntervalSince(lastBackupAt) < interval { return }
        do {
            try write()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The backups on the phone, newest first.
    func existing() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.documents,
                                                                  includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("PathOS-backup") }
            .sorted { a, b in (modified(a) ?? .distantPast) > (modified(b) ?? .distantPast) }
    }

    // MARK: Putting one back

    /// Replaces everything with what's in the file. Nothing is merged: a backup is a whole
    /// picture of a moment, and half of one picture beside half of another is neither.
    func restore(from data: Data) throws -> BackupArchive {
        let archive = try BackupArchive.decode(data)
        try deleteEverything()

        for item in archive.places {
            let place = SavedPlace(name: item.name, kind: PlaceKind(rawValue: item.kindRaw) ?? .other,
                                   coordinate: .init(latitude: item.latitude, longitude: item.longitude),
                                   radius: item.radius)
            place.id = item.id
            place.createdAt = item.createdAt
            context.insert(place)
        }

        var notesByID: [UUID: SpatialNote] = [:]
        for item in archive.notes {
            let note = SpatialNote(title: item.title, body: item.body,
                                   coordinate: .init(latitude: item.latitude, longitude: item.longitude),
                                   radius: item.radius)
            note.id = item.id
            note.photoData = item.photoData
            note.tags = item.tags
            note.createdAt = item.createdAt
            note.lastSurfacedAt = item.lastSurfacedAt
            note.isActive = item.isActive
            context.insert(note)
            notesByID[item.id] = note
        }
        for item in archive.photos {
            let photo = NotePhoto(data: item.data)
            photo.id = item.id
            photo.createdAt = item.createdAt
            photo.note = item.noteID.flatMap { notesByID[$0] }
            context.insert(photo)
        }

        for item in archive.events {
            let event = PathEvent(title: item.title, start: item.start)
            event.id = item.id
            event.notes = item.notes
            event.endsAt = item.endsAt
            event.isAllDay = item.isAllDay
            event.placeName = item.placeName
            event.latitude = item.latitude
            event.longitude = item.longitude
            event.tags = item.tags
            event.photoData = item.photoData
            event.originRaw = item.originRaw
            event.calendarEventID = item.calendarEventID
            event.reminderMinutesBefore = item.reminderMinutesBefore
            event.createdAt = item.createdAt
            context.insert(event)
        }

        for item in archive.sessions {
            let session = TimetableEntry(subject: item.subject, weekday: item.weekday,
                                         startMinutes: item.startMinutes, endMinutes: item.endMinutes,
                                         room: item.room, teacher: item.teacher)
            session.id = item.id
            session.notes = item.notes
            session.isActive = item.isActive
            session.createdAt = item.createdAt
            context.insert(session)
        }
        for item in archive.exceptions {
            let exception = TimetableException(dayStart: item.dayStart, reason: item.reason, entryID: item.entryID)
            exception.id = item.id
            exception.startMinutesOverride = item.startMinutesOverride
            exception.endMinutesOverride = item.endMinutesOverride
            exception.roomOverride = item.roomOverride
            exception.createdAt = item.createdAt
            context.insert(exception)
        }

        var tripsByID: [UUID: Trip] = [:]
        for item in archive.trips {
            let trip = Trip(name: item.name, startDate: item.startDate, endDate: item.endDate)
            trip.id = item.id
            trip.notes = item.notes
            trip.createdAt = item.createdAt
            context.insert(trip)
            tripsByID[item.id] = trip
        }
        for item in archive.legs {
            let leg = TripLeg(mode: TravelMode(rawValue: item.modeRaw) ?? .train, origin: item.origin,
                              destination: item.destination, departure: item.departure)
            leg.id = item.id
            leg.arrival = item.arrival
            leg.notes = item.notes
            leg.originLatitude = item.originLatitude
            leg.originLongitude = item.originLongitude
            leg.destinationLatitude = item.destinationLatitude
            leg.destinationLongitude = item.destinationLongitude
            leg.trip = item.tripID.flatMap { tripsByID[$0] }
            context.insert(leg)
        }

        for item in archive.mail {
            let mail = MailSuggestion()
            mail.id = item.id
            mail.messageID = item.messageID
            mail.senderName = item.senderName
            mail.senderAddress = item.senderAddress
            mail.subject = item.subject
            mail.receivedAt = item.receivedAt
            mail.kindRaw = item.kindRaw
            mail.title = item.title
            mail.summary = item.summary
            mail.start = item.start
            mail.endsAt = item.endsAt
            mail.isAllDay = item.isAllDay
            mail.placeName = item.placeName
            mail.usedAI = item.usedAI
            mail.statusRaw = item.statusRaw
            mail.eventID = item.eventID
            mail.account = item.account
            mail.threadID = item.threadID
            mail.createdAt = item.createdAt
            context.insert(mail)
        }

        for item in archive.scans {
            let scan = ScanRecord(kind: ScanKind(rawValue: item.kindRaw) ?? .note, title: item.title,
                                  summary: item.summary, rawText: item.rawText)
            scan.id = item.id
            scan.createdAt = item.createdAt
            scan.eventStart = item.eventStart
            scan.venueName = item.venueName
            scan.latitude = item.latitude
            scan.longitude = item.longitude
            context.insert(scan)
        }
        for item in archive.expenses {
            let expense = Expense(merchant: item.merchant, amount: item.amount,
                                  category: ExpenseCategory(rawValue: item.categoryRaw) ?? .other,
                                  date: item.date)
            expense.id = item.id
            expense.currencyCode = item.currencyCode
            expense.note = item.note
            context.insert(expense)
        }
        for item in archive.departures {
            let log = DepartureLog(placeKind: PlaceKind(rawValue: item.placeKindRaw) ?? .home, date: item.date)
            log.id = item.id
            log.weekday = item.weekday
            log.minutesSinceMidnight = item.minutesSinceMidnight
            context.insert(log)
        }
        for item in archive.days {
            let day = DayLog(dayStart: item.dayStart)
            day.distanceMeters = item.distanceMeters
            day.placeVisits = item.placeVisits
            day.firstSeenAt = item.firstSeenAt
            day.lastSeenAt = item.lastSeenAt
            day.attendedIDs = item.attendedIDs
            day.missedIDs = item.missedIDs
            day.completions = item.completions
            context.insert(day)
        }
        for item in archive.reminders ?? [] {
            let reminder = Reminder(title: item.title, day: item.day, dueAt: item.dueAt, notes: item.notes)
            reminder.id = item.id
            reminder.completedAt = item.completedAt
            reminder.originRaw = item.originRaw
            reminder.createdAt = item.createdAt
            context.insert(reminder)
        }

        for (key, value) in archive.settings {
            UserDefaults.standard.set(value, forKey: key)
        }
        for (key, value) in archive.settingLists {
            UserDefaults.standard.set(value, forKey: key)
        }
        try context.save()
        return archive
    }

    // MARK: Pieces

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func filename(at date: Date) -> String {
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        return "PathOS-backup-\(stamp).json"
    }

    /// Preferences worth carrying: the mail rules, the cab, what's switched on.
    private static let settingKeys = [
        "pathos.preferredCab", "pathos.adaptiveSound", "pathos.speaksDirections",
        "pathos.mapLayers", "pathos.calendarEventsEnabled",
        "pathos.mapPOI.all", "pathos.mapPOI.groups", "pathos.repeatsUrgentAlerts",
    ]
    private static let settingListKeys = ["pathos.prioritySenders", "pathos.mutedSenders", "pathos.mailAccounts"]

    private static var savedSettings: [String: String] {
        var values: [String: String] = [:]
        for key in settingKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                values[key] = String(describing: value)
            }
        }
        return values
    }

    private static var savedSettingLists: [String: [String]] {
        var values: [String: [String]] = [:]
        for key in settingListKeys {
            if let list = UserDefaults.standard.stringArray(forKey: key) {
                values[key] = list
            }
        }
        return values
    }

    private func fetch<Model: PersistentModel>(_ type: Model.Type) -> [Model] {
        (try? context.fetch(FetchDescriptor<Model>())) ?? []
    }

    private func deleteEverything() throws {
        try context.delete(model: NotePhoto.self)
        try context.delete(model: SpatialNote.self)
        try context.delete(model: SavedPlace.self)
        try context.delete(model: PathEvent.self)
        try context.delete(model: TimetableEntry.self)
        try context.delete(model: TimetableException.self)
        try context.delete(model: TripLeg.self)
        try context.delete(model: Trip.self)
        try context.delete(model: MailSuggestion.self)
        try context.delete(model: ScanRecord.self)
        try context.delete(model: Expense.self)
        try context.delete(model: DepartureLog.self)
        try context.delete(model: DayLog.self)
        try context.delete(model: Reminder.self)
    }

    /// Keeps the last few and removes the rest, so backups can't fill the phone.
    private func tidy(in directory: URL) {
        let files = existing()
        guard files.count > keep else { return }
        for file in files.dropFirst(keep) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
