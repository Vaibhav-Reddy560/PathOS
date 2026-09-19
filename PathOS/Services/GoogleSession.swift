import AuthenticationServices
import Foundation

/// Signs in to Google and keeps the sign-in alive, then makes read-only Gmail requests with it.
///
/// There's no server: the phone talks to Google directly, and the tokens stay in its Keychain.
final class GoogleSession {
    /// Shows Google's sign-in page and returns the redirect it finishes on.
    typealias Presenter = (_ url: URL, _ callbackScheme: String) async throws -> URL

    /// Before PathOS could hold more than one account, the only sign-in was kept here.
    static let legacyKeychainAccount = "google.tokens"
    private static let gmailBase = "https://gmail.googleapis.com/gmail/v1/users/me/"

    private var tokens: GoogleTokens?
    private var refreshTask: Task<GoogleTokens, Error>?
    private let urlSession: URLSession
    /// Where this sign-in's tokens are kept in the Keychain.
    private(set) var keychainAccount: String

    /// Each Gmail account has its own sign-in, kept under its address.
    static func keychainAccount(for email: String) -> String {
        "google.tokens." + email.lowercased()
    }

    init(keychainAccount: String, urlSession: URLSession = .shared) {
        self.keychainAccount = keychainAccount
        self.urlSession = urlSession
        tokens = Keychain.load(GoogleTokens.self, account: keychainAccount)
    }

    /// Moves the sign-in to another Keychain entry, once it's known whose it is.
    func rekey(to account: String) {
        guard account != keychainAccount else { return }
        Keychain.delete(account: keychainAccount)
        keychainAccount = account
        if let tokens {
            Keychain.save(tokens, account: account)
        }
    }

    var isSignedIn: Bool { tokens != nil }

    // MARK: Signing in and out

    func signIn(present: Presenter, loginHint: String? = nil) async throws {
        let pkce = PKCE.random()
        let state = UUID().uuidString
        let callback: URL
        do {
            callback = try await present(GoogleOAuth.authorizationURL(pkce: pkce, state: state, loginHint: loginHint), GoogleConfig.redirectScheme)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw GoogleOAuthError.cancelled
        }
        let code = try GoogleOAuth.code(from: callback, expectedState: state)
        let data = try await post(GoogleOAuth.tokenEndpoint, body: GoogleOAuth.exchangeBody(code: code, pkce: pkce))
        store(try GoogleOAuth.tokens(from: data, requireGmail: true))
    }

    /// Forgets the sign-in here and asks Google to withdraw it, so the access shows as removed in
    /// the Google account too. Best effort: signing out locally never waits on the network.
    func signOut() async {
        let refreshToken = tokens?.refreshToken
        clear()
        if let refreshToken {
            _ = try? await post(GoogleOAuth.revokeEndpoint, body: GoogleOAuth.formEncoded([("token", refreshToken)]))
        }
    }

    private func store(_ tokens: GoogleTokens) {
        self.tokens = tokens
        Keychain.save(tokens, account: keychainAccount)
    }

    private func clear() {
        tokens = nil
        refreshTask?.cancel()
        refreshTask = nil
        Keychain.delete(account: keychainAccount)
    }

    // MARK: Tokens

    /// A current access token, refreshed when it's about to run out. Concurrent callers share one refresh.
    func accessToken() async throws -> String {
        guard let tokens else { throw GoogleOAuthError.signInExpired }
        if tokens.isFresh() {
            return tokens.accessToken
        }
        if let refreshTask {
            return try await refreshTask.value.accessToken
        }
        let task = Task { try await refresh(tokens) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.accessToken
    }

    private func refresh(_ current: GoogleTokens) async throws -> GoogleTokens {
        let data = try await post(GoogleOAuth.tokenEndpoint, body: GoogleOAuth.refreshBody(refreshToken: current.refreshToken))
        do {
            let fresh = try GoogleOAuth.tokens(from: data, previousRefreshToken: current.refreshToken, requireGmail: false)
            store(fresh)
            return fresh
        } catch {
            // A dead refresh token never comes back to life; keeping it would only fail again.
            if error == .signInExpired {
                clear()
            }
            throw error
        }
    }

    private func post(_ url: URL, body: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // Google's token endpoint answers errors with a JSON body, which the caller reads.
        return try await urlSession.data(for: request).0
    }

    // MARK: Gmail

    func profile() async throws -> GmailProfile {
        try await gmail(GmailProfile.self, path: "profile")
    }

    func messageIDs(matching query: String, max: Int) async throws -> [String] {
        let list = try await gmail(GmailMessageList.self, path: "messages", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(max)),
        ])
        return (list.messages ?? []).map(\.id)
    }

    func message(id: String) async throws -> GmailMessageResource {
        try await gmail(GmailMessageResource.self, path: "messages/\(id)", query: [URLQueryItem(name: "format", value: "full")])
    }

    private func gmail<Response: Decodable>(_ type: Response.Type, path: String, query: [URLQueryItem] = []) async throws -> Response {
        guard var components = URLComponents(string: Self.gmailBase + path) else { throw GoogleOAuthError.server("Bad Gmail address.") }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw GoogleOAuthError.server("Bad Gmail address.") }

        // One retry: a 401 can mean the token expired between the check and the request.
        for attempt in 0..<2 {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            switch status {
            case 200..<300:
                return try JSONDecoder().decode(Response.self, from: data)
            case 401 where attempt == 0:
                tokens?.expiresAt = .distantPast
                continue
            case 401:
                clear()
                throw GoogleOAuthError.signInExpired
            default:
                throw Self.gmailError(status: status, data: data)
            }
        }
        throw GoogleOAuthError.signInExpired
    }

    private nonisolated struct APIErrorResponse: Decodable {
        struct Body: Decodable {
            var message: String
        }

        var error: Body
    }

    private static func gmailError(status: Int, data: Data) -> GoogleOAuthError {
        let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error.message
        if status == 403, message?.localizedCaseInsensitiveContains("insufficient") == true {
            return .gmailNotGranted
        }
        if status == 429 {
            return .server("Gmail asked PathOS to slow down. It'll try again later.")
        }
        // Google's own message says what's wrong, e.g. the Gmail API not being enabled on the project.
        return .server(message ?? "Gmail couldn't be reached (\(status)).")
    }
}
