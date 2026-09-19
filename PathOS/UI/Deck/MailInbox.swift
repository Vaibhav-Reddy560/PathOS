import AuthenticationServices
import SwiftData
import SwiftUI

/// Mail waiting for a decision: events and deadlines to add, and updates worth knowing, from
/// every connected account. Priority senders come first; muted senders don't show at all.
/// Nothing from Gmail reaches your Day without passing through here.
struct MailInbox: View {
    @Environment(AppState.self) private var state
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Query(
        filter: #Predicate<MailSuggestion> { $0.statusRaw == "pending" },
        sort: \MailSuggestion.receivedAt,
        order: .reverse
    )
    private var pending: [MailSuggestion]
    @State private var isManagingSenders = false
    @State private var isShowingMuted = false

    var body: some View {
        let mail = state.mail
        let arranged = SenderRules.arrange(pending, address: \.senderAddress, priority: mail.prioritySenders, muted: mail.mutedSenders)

        VStack(alignment: .leading, spacing: 16) {
            if mail.accounts.isEmpty {
                connectPrompt
            } else {
                ForEach(mail.accounts.filter { !$0.isSignedIn }) { account in
                    reconnect(account.email)
                }
                accountsLine

                if pending.isEmpty || (arranged.priority.isEmpty && arranged.others.isEmpty && !isShowingMuted) {
                    EmptyState(
                        symbol: "envelope.open",
                        title: "Nothing waiting",
                        message: "Events, deadlines and updates from your mail appear here for you to add or dismiss."
                    )
                }
                if !arranged.priority.isEmpty {
                    section("Priority", arranged.priority)
                }
                if !arranged.others.isEmpty {
                    section(arranged.priority.isEmpty ? "From your mail" : "Everything else", arranged.others)
                }
                if arranged.mutedCount > 0 {
                    Button {
                        withAnimation(PathMotion.control) { isShowingMuted.toggle() }
                    } label: {
                        Label(isShowingMuted ? "Hide muted senders" : "\(arranged.mutedCount) from muted senders",
                              systemImage: isShowingMuted ? "eye.slash" : "speaker.slash")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .pathSecondaryAction()
                    if isShowingMuted {
                        section("Muted", pending.filter { mail.isMuted($0.senderAddress) })
                    }
                }
            }
        }
        .sheet(isPresented: $isManagingSenders) {
            NavigationStack { MailSendersView() }
        }
    }

    private func section(_ title: String, _ suggestions: [MailSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: title, trailing: "\(suggestions.count)")
            ForEach(suggestions) { suggestion in
                MailSuggestionCard(suggestion: suggestion)
            }
        }
    }

    /// Which accounts are read, when, and the way to change who comes first.
    private var accountsLine: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.mail.accounts.map(\.email).joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.mist)
                .lineLimit(2)
            HStack(spacing: 10) {
                Button {
                    Task { await state.mail.check() }
                } label: {
                    OneLineButtonLabel(title: state.mail.isChecking ? "Checking…" : "Check now", symbol: "arrow.clockwise")
                }
                .pathSecondaryAction()
                .disabled(state.mail.isChecking)

                Button {
                    isManagingSenders = true
                } label: {
                    OneLineButtonLabel(title: "Senders", symbol: "star")
                }
                .pathSecondaryAction()
            }
        }
    }

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
                    Label(state.mail.isConnecting ? "Signing in…" : "Sign in to Google", systemImage: "envelope")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
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
                    Label(state.mail.isConnecting ? "Signing in…" : "Sign in again", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .pathSecondaryAction()
                .disabled(state.mail.isConnecting)
            }
        }
    }
}

private struct MailSuggestionCard: View {
    let suggestion: MailSuggestion

    @Environment(AppState.self) private var state
    @Environment(\.openURL) private var openURL
    @State private var isAdding = false

    var body: some View {
        ContentTile {
            VStack(alignment: .leading, spacing: 12) {
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
                    }
                    Spacer(minLength: 0)
                    senderMenu
                }
                .accessibilityElement(children: .combine)

                actions
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
            }
        }
        .contextMenu { menuItems }
    }

    private var isPriority: Bool { state.mail.isPriority(suggestion.senderAddress) }

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
        if let url = gmailURL {
            Button("Open in Gmail", systemImage: "envelope") { openURL(url) }
        }
        Button("Dismiss", systemImage: "xmark", role: .destructive) { state.mail.dismiss(suggestion) }
    }

    /// "Event · Sat 21 Sep, 2:00 PM", "To do · Thu 25 Sep", "Update".
    private var headline: String {
        let when = suggestion.kind == .update ? nil : suggestion.whenText
        return [suggestion.kind.label, when].compactMap { $0 }.joined(separator: " · ")
    }

    private var gmailURL: URL? {
        MailParsing.webURL(messageID: suggestion.messageID, account: state.mail.account(of: suggestion))
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            switch suggestion.kind {
            case .event, .task:
                if suggestion.canAddDirectly {
                    Button(action: add) {
                        Label {
                            Text(isAdding ? "Adding…" : "Add to Day")
                        } icon: {
                            Image(systemName: "plus").foregroundStyle(.aurora)
                        }
                        .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .pathSecondaryAction()
                    .disabled(isAdding)

                    Button(action: edit) {
                        Text("Edit")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .pathSecondaryAction()
                } else {
                    // No date in the email: the editor lets you set one before anything is saved.
                    Button(action: edit) {
                        Label("Set a time", systemImage: "calendar")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .pathSecondaryAction()
                }

                Button {
                    state.mail.dismiss(suggestion)
                } label: {
                    Text("Not now")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .pathSecondaryAction()

            case .update, .ignore:
                Button {
                    state.mail.dismiss(suggestion)
                } label: {
                    Label("Got it", systemImage: "checkmark")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .pathSecondaryAction()

                if let url = gmailURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open in Gmail", systemImage: "arrow.up.right")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .pathSecondaryAction()
                }
            }
        }
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

extension MailInbox {
    /// Addresses anyone can have, where "everyone at" would mean the whole world.
    static func isPublicDomain(_ domain: String) -> Bool {
        ["@gmail.com", "@googlemail.com", "@yahoo.com", "@yahoo.co.in", "@outlook.com", "@hotmail.com", "@live.com",
         "@icloud.com", "@me.com", "@rediffmail.com", "@proton.me", "@protonmail.com"].contains(domain)
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
