import CryptoKit
import Foundation

/// The Google Cloud OAuth client registered for PathOS. An iOS client has no secret, and its id
/// ships inside the app either way, so it lives in source.
nonisolated enum GoogleConfig {
    static let clientID = "333069009087-k2fu3s6a5llgsj8ush7p2e2ovt9j4o4o.apps.googleusercontent.com"
    /// Read-only: PathOS can find and read mail, never send, change or delete it.
    static let gmailScope = "https://www.googleapis.com/auth/gmail.readonly"

    /// Google redirects iOS clients to their own id, reversed.
    static var redirectScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }
}

/// Proof Key for Code Exchange (RFC 7636): the app proves the code it redeems is the one it asked
/// for, which is what stands in for a client secret on a phone.
nonisolated struct PKCE: Sendable {
    let verifier: String

    var challenge: String { Self.challenge(for: verifier) }

    static func random() -> PKCE {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return PKCE(verifier: Data(bytes).base64URLEncodedString())
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

nonisolated enum GoogleOAuthError: LocalizedError, Equatable {
    case cancelled
    case denied
    case stateMismatch
    case missingCode
    case gmailNotGranted
    /// Google has withdrawn the sign-in: the 7-day limit for test apps, or access was revoked.
    case signInExpired
    case server(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .denied: "Google sign-in was declined."
        case .stateMismatch: "The sign-in reply didn't match the request. Try again."
        case .missingCode: "Google didn't return a sign-in code. Try again."
        case .gmailNotGranted: "PathOS needs the box that allows reading your email ticked on Google's permission screen."
        case .signInExpired: "Google signed PathOS out. Reconnect Gmail to keep checking your mail."
        case .server(let message): message
        }
    }
}

/// Tokens as Google returns them from the token endpoint.
nonisolated struct GoogleTokenResponse: Decodable, Sendable {
    var access_token: String
    var expires_in: Double
    var refresh_token: String?
    var scope: String?
}

nonisolated struct GoogleErrorResponse: Decodable, Sendable {
    var error: String
    var error_description: String?
}

/// What PathOS keeps between launches, in the Keychain.
nonisolated struct GoogleTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var expiresAt: Date
    var refreshToken: String

    /// A minute early, so a token never expires between the check and the request.
    func isFresh(now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) > 60
    }
}

nonisolated enum GoogleOAuth {
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    static func authorizationURL(pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: GoogleConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: GoogleConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleConfig.gmailScope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// The authorization code from Google's redirect, after checking it answers our request.
    static func code(from callback: URL, expectedState: String) throws(GoogleOAuthError) -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            throw error == "access_denied" ? .denied : .server("Google sign-in failed (\(error)).")
        }
        guard value("state") == expectedState else { throw .stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw .missingCode }
        return code
    }

    static func exchangeBody(code: String, pkce: PKCE) -> Data {
        formEncoded([
            ("code", code),
            ("client_id", GoogleConfig.clientID),
            ("redirect_uri", GoogleConfig.redirectURI),
            ("grant_type", "authorization_code"),
            ("code_verifier", pkce.verifier),
        ])
    }

    static func refreshBody(refreshToken: String) -> Data {
        formEncoded([
            ("client_id", GoogleConfig.clientID),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ])
    }

    /// Turns a token response into stored tokens. A refresh doesn't return a new refresh token,
    /// so the existing one carries over.
    static func tokens(
        from data: Data,
        previousRefreshToken: String? = nil,
        requireGmail: Bool,
        now: Date = Date()
    ) throws(GoogleOAuthError) -> GoogleTokens {
        guard let response = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data) else {
            throw serverError(from: data)
        }
        // Google's consent screen lets people untick individual permissions.
        if requireGmail, let scope = response.scope, !scope.split(separator: " ").contains(Substring(GoogleConfig.gmailScope)) {
            throw .gmailNotGranted
        }
        guard let refresh = response.refresh_token ?? previousRefreshToken else {
            throw .server("Google didn't return a lasting sign-in. Disconnect and connect again.")
        }
        return GoogleTokens(
            accessToken: response.access_token,
            expiresAt: now.addingTimeInterval(response.expires_in),
            refreshToken: refresh
        )
    }

    /// `invalid_grant` is how Google says the sign-in is gone, rather than that something failed.
    static func serverError(from data: Data) -> GoogleOAuthError {
        guard let response = try? JSONDecoder().decode(GoogleErrorResponse.self, from: data) else {
            return .server("Google's reply couldn't be read.")
        }
        if response.error == "invalid_grant" {
            return .signInExpired
        }
        return .server(response.error_description ?? "Google sign-in failed (\(response.error)).")
    }

    /// `application/x-www-form-urlencoded`, escaping everything outside RFC 3986's unreserved set.
    /// `URLComponents` leaves `+` and `/` alone, which a form body can't.
    static func formEncoded(_ fields: [(String, String)]) -> Data {
        // Spelled out: `.alphanumerics` would also let non-ASCII letters through unescaped.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields
            .map { name, value in
                "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

extension Data {
    nonisolated func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
