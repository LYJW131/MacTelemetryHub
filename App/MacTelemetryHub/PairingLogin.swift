import AppKit
import AuthenticationServices
import os

/**
 * 设置页「登录 Cloudflare」那一下：浏览器登录确认 → 回调拿授权码 → 凭 verifier 兑换。
 *
 * 协议细节都在 `PairingProtocol`；这里只管 `ASWebAuthenticationSession` 和那一次 POST。
 * 落盘和重开上报会话交给 `ServiceController.applyPairingCredentials`。
 */
@MainActor
final class PairingLogin: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let source = "mac"
    static let callbackScheme = "mactelemetryhub"
    static let redirectURI = "mactelemetryhub://pair"

    enum Outcome {
        case paired(PairingProtocol.Credentials)
        /// 用户关掉了登录窗口。什么都没发生，旧 secret 照常可用。
        case cancelled
    }

    enum LoginError: LocalizedError {
        case alreadyRunning
        case couldNotStart
        case noCallback

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: "登录已经在进行中。"
            case .couldNotStart: "无法打开登录窗口。"
            case .noCallback: "登录窗口没有返回结果。"
            }
        }
    }

    @Published private(set) var isRunning = false

    /// 会话必须被持有到回调为止，局部变量一出作用域登录窗就没了。
    private var session: ASWebAuthenticationSession?
    /// 点按钮那一刻的设置窗口。等回调时浏览器可能已经是 key window，不能那时再取。
    nonisolated(unsafe) private var anchor: NSWindow?

    func pair(anchor window: NSWindow?) async throws -> Outcome {
        guard !isRunning else { throw LoginError.alreadyRunning }
        isRunning = true
        anchor = window
        defer {
            isRunning = false
            anchor = nil
            session = nil
        }

        let attempt = try PairingProtocol.Attempt.random()
        let url = PairingProtocol.authorizationURL(
            source: Self.source,
            redirectURI: Self.redirectURI,
            attempt: attempt
        )
        let callback: URL
        do {
            callback = try await authenticate(url)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return .cancelled
        }
        let code = try PairingProtocol.authorizationCode(from: callback, expectedState: attempt.state)

        let request = try PairingProtocol.tokenRequest(
            code: code,
            codeVerifier: attempt.codeVerifier,
            userAgent: TelemetryPoster.userAgent
        )
        let (data, response) = try await IsolatedHTTPClient.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return .paired(try PairingProtocol.credentials(from: data, status: status, expectedSource: Self.source))
    }

    private func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // start() 失败时系统会不会再回调一次没有写明，两条路都可能走到，只放行第一条。
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Result<URL, Error>) -> Void = { result in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            // 显式 @Sendable：回调线程不保证是主线程，别让它继承 MainActor 隔离。
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.callbackScheme
            ) { @Sendable callback, error in
                if let callback {
                    finish(.success(callback))
                } else {
                    finish(.failure(error ?? LoginError.noCallback))
                }
            }
            session.presentationContextProvider = self
            // 用系统浏览器的 Cloudflare Access 登录态，登过一次就不用再输验证码。
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                finish(.failure(LoginError.couldNotStart))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let anchor { return anchor }
        // 系统在主线程上问这个；兜底窗口得在主线程上建。
        return MainActor.assumeIsolated { NSApp.keyWindow ?? ASPresentationAnchor() }
    }
}
