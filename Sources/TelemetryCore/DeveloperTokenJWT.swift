import Foundation

/** developer token 自带的两个时刻。`iat` Apple 一般都签，但规范里它是可选的 */
struct DeveloperTokenLifetime: Sendable, Equatable {
    let issuedAt: Date?
    let expiresAt: Date
}

/// 只解不验签的 developer token JWT 读取，以及「该不该续」这条规则。
enum DeveloperTokenJWT {
    /**
     * 过了「签发时刻 → 到期时刻」的中点就该换一份新的。
     *
     * 和站点 src/lib/musickit.ts、Worker workers/api/src/musickit-token.ts 里的
     * pastHalfLife 是同一条规则，改一处记得对齐。token 里没有 `iat` 时退化成
     * 「到期前一天」：总比永远不续强。
     */
    static func shouldRenew(_ lifetime: DeveloperTokenLifetime, now: Date) -> Bool {
        if let issuedAt = lifetime.issuedAt, issuedAt < lifetime.expiresAt {
            return now >= issuedAt.addingTimeInterval(lifetime.expiresAt.timeIntervalSince(issuedAt) / 2)
        }
        return now >= lifetime.expiresAt.addingTimeInterval(-24 * 60 * 60)
    }

    /**
     * 读 JWT 的 `iat` 和 `exp`。只解不验签 —— 签名是 Apple 那边的事，这边只需要
     * 知道什么时候该续，读错了最坏也就是早续一次。
     */
    static func lifetime(ofJWT token: String) -> DeveloperTokenLifetime? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        // JWT 用的是 base64url，且省掉了尾部填充
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        guard let data = Data(base64Encoded: encoded),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double
        else { return nil }
        let iat = claims["iat"] as? Double
        return DeveloperTokenLifetime(
            issuedAt: iat.map { Date(timeIntervalSince1970: $0) },
            expiresAt: Date(timeIntervalSince1970: exp)
        )
    }
}
