import Foundation

/**
 * 发往同一 ingest 主机的 POST 复用一条连接，省掉每次约两个往返的 TCP + TLS 握手。
 *
 * 本机代理会把已经失活的连接留在池里，复用它的请求要等到超时才失败，
 * 所以首发用短超时；任何 URLError 都整池丢弃，再按 `IsolatedHTTPClient`
 * 新建连接重发一次。重发可能让服务端收到两次同一封信，信封是快照，重复提交无害。
 */
actor ReusableHTTPClient {
    typealias Fallback = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let firstAttemptTimeout: TimeInterval
    private let configuration: URLSessionConfiguration
    private let fallback: Fallback
    private var session: URLSession?

    init(
        firstAttemptTimeout: TimeInterval,
        configuration: URLSessionConfiguration = .ephemeral,
        fallback: @escaping Fallback = { try await IsolatedHTTPClient.data(for: $0) }
    ) {
        self.firstAttemptTimeout = firstAttemptTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        self.configuration = configuration
        self.fallback = fallback
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let pooled = currentSession()
        var firstAttempt = request
        firstAttempt.timeoutInterval = min(request.timeoutInterval, firstAttemptTimeout)
        do {
            return try await pooled.data(for: firstAttempt)
        } catch let error as URLError where error.code != .cancelled {
            discard(pooled)
            return try await fallback(request)
        }
    }

    private func currentSession() -> URLSession {
        if let session { return session }
        let created = URLSession(configuration: configuration)
        session = created
        return created
    }

    private func discard(_ stale: URLSession) {
        guard session === stale else { return }
        session = nil
        stale.finishTasksAndInvalidate()
    }
}
