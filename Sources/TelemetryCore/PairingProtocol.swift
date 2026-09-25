import CryptoKit
import Foundation
import Security

/**
 * 配对登录（授权码 + PKCE）里不碰界面和网络的那部分。
 *
 * 契约在站点仓库 `docs/reporter-pairing.md`：浏览器里用 Cloudflare Access 登录并确认，
 * 回调带回一个 5 分钟内有效的授权码，App 拿它和只有自己知道的 verifier 换这个来源专用的
 * service token。兑换成功那一刻旧 secret 就作废了。
 */
enum PairingProtocol {
    static let authorizeURL = URL(string: "https://api.homepage.lyjw.llc/pair/authorize")!
    static let tokenURL = URL(string: "https://api.homepage.lyjw.llc/api/pair/token")!

    /// 一次配对要带着走的三个随机值。verifier 只留在本进程里，不进 URL。
    struct Attempt: Equatable, Sendable {
        let codeVerifier: String
        let codeChallenge: String
        let state: String

        init(codeVerifier: String, state: String) {
            self.codeVerifier = codeVerifier
            self.codeChallenge = PairingProtocol.codeChallenge(for: codeVerifier)
            self.state = state
        }

        /// 32 字节随机数的 base64url 做 verifier，state 另取 32 字节。
        static func random(
            randomBytes: (Int) throws -> Data = PairingProtocol.secureRandomBytes
        ) throws -> Attempt {
            Attempt(
                codeVerifier: PairingProtocol.base64URL(try randomBytes(32)),
                state: PairingProtocol.base64URL(try randomBytes(32))
            )
        }
    }

    enum PairingError: LocalizedError, Equatable {
        case randomUnavailable(OSStatus)
        case callbackMissingCode
        case stateMismatch
        case denied
        case authorizationError(String)
        case exchangeFailed(status: Int, reason: String?)
        case unexpectedSource(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case let .randomUnavailable(status): "无法生成随机数（\(status)）。"
            case .callbackMissingCode: "回调里没有授权码。"
            case .stateMismatch: "回调的 state 与本次登录不符，已丢弃。"
            case .denied: "已在确认页拒绝，原有凭据不变。"
            case let .authorizationError(code): "授权页返回错误：\(code)。"
            case let .exchangeFailed(status, reason):
                reason.map { "兑换凭据失败（\(status)）：\($0)" } ?? "兑换凭据失败（HTTP \(status)）。"
            case let .unexpectedSource(source): "服务端发来的是 \(source) 的凭据，不是本机来源，已丢弃。"
            case .invalidResponse: "兑换凭据的响应无法解析。"
            }
        }
    }

    struct Credentials: Decodable, Equatable, Sendable {
        let source: String
        let clientId: String
        let clientSecret: String
        let ingestUrl: String
    }

    private struct TokenEnvelope: Decodable {
        let ok: Bool
        let data: Credentials?
        let error: String?
    }

    private struct TokenRequestBody: Encodable {
        let code: String
        let codeVerifier: String
    }

    static func secureRandomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw PairingError.randomUnavailable(status) }
        return Data(bytes)
    }

    /// RFC 4648 §5，去掉填充。
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// S256：`base64url(SHA-256(ASCII(verifier)))`。
    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func authorizationURL(source: String, redirectURI: String, attempt: Attempt) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "source", value: source),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: attempt.state),
            URLQueryItem(name: "code_challenge", value: attempt.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        // queryItems 不转义查询里合法的 `:` 和 `/`，Worker 解码出来是同一个值；这里仍然
        // 全转义，让 redirect_uri 在地址栏和日志里一眼看得出是一个完整的参数值。
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: "/", with: "%2F")
        return components.url!
    }

    /// 从回调里取授权码。先核对 state：state 不符时连 error 也不信。
    static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard value("state") == expectedState else { throw PairingError.stateMismatch }
        if let error = value("error") {
            throw error == "access_denied" ? PairingError.denied : PairingError.authorizationError(error)
        }
        guard let code = value("code"), !code.isEmpty else { throw PairingError.callbackMissingCode }
        return code
    }

    static func tokenRequest(
        code: String,
        codeVerifier: String,
        userAgent: String,
        timeout: TimeInterval = 30
    ) throws -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(TokenRequestBody(code: code, codeVerifier: codeVerifier))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Cloudflare 的浏览器完整性检查会拦某些默认 UA，必须带自己的。
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        return request
    }

    /// 不看状态码先解包：400 的正文里才有失败原因。
    static func credentials(from data: Data, status: Int, expectedSource: String) throws -> Credentials {
        let envelope = try? JSONDecoder().decode(TokenEnvelope.self, from: data)
        guard (200..<300).contains(status), let envelope, envelope.ok else {
            throw PairingError.exchangeFailed(status: status, reason: envelope?.error)
        }
        guard let credentials = envelope.data,
              !credentials.clientId.isEmpty,
              !credentials.clientSecret.isEmpty,
              let ingest = URL(string: credentials.ingestUrl),
              ["http", "https"].contains(ingest.scheme?.lowercased() ?? ""),
              ingest.host != nil else {
            throw PairingError.invalidResponse
        }
        guard credentials.source == expectedSource else {
            throw PairingError.unexpectedSource(credentials.source)
        }
        return credentials
    }
}
