import Foundation

/**
 * 手里那对 Apple Music token，以及「什么时候再去要一份」。
 *
 * 从 ServiceController 拆出来的理由是它自成一件事：MusicKit 的缓存读取、到期
 * 更早的那份不许顶掉手里的、失败退避、已经发出去的两个 token 各自记一份。上报
 * 循环只需要问它三句话 —— 有没有新的、发出去了、重开一轮把记录清掉。
 *
 * UI 状态（在飞、上次成功时刻、错误文案）仍然留在 ServiceController 上：那几个
 * 是 `@Published`，搬成转发属性的话 SwiftUI 的观察会静默失效。这里只把结果交出去。
 */
@MainActor
final class AppleMusicCredentialStore {
    /// 刷新走完之后调用方该拿它怎么办。
    enum RefreshOutcome {
        /// 门闩没放行（正在刷、没授权、还没到点）。错误文案原样不动。
        case skipped
        /// 这一轮没拿到，附上要展示的错误。
        case failed(String?)
        case refreshed
    }

    enum AuthorizationOutcome {
        /// 手里有凭据了。`error` 是刷新过程留下的文案，调用方照抄。
        case ready(error: String?)
        case failed(String?)
    }

    /// MusicKit 读取失败后的退避。
    private static let retryDelay: TimeInterval = 60
    /// token 检测仍在主循环内，但 MusicKit 的缓存没有必要每五秒读取一次。
    private static let refreshInterval: TimeInterval = 5 * 60

    private let authorization: AppleMusicAuthorizationManager
    /// MusicKit 最近一次返回的缓存值。
    private(set) var credentials: AppleMusicCredentials?
    private var lastPostedDeveloperToken: String?
    private var lastPostedUserToken: String?
    private var nextRefreshAt = Date.distantPast
    private var isRefreshing = false

    init(authorization: AppleMusicAuthorizationManager) {
        self.authorization = authorization
    }

    var developerTokenChanged: Bool {
        credentials.map { $0.developerToken != lastPostedDeveloperToken } ?? false
    }

    var musicUserTokenChanged: Bool {
        credentials.map { $0.musicUserToken != lastPostedUserToken } ?? false
    }

    /// 每个上报会话都完整发一次，之后两个 token 才分别判变。
    func resetPostedTokens() {
        lastPostedDeveloperToken = nil
        lastPostedUserToken = nil
    }

    /**
     * 记下这封信实际带出去的字段。
     *
     * 传的是循环开头捕获的那份而不是此刻手里的：POST 飞行期间可能又刷了一次，
     * 那份新的还没发出去，不能算已上报。
     */
    func notePosted(_ sent: AppleMusicCredentials?, developerToken: Bool, musicUserToken: Bool) {
        if developerToken { lastPostedDeveloperToken = sent?.developerToken }
        if musicUserToken { lastPostedUserToken = sent?.musicUserToken }
    }

    /**
     * 首次授权，由用户在设置页点出来 —— 只有这条路径会弹系统对话框。
     *
     * 授权成功就立刻读一次 MusicKit 缓存。网络请求仍只有主循环那一条路径。
     */
    func authorize() async -> AuthorizationOutcome {
        guard await authorization.requestAuthorization() else {
            return .failed(authorization.lastError)
        }
        let error: String?
        switch await refreshIfNeeded(force: true) {
        case .skipped, .refreshed: error = nil
        case let .failed(message): error = message
        }
        guard credentials != nil else { return .failed(authorization.lastError) }
        return .ready(error: error)
    }

    /**
     * 在主上报循环里定期读取 MusicKit 的 token。
     *
     * 平时读的是 SDK 缓存，不产生网络请求；缓存那份过了半衰期由
     * AppleMusicAuthorizationManager 带 ignoreCache 重签。主循环分别比较
     * 两个 token，只上报变了的字段。
     */
    @discardableResult
    func refreshIfNeeded(force: Bool = false) async -> RefreshOutcome {
        guard !isRefreshing else { return .skipped }
        // 后台绝不请求授权，没批准就什么都不做 —— 从循环里弹系统弹窗是不能接受的
        guard authorization.isCurrentlyAuthorized else { return .skipped }
        guard force || Date() >= nextRefreshAt else { return .skipped }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let minted = await authorization.mintCredentials(held: credentials?.lifetime) else {
            nextRefreshAt = Date().addingTimeInterval(Self.retryDelay)
            return .failed(authorization.lastError)
        }
        // 到期更早的 developer token 不能顶掉手里的：SDK 缓存可能回退到重签前那份，
        // 要不要重签已经按手里那份判过了（见 mintCredentials 的 held），这里只负责
        // 不让旧的顶掉新的。user token 不绑定某一份 developer token，它的变化照常接受。
        if let held = credentials, minted.expiresAt < held.expiresAt {
            credentials = AppleMusicCredentials(
                musicUserToken: minted.musicUserToken,
                developerToken: held.developerToken,
                lifetime: held.lifetime
            )
        } else {
            credentials = minted
        }
        nextRefreshAt = Date().addingTimeInterval(Self.refreshInterval)
        return .refreshed
    }
}
