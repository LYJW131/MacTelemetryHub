import Foundation

/**
 * 上报请求不能共用 `URLSession.shared` 的长连接池。
 *
 * 本机代理会让一条已经失活的 HTTP/2/HTTP/3 连接继续留在池里；下一次 POST
 * 复用它以后，请求体已经写出，却要等到 CFNetwork 的 stall recovery 才失败。
 * 一次性 session 让每次请求都重新建连，请求结束后随即丢掉对应连接池。
 */
enum IsolatedHTTPClient {
    static func session(for request: URLRequest) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        return URLSession(configuration: configuration)
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let session = session(for: request)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }
}
