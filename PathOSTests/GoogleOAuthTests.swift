import Foundation
import Testing
@testable import PathOS

struct GoogleOAuthTests {
    private let redirect = GoogleConfig.redirectURI

    @Test func pkceMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifiersAreLongURLSafeAndNeverRepeat() {
        let verifier = PKCE.random().verifier
        #expect((43...128).contains(verifier.count))
        #expect(verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) })
        #expect(PKCE.random().verifier != verifier)
    }

    @Test func theRedirectIsTheClientIDReversed() {
        #expect(GoogleConfig.redirectScheme == "com.googleusercontent.apps.333069009087-k2fu3s6a5llgsj8ush7p2e2ovt9j4o4o")
        #expect(redirect == "com.googleusercontent.apps.333069009087-k2fu3s6a5llgsj8ush7p2e2ovt9j4o4o:/oauth2redirect")
    }

    @Test func signInAsksOnlyToReadGmail() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = GoogleOAuth.authorizationURL(pkce: pkce, state: "abc")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(url.host() == "accounts.google.com")
        #expect(value("scope") == "https://www.googleapis.com/auth/gmail.readonly")
        #expect(value("code_challenge") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("response_type") == "code")
        #expect(value("redirect_uri") == redirect)
        #expect(value("state") == "abc")
        // The verifier itself is the secret half and must never be in the URL.
        #expect(!url.absoluteString.contains(pkce.verifier))
    }

    @Test func aRedirectIsOnlyAcceptedForTheRequestWeMade() throws {
        #expect(try GoogleOAuth.code(from: URL(string: "\(redirect)?state=abc&code=4/0Axyz")!, expectedState: "abc") == "4/0Axyz")
        #expect(throws: GoogleOAuthError.stateMismatch) {
            try GoogleOAuth.code(from: URL(string: "\(redirect)?state=forged&code=4/0Axyz")!, expectedState: "abc")
        }
        #expect(throws: GoogleOAuthError.denied) {
            try GoogleOAuth.code(from: URL(string: "\(redirect)?error=access_denied&state=abc")!, expectedState: "abc")
        }
        #expect(throws: GoogleOAuthError.missingCode) {
            try GoogleOAuth.code(from: URL(string: "\(redirect)?state=abc")!, expectedState: "abc")
        }
    }

    @Test func aRefreshKeepsTheRefreshTokenGoogleDoesntResend() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let signIn = Data(#"{"access_token":"a1","expires_in":3599,"refresh_token":"r1","scope":"https://www.googleapis.com/auth/gmail.readonly","token_type":"Bearer"}"#.utf8)
        let tokens = try GoogleOAuth.tokens(from: signIn, requireGmail: true, now: now)
        #expect(tokens.refreshToken == "r1")
        #expect(tokens.expiresAt == now.addingTimeInterval(3_599))
        #expect(tokens.isFresh(now: now))
        // Treated as spent a minute early, so it can't lapse mid-request.
        #expect(!tokens.isFresh(now: now.addingTimeInterval(3_550)))

        let refresh = Data(#"{"access_token":"a2","expires_in":3599,"token_type":"Bearer"}"#.utf8)
        let refreshed = try GoogleOAuth.tokens(from: refresh, previousRefreshToken: "r1", requireGmail: false, now: now)
        #expect(refreshed.accessToken == "a2")
        #expect(refreshed.refreshToken == "r1")
    }

    @Test func untickingGmailOnGooglesScreenIsCaught() {
        let data = Data(#"{"access_token":"a","expires_in":3599,"refresh_token":"r","scope":"openid"}"#.utf8)
        #expect(throws: GoogleOAuthError.gmailNotGranted) {
            try GoogleOAuth.tokens(from: data, requireGmail: true)
        }
    }

    @Test func aWithdrawnSignInReadsAsExpiredNotBroken() {
        let expired = Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8)
        #expect(throws: GoogleOAuthError.signInExpired) {
            try GoogleOAuth.tokens(from: expired, previousRefreshToken: "r", requireGmail: false)
        }
        let misconfigured = Data(#"{"error":"invalid_client","error_description":"The OAuth client was not found."}"#.utf8)
        #expect(GoogleOAuth.serverError(from: misconfigured) == .server("The OAuth client was not found."))
    }

    @Test func formBodiesEscapeWhatURLComponentsLeavesAlone() {
        let body = String(decoding: GoogleOAuth.formEncoded([("code", "4/0A+b=c&d"), ("name", "é ~")]), as: UTF8.self)
        #expect(body == "code=4%2F0A%2Bb%3Dc%26d&name=%C3%A9%20~")
    }
}
