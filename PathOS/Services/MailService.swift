import CoreLocation
import Foundation
import Observation
import SwiftData

/// Gmail, read on the phone: new mail is checked in the background, each message is read by the
/// on-device model, and anything worth your time waits in the Day deck until you approve it.
/// Several accounts can be read, such as a personal one and a college one; each has its own
/// sign-in and its own place in the mail.
@Observable
final class MailService {
    enum Connection: Equatable {
        case disconnected
        case connected
        /// Google withdrew a sign-in — every 7 days while the Cloud project is in Testing.
        case expired
    }

    /// A Gmail account PathOS reads.
    struct Account: Identifiable, Equatable {
        var email: String
        var isSignedIn: Bool
        /// When a check of it last finished without an error.
        var lastCheckedAt: Date?

        var id: String { email }
    }

    private(set) var accounts: [Account] = []
    private(set) var isChecking = false
    private(set) var isConnecting = false
    private(set) var lastError: String?
    /// Senders whose mail comes first: addresses, or "@college.edu" for everyone there.
    private(set) var prioritySenders: [String] = UserDefaults.standard.stringArray(forKey: Keys.prioritySenders) ?? [] {
        didSet { UserDefaults.standard.set(prioritySenders, forKey: Keys.prioritySenders) }
    }
    /// Senders you don't want to hear from: their mail isn't read and doesn't show.
    private(set) var mutedSenders: [String] = UserDefaults.standard.stringArray(forKey: Keys.mutedSenders) ?? [] {
        didSet { UserDefaults.standard.set(mutedSenders, forKey: Keys.mutedSenders) }
    }

    /// Connected when every account is signed in; expired while one needs signing in again.
    var connection: Connection {
        if accounts.isEmpty { return .disconnected }
        return accounts.contains { !$0.isSignedIn } ? .expired : .connected
    }

    /// The account whose check is oldest, so a check is due as soon as any account needs one.
    var lastCheckedAt: Date? {
        accounts.filter(\.isSignedIn).map { $0.lastCheckedAt ?? .distantPast }.min()
    }

    @ObservationIgnored private var sessions: [String: GoogleSession] = [:]
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let ai: AIClient
    @ObservationIgnored private let eventStore: EventStore
    @ObservationIgnored private let places: PlacesService
    @ObservationIgnored private let notifications: NotificationService

    private nonisolated enum Keys {
        static let accounts = "pathos.mail.accounts"
        static let prioritySenders = "pathos.mail.prioritySenders"
        static let mutedSenders = "pathos.mail.mutedSenders"
        static func lastChecked(_ email: String) -> String { "pathos.mail.lastChecked." + email }
        /// Where the next search of that account starts. Only moves once everything before it has been read.
        static func cursor(_ email: String) -> String { "pathos.mail.cursor." + email }

        // From before there could be more than one account.
        static let legacyAccount = "pathos.mail.account"
        static let legacyLastChecked = "pathos.mail.lastChecked"
        static let legacyCursor = "pathos.mail.cursor"
        static let legacyWasConnected = "pathos.mail.wasConnected"
    }

    /// The newest messages a single check looks at. Mail beyond this in one gap is left unread.
    static let searchWindow = 30

    init(
        context: ModelContext,
        ai: AIClient,
        eventStore: EventStore,
        places: PlacesService,
        notifications: NotificationService
    ) {
        self.context = context
        self.ai = ai
        self.eventStore = eventStore
        self.places = places
        self.notifications = notifications
        Self.moveSingleAccountSetUp()

        let defaults = UserDefaults.standard
        for email in defaults.stringArray(forKey: Keys.accounts) ?? [] {
            let session = GoogleSession(keychainAccount: GoogleSession.keychainAccount(for: email))
            sessions[email] = session
            accounts.append(Account(
                email: email,
                isSignedIn: session.isSignedIn,
                lastCheckedAt: defaults.object(forKey: Keys.lastChecked(email)) as? Date
            ))
        }
    }

    /// The one account PathOS used to keep, moved into the list of accounts, once.
    private static func moveSingleAccountSetUp() {
        let defaults = UserDefaults.standard
        guard defaults.stringArray(forKey: Keys.accounts) == nil else { return }
        var emails: [String] = []
        if let email = defaults.string(forKey: Keys.legacyAccount)?.lowercased() {
            GoogleSession(keychainAccount: GoogleSession.legacyKeychainAccount).rekey(to: GoogleSession.keychainAccount(for: email))
            defaults.set(defaults.object(forKey: Keys.legacyCursor), forKey: Keys.cursor(email))
            defaults.set(defaults.object(forKey: Keys.legacyLastChecked), forKey: Keys.lastChecked(email))
            emails = [email]
        }
        defaults.set(emails, forKey: Keys.accounts)
        for key in [Keys.legacyAccount, Keys.legacyCursor, Keys.legacyLastChecked, Keys.legacyWasConnected] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Accounts

    /// Adds a Gmail account, or signs one back in when `email` names it.
    func connect(present: GoogleSession.Presenter, reconnecting email: String? = nil) async {
        isConnecting = true
        defer { isConnecting = false }
        let session = GoogleSession(keychainAccount: "google.tokens.signing-in")
        do {
            try await session.signIn(present: present, loginHint: email)
            let address = try await session.profile().emailAddress.lowercased()
            session.rekey(to: GoogleSession.keychainAccount(for: address))
            sessions[address] = session
            if let index = accounts.firstIndex(where: { $0.email == address }) {
                accounts[index].isSignedIn = true
            } else {
                accounts.append(Account(email: address, isSignedIn: true))
                UserDefaults.standard.set(accounts.map(\.email), forKey: Keys.accounts)
            }
            lastError = nil
            await check()
        } catch GoogleOAuthError.cancelled {
            return
        } catch {
            await session.signOut()
            lastError = error.localizedDescription
        }
    }

    /// Signs one account out and forgets what its mail said. Events you already approved stay on
    /// your Day.
    func disconnect(_ email: String) async {
        await sessions[email]?.signOut()
        sessions[email] = nil
        accounts.removeAll { $0.email == email }
        let defaults = UserDefaults.standard
        defaults.set(accounts.map(\.email), forKey: Keys.accounts)
        defaults.removeObject(forKey: Keys.cursor(email))
        defaults.removeObject(forKey: Keys.lastChecked(email))
        lastError = nil
        for suggestion in (try? context.fetch(FetchDescriptor<MailSuggestion>())) ?? []
        where suggestion.status != .added && (suggestion.account == email || (suggestion.account == nil && accounts.isEmpty)) {
            context.delete(suggestion)
        }
        try? context.save()
    }

    /// The account a suggestion arrived at: its own, or for mail read before there could be more
    /// than one, the first.
    func account(of suggestion: MailSuggestion) -> String? {
        suggestion.account ?? accounts.first?.email
    }

    // MARK: Senders

    func isPriority(_ address: String) -> Bool { SenderRules.matchesAny(prioritySenders, address: address) }
    func isMuted(_ address: String) -> Bool { SenderRules.matchesAny(mutedSenders, address: address) }

    /// Adds or removes a priority sender. Returns false when `rule` is neither an address nor a domain.
    @discardableResult
    func setPriority(_ rule: String, _ isOn: Bool) -> Bool {
        guard let rule = SenderRules.normalized(rule) else { return false }
        prioritySenders.removeAll { $0 == rule }
        if isOn {
            prioritySenders.append(rule)
            mutedSenders.removeAll { $0 == rule }
        }
        return true
    }

    /// Mutes or unmutes a sender. Returns false when `rule` is neither an address nor a domain.
    @discardableResult
    func setMuted(_ rule: String, _ isOn: Bool) -> Bool {
        guard let rule = SenderRules.normalized(rule) else { return false }
        mutedSenders.removeAll { $0 == rule }
        if isOn {
            mutedSenders.append(rule)
            prioritySenders.removeAll { $0 == rule }
        }
        return true
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

    /// Reads mail that arrived since the last check, account by account. `limit` caps how many
    /// messages each account has read, so a background check fits in the time iOS gives it; the
    /// rest are picked up next time.
    @discardableResult
    func check(limit: Int = 25, notify: Bool = false) async -> Int {
        guard !isChecking else { return 0 }
        isChecking = true
        defer { isChecking = false }

        var found: [MailSuggestion] = []
        for account in accounts where account.isSignedIn {
            found += await check(account.email, limit: limit, notify: notify)
        }
        if notify {
            announce(found)
        }
        pruneSkipped()
        return found.count
    }

    private func check(_ email: String, limit: Int, notify: Bool) async -> [MailSuggestion] {
        guard let session = sessions[email] else { return [] }
        let defaults = UserDefaults.standard
        let startedAt = Date()
        do {
            let cursor = defaults.object(forKey: Keys.cursor(email)) as? Date
            let ids = try await session.messageIDs(matching: MailParsing.searchQuery(since: cursor), max: Self.searchWindow)
            let known = knownMessageIDs()
            let unread = ids.filter { !known.contains($0) }

            var found: [MailSuggestion] = []
            var readAll = unread.count <= limit
            for id in unread.prefix(limit) {
                let message = MailParsing.message(from: try await session.message(id: id))
                // Muted senders' mail isn't read at all; it's noted only so it's never fetched again.
                let proposal: MailProposal
                if isMuted(message.senderAddress) {
                    proposal = MailProposal(kind: .ignore, title: message.subject, summary: "", usedAI: false)
                } else if let read = await triage(message) {
                    proposal = read
                } else {
                    // The model is busy. Leave this and the rest for the next check.
                    readAll = false
                    break
                }
                let suggestion = MailSuggestion(message: message, proposal: proposal, account: email)
                context.insert(suggestion)
                try? context.save()
                if suggestion.status == .pending {
                    found.append(suggestion)
                }
            }

            if readAll {
                defaults.set(startedAt, forKey: Keys.cursor(email))
            }
            defaults.set(startedAt, forKey: Keys.lastChecked(email))
            if let index = accounts.firstIndex(where: { $0.email == email }) {
                accounts[index].lastCheckedAt = startedAt
            }
            lastError = nil
            return found
        } catch GoogleOAuthError.signInExpired {
            if let index = accounts.firstIndex(where: { $0.email == email }) {
                accounts[index].isSignedIn = false
            }
            if notify {
                notifications.post(
                    id: "pathos.mail.expired.\(email)",
                    title: "Reconnect Gmail",
                    body: "Google signed PathOS out of \(email), as it does every 7 days while PathOS is a test app. Tap to sign in again.",
                    category: NotificationService.Category.mail,
                    link: URL(string: "pathos://settings")
                )
            }
        } catch {
            lastError = "\(email): \(error.localizedDescription)"
        }
        return []
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
        let arranged = SenderRules.arrange(found, address: \.senderAddress, priority: prioritySenders, muted: mutedSenders)
        let found = arranged.priority + arranged.others
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
            link: URL(string: "pathos://mail")
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
