import CoreLocation
import Foundation
import Observation
import SwiftData

/// Gmail, read on the phone: new mail is checked in the background, each message is read by the
/// on-device model, and anything worth your time waits in the Day deck until you approve it.
@Observable
final class MailService {
    enum Connection: Equatable {
        case disconnected
        case connected
        /// Google withdrew the sign-in — every 7 days while the Cloud project is in Testing.
        case expired
    }

    private(set) var connection: Connection
    private(set) var isChecking = false
    private(set) var isConnecting = false
    private(set) var lastError: String?
    /// The Gmail address, for Settings and for opening messages in the right account.
    private(set) var account: String? = UserDefaults.standard.string(forKey: Keys.account) {
        didSet { UserDefaults.standard.set(account, forKey: Keys.account) }
    }
    /// When a check last finished without an error.
    private(set) var lastCheckedAt: Date? = UserDefaults.standard.object(forKey: Keys.lastChecked) as? Date {
        didSet { UserDefaults.standard.set(lastCheckedAt, forKey: Keys.lastChecked) }
    }

    /// Where the next search starts. Only moves once everything before it has been read.
    @ObservationIgnored private var cursor: Date? {
        get { UserDefaults.standard.object(forKey: Keys.cursor) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Keys.cursor) }
    }

    @ObservationIgnored private let session: GoogleSession
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let ai: AIClient
    @ObservationIgnored private let eventStore: EventStore
    @ObservationIgnored private let places: PlacesService
    @ObservationIgnored private let notifications: NotificationService

    private nonisolated enum Keys {
        static let account = "pathos.mail.account"
        static let lastChecked = "pathos.mail.lastChecked"
        static let cursor = "pathos.mail.cursor"
        static let wasConnected = "pathos.mail.wasConnected"
    }

    /// The newest messages a single check looks at. Mail beyond this in one gap is left unread.
    static let searchWindow = 30

    init(
        context: ModelContext,
        ai: AIClient,
        eventStore: EventStore,
        places: PlacesService,
        notifications: NotificationService,
        session: GoogleSession = GoogleSession()
    ) {
        self.context = context
        self.ai = ai
        self.eventStore = eventStore
        self.places = places
        self.notifications = notifications
        self.session = session
        if session.isSignedIn {
            connection = .connected
        } else {
            connection = UserDefaults.standard.bool(forKey: Keys.wasConnected) ? .expired : .disconnected
        }
    }

    // MARK: Connecting

    func connect(present: GoogleSession.Presenter) async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await session.signIn(present: present)
            account = try? await session.profile().emailAddress
            UserDefaults.standard.set(true, forKey: Keys.wasConnected)
            connection = .connected
            lastError = nil
            await check()
        } catch GoogleOAuthError.cancelled {
            return
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Signs out and forgets what the mail said. Events you already approved stay on your Day.
    func disconnect() async {
        await session.signOut()
        UserDefaults.standard.set(false, forKey: Keys.wasConnected)
        account = nil
        lastCheckedAt = nil
        cursor = nil
        lastError = nil
        connection = .disconnected
        for suggestion in (try? context.fetch(FetchDescriptor<MailSuggestion>())) ?? [] where suggestion.status != .added {
            context.delete(suggestion)
        }
        try? context.save()
    }

    // MARK: Checking

    /// Checks unless it did so recently. Returns how many new things are waiting for you.
    @discardableResult
    func checkIfDue(every interval: TimeInterval, limit: Int = 25, notify: Bool = false) async -> Int {
        if let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < interval {
            return 0
        }
        return await check(limit: limit, notify: notify)
    }

    /// Reads mail that arrived since the last check. `limit` caps how many messages are read, so a
    /// background check fits in the time iOS gives it; the rest are picked up next time.
    @discardableResult
    func check(limit: Int = 25, notify: Bool = false) async -> Int {
        guard connection == .connected, !isChecking else { return 0 }
        isChecking = true
        defer { isChecking = false }

        let startedAt = Date()
        do {
            let ids = try await session.messageIDs(matching: MailParsing.searchQuery(since: cursor), max: Self.searchWindow)
            let known = knownMessageIDs()
            let unread = ids.filter { !known.contains($0) }

            var found: [MailSuggestion] = []
            var readAll = unread.count <= limit
            for id in unread.prefix(limit) {
                let message = MailParsing.message(from: try await session.message(id: id))
                guard let proposal = await triage(message) else {
                    // The model is busy. Leave this and the rest for the next check.
                    readAll = false
                    break
                }
                let suggestion = MailSuggestion(message: message, proposal: proposal)
                context.insert(suggestion)
                try? context.save()
                if suggestion.status == .pending {
                    found.append(suggestion)
                }
            }

            if readAll {
                cursor = startedAt
            }
            lastCheckedAt = startedAt
            lastError = nil
            if notify {
                announce(found)
            }
            pruneSkipped()
            return found.count
        } catch GoogleOAuthError.signInExpired {
            connection = .expired
            if notify {
                notifications.post(
                    id: "pathos.mail.expired",
                    title: "Reconnect Gmail",
                    body: "Google signs PathOS out every 7 days while it's a test app. Tap to sign in again.",
                    category: NotificationService.Category.mail,
                    link: URL(string: "pathos://settings")
                )
            }
        } catch {
            lastError = error.localizedDescription
        }
        return 0
    }

    /// The on-device model when it's available, rules when it isn't. Nil means try again later.
    private func triage(_ message: MailMessage) async -> MailProposal? {
        var proposal = MailTriage.heuristic(message)
        if ai.isAvailable {
            do {
                proposal = try await ai.readMail(message)
            } catch where AIClient.isTransient(error) {
                return nil
            } catch {
                // Guardrails or a message too long for the model: the rules' reading stands.
            }
        }
        return MailTriage.finalize(proposal, message: message)
    }

    private func knownMessageIDs() -> Set<String> {
        Set(((try? context.fetch(FetchDescriptor<MailSuggestion>())) ?? []).map(\.messageID))
    }

    /// Skipped mail is only kept to avoid reading it twice; after a month the search has moved past it.
    private func pruneSkipped(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let skipped = MailStatus.skipped.rawValue
        let descriptor = FetchDescriptor<MailSuggestion>(predicate: #Predicate { $0.statusRaw == skipped && $0.receivedAt < cutoff })
        for suggestion in (try? context.fetch(descriptor)) ?? [] {
            context.delete(suggestion)
        }
        try? context.save()
    }

    private func announce(_ found: [MailSuggestion]) {
        guard let first = found.first else { return }
        let title: String
        let body: String
        if found.count == 1 {
            title = "\(first.kind.label) from your mail"
            body = [first.title, first.whenText].compactMap { $0 }.joined(separator: " · ")
        } else {
            title = "\(found.count) things from your mail"
            body = found.prefix(3).map(\.title).joined(separator: " · ")
        }
        notifications.post(
            id: "pathos.mail.\(first.messageID)",
            title: title,
            body: body + ". Tap to review.",
            category: NotificationService.Category.mail,
            link: URL(string: "pathos://day")
        )
    }

    // MARK: Your decisions

    func suggestion(id: UUID) -> MailSuggestion? {
        let descriptor = FetchDescriptor<MailSuggestion>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    /// Approves a suggestion as it stands: it becomes an event on your Day, with a reminder.
    func add(_ suggestion: MailSuggestion, near location: CLLocation?) async {
        guard suggestion.canAddDirectly, let start = suggestion.start else { return }
        var coordinate: CLLocationCoordinate2D?
        if let place = suggestion.placeName, !MailTriage.isOnline(place), let location {
            coordinate = (try? await places.search(place, near: location, radius: 30_000))?.first?.coordinate
        }

        let event = PathEvent(
            title: suggestion.title,
            start: start,
            endsAt: Self.end(for: suggestion, start: start),
            notes: Self.notes(for: suggestion),
            placeName: suggestion.placeName,
            coordinate: coordinate,
            tags: suggestion.kind == .task ? ["Task"] : [],
            origin: .mail,
            reminderMinutesBefore: suggestion.kind == .task ? 60 : 15
        )
        event.isAllDay = suggestion.isAllDay
        eventStore.save(event)
        markAdded(id: suggestion.id, eventID: event.id)
    }

    func markAdded(id: UUID, eventID: UUID) {
        guard let suggestion = suggestion(id: id) else { return }
        suggestion.status = .added
        suggestion.eventID = eventID
        try? context.save()
    }

    func dismiss(_ suggestion: MailSuggestion) {
        suggestion.status = .dismissed
        try? context.save()
    }

    /// A task is a moment, not a stretch of time; an all-day item runs to the end of its day.
    static func end(for suggestion: MailSuggestion, start: Date) -> Date? {
        if suggestion.isAllDay {
            return Calendar.current.startOfDay(for: start).addingTimeInterval(86_399)
        }
        return suggestion.kind == .task ? start : suggestion.endsAt
    }

    /// The summary, and where it came from, so the event makes sense without the email.
    static func notes(for suggestion: MailSuggestion) -> String {
        let source = "From \(suggestion.senderName): “\(suggestion.subject)”"
        return suggestion.summary.isEmpty ? source : "\(suggestion.summary)\n\n\(source)"
    }
}
