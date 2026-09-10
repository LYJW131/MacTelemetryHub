import CryptoKit
import Foundation

struct R2UploadConfiguration: Sendable {
    let endpoint: URL
    let bucket: String
    let accessKeyID: String
    let secretAccessKey: String
}

/**
 * 图标 / 封面直传 R2。
 *
 * 这里只有 SigV4 和两个请求，没有任何设置读取：四项配置从哪里来是 App 的事
 * （见 `AppSettings+R2.swift`），签名和上传是纯逻辑，可以单独测。
 */
enum R2IconUploader {
    enum UploadError: LocalizedError {
        case invalidConfiguration
        case hashMismatch
        case httpStatus(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: "R2 直传配置无效。"
            case .hashMismatch: "图标内容哈希不一致。"
            case let .httpStatus(status, detail):
                detail.isEmpty ? "R2 上传失败（HTTP \(status)）。" : "R2 上传失败（HTTP \(status)：\(detail)）。"
            }
        }
    }

    /**
     * 检查内容寻址对象是否仍在桶里。
     *
     * 这一步只在后台图标 resolver 里跑，不再挡住前台应用名称上报。每个图标
     * 最多五分钟检查一次，用来接住桶被清空或对象被手动删除后的自愈。
     */
    static func exists(
        objectKey: String,
        configuration: R2UploadConfiguration,
        timeout: TimeInterval
    ) async throws -> Bool {
        let url = try objectURL(
            endpoint: configuration.endpoint,
            bucket: configuration.bucket,
            objectKey: objectKey
        )
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        sign(&request, payloadHash: emptyPayloadHash, contentType: nil,
             method: "HEAD", url: url, configuration: configuration, now: Date())
        let (_, response) = try await IsolatedHTTPClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.httpStatus(0, "R2 返回了无效响应")
        }
        if http.statusCode == 404 { return false }
        guard (200..<300).contains(http.statusCode) else {
            throw UploadError.httpStatus(http.statusCode, "检查图标对象失败")
        }
        return true
    }

    static func upload(
        data: Data,
        contentHash: String,
        objectKey: String,
        configuration: R2UploadConfiguration,
        timeout: TimeInterval
    ) async throws {
        let actualHash = sha256Hex(data)
        guard actualHash == contentHash else { throw UploadError.hashMismatch }

        let objectURL = try objectURL(
            endpoint: configuration.endpoint,
            bucket: configuration.bucket,
            objectKey: objectKey
        )
        var request = URLRequest(url: objectURL)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.timeoutInterval = timeout
        // 内容寻址 = 不可变，让浏览器和 Cloudflare 边缘放心缓存一年
        request.setValue("public, max-age=31536000, immutable", forHTTPHeaderField: "Cache-Control")
        sign(&request, payloadHash: actualHash, contentType: contentType(for: objectKey),
             method: "PUT", url: objectURL, configuration: configuration, now: Date())

        let (responseData, response) = try await IsolatedHTTPClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.httpStatus(0, "R2 返回了无效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: responseData.prefix(512), encoding: .utf8) ?? ""
            throw UploadError.httpStatus(http.statusCode, detail)
        }
    }

    /// 编码产物的内容地址。身份哈希标识「哪个应用的图标」，这个标识「哪份字节」。
    /// 桌面图标是 PNG；充电头封面是 Anker 源 JPEG 原样上传，扩展名跟字节走。
    static func objectKey(for data: Data, ext: String = "png") -> String {
        "\(sha256Hex(data)).\(ext)"
    }

    static func contentHash(of data: Data) -> String { sha256Hex(data) }

    /// 空请求体的 payload 哈希，SigV4 里 HEAD 用它
    static let emptyPayloadHash =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /**
     * 对象键的扩展名决定 Content-Type；键本身是内容地址，扩展名就是事实。
     *
     * 三种扩展名各写各的。从前 webp 是兜底分支，于是「未知扩展名」被当成 webp
     * 发出去 —— 那既不是事实，也让「有没有覆盖 webp」看不出来。眼下
     * `objectKey(for:ext:)` 只签出 png 和 jpg，最后那条兜底走不到。
     */
    static func contentType(for objectKey: String) -> String {
        if objectKey.hasSuffix(".png") { return "image/png" }
        if objectKey.hasSuffix(".jpg") || objectKey.hasSuffix(".jpeg") { return "image/jpeg" }
        if objectKey.hasSuffix(".webp") { return "image/webp" }
        return "application/octet-stream"
    }

    /**
     * SigV4 签名。HEAD 和 PUT 共用一份，免得两处各写一遍再慢慢分家。
     *
     * `Cache-Control` 有意不进签名头列表：SigV4 只要求签 host 和 x-amz-*，
     * 多发的头不参与签名，R2 也认（实测 200）。
     *
     * `now` 由调用方给：签名结果完全由它决定，注进来才测得了。
     */
    static func sign(
        _ request: inout URLRequest,
        payloadHash: String,
        contentType: String?,
        method: String,
        url: URL,
        configuration: R2UploadConfiguration,
        now: Date
    ) {
        let amzDate = timestamp(now)
        let shortDate = String(amzDate.prefix(8))
        let scope = "\(shortDate)/auto/s3/aws4_request"
        let canonicalPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
            ?? url.path

        var headers: [(String, String)] = [("host", hostHeader(for: url))]
        if let contentType { headers.append(("content-type", contentType)) }
        headers.append(("x-amz-content-sha256", payloadHash))
        headers.append(("x-amz-date", amzDate))
        // 规范请求要求签名头按字典序排列
        headers.sort { $0.0 < $1.0 }

        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)" }.joined(separator: "\n") + "\n"
        let canonicalRequest = [
            method,
            canonicalPath,
            "",
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")
        let signingKey = hmac(
            hmac(
                hmac(
                    hmac(Data("AWS4\(configuration.secretAccessKey)".utf8), shortDate),
                    "auto"
                ),
                "s3"
            ),
            "aws4_request"
        )
        let signature = hex(hmac(signingKey, stringToSign))

        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(configuration.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    static func objectURL(endpoint: URL, bucket: String, objectKey: String) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw UploadError.invalidConfiguration
        }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let bucketPath = bucket.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bucket
        let keyPath = objectKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? objectKey
        let path = [basePath, bucketPath, keyPath].filter { !$0.isEmpty }.joined(separator: "/")
        components.percentEncodedPath = "/\(path)"
        guard let url = components.url else { throw UploadError.invalidConfiguration }
        return url
    }

    private static func hostHeader(for url: URL) -> String {
        var host = url.host ?? ""
        if let port = url.port { host += ":\(port)" }
        return host
    }

    /**
     * SigV4 的 `x-amz-date`：`yyyyMMdd'T'HHmmss'Z'`，UTC。
     *
     * 从前每签一次就新建一个 DateFormatter。格式是常量，没必要每次重建；而
     * DateFormatter 不是 Sendable，静态缓存过不了严格并发检查，所以换成
     * `Date.ISO8601FormatStyle`（值类型、Sendable），输出逐字符相同。
     */
    private static let amzDateStyle = Date.ISO8601FormatStyle(
        dateSeparator: .omitted,
        dateTimeSeparator: .standard,
        timeSeparator: .omitted,
        timeZoneSeparator: .omitted,
        includingFractionalSeconds: false,
        timeZone: .gmt
    )

    static func timestamp(_ now: Date) -> String {
        now.formatted(amzDateStyle)
    }

    private static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        ))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
