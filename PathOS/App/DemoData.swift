#if DEBUG
import CoreLocation
import Foundation
import SwiftData
import UIKit

extension AppState {
    /// Launch with `-PathOSDemoData` to seed places, memories and an upcoming event around
    /// MG Road, Bengaluru (12.9716, 77.5946), so every map state can be checked in the simulator.
    func seedDemoDataIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-PathOSDemoData"), vault.allPlaces().isEmpty else { return }

        let center = CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)
        func offset(north: Double, east: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: center.latitude + north, longitude: center.longitude + east)
        }

        vault.setPlace(.home, name: "Home", at: offset(north: 0.009, east: 0.006))
        vault.setPlace(.work, name: "Work", at: offset(north: -0.005, east: -0.004))
        vault.saveNote(title: "Car · Level B2, Pillar C-14", body: "Near the lift lobby", at: offset(north: 0.0014, east: -0.0011))
        vault.saveNote(title: "Locker 42", body: "Code 1908", at: offset(north: -0.0021, east: 0.0017))

        let venue = offset(north: 0.0032, east: 0.0024)
        let event = ScanRecord(kind: .event, title: "Jazz at the Courtyard", summary: "Live quartet, free entry", rawText: "")
        event.eventStart = Date().addingTimeInterval(40 * 60)
        event.venueName = "The Courtyard"
        event.latitude = venue.latitude
        event.longitude = venue.longitude
        modelContainer.mainContext.insert(event)

        let campus = offset(north: -0.0042, east: 0.0035)
        let lecture = PathEvent(
            title: "DBMS lecture",
            start: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date(),
            endsAt: Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date()),
            notes: "Room 304",
            placeName: "Campus block B",
            coordinate: campus,
            tags: ["Class"],
            origin: .timetable
        )
        let meetup = PathEvent(
            title: "Design meetup",
            start: Date().addingTimeInterval(25 * 60),
            endsAt: Date().addingTimeInterval(115 * 60),
            notes: "Bring the prototype",
            placeName: "The Courtyard",
            coordinate: venue,
            tags: ["Friends", "Work"],
            origin: .captured
        )
        modelContainer.mainContext.insert(lecture)
        modelContainer.mainContext.insert(meetup)

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let log = DayLog(dayStart: Calendar.current.startOfDay(for: yesterday))
        log.distanceMeters = 8_450
        log.firstSeenAt = yesterday
        log.lastSeenAt = yesterday
        modelContainer.mainContext.insert(log)

        try? modelContainer.mainContext.save()
    }

    private func seedDemoMail() {
        let accounts = ["vaibhav.reddy560@gmail.com", "1bm22cs001@bmsce.ac.in"]
        mail.seedDemoAccounts(accounts)
        let context = modelContainer.mainContext
        guard ((try? context.fetch(FetchDescriptor<MailSuggestion>())) ?? []).isEmpty else { return }
        let samples: [(account: String, sender: String, address: String, kind: MailKind, title: String, summary: String, start: Date?)] = [
            (accounts[0], "Tanu Goel", "tanu@econvista.org", .event, "Econvista 2026", "Attend Econvista 2026 to explore AI and India's economic future.", Date().addingTimeInterval(86_400)),
            (accounts[0], "Pentel", "rewards@pentel.com", .update, "Creator Collective Rewards", "Program to earn points by engaging in Creator Collective activities.", nil),
            (accounts[1], "Dean Academics", "dean@bmsce.ac.in", .task, "Submit the internship form", "Upload the signed form on the portal.", Date().addingTimeInterval(3 * 86_400)),
            (accounts[1], "CSE Department", "hod@cse.bmsce.ac.in", .event, "Guest lecture: compilers", "Seminar hall 2, all third years.", nil),
        ]
        for sample in samples {
            let message = MailMessage(id: UUID().uuidString, threadID: UUID().uuidString, subject: sample.title, senderName: sample.sender,
                                      senderAddress: sample.address, receivedAt: Date().addingTimeInterval(-7_200), snippet: sample.summary,
                                      body: sample.summary, labels: [])
            let proposal = MailProposal(kind: sample.kind, title: sample.title, summary: sample.summary, start: sample.start, usedAI: false)
            context.insert(MailSuggestion(message: message, proposal: proposal, account: sample.account))
        }
        try? context.save()
    }

    /// `-PathOSDeepLink pathos://radar` and `-PathOSDeckDetent large` open a screen at launch,
    /// and `-PathOSDemoReadouts YES` fills the peek strip,
    /// avoiding the simulator's "Open in PathOS?" prompt that `simctl openurl` triggers.
    func applyDebugLaunchArguments() {
        let arguments = UserDefaults.standard
        if let link = arguments.string(forKey: "PathOSDeepLink"), let url = URL(string: link) {
            handle(url: url)
        }
        if arguments.bool(forKey: "PathOSDemoReadouts") {
            weather.seedDemoSnapshot()
            barometer.seedDemoAltitude()
        }
        // `-PathOSChangeProposal YES` shows a drafted change on the assistant, without the model.
        if arguments.bool(forKey: "PathOSChangeProposal") {
            let start = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: Date().addingTimeInterval(86_400)) ?? Date()
            pendingChange = PendingChange(
                request: "Move tomorrow's DBMS class to 4",
                change: .moveClass(slotID: UUID(), subject: "DBMS", room: "304",
                                   from: DateInterval(start: start, duration: 55 * 60),
                                   to: DateInterval(start: start.addingTimeInterval(3_600), duration: 55 * 60),
                                   everyWeek: false)
            )
            isAssistantActive = true
        }
        // `-PathOSDeckCycle YES` opens and collapses the deck every few seconds, to record it.
        if arguments.bool(forKey: "PathOSDeckCycle") {
            Task {
                while true {
                    try? await Task.sleep(for: .seconds(3))
                    guard isLaunchComplete else { continue }
                    deckStop = deckStop == .collapsed ? .full : .collapsed
                }
            }
        }
        // `-PathOSDemoMail YES` fills Day → Mail from two accounts, for checking its layout in the
        // simulator, which can't sign in to Google.
        if arguments.bool(forKey: "PathOSDemoMail") {
            seedDemoMail()
        }
        // `-PathOSAppIcon map|route` switches the Home Screen icon, so a trial one can be put on a
        // phone from here rather than tapped through Settings.
        if let icon = arguments.string(forKey: "PathOSAppIcon") {
            Task {
                // iOS refuses the change until the app is properly foregrounded.
                try? await Task.sleep(for: .seconds(1))
                try? await UIApplication.shared.setAlternateIconName(icon == "map" ? "AppIconMap" : nil)
            }
        }
        switch arguments.string(forKey: "PathOSDeckDetent") {
        case "medium", "large": deckStop = .full
        default: break
        }
    }
}
#endif
