import Foundation
import XCTest
@testable import TelemetryCore

final class ReusableHTTPClientTests: XCTestCase {
    private let url = URL(string: "https://ingest.example.test/api/ingest/mac")!

    override func tearDown() {
        StubProtocol.reset()
        super.tearDown()
    }

    private func client(fallback: @escaping ReusableHTTPClient.Fallback) -> ReusableHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ReusableHTTPClient(firstAttemptTimeout: 3, configuration: configuration, fallback: fallback)
    }

    private func request(timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        return request
    }

    func testFirstAttemptUsesShortTimeoutAndSkipsFallbackOnSuccess() async throws {
        StubProtocol.respond { _ in .success(status: 202) }
        let client = client { _ in XCTFail("fallback should not run"); throw URLError(.unknown) }

        let (_, response) = try await client.data(for: request(timeout: 10))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 202)
        XCTAssertEqual(StubProtocol.seenTimeouts, [3])
    }

    func testStaleConnectionFallsBackWithOriginalTimeout() async throws {
        StubProtocol.respond { _ in .failure(URLError(.timedOut)) }
        let fallbackTimeouts = Recorder()
        let client = client { request in
            await fallbackTimeouts.append(request.timeoutInterval)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!)
        }

        let (_, response) = try await client.data(for: request(timeout: 10))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 202)
        let timeouts = await fallbackTimeouts.values
        XCTAssertEqual(timeouts, [10])
    }

    func testHTTPErrorStatusIsReturnedWithoutFallback() async throws {
        StubProtocol.respond { _ in .success(status: 401) }
        let client = client { _ in XCTFail("fallback should not run"); throw URLError(.unknown) }

        let (_, response) = try await client.data(for: request(timeout: 10))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
    }

    func testPoolIsRebuiltAfterFallback() async throws {
        var attempts = 0
        StubProtocol.respond { _ in
            attempts += 1
            return attempts == 1 ? .failure(URLError(.networkConnectionLost)) : .success(status: 202)
        }
        let client = client { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!)
        }

        _ = try await client.data(for: request(timeout: 10))
        _ = try await client.data(for: request(timeout: 10))

        XCTAssertEqual(StubProtocol.seenTimeouts, [3, 3])
    }
}

private actor Recorder {
    private(set) var values: [TimeInterval] = []
    func append(_ value: TimeInterval) { values.append(value) }
}

private enum StubOutcome {
    case success(status: Int)
    case failure(URLError)
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var handler: ((URLRequest) -> StubOutcome)?
    nonisolated(unsafe) private(set) static var seenTimeouts: [TimeInterval] = []
    private static let lock = NSLock()

    static func respond(_ handler: @escaping (URLRequest) -> StubOutcome) {
        lock.withLock { self.handler = handler }
    }

    static func reset() {
        lock.withLock {
            handler = nil
            seenTimeouts = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let outcome: StubOutcome? = Self.lock.withLock {
            Self.seenTimeouts.append(request.timeoutInterval)
            return Self.handler?(request)
        }
        switch outcome {
        case .success(let status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }

    override func stopLoading() {}
}
