import CryptoKit
import Foundation

struct AnkerCloudSession: Equatable, Sendable {
    var userID: String
    var authToken: String
    var expiresAt: TimeInterval
}

struct AnkerScreensaverPicture: Identifiable, Equatable, Sendable {
    let id: Int
    let seq: Int
    let name: String
    let hashCode: UInt32
    let imageURL: URL?
    let shortURL: String
}

enum AnkerCloudError: LocalizedError {
    case missingCredentials
    case notLoggedIn
    case invalidResponse
    case server(Int, String)
    case missingUserID
    case missingToken
    case missingSerial
    case missingHash(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "请先填写 Anker 账号和密码。"
        case .notLoggedIn: "还没有登录云端。封面列表只在你点「登录并写入用户 ID」之后才会去拉。"
        case .invalidResponse: "Anker 云端返回了无法解析的响应。"
        case let .server(_, message): message
        case .missingUserID: "登录成功但没有返回用户 ID。"
        case .missingToken: "登录成功但没有返回会话令牌。"
        case .missingSerial: "还没有读到充电头序列号，连上后再拉封面。"
        case let .missingHash(id): "封面 \(id) 没有 hash_code，无法切换。"
        }
    }
}

/// CN Anker Power HTTP client. Bodies stay plaintext; only the password is wrapped.
enum AnkerCloudClient {
    static let defaultHost = URL(string: "https://aiot-api-cn.anker.com.cn")!

    static func login(
        account: String,
        password: String,
        host: URL = defaultHost,
        now: Date = Date()
    ) async throws -> AnkerCloudSession {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else { throw AnkerCloudError.missingCredentials }
        let envelope = try AnkerPassportCrypto.passwordEnvelope(password)
        let offsetMs = Int((TimeZone.current.secondsFromGMT(for: now)) * 1_000)
        let body: [String: Any] = [
            "ab": "CN",
            "client_secret_info": ["public_key": envelope.clientPublicKeyHex],
            "enc": 0,
            "email": trimmed,
            "password": envelope.encryptedPassword,
            "time_zone": offsetMs,
            "transaction": String(Int(now.timeIntervalSince1970 * 1_000)),
        ]
        let json = try await post(host: host, path: "/passport/login", body: body, session: nil)
        let data = try requireData(json)
        guard let userID = string(data["user_id"]), userID.utf8.count == 40 else {
            throw AnkerCloudError.missingUserID
        }
        guard let token = string(data["auth_token"]), !token.isEmpty else {
            throw AnkerCloudError.missingToken
        }
        let expires = number(data["token_expires_at"]) ?? 0
        return AnkerCloudSession(userID: userID, authToken: token, expiresAt: expires)
    }

    static func listScreensavers(
        serial: String,
        session: AnkerCloudSession,
        host: URL = defaultHost
    ) async throws -> [AnkerScreensaverPicture] {
        let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AnkerCloudError.missingSerial }
        let json = try await post(
            host: host,
            path: "/mini_power/v1/app/style/get_manual_clock_screensavers",
            body: ["sn": trimmed],
            session: session
        )
        let data = try requireData(json)
        let rows = data["list"] as? [[String: Any]] ?? []
        return try rows.compactMap { row in
            guard let id = int(row["id"]) else { return nil }
            guard let hash = AnkerPassportCrypto.parseHashCode(string(row["hash_code"]) ?? "") else {
                throw AnkerCloudError.missingHash(id)
            }
            let image = string(row["img_url"]).flatMap(URL.init(string:))
            return AnkerScreensaverPicture(
                id: id,
                seq: int(row["seq"]) ?? 0,
                name: (string(row["name"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                hashCode: hash,
                imageURL: image,
                shortURL: string(row["short_url"]) ?? ""
            )
        }.sorted { lhs, rhs in
            if lhs.seq != rhs.seq { return lhs.seq < rhs.seq }
            return lhs.id < rhs.id
        }
    }

    static func imageData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AnkerCloudError.server(status, "封面图片下载失败（HTTP \(status)）")
        }
        return data
    }

    private static func post(
        host: URL,
        path: String,
        body: [String: Any],
        session: AnkerCloudSession?
    ) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: host)?.absoluteURL else {
            throw AnkerCloudError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("anker_power", forHTTPHeaderField: "app-name")
        request.setValue("3.22.2", forHTTPHeaderField: "app-version")
        request.setValue("iOS", forHTTPHeaderField: "os-type")
        request.setValue("PHONE", forHTTPHeaderField: "model-type")
        request.setValue("CN", forHTTPHeaderField: "country")
        request.setValue("zh", forHTTPHeaderField: "language")
        request.setValue("ktor-client", forHTTPHeaderField: "user-agent")
        if let session {
            request.setValue(session.authToken, forHTTPHeaderField: "x-auth-token")
            request.setValue(session.userID, forHTTPHeaderField: "uid")
            request.setValue(md5Hex(session.userID), forHTTPHeaderField: "gtoken")
        }
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw AnkerCloudError.invalidResponse }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if http.statusCode == 401 || int(object?["code"]) == 401 {
            throw AnkerCloudError.server(401, string(object?["msg"]) ?? "Anker 登录已过期，请重新登录。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AnkerCloudError.server(
                http.statusCode,
                string(object?["msg"]) ?? "Anker 云端请求失败（HTTP \(http.statusCode)）"
            )
        }
        guard let object else { throw AnkerCloudError.invalidResponse }
        let code = int(object["code"]) ?? -1
        guard code == 0 else {
            throw AnkerCloudError.server(code, string(object["msg"]) ?? "Anker 云端返回 \(code)")
        }
        return object
    }

    private static func requireData(_ object: [String: Any]) throws -> [String: Any] {
        guard let data = object["data"] as? [String: Any] else { throw AnkerCloudError.invalidResponse }
        return data
    }

    private static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    private static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? CustomStringConvertible, !(value is NSNull) {
            let text = String(describing: value)
            return text == "<null>" ? nil : text
        }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func number(_ value: Any?) -> TimeInterval? {
        if let value = value as? TimeInterval { return value }
        if let value = value as? Int { return TimeInterval(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return TimeInterval(value) }
        return nil
    }
}
