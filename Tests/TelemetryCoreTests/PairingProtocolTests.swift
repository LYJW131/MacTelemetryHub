import Foundation
import Testing

@testable import TelemetryCore

struct PairingProtocolTests {
    /// RFC 7636 附录 B 的样例。
    @Test func challengeMatchesRFC7636Vector() {
        #expect(
            PairingProtocol.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    @Test func randomAttemptIsBase64URLWithoutPadding() throws {
        let attempt = try PairingProtocol.Attempt.random { Data(repeating: 0xFB, count: $0) }
        // 32 字节 → 43 个字符；0xFB 的标准 base64 含 `+` 和 `/`，都得换掉。
        #expect(attempt.codeVerifier.count == 43)
        #expect(!attempt.codeVerifier.contains { "+/=".contains($0) })
        #expect(attempt.codeChallenge == PairingProtocol.codeChallenge(for: attempt.codeVerifier))

        let real = try PairingProtocol.Attempt.random()
        let other = try PairingProtocol.Attempt.random()
        #expect(real.codeVerifier != other.codeVerifier)
        #expect(real.state != real.codeVerifier)
    }

    @Test func authorizationURLCarriesEveryParameter() throws {
        let attempt = PairingProtocol.Attempt(codeVerifier: "verifier", state: "st-ate_1")
        let url = PairingProtocol.authorizationURL(
            source: "mac",
            redirectURI: "mactelemetryhub://pair",
            attempt: attempt
        )
        #expect(url.absoluteString.hasPrefix("https://api.homepage.lyjw.llc/pair/authorize?"))
        #expect(url.absoluteString.contains("redirect_uri=mactelemetryhub%3A%2F%2Fpair"))

        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query == [
            "source": "mac",
            "redirect_uri": "mactelemetryhub://pair",
            "state": "st-ate_1",
            "code_challenge": attempt.codeChallenge,
            "code_challenge_method": "S256",
        ])
    }

    @Test func callbackYieldsCodeOnlyWithMatchingState() throws {
        let ok = URL(string: "mactelemetryhub://pair?code=abc.def&state=s1")!
        #expect(try PairingProtocol.authorizationCode(from: ok, expectedState: "s1") == "abc.def")

        #expect(throws: PairingProtocol.PairingError.stateMismatch) {
            try PairingProtocol.authorizationCode(from: ok, expectedState: "s2")
        }
        // state 不符时 error 也不信：别人的回调不该让本次显示「已拒绝」。
        let foreignDeny = URL(string: "mactelemetryhub://pair?error=access_denied&state=x")!
        #expect(throws: PairingProtocol.PairingError.stateMismatch) {
            try PairingProtocol.authorizationCode(from: foreignDeny, expectedState: "s1")
        }
        let deny = URL(string: "mactelemetryhub://pair?error=access_denied&state=s1")!
        #expect(throws: PairingProtocol.PairingError.denied) {
            try PairingProtocol.authorizationCode(from: deny, expectedState: "s1")
        }
        let other = URL(string: "mactelemetryhub://pair?error=invalid_request&state=s1")!
        #expect(throws: PairingProtocol.PairingError.authorizationError("invalid_request")) {
            try PairingProtocol.authorizationCode(from: other, expectedState: "s1")
        }
        let empty = URL(string: "mactelemetryhub://pair?state=s1")!
        #expect(throws: PairingProtocol.PairingError.callbackMissingCode) {
            try PairingProtocol.authorizationCode(from: empty, expectedState: "s1")
        }
    }

    @Test func tokenRequestIsJSONWithOwnUserAgent() throws {
        let request = try PairingProtocol.tokenRequest(code: "c", codeVerifier: "v", userAgent: "hub/1")
        #expect(request.url == PairingProtocol.tokenURL)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "hub/1")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["code": "c", "codeVerifier": "v"])
    }

    @Test func successfulExchangeDecodesCredentials() throws {
        let body = Data("""
        {"ok":true,"data":{"source":"mac","clientId":"id.access","clientSecret":"cfast_x",\
        "ingestUrl":"https://ingest.homepage.lyjw.llc/api/ingest/mac"}}
        """.utf8)
        let credentials = try PairingProtocol.credentials(from: body, status: 200, expectedSource: "mac")
        #expect(credentials.clientId == "id.access")
        #expect(credentials.clientSecret == "cfast_x")
        #expect(credentials.ingestUrl == "https://ingest.homepage.lyjw.llc/api/ingest/mac")

        #expect(throws: PairingProtocol.PairingError.unexpectedSource("mac")) {
            try PairingProtocol.credentials(from: body, status: 200, expectedSource: "iphone")
        }
    }

    @Test func failedExchangeSurfacesServerReason() {
        let body = Data(#"{"ok":false,"error":"code expired"}"#.utf8)
        #expect(throws: PairingProtocol.PairingError.exchangeFailed(status: 400, reason: "code expired")) {
            try PairingProtocol.credentials(from: body, status: 400, expectedSource: "mac")
        }
        // Cloudflare 的拦截页不是 JSON，只剩状态码可说。
        #expect(throws: PairingProtocol.PairingError.exchangeFailed(status: 403, reason: nil)) {
            try PairingProtocol.credentials(from: Data("<html>".utf8), status: 403, expectedSource: "mac")
        }
        let missingSecret = Data("""
        {"ok":true,"data":{"source":"mac","clientId":"id","clientSecret":"","ingestUrl":"https://x/y"}}
        """.utf8)
        #expect(throws: PairingProtocol.PairingError.invalidResponse) {
            try PairingProtocol.credentials(from: missingSecret, status: 200, expectedSource: "mac")
        }
    }
}
