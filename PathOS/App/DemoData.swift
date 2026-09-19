#if DEBUG
import CoreLocation
import Foundation
import SwiftData

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
                    deckStop = deckStop == .collapsed ? .half : .collapsed
                }
            }
        }
        switch arguments.string(forKey: "PathOSDeckDetent") {
        case "medium": deckStop = .half
        case "large": deckStop = .full
        default: break
        }
    }
}
#endif
