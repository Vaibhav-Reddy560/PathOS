import AuthenticationServices
import SwiftData
import SwiftUI

/// Mail waiting for a decision: events and deadlines to add, and updates worth knowing.
///
/// Sorted by the account it arrived at, so it's always clear which of your addresses it was sent
/// to, and within each, priority senders first; muted senders don't show. Nothing from Gmail
/// reaches your Day without passing through here.
struct MailInbox: View {
    @Environment(AppState.self) private var state
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Query(
        filter: #Predicate<MailSuggestion> { $0.statusRaw == "pending" },
        sort: \MailSuggestion.receivedAt,
        order: .reverse
    )
    private var pending: [MailSuggestion]
    /// One account's mail, or every account's.
    @State private var shownAccount: String?
    @State private var isManagingSenders = false
    @State private var isShowingMuted = false

    var body: some View {
        let mail = state.mail

        VStack(alignment: .leading, spacing: 16) {
            if mail.accounts.isEmpty {
                connectPrompt
            } else {
                ForEach(mail.accounts.filter { !$0.isSignedIn }) { account in
                    reconnect(account.email)
                }
                if mail.accounts.count > 1 {
                    accountPicker
                }
                // All: every account's mail in one list, newest first, each card saying which
                // address it came to. One account: just its mail, under its address.
                if mail.accounts.count > 1, shownAccount == nil {
                    allAccounts
                } else {
                    ForEach(mail.accounts.filter { shownAccount == nil || $0.email == shownAccount }) { account in
                        accountSection(account)
                    }
                }
                controls
            }
        }
        .sheet(isPresented: $isManagingSenders) {
            NavigationStack { MailSendersView() }
        }
    }

    // MARK: Accounts

    /// Waiting mail for an account, less muted senders.
    private func waiting(for email: String) -> [MailSuggestion] {
        pending.filter { state.mail.account(of: $0) == email }
    }

    private var accountPicker: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    chip(title: "All", count: visibleCount(pending), isSelected: shownAccount == nil) { shownAccount = nil }
                    ForEach(state.mail.accounts) { account in
                        chip(
                            title: Self.shortName(account.email),
                            count: visibleCount(waiting(for: account.email)),
                            isSelected: shownAccount == account.email
                        ) { shownAccount = account.email }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func chip(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(PathMotion.control) { action() }
        } label: {
            Text(count > 0 ? "\(title) · \(count)" : title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .ion : .mist)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.interactive() : .identity, in: .capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func visibleCount(_ suggestions: [MailSuggestion]) -> Int {
        suggestions.filter { !state.mail.isMuted($0.senderAddress) }.count
    }

    /// Every account's mail together, priority senders first, then newest first.
    @ViewBuilder
    private var allAccounts: some View {
        let mail = state.mail
        let arranged = SenderRules.arrange(pending, address: \.senderAddress, priority: mail.prioritySenders, muted: mail.mutedSenders)

        VStack(alignment: .leading, spacing: 10) {
            // Each account's state in a line, since there's no header per account here.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(mail.accounts) { account in
                    Text("\(Self.shortName(account.email)): \(status(of: account))")
                        .font(.caption)
                        .foregroundStyle(mail.accountErrors[account.email] == nil ? .mist : .amber)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 4)

            if arranged.priority.isEmpty && arranged.others.isEmpty {
                Text("Nothing waiting from any account.")
                    .font(.subheadline)
                    .foregroundStyle(.mist)
                    .padding(.horizontal, 4)
            }
            ForEach(arranged.priority) { MailSuggestionCard(suggestion: $0, showsAccount: true) }
            ForEach(arranged.others) { MailSuggestionCard(suggestion: $0, showsAccount: true) }
        }
    }

    /// One account: its address and state, then its mail, priority senders first.
    @ViewBuilder
    private func accountSection(_ account: MailService.Account) -> some View {
        let mail = state.mail
        let arranged = SenderRules.arrange(waiting(for: account.email), address: \.senderAddress,
                                           priority: mail.prioritySenders, muted: mail.mutedSenders)

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.ion)
                    Text(account.email)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ice)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    InstrumentLabel("\(arranged.priority.count + arranged.others.count)")
                }
                Text(status(of: account))
                    .font(.caption)
                    .foregroundStyle(mail.accountErrors[account.email] == nil ? .mist : .amber)
                    .lineLimit(3)
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)

            if arranged.priority.isEmpty && arranged.others.isEmpty && mail.reading[account.email] == nil && account.isSignedIn {
                Text("Nothing waiting from this account.")
                    .font(.subheadline)
                    .foregroundStyle(.mist)
                    .padding(.horizontal, 4)
            }
            ForEach(arranged.priority) { MailSuggestionCard(suggestion: $0) }
            ForEach(arranged.others) { MailSuggestionCard(suggestion: $0) }

            if arranged.mutedCount > 0 {
                Button {
                    withAnimation(PathMotion.control) { isShowingMuted.toggle() }
                } label: {
                    OneLineButtonLabel(title: isShowingMuted ? "Hide muted senders" : "\(arranged.mutedCount) from muted senders",
                                       symbol: isShowingMuted ? "eye.slash" : "speaker.slash")
                        .font(.subheadline.weight(.semibold))
                }
                .pathSecondaryAction()
                if isShowingMuted {
                    ForEach(waiting(for: account.email).filter { mail.isMuted($0.senderAddress) }) {
                        MailSuggestionCard(suggestion: $0)
                    }
                }
            }
        }
    }

    /// "Reading 4 of 30…", "Checked 2 min ago", or what went wrong.
    private func status(of account: MailService.Account) -> String {
        let mail = state.mail
        if let reading = mail.reading[account.email] {
            return reading.total > 0 ? "Reading \(reading.done + 1) of \(reading.total)…" : "Checking for new mail…"
        }
        if let error = mail.accountErrors[account.email] {
            return "Couldn't check: \(error)"
        }
        if !account.isSignedIn {
            return "Signed out by Google"
        }
        return account.lastCheckedAt.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet"
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                Task { await state.mail.check() }
            } label: {
                OneLineButtonLabel(title: state.mail.isChecking ? "Checking…" : "Check now", symbol: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
            }
            .pathSecondaryAction()
            .disabled(state.mail.isChecking)

            Button {
                isManagingSenders = true
            } label: {
                OneLineButtonLabel(title: "Senders", symbol: "star")
                    .font(.subheadline.weight(.semibold))
            }
            .pathSecondaryAction()
        }
    }

    /// "vaibhav.reddy560" for a Gmail address; the organisation, "bmsce.ac.in", for a college or
    /// work one, which says more than a roll number.
    static func shortName(_ email: String) -> String {
        let parts = email.split(separator: "@")
        guard parts.count == 2 else { return email }
        return isPublicDomain("@" + parts[1]) ? String(parts[0]) : String(parts[1])
    }

    /// Addresses anyone can have, where "everyone at" would mean the whole world.
    static func isPublicDomain(_ domain: String) -> Bool {
        ["@gmail.com", "@googlemail.com", "@yahoo.com", "@yahoo.co.in", "@outlook.com", "@hotmail.com", "@live.com",
         "@icloud.com", "@me.com", "@rediffmail.com", "@proton.me", "@protonmail.com"].contains(domain)
    }

    // MARK: Signing in

    private var connectPrompt: some View {
        ContentTile {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    SignalGlyph(symbol: "envelope", role: .world)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connect Gmail")
                            .font(.headline)
                            .foregroundStyle(.ice)
                        Text("PathOS reads new mail on your iPhone and picks out events, deadlines and updates. You approve each one before it goes on your Day.")
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                    }
                }
                Button {
                    Task { await state.mail.connect(present: webAuthenticationSession.googleSignIn) }
                } label: {
                    OneLineButtonLabel(title: state.mail.isConnecting ? "Signing in…" : "Sign in to Google", symbol: "envelope")
                        .font(.subheadline.weight(.semibold))
                }
                .pathPrimaryAction()
                .disabled(state.mail.isConnecting)
            }
        }
    }

    private func reconnect(_ email: String) -> some View {
        ContentTile {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    SignalGlyph(symbol: "envelope.badge", role: .attention)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reconnect \(email)")
                            .font(.headline)
                            .foregroundStyle(.ice)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text("Google signs PathOS out every 7 days while it's a test app, so new mail here isn't being checked.")
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                    }
                }
                .accessibilityElement(children: .combine)

                Button {
                    Task { await state.mail.connect(present: webAuthenticationSession.googleSignIn, reconnecting: email) }
                } label: {
                    OneLineButtonLabel(title: state.mail.isConnecting ? "Signing in…" : "Sign in again", symbol: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .pathSecondaryAction()
                .disabled(state.mail.isConnecting)
            }
        }
    }
}

// MARK: - A suggestion

private struct MailSuggestionCard: View {
    let suggestion: MailSuggestion
    /// Says which of your addresses it came to, where mail from several is mixed together.
    var showsAccount = false

    @Environment(AppState.self) private var state
    @Environment(\.openURL) private var openURL
    @State private var isAdding = false
    @State private var isReading = false

    var body: some View {
        ContentTile {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    SignalGlyph(symbol: suggestion.kind.symbol, role: .world)
                    VStack(alignment: .leading, spacing: 3) {
                        InstrumentLabel(headline, role: .world)
                        Text(suggestion.title)
                            .font(.headline)
                            .foregroundStyle(.ice)
                            .lineLimit(2)
                        if !suggestion.summary.isEmpty && suggestion.summary != suggestion.title {
                            Text(suggestion.summary)
                                .font(.subheadline)
                                .foregroundStyle(.mist)
                                .lineLimit(3)
                        }
                        if let place = suggestion.placeName {
                            Label(place, systemImage: MailTriage.isOnline(place) ? "video" : "mappin")
                                .font(.subheadline)
                                .foregroundStyle(.mist)
                                .lineLimit(1)
                        }
                        HStack(spacing: 5) {
                            if isPriority {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.aurora)
                                    .accessibilityLabel("Priority sender")
                            }
                            Text("\(suggestion.senderName) · \(suggestion.receivedAt.formatted(.relative(presentation: .named)))")
                                .font(.footnote)
                                .foregroundStyle(.mist)
                                .lineLimit(1)
                        }
                        if showsAccount, let account = state.mail.account(of: suggestion) {
                            Label("To \(MailInbox.shortName(account))", systemImage: "arrow.down.to.line")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.ion)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    senderMenu
                }
                .accessibilityElement(children: .combine)

                actions
            }
        }
        .contextMenu { menuItems }
        .sheet(isPresented: $isReading) {
            NavigationStack { MailReaderView(suggestion: suggestion) }
        }
    }

    private var isPriority: Bool { state.mail.isPriority(suggestion.senderAddress) }

    /// "Event · Sat 21 Sep, 2:00 PM", "To do · Thu 25 Sep", "Update".
    private var headline: String {
        let when = suggestion.kind == .update ? nil : suggestion.whenText
        return [suggestion.kind.label, when].compactMap { $0 }.joined(separator: " · ")
    }

    /// Every button the same height: the main action wide, then the rest, named where there's
    /// room, as symbols where there isn't, and under it when even that won't fit.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                primaryAction
                secondaryActions(named: true)
            }
            HStack(spacing: 8) {
                primaryAction
                secondaryActions(named: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                primaryAction
                HStack(spacing: 8) { secondaryActions(named: false) }
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch suggestion.kind {
        case .event, .task:
            if suggestion.canAddDirectly {
                Button(action: add) {
                    ActionLabel(title: isAdding ? "Adding…" : "Add to Day", symbol: "plus", isWide: true)
                }
                .pathPrimaryAction()
                .disabled(isAdding)
            } else {
                // No date in the email: the editor lets you set one before anything is saved.
                Button(action: edit) {
                    ActionLabel(title: "Set a time", symbol: "calendar", isWide: true)
                }
                .pathPrimaryAction()
            }
        case .update, .ignore:
            Button {
                state.mail.dismiss(suggestion)
            } label: {
                ActionLabel(title: "Got it", symbol: "checkmark", isWide: true)
            }
            .pathSecondaryAction()
        }
    }

    @ViewBuilder
    private func secondaryActions(named: Bool) -> some View {
        if suggestion.canAddDirectly {
            secondary("Edit", symbol: "pencil", named: named, action: edit)
        }
        secondary("Read", symbol: "envelope.open", named: named) { isReading = true }
        if suggestion.kind == .event || suggestion.kind == .task {
            secondary("Not now", symbol: "xmark", named: false) { state.mail.dismiss(suggestion) }
        }
    }

    /// A button beside the main one: its name and symbol, or just the symbol in a circle.
    @ViewBuilder
    private func secondary(_ title: String, symbol: String, named: Bool, action: @escaping () -> Void) -> some View {
        if named {
            Button(action: action) {
                ActionLabel(title: title, symbol: symbol)
            }
            .pathSecondaryAction()
        } else {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .pathSecondaryAction()
            .buttonBorderShape(.circle)
            .accessibilityLabel(title)
        }
    }

    /// Who the sender is to you, and what to do with this message.
    private var senderMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.mist)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .padding(.top, -10)
        .padding(.trailing, -10)
        .accessibilityLabel("More for \(suggestion.senderName)")
    }

    @ViewBuilder
    private var menuItems: some View {
        let address = suggestion.senderAddress
        let isMuted = state.mail.isMuted(address)
        Section(suggestion.senderName.isEmpty ? address : "\(suggestion.senderName) · \(address)") {
            Button(isPriority ? "Remove from priority" : "Always show first", systemImage: isPriority ? "star.slash" : "star") {
                state.mail.setPriority(address, !isPriority)
            }
            Button(isMuted ? "Unmute" : "Mute this sender", systemImage: isMuted ? "speaker.wave.2" : "speaker.slash") {
                state.mail.setMuted(address, !isMuted)
            }
            if let domain = address.split(separator: "@").last.map({ "@" + $0 }), !MailInbox.isPublicDomain(domain) {
                let everyone = state.mail.prioritySenders.contains(domain)
                Button(everyone ? "Remove everyone at \(domain)" : "Show everyone at \(domain) first", systemImage: "person.2") {
                    state.mail.setPriority(domain, !everyone)
                }
            }
        }
        Button("Read", systemImage: "envelope.open") { isReading = true }
        if let url = state.mail.gmailAppURL(for: suggestion), UIApplication.shared.canOpenURL(url) {
            Button("Open in Gmail", systemImage: "arrow.up.right") { openURL(url) }
        }
        Button("Dismiss", systemImage: "xmark", role: .destructive) { state.mail.dismiss(suggestion) }
    }

    private func add() {
        isAdding = true
        let isTask = suggestion.kind == .task
        Task {
            await state.mail.add(suggestion, near: state.location.location)
            isAdding = false
            state.haptics.success()
            state.showToast(isTask ? "Added to your Day with a reminder" : "Event added to your Day")
        }
    }

    private func edit() {
        state.eventSheet = EventSheetRequest(editing: nil, text: nil, mailSuggestion: suggestion.id)
    }
}

/// A card button's label: one line, one height; the main action takes the room left.
private struct ActionLabel: View {
    let title: String
    let symbol: String
    var isWide = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title)
                .lineLimit(1)
                .fixedSize()
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, isWide ? 0 : 4)
        .frame(maxWidth: isWide ? .infinity : nil, minHeight: 36)
    }
}

// MARK: - Reading a message

/// The whole message, fetched from Gmail to read here: PathOS keeps only its summary. Gmail's
/// app opens at the conversation where it can.
struct MailReaderView: View {
    let suggestion: MailSuggestion

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var message: MailMessage?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(suggestion.subject.isEmpty ? suggestion.title : suggestion.subject)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.ice)
                    .textSelection(.enabled)

                VStack(alignment: .leading, spacing: 3) {
                    Text("From \(suggestion.senderName) <\(suggestion.senderAddress)>")
                    if let account = state.mail.account(of: suggestion) {
                        Text("To \(account)")
                    }
                    Text(suggestion.receivedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.footnote)
                .foregroundStyle(.mist)
                .textSelection(.enabled)

                Divider().overlay(Color.mist.opacity(0.3))

                if let message {
                    Text(message.body.isEmpty ? message.snippet : message.body)
                        .font(.body)
                        .foregroundStyle(.ice)
                        .textSelection(.enabled)
                } else if let problem {
                    Text(problem)
                        .font(.subheadline)
                        .foregroundStyle(.amber)
                } else {
                    ProgressView()
                        .tint(.ion)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(20)
        }
        .background(Color.deepSurface)
        .navigationTitle("Mail")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            if let url = state.mail.gmailAppURL(for: suggestion), UIApplication.shared.canOpenURL(url) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Open in Gmail") { openURL(url) }
                }
            }
        }
        .task {
            do {
                message = try await state.mail.fullMessage(suggestion)
            } catch {
                problem = "Couldn't fetch this message: \(error.localizedDescription)"
            }
        }
    }
}

extension WebAuthenticationSession {
    /// Google's sign-in page, shown by iOS in its own secure browser sheet. The shared session
    /// means an account already signed in to Google in Safari is one tap away.
    var googleSignIn: GoogleSession.Presenter {
        { url, scheme in
            try await authenticate(
                using: url,
                callback: .customScheme(scheme),
                preferredBrowserSession: .shared,
                additionalHeaderFields: [:]
            )
        }
    }
}
