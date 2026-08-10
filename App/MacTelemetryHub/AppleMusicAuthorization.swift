import Foundation
import MusicKit

struct AppleMusicCredentials: Sendable {
    let musicUserToken: String
    let developerToken: String
    /// developer token 的到期时刻，从它自己的 JWT `exp` 解出。
    /// 后端拿到的是一份会过期的凭据，续期时机全靠这个数，所以它跟 token 一起走。
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
     * 使用 MusicKit 默认缓存。上报循环会定期再取并分别比较两个 token；缓存值没变
     * 就静默，SDK 真正轮换其中一个时才把那个字段带进下一次遥测信封。
     *
     * 不弹窗：授权没批准就直接返回 nil，交给调用方决定要不要提示。
     */
    func mintCredentials() async -> AppleMusicCredentials? {
        authorizationStatus = MusicAuthorization.currentStatus
        guard authorizationStatus == .authorized else {
            hasUserToken = false
            return nil
        }

        do {
            // MusicDataRequest.tokenProvider 是 SDK 里的可变全局量，Swift 6 的严格
            // 并发检查不让碰。新建一个默认 provider 行为一样，且不动那个全局量。
            let provider = DefaultMusicTokenProvider()
            let developerToken = try await provider.developerToken(options: [])
            let musicUserToken = try await provider.userToken(for: developerToken, options: [])
            guard !musicUserToken.isEmpty, !developerToken.isEmpty else {
                throw AppleMusicAuthorizationError.emptyToken
            }
            guard let expiresAt = Self.expiry(ofJWT: developerToken) else {
                throw AppleMusicAuthorizationError.unreadableExpiry
            }

            hasUserToken = true
            lastError = nil
            return AppleMusicCredentials(
                musicUserToken: musicUserToken,
                developerToken: developerToken,
                expiresAt: expiresAt
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /**
     * 读 JWT 的 `exp`。只解不验签 —— 签名是 Apple 那边的事，这边只需要知道
     * 什么时候该续，读错了最坏也就是早续一次。
     */
    static func expiry(ofJWT token: String) -> Date? {
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
        return Date(timeIntervalSince1970: exp)
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
