@preconcurrency import Network
import Foundation

struct HTTPRequest: Sendable {
    let method: String
    let path: String
}

struct HTTPResponse: Sendable {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data

    static func json(_ data: Data, status: Int = 200, reason: String = "OK") -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, contentType: "application/json; charset=utf-8", body: data)
    }

    static func text(_ text: String, contentType: String = "text/plain; charset=utf-8", status: Int = 200, reason: String = "OK") -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, contentType: contentType, body: Data(text.utf8))
    }
}

@MainActor
final class LocalHTTPServer: ObservableObject {
    @Published private(set) var listeningURL: URL?
    @Published private(set) var lastError: String?

    private var listener: NWListener?
    private var retryTask: Task<Void, Never>?
    private var desiredPort: Int?
    private let handler: @MainActor (HTTPRequest) async -> HTTPResponse

    init(handler: @escaping @MainActor (HTTPRequest) async -> HTTPResponse) {
        self.handler = handler
    }

    func start(port: Int) {
        listener?.cancel()
        listener = nil
        retryTask?.cancel()
        retryTask = nil
        desiredPort = port
        startListener(port: port)
    }

    private func startListener(port: Int) {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            lastError = "HTTP 端口无效"
            return
        }
        do {
            let listener = try NWListener(using: .tcp, on: endpointPort)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.listeningURL = URL(string: "http://127.0.0.1:\(port)/")
                        self.lastError = nil
                    case let .failed(error):
                        self.listeningURL = nil
                        self.lastError = "HTTP 服务启动失败：\(error.localizedDescription)"
                        self.scheduleRetry(port: port)
                    case .cancelled:
                        self.listeningURL = nil
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            lastError = "HTTP 服务启动失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        desiredPort = nil
        retryTask?.cancel()
        retryTask = nil
        listener?.cancel()
        listener = nil
        listeningURL = nil
    }

    private func scheduleRetry(port: Int) {
        guard desiredPort == port else { return }
        listener?.cancel()
        listener = nil
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.desiredPort == port else { return }
            self.startListener(port: port)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var requestData = accumulated
                if let data { requestData.append(data) }
                if requestData.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete {
                    guard let request = self.parseRequest(requestData) else {
                        self.send(.text("Bad Request\n", status: 400, reason: "Bad Request"), on: connection)
                        return
                    }
                    let response = await self.handler(request)
                    self.send(response, on: connection)
                } else if error == nil, requestData.count < 65_536 {
                    self.receive(on: connection, accumulated: requestData)
                } else {
                    connection.cancel()
                }
            }
        }
    }

    private func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let text = String(data: data, encoding: .utf8), let line = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let path = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        return HTTPRequest(method: String(parts[0]).uppercased(), path: path)
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        var header = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        header += "Content-Type: \(response.contentType)\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        header += "Connection: close\r\n\r\n"
        var output = Data(header.utf8)
        output.append(response.body)
        connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
    }
}
