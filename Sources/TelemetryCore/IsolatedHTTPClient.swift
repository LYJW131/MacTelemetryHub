import Foundation

/**
 * 不能共用 `URLSession.shared` 的长连接池。
 *
 * 本机代理会让一条已经失活的 HTTP/2/HTTP/3 连接继续留在池里；下一次 POST
 * 复用它以后，请求体已经写出，却要等到 CFNetwork 的 stall recovery 才失败。
 * 一次性 session 让每次请求都重新建连，请求结束后随即丢掉对应连接池。
 * 要复用连接走 `ReusableHTTPClient`，它用短超时兜住这种失活连接。
 * 图标 HEAD 紧接着 PUT 可以共用这一次 session：连接刚建好，不是池里那条失活的。
 */
enum IsolatedHTTPClient {
    static func session(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    static func session(for request: URLRequest) -> URLSession {
        session(timeout: request.timeoutInterval)
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let session = session(for: request)
        defer { session.finishTasksAndInvalidate() }
        return try await data(for: request, session: session)
    }

    static func data(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
