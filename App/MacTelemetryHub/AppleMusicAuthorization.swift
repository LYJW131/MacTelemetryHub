import Foundation
import MusicKit
import os

struct AppleMusicCredentials: Sendable {
    let musicUserToken: String
    let developerToken: String
    /// developer token 自己 JWT 里的签发与到期时刻。
    /// 后端拿到的是一份会过期的凭据，续期时机全靠这两个数，所以它们跟 token 一起走。
    let lifetime: DeveloperTokenLifetime

    var expiresAt: Date { lifetime.expiresAt }
}

/** developer token 自带的两个时刻。`iat` Apple 一般都签，但规范里它是可选的 */
struct DeveloperTokenLifetime: Sendable, Equatable {
    let issuedAt: Date?
    let expiresAt: Date
}

/**
 * MusicKit 授权与取 token。
 *
 * 存在的理由是不想把 .p8 私钥放到后端：签名密钥留在这台机器的钥匙串里由系统
 * 保管，后端只拿一份短期的 developer token 加 music user token。代价是后端手上
 * 那份会过期，得由这边持续续上 —— 见 ServiceController 里按 `exp` 触发的那段。
 *
 * 这里不自己存任何 token。授权状态是系统（TCC）在管，只要还是 authorized，
 * MusicKit 随时能再签一份出来，自己存一份既多余、又是一处不会被清理的长期凭据
 * ——用户在系统设置里撤销授权时，MusicKit 会立刻停发，而自存的那份不会消失。
 */
@MainActor
final class AppleMusicAuthorizationManager: ObservableObject {
    @Published private(set) var authorizationStatus: MusicAuthorization.Status
    @Published private(set) var hasUserToken = false
    @Published private(set) var isAuthorizing = false
    @Published private(set) var lastError: String?

    init() {
        authorizationStatus = MusicAuthorization.currentStatus
    }

    var statusDescription: String {
        switch authorizationStatus {
        case .authorized: "已获资料库权限"
        case .denied: "权限已拒绝"
        case .restricted: "权限受系统限制"
        case .notDetermined: "尚未请求权限"
        @unknown default: "权限状态未知"
        }
    }

    /**
     * 首次授权。会弹系统对话框，所以只能由用户在设置页点出来。
     *
     * 后台续期那条路径绝不调它 —— 从循环里弹一个用户没预期的系统弹窗是不能接受的。
     */
    func requestAuthorization() async -> Bool {
        guard !isAuthorizing else { return false }
        isAuthorizing = true
        lastError = nil
        defer { isAuthorizing = false }

        authorizationStatus = await MusicAuthorization.request()
        guard authorizationStatus == .authorized else {
            lastError = "Apple Music 资料库权限未获批准（\(statusDescription)）。"
            return false
        }
        return true
    }

    /**
     * 现签一对 token。
     *
     * 先读 MusicKit 的缓存：缓存值没变就静默，不产生网络请求。但缓存不会自己
     * 轮换 —— 实测 developer token 过期两天后，不带 ignoreCache 拿到的还是那份
     * 过期的，后端因此一直拿 401。所以这里按 token 自己的 `iat`/`exp` 判：过了
     * 半衰期（或已经过期）就带 `.ignoreCache` 重签一份，规则和站点、Worker 那侧
     * 的 pastHalfLife 一致。user token 总是对着最终那份 developer token 去取。
     *
     * `held` 是调用方手里、已经上报出去的那份 developer token 的时刻。判要不要重签
     * 以它为准而不是以缓存那份：万一 ignoreCache 重签后 SDK 缓存没跟着换，下一轮
     * 缓存读回的还是旧的，按旧的判就会每轮都重签、每轮都上报一份新 token。以手里
     * 那份为准，缓存回退到更旧的只会被调用方按到期时刻丢弃，不会触发新一轮签发。
     *
     * 不弹窗：授权没批准就直接返回 nil，交给调用方决定要不要提示。
     */
    func mintCredentials(held: DeveloperTokenLifetime? = nil) async -> AppleMusicCredentials? {
        authorizationStatus = MusicAuthorization.currentStatus
        guard authorizationStatus == .authorized else {
            hasUserToken = false
            return nil
        }

        do {
            // MusicDataRequest.tokenProvider 是 SDK 里的可变全局量，Swift 6 的严格
            // 并发检查不让碰。新建一个默认 provider 行为一样，且不动那个全局量。
            let provider = DefaultMusicTokenProvider()
            var developerToken = try await provider.developerToken(options: [])
            guard !developerToken.isEmpty else { throw AppleMusicAuthorizationError.emptyToken }
            guard var lifetime = Self.lifetime(ofJWT: developerToken) else {
                throw AppleMusicAuthorizationError.unreadableExpiry
            }

            // 缓存那份比手里的还旧（或一样），就按手里那份的寿命判；缓存已经轮换到更新的，按新的判
            let reference = held.map { lifetime.expiresAt <= $0.expiresAt ? $0 : lifetime } ?? lifetime
            if Self.shouldRenew(reference, now: Date()) {
                Self.logger.notice(
                    "developer token 到期 \(reference.expiresAt.ISO8601Format(), privacy: .public)，已过半衰期，忽略缓存重签"
                )
                developerToken = try await provider.developerToken(options: .ignoreCache)
                guard !developerToken.isEmpty else { throw AppleMusicAuthorizationError.emptyToken }
                guard let renewed = Self.lifetime(ofJWT: developerToken) else {
                    throw AppleMusicAuthorizationError.unreadableExpiry
                }
                if renewed.expiresAt <= reference.expiresAt {
                    // 重签也没拿到更新的：不是缓存问题，多半是 Apple 那边没签出来。
                    // 记下来，仍把它交出去 —— 调用方按到期时刻比较，不会拿它顶掉手里更好的
                    Self.logger.error(
                        "忽略缓存重签后 developer token 到期仍是 \(renewed.expiresAt.ISO8601Format(), privacy: .public)"
                    )
                }
                lifetime = renewed
            }

            let musicUserToken = try await provider.userToken(for: developerToken, options: [])
            guard !musicUserToken.isEmpty else { throw AppleMusicAuthorizationError.emptyToken }

            hasUserToken = true
            lastError = nil
            return AppleMusicCredentials(
                musicUserToken: musicUserToken,
                developerToken: developerToken,
                lifetime: lifetime
            )
        } catch {
            lastError = error.localizedDescription
            Self.logger.error("取 Apple Music token 失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "MacTelemetryHub",
        category: "apple-music"
    )

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

private enum AppleMusicAuthorizationError: LocalizedError {
    case emptyToken
    case unreadableExpiry

    var errorDescription: String? {
        switch self {
        case .emptyToken: "MusicKit 返回了空的 Apple Music token。"
        case .unreadableExpiry: "developer token 里读不到有效期，无法安排续期。"
        }
    }
}
