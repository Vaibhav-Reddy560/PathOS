import Foundation
import Testing
@testable import PathOS

/// The file that outlives the app: it has to be readable back, exactly, years later.
struct BackupArchiveTests {
    private func filled() -> BackupArchive {
        var archive = BackupArchive()
        archive.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        archive.appVersion = "1.0"
        archive.places = [.init(id: UUID(), name: "Home", kindRaw: "home", latitude: 12.9265,
                                longitude: 77.5935, radius: 120, createdAt: Date(timeIntervalSince1970: 1_700_000_000))]
        archive.notes = [.init(id: UUID(), title: "Parked", body: "Level 2, near the lift",
                               latitude: 12.9, longitude: 77.6, radius: 60, photoData: Data([0xFF, 0xD8, 0xFF]),
                               tags: ["Parking"], createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                               lastSurfacedAt: nil, isActive: true)]
        archive.photos = [.init(id: UUID(), noteID: archive.notes[0].id, data: Data([0x89, 0x50, 0x4E, 0x47]),
                                createdAt: Date(timeIntervalSince1970: 1_700_000_200))]
        archive.events = [.init(id: UUID(), title: "Econvista", notes: "", start: Date(timeIntervalSince1970: 1_800_000_000),
                                endsAt: nil, isAllDay: false, placeName: "BMS College", latitude: 12.94,
                                longitude: 77.56, tags: [], photoData: nil, originRaw: "manual",
                                calendarEventID: nil, reminderMinutesBefore: 15,
                                createdAt: Date(timeIntervalSince1970: 1_700_000_300))]
        archive.sessions = [.init(id: UUID(), subject: "Physics", weekday: 2, startMinutes: 540,
                                  endMinutes: 600, room: "LH-3", teacher: nil, isActive: true,
                                  createdAt: Date(timeIntervalSince1970: 1_700_000_400))]
        archive.mail = [.init(id: UUID(), messageID: "abc", senderName: "Dean", senderAddress: "dean@bmsce.ac.in",
                              subject: "Fees", receivedAt: Date(timeIntervalSince1970: 1_700_000_500),
                              kindRaw: "deadline", title: "Fees due", summary: "", start: nil, endsAt: nil,
                              isAllDay: false, placeName: nil, usedAI: false, statusRaw: "pending",
                              eventID: nil, account: "me@gmail.com", threadID: "t1",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_600))]
        archive.settings = ["pathos.preferredCab": "uber"]
        archive.settingLists = ["pathos.prioritySenders": ["@bmsce.ac.in"]]
        return archive
    }

    /// Written and read back, it is the same thing — photos included.
    @Test func itSurvivesBeingWrittenAndReadBack() throws {
        let archive = filled()
        let restored = try BackupArchive.decode(BackupArchive.encode(archive))
        #expect(restored == archive)
        #expect(restored.notes.first?.photoData == Data([0xFF, 0xD8, 0xFF]))
        #expect(restored.photos.first?.noteID == archive.notes.first?.id)
        #expect(restored.settingLists["pathos.prioritySenders"] == ["@bmsce.ac.in"])
    }

    /// Dates are written to the millisecond, which is as exact as an ISO-8601 stamp gets while
    /// staying readable. A date made now comes back within that.
    @Test func datesComeBackToTheMillisecond() throws {
        var archive = BackupArchive()
        archive.places = [.init(id: UUID(), name: "Work", kindRaw: "work", latitude: 12.94,
                                longitude: 77.56, radius: 120, createdAt: Date())]
        let restored = try BackupArchive.decode(BackupArchive.encode(archive))
        let difference = abs((restored.places.first?.createdAt.timeIntervalSince1970 ?? 0)
            - (archive.places.first?.createdAt.timeIntervalSince1970 ?? 0))
        #expect(difference < 0.001)
    }

    /// Plain JSON with ISO dates, so anything can read it, not only this app.
    @Test func itIsReadableWithoutPathOS() throws {
        let data = try BackupArchive.encode(filled())
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == BackupArchive.currentVersion)
        let places = try #require(json["places"] as? [[String: Any]])
        #expect(places.first?["name"] as? String == "Home")
        #expect(String(data: data, encoding: .utf8)?.contains("2023-11-14") == true)
    }

    /// A file from a newer PathOS says so rather than restoring half of itself.
    @Test func aNewerFileIsRefused() throws {
        var archive = filled()
        archive.version = BackupArchive.currentVersion + 1
        let data = try BackupArchive.encode(archive)
        #expect(throws: BackupError.self) { try BackupArchive.decode(data) }
    }

    /// What you'd be putting back, in words.
    @Test func itSaysWhatItHolds() {
        let summary = filled().summary
        #expect(summary.contains("1 place"))
        #expect(summary.contains("1 memory"))
        #expect(summary.contains("2 photos"))
        #expect(summary.contains("1 event"))
        #expect(summary.contains("1 session"))
        #expect(BackupArchive().summary == "Nothing saved yet")
        #expect(BackupArchive().isEmpty)
        #expect(!filled().isEmpty)
    }

    /// One file per day, named so the newest is obvious in Files.
    @Test func backupsAreNamedByTheDay() {
        let name = BackupService.filename(at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(name.hasPrefix("PathOS-backup-2023-11-14"))
        #expect(name.hasSuffix(".json"))
    }

    // MARK: Fields added later

    /// A backup written before attendance, completions and reminders were kept still restores.
    /// The generated decoder refuses a missing key even for an array with a default, which is
    /// what made every older backup unreadable once attendance was added.
    @Test func anOlderBackupStillRestores() throws {
        let json = """
        {"version": 1, "createdAt": "2026-09-01T10:00:00.000Z", "appVersion": "0.9",
         "places": [], "notes": [], "photos": [], "events": [], "sessions": [], "exceptions": [],
         "trips": [], "legs": [], "mail": [], "scans": [], "expenses": [], "departures": [],
         "days": [{"dayStart": "2026-09-01T00:00:00.000Z", "distanceMeters": 4200, "placeVisits": 3}],
         "settings": {}, "settingLists": {}}
        """
        let archive = try BackupArchive.decode(Data(json.utf8))
        #expect(archive.days.count == 1)
        #expect(archive.days[0].distanceMeters == 4_200)
        #expect(archive.days[0].attendedIDs.isEmpty)
        #expect(archive.days[0].completions.isEmpty)
        #expect(archive.reminders == nil)
    }

    @Test func remindersAndCompletionsComeBack() throws {
        var archive = filled()
        let done = Date(timeIntervalSince1970: 1_800_003_000)
        archive.days = [.init(dayStart: Date(timeIntervalSince1970: 1_799_971_200), distanceMeters: 1_000,
                              placeVisits: 1, completions: [ItemCompletion(id: "event:x", at: done)])]
        archive.reminders = [.init(id: UUID(), title: "Buy milk", notes: "", day: Date(timeIntervalSince1970: 1_799_971_200),
                                   dueAt: nil, completedAt: done, originRaw: "captured",
                                   createdAt: Date(timeIntervalSince1970: 1_799_990_000))]
        let back = try BackupArchive.decode(BackupArchive.encode(archive))
        #expect(back.reminders == archive.reminders)
        #expect(back.days[0].completions == archive.days[0].completions)
    }
}
