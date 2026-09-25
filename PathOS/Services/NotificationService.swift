import Foundation
import Observation
import UserNotifications

@Observable
final class NotificationService: NSObject {
    nonisolated enum Category {
        static let commute = "pathos.commute"
        static let spatialNote = "pathos.spatialNote"
        static let exitCheck = "pathos.exitCheck"
        static let ambient = "pathos.ambient"
        static let event = "pathos.event"
        static let journey = "pathos.journey"
        static let mail = "pathos.mail"
        static let tripLeg = "pathos.tripLeg"
        /// "Still going?", answered from the notification itself.
        static let stillGoing = "pathos.stillGoing"
    }

    nonisolated enum Action {
        static let pinContext = "pathos.action.pinContext"
        static let trackLeg = "pathos.action.trackLeg"
        static let dropDeparture = "pathos.action.dropDeparture"
        static let keepDeparture = "pathos.action.keepDeparture"
    }

    private(set) var isAuthorized = false

    /// Called with the `pathos://` link of a tapped notification.
    @ObservationIgnored var onOpenURL: ((URL) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.commute,
                actions: [UNNotificationAction(identifier: Action.pinContext, title: "Pin to Lock Screen", options: [.foreground])],
                intentIdentifiers: []
            ),
            UNNotificationCategory(identifier: Category.spatialNote, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.exitCheck, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.ambient, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.event, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.journey, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.mail, actions: [], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Category.stillGoing,
                actions: [
                    UNNotificationAction(identifier: Action.dropDeparture, title: "Drop it", options: [.destructive]),
                    UNNotificationAction(identifier: Action.keepDeparture, title: "I'm going", options: []),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.tripLeg,
                actions: [UNNotificationAction(identifier: Action.trackLeg, title: "Start tracking", options: [.foreground])],
                intentIdentifiers: []
            ),
        ])
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        isAuthorized = granted
        return granted
    }

    func refreshStatus() async {
        let status = await Self.authorizationStatus()
        isAuthorized = status == .authorized || status == .provisional || status == .ephemeral
    }

    /// Delivers immediately.
    func post(id: String, title: String, body: String, category: String? = nil, link: URL? = nil,
              timeSensitive: Bool = false, sound: Bool = true, repeatAfter: TimeInterval? = nil) {
        let content = makeContent(title: title, body: body, category: category, link: link, sound: sound)
        if timeSensitive {
            content.interruptionLevel = .timeSensitive
        }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil), withCompletionHandler: nil)

        // A second one, in case the first went unheard. Opening PathOS takes it back.
        guard let repeatAfter, repeatAfter > 0 else { return }
        let again = makeContent(title: title, body: body, category: category, link: link, sound: sound)
        again.interruptionLevel = timeSensitive ? .timeSensitive : .active
        center.add(
            UNNotificationRequest(
                identifier: AlertEscalation.repeatID(of: id),
                content: again,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: repeatAfter, repeats: false)
            ),
            withCompletionHandler: nil
        )
    }

    /// Takes back every nudge that hasn't fired yet: you're holding the phone, so you've seen it.
    func cancelRepeats() {
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasSuffix(".again") }
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Delivers once at `date`, for events and journeys planned ahead.
    func schedule(id: String, at date: Date, title: String, body: String, category: String? = nil, link: URL? = nil, timeSensitive: Bool = false) {
        guard date > Date() else { return }
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let content = makeContent(title: title, body: body, category: category, link: link, sound: true)
        if timeSensitive {
            content.interruptionLevel = .timeSensitive
        }
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger), withCompletionHandler: nil)
    }

    /// Repeats every week at the given weekday (1 = Sunday) and time.
    func scheduleWeekly(id: String, weekday: Int, hour: Int, minute: Int, title: String, body: String, category: String?, link: URL?) {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let content = makeContent(title: title, body: body, category: category, link: link, sound: true)
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger), withCompletionHandler: nil)
    }

    func removePending(withPrefix prefix: String) async {
        let identifiers = await Self.pendingIdentifiers().filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func makeContent(title: String, body: String, category: String?, link: URL?, sound: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound {
            content.sound = .default
        }
        if let category {
            content.categoryIdentifier = category
        }
        if let link {
            content.userInfo = ["link": link.absoluteString]
        }
        return content
    }

    nonisolated private static func pendingIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { @Sendable requests in
                continuation.resume(returning: requests.map(\.identifier))
            }
        }
    }

    nonisolated private static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let link = response.notification.request.content.userInfo["link"] as? String
        let target: URL? = switch action {
        case Action.pinContext: URL(string: "pathos://context/pin")
        // The leg's own link, with "/track" to start following it rather than just show it.
        case Action.trackLeg: link.flatMap { URL(string: $0 + "/track") }
        // pathos://departure?id=… becomes pathos://departure/drop?id=…, answered without opening.
        case Action.dropDeparture: link.flatMap { URL(string: $0.replacingOccurrences(of: "://departure?", with: "://departure/drop?")) }
        case Action.keepDeparture: link.flatMap { URL(string: $0.replacingOccurrences(of: "://departure?", with: "://departure/keep?")) }
        default: link.flatMap(URL.init(string:))
        }
        if let target {
            Task { @MainActor in
                self.onOpenURL?(target)
            }
        }
        completionHandler()
    }
}
