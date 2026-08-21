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

    static func text(
        _ text: String,
        contentType: String = "text/plain; charset=utf-8",
        status: Int = 200,
        reason: String = "OK"
    ) -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, contentType: contentType, body: Data(text.utf8))
    }
}

/**
 * 一条还开着的 HTTP 连接，给 SSE 用。
 *
 * 普通响应写完就关；SSE 要把头先发出去，连接留着，按蓝牙推流往里写
 * `data:` 行。客户端断开或 `close()` 都会走到 `onClose`。
 */
@MainActor
final class HTTPStream {
    fileprivate let connection: NWConnection
    private(set) var isOpen = true
    var onClose: (() -> Void)?

    fileprivate init(connection: NWConnection) {
        self.connection = connection
    }

    func send(json: Data) {
        guard isOpen, let text = String(data: json, encoding: .utf8) else { return }
        var body = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            body += "data: \(line)\n"
        }
        body += "\n"
        send(raw: Data(body.utf8))
    }

    fileprivate func send(raw: Data, thenClose: Bool = false) {
        guard isOpen else { return }
        connection.send(content: raw, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil || thenClose { self.close() }
            }
        })
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        let callback = onClose
        onClose = nil
        callback?()
        connection.cancel()
    }
}

enum HTTPHandlerResult {
    case response(HTTPResponse)
    /// 先发流式响应头，再把还活着的连接交给这段代码。
    case stream(@MainActor (HTTPStream) -> Void)
}

@MainActor
final class LocalHTTPServer: ObservableObject {
    @Published private(set) var listeningURL: URL?
    @Published private(set) var boundHost: String?
    @Published private(set) var boundPort: Int?
    @Published private(set) var lastError: String?

    /// 状态栏和总览用：就是正在绑的那个地址，通配地址也原样写出来。
    var listeningDescription: String? {
        guard let host = boundHost, let port = boundPort else { return nil }
        return Self.httpURL(host: host, port: port)?.absoluteString
    }

    private var listener: NWListener?
    private var retryTask: Task<Void, Never>?
    private var desiredHost: String?
    private var desiredPort: Int?
    private var streams: [HTTPStream] = []
    private let handler: @MainActor (HTTPRequest) async -> HTTPHandlerResult

    init(handler: @escaping @MainActor (HTTPRequest) async -> HTTPHandlerResult) {
        self.handler = handler
    }

    func start(host: String, port: Int) {
        closeStreams()
        listener?.cancel()
        listener = nil
        retryTask?.cancel()
        retryTask = nil
        desiredHost = host
        desiredPort = port
        boundHost = nil
        boundPort = nil
        listeningURL = nil
        startListener(host: host, port: port)
    }

    private func startListener(host: String, port: Int) {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            lastError = "HTTP 端口无效"
            return
        }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: endpointPort)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.boundHost = host
                        self.boundPort = port
                        self.listeningURL = Self.openableURL(bindHost: host, port: port)
                        self.lastError = nil
                    case let .failed(error):
                        self.boundHost = nil
                        self.boundPort = nil
                        self.listeningURL = nil
                        self.lastError = "HTTP 服务启动失败：\(error.localizedDescription)"
                        self.scheduleRetry(host: host, port: port)
                    case .cancelled:
                        self.boundHost = nil
                        self.boundPort = nil
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
        desiredHost = nil
        desiredPort = nil
        retryTask?.cancel()
        retryTask = nil
        closeStreams()
        listener?.cancel()
        listener = nil
        boundHost = nil
        boundPort = nil
        listeningURL = nil
    }

    /// `0.0.0.0` / `::` 浏览器打不开，打开按钮退到本机回环。
    private static func openableURL(bindHost: String, port: Int) -> URL? {
        switch bindHost {
        case "0.0.0.0": return httpURL(host: "127.0.0.1", port: port)
        case "::": return httpURL(host: "::1", port: port)
        default: return httpURL(host: bindHost, port: port)
        }
    }

    static func httpURL(host: String, port: Int) -> URL? {
        if host.contains(":") {
            return URL(string: "http://[\(host)]:\(port)/")
        }
        return URL(string: "http://\(host):\(port)/")
    }

    private func closeStreams() {
        let open = streams
        streams.removeAll()
        for stream in open { stream.close() }
    }

    private func scheduleRetry(host: String, port: Int) {
        guard desiredHost == host, desiredPort == port else { return }
        listener?.cancel()
        listener = nil
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self,
                  self.desiredHost == host, self.desiredPort == port else { return }
            self.startListener(host: host, port: port)
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
                        self.reply(.text("Bad Request\n", status: 400, reason: "Bad Request"), on: connection)
                        return
                    }
                    switch await self.handler(request) {
                    case let .response(response):
                        self.reply(response, on: connection)
                    case let .stream(start):
                        self.beginStream(on: connection, start: start)
                    }
                } else if error == nil, requestData.count < 65_536 {
                    self.receive(on: connection, accumulated: requestData)
                } else {
                    connection.cancel()
                }
            }
        }
    }

    private func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let text = String(data: data, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let path = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        return HTTPRequest(method: String(parts[0]).uppercased(), path: path)
    }

    private func reply(_ response: HTTPResponse, on connection: NWConnection) {
        var header = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        header += "Content-Type: \(response.contentType)\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Methods: GET, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: *\r\n"
        header += "Access-Control-Allow-Private-Network: true\r\n"
        header += "Connection: close\r\n\r\n"
        var output = Data(header.utf8)
        output.append(response.body)
        connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func beginStream(on connection: NWConnection, start: @escaping @MainActor (HTTPStream) -> Void) {
        let stream = HTTPStream(connection: connection)
        streams.append(stream)
        stream.onClose = { [weak self, weak stream] in
            guard let self, let stream else { return }
            self.streams.removeAll { $0 === stream }
        }
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: text/event-stream; charset=utf-8\r\n"
        header += "Cache-Control: no-cache, no-store\r\n"
        header += "Connection: keep-alive\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Private-Network: true\r\n"
        header += "X-Accel-Buffering: no\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self, weak stream] error in
            Task { @MainActor in
                if error != nil {
                    stream?.close()
                    return
                }
                guard let self, let stream, stream.isOpen else { return }
                start(stream)
                self.watch(stream)
            }
        })
    }

    /// 请求头已经读完。再挂一次 receive，只为知道对端把连接掐了。
    private func watch(_ stream: HTTPStream) {
        stream.connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self, weak stream] _, _, isComplete, error in
            Task { @MainActor in
                guard let self, let stream, stream.isOpen else { return }
                if isComplete || error != nil {
                    stream.close()
                } else {
                    self.watch(stream)
                }
            }
        }
    }
}
