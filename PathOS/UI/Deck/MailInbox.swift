import AuthenticationServices
import SwiftData
import SwiftUI

/// Mail waiting for a decision: events and deadlines to add, and updates worth knowing.
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

    var body: some View {
        switch state.mail.connection {
        case .disconnected:
            EmptyView()
        case .expired:
            reconnect
        case .connected:
            if !pending.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    DeckSectionHeader(title: "From your mail", trailing: "\(pending.count)")
                    ForEach(pending) { suggestion in
                        MailSuggestionCard(suggestion: suggestion)
                    }
                }
            }
        }
    }

    private var reconnect: some View {
        ContentTile {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    SignalGlyph(symbol: "envelope.badge", role: .attention)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reconnect Gmail")
                            .font(.headline)
                            .foregroundStyle(.ice)
                        Text("Google signs PathOS out every 7 days while it's a test app, so new mail isn't being checked.")
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                    }
                }
                .accessibilityElement(children: .combine)

                Button {
                    Task { await state.mail.connect(present: webAuthenticationSession.googleSignIn) }
                } label: {
                    Label(state.mail.isConnecting ? "Signing in…" : "Sign in to Google", systemImage: "arrow.clockwise")
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
                        Text("\(suggestion.senderName) · \(suggestion.receivedAt.formatted(.relative(presentation: .named)))")
                            .font(.footnote)
                            .foregroundStyle(.mist)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)

                actions
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
            }
        }
        .contextMenu {
            if let url = gmailURL {
                Button("Open in Gmail", systemImage: "envelope") { openURL(url) }
            }
            Button("Dismiss", systemImage: "xmark", role: .destructive) { state.mail.dismiss(suggestion) }
        }
    }

    /// "Event · Sat 21 Sep, 2:00 PM", "To do · Thu 25 Sep", "Update".
    private var headline: String {
        let when = suggestion.kind == .update ? nil : suggestion.whenText
        return [suggestion.kind.label, when].compactMap { $0 }.joined(separator: " · ")
    }

    private var gmailURL: URL? {
        MailParsing.webURL(messageID: suggestion.messageID, account: state.mail.account)
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
