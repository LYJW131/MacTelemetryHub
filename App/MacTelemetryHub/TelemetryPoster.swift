import Foundation

/**
 * 心跳和数据包共用的 ingest POST。
 *
 * 编码、User-Agent、鉴权头只在这里写一次。数据包走 `post`，失败不推进门闩。
 * 心跳的阻塞发送仍是信号量：睡眠和退出的观察者返回之后进程就停了。
 */
enum TelemetryPoster {
    static let userAgent = "mac-telemetry-hub/4"

    static func request(
        url: URL,
        body: Data,
        clientID: String,
        secret: String,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Cloudflare Access service token：边缘验过才放行，Worker 再验 Access 签的 JWT
        request.setValue(clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        request.timeoutInterval = timeout
        return request
    }

    static func post(_ request: URLRequest) async throws -> TelemetryIngestResponse {
        let (responseData, response) = try await IsolatedHTTPClient.data(for: request)
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw ReporterError.httpStatus(
                response.statusCode,
                detail: ReporterError.ingestErrorDetail(responseData)
            )
        }
        return try JSONDecoder().decode(TelemetryIngestResponse.self, from: responseData)
    }

    static func send(_ request: URLRequest) -> Task<Void, Never> {
        Task { _ = try? await IsolatedHTTPClient.data(for: request) }
    }

    static func sendBlocking(_ request: URLRequest) {
        let done = DispatchSemaphore(value: 0)
        let session = IsolatedHTTPClient.session(for: request)
        session.dataTask(with: request) { _, _, _ in
            session.finishTasksAndInvalidate()
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + request.timeoutInterval)
    }
}
