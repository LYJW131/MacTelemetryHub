import Foundation
import MusicKit
import os

/// 这台机器唯一还往后端送的 Apple Music 凭据：用户那份授权。
struct AppleMusicCredentials: Sendable {
    let musicUserToken: String
}

/**
 * MusicKit 授权与取 music user token。
 *
 * 两份凭据现在各归各家：developer token 是 Worker 的事，它自己拿 .p8 私钥签，
 * 想签多新签多新，不会过期在别人手里；这台 Mac 只管用户那份授权 —— 它绑的是
 * 这台机器上登录的 Apple 账号，除了这里没有别的地方能拿到。信封里也就只剩
 * musicUserToken 一个字段，developer token 带上去会被判为已停用而整封退回。
 *
 * 这里仍要向 MusicKit 要一份 developer token，但只是为了换 user token —— SDK 的
 * `userToken(for:)` 必须收一份，值本身既不留也不上报。
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

    /**
     * 系统此刻的授权状态。
     *
     * 后台续期那条路径要的是这一个：`authorizationStatus` 是上次读到的缓存值，
     * 用户在系统设置里撤销授权后它不会自己变。有了它，调用方不必为了问一句
     * 「批准了吗」而 `import MusicKit`。
     */
    var isCurrentlyAuthorized: Bool { MusicAuthorization.currentStatus == .authorized }

    /// 上次读到的授权状态是不是 authorized。本机状态接口展示用，跟
    /// `statusDescription` 同源，两者必须一致。
    var isAuthorized: Bool { authorizationStatus == .authorized }

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
     * 读一次 MusicKit 缓存里的 music user token。
     *
     * 读的是 SDK 缓存，缓存没变就不产生网络请求。中途那份 developer token 只是
     * `userToken(for:)` 的入参 —— 它归 Worker 自己签，这边既不判它的寿命也不留它，
     * 拿到的是不是过期的都无所谓，user token 换出来就行。
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
            guard !developerToken.isEmpty else { throw AppleMusicAuthorizationError.emptyToken }

            let musicUserToken = try await provider.userToken(for: developerToken, options: [])
            guard !musicUserToken.isEmpty else { throw AppleMusicAuthorizationError.emptyToken }

            hasUserToken = true
            lastError = nil
            return AppleMusicCredentials(musicUserToken: musicUserToken)
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
}

private enum AppleMusicAuthorizationError: LocalizedError {
    case emptyToken

    var errorDescription: String? {
        switch self {
        case .emptyToken: "MusicKit 返回了空的 Apple Music token。"
        }
    }
}
