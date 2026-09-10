import Foundation
import Testing

@testable import TelemetryCore

struct DeveloperTokenJWTTests {
    /// 造一个只有 payload 段有意义的 JWT：这边只解不验签。
    private func token(claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")   // base64url 省掉尾部填充
        return "header.\(encoded).signature"
    }

    @Test func readsIssuedAtAndExpiryFromUnpaddedBase64URL() throws {
        let jwt = token(claims: ["iat": 1_700_000_000, "exp": 1_715_552_000, "iss": "TEAMID"])
        // 省掉填充的 payload 才是 Apple 实际签出来的样子
        #expect(!jwt.split(separator: ".")[1].contains("="))
        let lifetime = try #require(DeveloperTokenJWT.lifetime(ofJWT: jwt))
        #expect(lifetime.issuedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(lifetime.expiresAt == Date(timeIntervalSince1970: 1_715_552_000))
    }

    @Test func missingIssuedAtIsAllowedButExpiryIsRequired() throws {
        let withoutIAT = try #require(DeveloperTokenJWT.lifetime(ofJWT: token(claims: ["exp": 100])))
        #expect(withoutIAT.issuedAt == nil)
        #expect(withoutIAT.expiresAt == Date(timeIntervalSince1970: 100))

        #expect(DeveloperTokenJWT.lifetime(ofJWT: token(claims: ["iat": 1])) == nil)
        #expect(DeveloperTokenJWT.lifetime(ofJWT: "not-a-jwt") == nil)
        #expect(DeveloperTokenJWT.lifetime(ofJWT: "header.@@@.signature") == nil)
    }

    /// 半衰期这条规则和站点 src/lib/musickit.ts、Worker 的 pastHalfLife 一致。
    @Test func renewalTriggersExactlyAtTheHalfLife() {
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        let lifetime = DeveloperTokenLifetime(
            issuedAt: issuedAt,
            expiresAt: Date(timeIntervalSince1970: 3_000)
        )
        #expect(!DeveloperTokenJWT.shouldRenew(lifetime, now: Date(timeIntervalSince1970: 1_999)))
        #expect(DeveloperTokenJWT.shouldRenew(lifetime, now: Date(timeIntervalSince1970: 2_000)))
        #expect(DeveloperTokenJWT.shouldRenew(lifetime, now: Date(timeIntervalSince1970: 9_999)))
    }

    /// 没有 `iat` 时退化成「到期前一天」：总比永远不续强。
    @Test func withoutIssuedAtRenewalIsOneDayBeforeExpiry() {
        let expiresAt = Date(timeIntervalSince1970: 10 * 24 * 60 * 60)
        let lifetime = DeveloperTokenLifetime(issuedAt: nil, expiresAt: expiresAt)
        let oneDay: TimeInterval = 24 * 60 * 60
        #expect(!DeveloperTokenJWT.shouldRenew(lifetime, now: expiresAt.addingTimeInterval(-oneDay - 1)))
        #expect(DeveloperTokenJWT.shouldRenew(lifetime, now: expiresAt.addingTimeInterval(-oneDay)))
    }

    /// `iat` 不早于 `exp` 的 token 算不出中点，走「到期前一天」那条。
    @Test func nonsensicalIssuedAtFallsBackToTheOneDayRule() {
        let expiresAt = Date(timeIntervalSince1970: 10 * 24 * 60 * 60)
        let lifetime = DeveloperTokenLifetime(
            issuedAt: expiresAt.addingTimeInterval(60),
            expiresAt: expiresAt
        )
        let oneDay: TimeInterval = 24 * 60 * 60
        #expect(!DeveloperTokenJWT.shouldRenew(lifetime, now: expiresAt.addingTimeInterval(-oneDay - 1)))
        #expect(DeveloperTokenJWT.shouldRenew(lifetime, now: expiresAt.addingTimeInterval(-oneDay)))
    }
}
