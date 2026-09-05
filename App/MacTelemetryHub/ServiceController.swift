import AppKit
import CryptoKit
import Foundation
import MusicKit

private struct R2UploadConfiguration: Sendable {
    let endpoint: URL
    let bucket: String
    let accessKeyID: String
    let secretAccessKey: String
}

/**
 * 上报请求不能共用 `URLSession.shared` 的长连接池。
 *
 * 本机代理会让一条已经失活的 HTTP/2/HTTP/3 连接继续留在池里；下一次 POST
 * 复用它以后，请求体已经写出，却要等到 CFNetwork 的 stall recovery 才失败。
 * 一次性 session 让每次请求都重新建连，请求结束后随即丢掉对应连接池。
 */
private enum IsolatedHTTPClient {
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

private enum R2IconUploader {
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

    @MainActor
    static func configuration(settings: AppSettings) -> R2UploadConfiguration? {
        let endpointText = settings.r2Endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let bucket = settings.r2Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessKeyID = settings.r2AccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretAccessKey = settings.r2SecretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpointText.isEmpty, !bucket.isEmpty, !accessKeyID.isEmpty,
              !secretAccessKey.isEmpty,
              let endpoint = URL(string: endpointText),
              endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
            return nil
        }
        return R2UploadConfiguration(
            endpoint: endpoint,
            bucket: bucket,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey
        )
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
             method: "HEAD", url: url, configuration: configuration)
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
             method: "PUT", url: objectURL, configuration: configuration)

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
    private static let emptyPayloadHash =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// 对象键的扩展名决定 Content-Type；键本身是内容地址，扩展名就是事实
    private static func contentType(for objectKey: String) -> String {
        if objectKey.hasSuffix(".png") { return "image/png" }
        if objectKey.hasSuffix(".jpg") || objectKey.hasSuffix(".jpeg") { return "image/jpeg" }
        return "image/webp"
    }

    /**
     * SigV4 签名。HEAD 和 PUT 共用一份，免得两处各写一遍再慢慢分家。
     *
     * `Cache-Control` 有意不进签名头列表：SigV4 只要求签 host 和 x-amz-*，
     * 多发的头不参与签名，R2 也认（实测 200）。
     */
    private static func sign(
        _ request: inout URLRequest,
        payloadHash: String,
        contentType: String?,
        method: String,
        url: URL,
        configuration: R2UploadConfiguration
    ) {
        let amzDate = timestamp()
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

    private static func objectURL(endpoint: URL, bucket: String, objectKey: String) throws -> URL {
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

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
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

enum TelemetryModule: String, CaseIterable, Hashable, Sendable {
    case desktop
    case appleMusic
    case charger
    case powerBank
    case timezone
    case vibeCoding
    case vibeCodingYear

    var displayName: String {
        switch self {
        case .desktop: "前台应用"
        case .appleMusic: "Apple Music"
        case .charger: "充电头"
        case .powerBank: "充电宝"
        case .timezone: "Mac 时区"
        case .vibeCoding: "Vibe Coding"
        case .vibeCodingYear: "年度用量"
        }
    }
}

private struct ChargerUploadSignature: Equatable {
    let connected: Bool
    let totalOutputPowerW: Double?
    let device: StatusDevicePayload
    let ports: [String: StatusPortPayload]

    init(_ payload: StatusPayload) {
        connected = payload.connected
        totalOutputPowerW = payload.totalOutputPowerW
        device = payload.device
        ports = payload.ports
    }
}

/**
 * 只包含「插拔 / 换设备」这类结构性变化的指纹，用来决定要不要即时上报。
 *
 * `mode` 是充电头自己给的端口开关位（0xA5/0xA6/0xA7 结构体的第一个字节），
 * 不是从功率推出来的 —— 实测插着线不取电的口是 `Output` + 0.00W，功率阈值
 * 那套会把它误判成关。所以它是最直接的插拔信号，比设备身份还灵：插一个
 * 表里没有的设备，身份查不出名字，但开关位一定会翻。
 *
 * 读 `PortState` 而不是上报载荷，是因为载荷里的 `model` / `vendor` 是查表查出来
 * 的显示名，表里没有的设备就是 nil、跟空口分不出来。`vendorID` / `productID`
 * 是原始值，没这个问题。
 */
/**
 * 「结构变了没有」的指纹 —— 决定要不要立刻叫醒上报循环。
 *
 * 采集是 1 Hz 推流，但绝大多数帧只是功率在滚动，那种变化等节流窗口就行。真正
 * 该立刻发的是插拔、连断、设备换了。所以这里只收会「跳变」的字段，功率电压电流
 * 一概不进 —— 否则每帧都判定为变化，循环就从 5 秒一转变成 1 秒一转。
 */
/**
 * 电量**不进**这份指纹。
 *
 * 曾经按整数百分比收过，理由是「跳一格该立刻发」。它会跳得比想象中厉害：90W
 * 输出时电压下垂、电量计重算，实测四秒内从 34.32% 掉到 33.32%，而按电池容量算
 * 一个百分点要三十秒。于是整数每跳一格就算一次结构变化，即时上报退化成五秒一
 * 次的轮询 —— 加上追发之后更糟，每一格都把追发计数重置满，循环再也停不下来。
 *
 * 电量是滚动读数，它该走节流窗口，和功率电压一样。
 */
private struct ChargingDevicesStructuralSignature: Equatable {
    private struct Port: Equatable {
        let name: String
        let active: Bool
        let direction: String?
        let attached: Bool?
        let cable: String?
        let deviceModel: String?
        let vendor: String?

        init(_ port: DevicePortPayload) {
            name = port.name
            active = port.active
            direction = port.direction
            attached = port.attached
            cable = port.cable
            deviceModel = port.attachedDevice?.model
            vendor = port.attachedDevice?.vendor
        }
    }

    private struct Device: Equatable {
        let id: String
        let kind: ChargingDeviceKind
        let connected: Bool
        let thermalLimited: Bool?
        /// 底座现在作为 B 口混在 ports 里，上下底座自然被端口那一项覆盖。
        let ports: [Port]
        let coverName: String?
        let coverIconHash: String?

        init(_ device: ChargingDevicePayload) {
            id = device.id
            kind = device.kind
            connected = device.connected
            thermalLimited = device.battery?.thermalLimited
            ports = device.ports.map(Port.init)
            coverName = device.cover?.name
            coverIconHash = device.cover?.iconHash
        }
    }

    private let devices: [Device]

    init(_ payload: ChargingDevicesPayload) {
        devices = payload.devices.map(Device.init)
    }
}


/**
 * 只包含「插拔 / 换设备」这类结构性变化的指纹，用来决定要不要即时上报。
 *
 * `mode` 是充电头自己给的端口开关位（0xA5/0xA6/0xA7 结构体的第一个字节），
 * 不是从功率推出来的 —— 实测插着线不取电的口是 `Output` + 0.00W，功率阈值
 * 那套会把它误判成关。所以它是最直接的插拔信号，比设备身份还灵：插一个
 * 表里没有的设备，身份查不出名字，但开关位一定会翻。
 *
 * 读 `PortState` 而不是上报载荷，是因为载荷里的 `model` / `vendor` 是查表查出来
 * 的显示名，表里没有的设备就是 nil、跟空口分不出来。`vendorID` / `productID`
 * 是原始值，没这个问题。
 */
private struct ChargerStructuralSignature: Equatable {
    private struct Port: Equatable {
        /// 充电头给的端口开关位，插拔最直接的信号
        let mode: String
        let vendorID: UInt16?
        let productID: UInt16?
        let brandCode: UInt8?
        let modelCode: UInt16?
        let cableCode: String?

        init(_ port: PortState) {
            mode = port.mode
            vendorID = port.vendorID
            productID = port.productID
            brandCode = port.brandCode
            modelCode = port.modelCode
            cableCode = port.cableCode
        }
    }

    private let connected: Bool
    private let device: DeviceInfo
    private let ports: [String: Port]

    init(connected: Bool, state: ChargerState) {
        self.connected = connected
        device = state.device
        ports = state.ports.mapValues(Port.init)
    }
}

private struct DesktopUploadSignature: Equatable {
    let applicationName: String
    let bundleIdentifier: String?
    let iconHash: String?

    init(_ snapshot: DesktopActivitySnapshot) {
        applicationName = snapshot.applicationName
        bundleIdentifier = snapshot.bundleIdentifier
        iconHash = snapshot.iconHash
    }
}

private struct TelemetryIngestResponse: Decodable {
    struct Result: Decodable {
        let desktopIconAvailable: Bool?
        let chargerCoverIconAvailable: Bool?
    }

    let data: Result
}

private struct TimeZoneUploadSignature: Equatable {
    let identifier: String
    let abbreviation: String?
    let secondsFromGMT: Int

    init(_ snapshot: TimeZoneSnapshot) {
        identifier = snapshot.identifier
        abbreviation = snapshot.abbreviation
        secondsFromGMT = snapshot.secondsFromGMT
    }
}

/// 播放进度刻意不进签名：播放时它每次采集都在变，会让「有变化才发」退化成定时轮询。
/// 网页拿 positionMs + observedAt 自己插值，进度条不需要上报器喂。
/// 拖动进度条这类跳变由 `AppleMusicPositionAnchor` 单独识别。
private struct AppleMusicUploadSignature: Equatable {
    let state: String
    let title: String?
    let artist: String?
    let album: String?
    let trackID: String?
    let durationMs: Int
    /// 切换循环模式要让网页知道，所以它进签名
    let repeatOne: Bool
    let queueSource: String?
    let queueIndex: Int?
    let queueTrackIDs: [String]

    init(_ snapshot: AppleMusicSnapshot) {
        state = snapshot.state
        title = snapshot.title
        artist = snapshot.artist
        album = snapshot.album
        trackID = snapshot.trackID
        durationMs = snapshot.durationMs
        repeatOne = snapshot.repeatOne
        queueSource = snapshot.queue?.source
        queueIndex = snapshot.queue?.index
        queueTrackIDs = snapshot.queue?.tracks.map {
            "\($0.trackID ?? "")\t\($0.title)\t\($0.artist ?? "")\t\($0.album ?? "")"
        } ?? []
    }
}

/// 上一次发出去的播放锚点。网页就是照这个往前推的，
/// 所以「要不要重新发」等价于「网页现在推出来的值还准不准」。
private struct AppleMusicPositionAnchor {
    let state: String
    let positionMs: Int
    let observedAt: Int64

    init(_ snapshot: AppleMusicSnapshot) {
        state = snapshot.state
        positionMs = snapshot.positionMs
        observedAt = snapshot.observedAt
    }

    /// 网页在 `observedAt` 这一刻会显示的进度
    func predicted(at observedAt: Int64) -> Int {
        guard state == "playing" else { return positionMs }
        return positionMs + Int(max(0, observedAt - self.observedAt))
    }
}

@MainActor
final class ServiceController: ObservableObject {
    let settings: AppSettings
    /// 每台设备一条独立链路：各自的 CBCentralManager、各自的配对 UUID。
    /// 连接节奏两边一样：定向连接、同一套重连和推流 watchdog。
    let chargingLinks: [BluetoothService]
    var chargerLink: BluetoothService { chargingLinks[0] }
    var powerBankLink: BluetoothService { chargingLinks[1] }
    let covers: ChargerCoverController
    let desktopActivity = DesktopActivityMonitor()
    let timeZone = TimeZoneMonitor()
    let appleMusic = AppleMusicMonitor()
    let appleMusicAuthorization = AppleMusicAuthorizationManager()
    /// 一个模块一个采集器：长间隔那份（token / 费用）和
    /// 短间隔那份（此刻在不在用）。年度热力图另走一块，间隔更长、按周切片。
    let vibeCodingUsageCollector = VibeCodingUsageMonitor()
    let codingSessions = CodingSessionMonitor()
    let vibeCodingYearCollector = VibeCodingYearMonitor()
    private let chargingSSE = ChargingSSEBroker()
    lazy private(set) var httpServer = LocalHTTPServer { [weak self] request in
        guard let self else {
            return .response(.text("Unavailable\n", status: 503, reason: "Service Unavailable"))
        }
        return await self.route(request)
    }

    @Published private(set) var reporterLastSuccess: Date?
    @Published private(set) var reporterLastError: String?
    /// 两个采集器各有各的按钮，所以在飞状态也各记各的 —— 重扫会话不该把
    /// 那个两百多次请求的用量按钮也一起变灰。
    @Published private(set) var isRefreshingVibeCodingUsage = false
    @Published private(set) var isRefreshingVibeCodingSessions = false
    @Published private(set) var isRefreshingVibeCodingYear = false
    @Published private(set) var appleMusicCredentialsUploadAt: Date?
    @Published private(set) var appleMusicCredentialsUploadError: String?
    @Published private(set) var isUploadingAppleMusicCredentials = false
    /// MusicKit 最近一次返回的缓存值。
    private var appleMusicCredentials: AppleMusicCredentials?
    private var lastPostedAppleMusicDeveloperToken: String?
    private var lastPostedAppleMusicUserToken: String?
    private var nextAppleMusicCredentialsRefreshAt = Date.distantPast
    private var isRefreshingAppleMusicCredentials = false
    @Published private(set) var pendingManualReports: Set<TelemetryModule> = []
    @Published private(set) var lastManualReportError: [TelemetryModule: String] = [:]
    @Published private(set) var lastManualReportAt: [TelemetryModule: Date] = [:]

    private var reporterTask: Task<Void, Never>?
    /// vibe coding 的采集循环，跟上报循环各转各的
    private var vibeCodingCollectionTask: Task<Void, Never>?
    private var vibeCodingSessionsTask: Task<Void, Never>?
    /// 三类载荷独立判断是否需要上报。
    private var lastPostedVibeCodingUsageAt: Date?
    private var lastPostedVibeCodingNowAt: Date?
    private var lastPostedVibeCodingYearAt: Date?
    private var lastPostedChargingDevices: ChargingDevicesPayload?
    /// 只跟结构性变化比，管的是「要不要即时发」，不管「要不要带 charger 模块」
    private var lastPostedChargingStructural: ChargingDevicesStructuralSignature?
    private var lastPostedDesktop: DesktopUploadSignature?
    /// 隐藏虚拟应用已成功发出。单靠 Optional 无法区分“尚未发过”和“已发隐藏态”。
    private var lastPostedDesktopWasHidden = false
    /// 这个上报会话里已经在 R2 确认存在的图标身份指纹。
    private var uploadedDesktopIconHashes: Set<String> = []
    /// 图标直传连续失败次数，按身份哈希记。到上限就不再试，避免打成热循环
    private var iconUploadAttempts: [String: Int] = [:]
    private static let maxIconUploadAttempts = 3
    /// 最近一次在 R2 确认存在的时间；过期后后台 HEAD 一次，接住手动清桶。
    private var desktopIconVerifiedAt: [String: Date] = [:]
    private static let desktopIconVerificationInterval: TimeInterval = 5 * 60
    /// 同一枚图标在飞的那一次后台检查 / 直传。
    private var iconResolvers: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var uploadedDesktopIconOrder: [String] = []
    private var lastPostedTimeZone: TimeZoneUploadSignature?
    private var lastPostedAppleMusic: AppleMusicUploadSignature?
    private var lastPostedMusicAnchor: AppleMusicPositionAnchor?
    private var lastHeartbeatAt: Date?
    private var started = false
    private var observesPower = false
    /**
     * 已经宣告过离线，别再发在线的包了。
     *
     * 关盖时锁屏和睡眠是同时发生的两件事：`com.apple.loginwindow` 抢到前台会
     * 排一个 400ms 的防抖，而 `willSleepNotification` 的观察者同步发出 offline。
     * 观察者返回后系统还要几百毫秒才真的挂起，防抖恰好在这段窗口里到点，于是
     * 那封「前台应用 = 锁屏」的信封跟在 offline 后面发了出去 —— 它的 presence
     * 默认是 online（见 makeTelemetryEnvelope），站点每封都算一次在线心跳，
     * 刚宣告的离线就这么被复活成「已锁屏」，一直挂到心跳窗口超时才翻回去。
     *
     * 站点那边修不了：迟到那封的 heartbeatAt 确实更晚，不是乱序，是这边真的
     * 在 offline 之后又发了 online。所以宣告离线的同时把嘴闭上，`didWake` 再开。
     */
    private var suspended = false

    /// 事件驱动的模块用它把上报循环提前叫醒，不必干等到下一个周期
    private var wakeContinuation: CheckedContinuation<Void, Never>?
    /// 事件发生在循环正忙的时候，等待还没开始 —— 记下来，下次别睡
    private var pendingWake = false
    private var desktopSettleTask: Task<Void, Never>?

    /// 循环的常规周期。前台应用、音乐、充电器插拔都会提前叫醒它，所以这个只
    /// 用来照顾没有事件放行的活：充电器功率滚动这类按节流窗口发的变化、
    /// 心跳、vibe coding 三份采集的刷新间隔检查。
    private static let tickInterval = Duration.seconds(5)
    /**
     * 安静时段补心跳的间隔。
     *
     * 只在这一圈没有任何数据要发的时候才补 —— 有数据时那个包本身就证明活着。
     * 纯心跳是 /api/ingest/mac 的主要流量（实测 12 小时 1.9K 次调用里约三分之二
     * 是它），而它唯一影响的是「崩溃 / 断网 / 强制关机」的判定延迟：关盖、睡眠、
     * 退出走 declaredOffline，收到那一条就瞬时翻转，不等这个间隔。
     *
     * ⚠️ 必须明显短于站点的存活窗口（`lib/freshness.ts` 的 HEARTBEAT_WINDOW_MS，
     * 现在是 300 秒，Vercel 和 EdgeOne 两边都显式配着）。两者一样长的话每一轮
     * 都踩在窗口边上，安静时段全站会断续显示离线。**先放宽窗口，再降心跳频率。**
     *
     * 和「发送间隔」（AppSettings 的 postInterval，本机 30 秒）是两档独立的节奏：
     * 那个管有数据时多久发一次，这个管没数据时多久证明一次还活着。两个数字曾经
     * 被填反过 —— 90 秒是这里的，不是那里的。
     */
    private static let heartbeatInterval: TimeInterval = 90
    /**
     * 充电设备结构变化后的追发。
     *
     * 插上负载的头几十秒功率还在剧烈变化 —— PD 协商完成、设备自己调整取电，
     * 都要一会儿才稳。即时上报只发出去插拔那一瞬间的那一帧，那一帧往往还是
     * 0W 或者一个中间值，然后要等满一个节流窗口（本机 30 秒）才更新，站点上
     * 就会挂着一个明显不对的读数。
     *
     * 所以结构变化后按这个节奏追发几次。次数是有限的：功率滚动本来就该等节流
     * 窗口，追发只是覆盖「刚接入」这段不稳定期，不是把上报变成 5 秒一次的轮询。
     */
    private static let chargingBurstInterval: TimeInterval = 5
    private static let chargingBurstCount = 5

    /// MusicKit 读取失败后的退避。
    private static let appleMusicRetryDelay: TimeInterval = 60

    /// token 检测仍在主循环内，但 MusicKit 的缓存没有必要每五秒读取一次。
    private static let appleMusicCredentialsRefreshInterval: TimeInterval = 5 * 60

    /**
     * 前台应用的防抖窗口。
     *
     * 每收到一次激活通知就重新计时，所以连续 Cmd-Tab 只会在最后停下来的那个
     * 应用上触发一次上报 —— 路过的应用停留远不到这个时长。
     * 从前这个防抖是 2 秒采样「顺便」带来的，把延迟和防抖强度焊死成了同一个
     * 数字；拆开之后延迟降到这个量级，而防抖强度可以单独调。
     */
    private static let desktopSettleDelay = Duration.milliseconds(400)

    /// 防止长期运行、打开大量一次性应用时让图标缓存无限增长。
    private static let uploadedDesktopIconLimit = 64

    /// 进度偏离预测多少才算被拖过。留 2.5 秒，既不会把采样抖动当 seek，
    /// 也接得住真的拖动。
    private static let musicSeekToleranceMs = 2_500

    init() {
        let settings = AppSettings()
        self.settings = settings
        chargingLinks = [
            BluetoothService(settings: settings, slot: .charger),
            BluetoothService(settings: settings, slot: .powerBank),
        ]
        covers = ChargerCoverController(settings: settings, chargerLink: chargingLinks[0])
    }

    deinit {
        reporterTask?.cancel()
        vibeCodingCollectionTask?.cancel()
        vibeCodingSessionsTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        configureModules()
        if settings.httpServerEnabled, let host = settings.normalizedHTTPBindAddress {
            httpServer.start(host: host, port: settings.httpPort)
        }
        restartReporter()
        observePowerTransitions()
        sendHeartbeat("online")
    }

    func stop() {
        // 抢在拆掉一切之前声明离线。同步发 —— 调用方紧接着就要退出进程了。
        declareOffline()
        reporterTask?.cancel()
        // 循环可能正挂在 waitForNextTick 上，叫醒它才能立刻看到 cancel 并退出
        wakeReporter()
        reporterTask = nil
        desktopSettleTask?.cancel()
        desktopSettleTask = nil
        cancelDesktopIconResolvers()
        vibeCodingCollectionTask?.cancel()
        vibeCodingSessionsTask?.cancel()
        vibeCodingCollectionTask = nil
        vibeCodingSessionsTask = nil
        desktopActivity.stop()
        timeZone.stop()
        appleMusic.stop()
        vibeCodingUsageCollector.stop()
        codingSessions.stop()
        vibeCodingYearCollector.stop()
        chargingSSE.closeAll()
        httpServer.stop()
        for link in chargingLinks { link.shutdown() }
    }

    /**
     * 睡眠 / 唤醒时声明在离线。
     *
     * 挂在 ServiceController 而不是某一条充电链路上：在线状态跟开了哪些模块无关。
     */
    private func observePowerTransitions() {
        guard !observesPower else { return }
        observesPower = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            // 必须同步：观察者一返回系统就接着睡了
            MainActor.assumeIsolated { self?.declareOffline() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspended = false
                self?.sendHeartbeat("online")
            }
        }
        /**
         * 菜单里的「退出」会先调 stop()，但 Cmd-Q、Dock 退出、注销都不走那条路，
         * 只有这个通知能盖住全部优雅退出。stop() 里那次是重复发，无所谓 ——
         * 漏发才有代价，多发一条只是让网页把同一个状态再确认一遍。
         */
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.declareOffline() }
        }
    }

    /**
     * 宣告离线，然后闭嘴。睡眠、Cmd-Q、菜单退出三条优雅离开共用这一条路。
     *
     * `suspended` 必须先立起来再发：那一条是阻塞发送，主线程被挡住的这几秒里
     * 排队的防抖和上报循环都动不了，等轮到它们时看到的必须已经是闭嘴状态 ——
     * 否则关盖那下发出去的就是 offline 后面跟一封 online（见 suspended）。
     * 防抖顺手掐掉：光靠 suspended 拦住发送也够，但没必要让它白醒一趟。
     */
    private func declareOffline() {
        suspended = true
        desktopSettleTask?.cancel()
        desktopSettleTask = nil
        sendHeartbeat("offline", blocking: true)
    }

    func applySettings() throws {
        let oldHost = httpServer.boundHost
        let oldPort = httpServer.boundPort
        try settings.save()
        if settings.httpServerEnabled, let host = settings.normalizedHTTPBindAddress {
            if oldHost != host || oldPort != settings.httpPort || httpServer.listeningURL == nil {
                chargingSSE.closeAll()
                httpServer.start(host: host, port: settings.httpPort)
            }
        } else {
            chargingSSE.closeAll()
            httpServer.stop()
        }
        configureModules()
        restartReporter()
    }

    /// Queues one module for an immediate, module-scoped envelope.
    /// The normal reporter remains the only code path that performs the network request.
    @discardableResult
    func requestImmediateReport(_ module: TelemetryModule) -> Bool {
        guard canRequestImmediateReport(module) else { return false }

        pendingManualReports.insert(module)
        lastManualReportError[module] = nil
        wakeReporter()
        return true
    }

    /**
     * 两个采集器各自的「立刻重取」，互不牵连。
     *
     * 会话刷新只读本地元数据，年度图只从持久账本生成。
     * 各 agent 的限额已拆由 NAS 上的容器上报器负责，这里只管用量。
     *
     * 采集器自己带单飞门闩，这里的标志只管按钮状态。即时上报仍是一次：
     * 信封只有一个，`requestImmediateReport` 也只按模块开关走一遍。
     */
    func refreshVibeCodingUsageNow() async {
        guard settings.vibeCodingModuleEnabled, !isRefreshingVibeCodingUsage else { return }
        isRefreshingVibeCodingUsage = true
        defer { isRefreshingVibeCodingUsage = false }
        guard await vibeCodingUsageCollector.refreshNow(
            ccusageCLIPath: settings.ccusageCLIPath
        ) else { return }
        await vibeCodingYearCollector.refreshNow()
        _ = requestImmediateReport(.vibeCoding)
    }

    func refreshVibeCodingYearNow() async {
        guard settings.vibeCodingModuleEnabled, !isRefreshingVibeCodingYear else { return }
        isRefreshingVibeCodingYear = true
        defer { isRefreshingVibeCodingYear = false }
        guard await vibeCodingYearCollector.refreshNow() else { return }
        _ = requestImmediateReport(.vibeCodingYear)
    }

    func refreshVibeCodingSessionsNow() async {
        guard settings.vibeCodingModuleEnabled, !isRefreshingVibeCodingSessions else { return }
        isRefreshingVibeCodingSessions = true
        defer { isRefreshingVibeCodingSessions = false }
        await codingSessions.refreshNow(ccusageCLIPath: settings.ccusageCLIPath)
        _ = requestImmediateReport(.vibeCoding)
    }

    func canRequestImmediateReport(_ module: TelemetryModule) -> Bool {
        guard settings.postEnabled,
              let url = URL(string: settings.postURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil,
              moduleIsEnabled(module),
              moduleHasData(module),
              !pendingManualReports.contains(module) else { return false }
        return true
    }

    var currentDesktopReportingIsBlocked: Bool {
        settings.isDesktopReportingBlocked(
            bundleIdentifier: desktopActivity.snapshot?.bundleIdentifier
        )
    }

    func isManualReportInFlight(_ module: TelemetryModule) -> Bool {
        pendingManualReports.contains(module)
    }

    func manualReportMessage(for module: TelemetryModule) -> String? {
        if pendingManualReports.contains(module) { return "正在上报…" }
        if let error = lastManualReportError[module] { return "上报失败：\(error)" }
        if let date = lastManualReportAt[module] {
            return "已于 \(date.formatted(date: .omitted, time: .shortened)) 上报"
        }
        return nil
    }

    func manualReportFailed(_ module: TelemetryModule) -> Bool {
        lastManualReportError[module] != nil
    }

    /**
     * 首次授权，由用户在设置页点出来 —— 只有这条路径会弹系统对话框。
     *
     * 授权成功就立刻读取 MusicKit 当前缓存并叫醒上报循环。网络请求仍只有主循环
     * 那一条路径，按钮不会另开端点或绕过统一的变化判断。
     */
    func authorizeAppleMusic() async {
        guard !isUploadingAppleMusicCredentials else { return }
        isUploadingAppleMusicCredentials = true
        appleMusicCredentialsUploadError = nil
        defer { isUploadingAppleMusicCredentials = false }

        guard await appleMusicAuthorization.requestAuthorization() else {
            appleMusicCredentialsUploadError = appleMusicAuthorization.lastError
            return
        }
        await refreshAppleMusicCredentialsIfNeeded(force: true)
        guard appleMusicCredentials != nil else {
            appleMusicCredentialsUploadError = appleMusicAuthorization.lastError
            return
        }
        guard settings.postEnabled else {
            appleMusicCredentialsUploadError = "Apple Music 已授权；开启远端上报后会自动发送 token。"
            return
        }
        wakeReporter()
    }

    /**
     * 在主上报循环里定期读取 MusicKit 的缓存值。
     *
     * 不使用 ignoreCache：缓存不变就不会产生任何网络请求；SDK 轮换 developer token
     * 或 user token 后，下面的主循环会分别发现变化，只上报对应字段。
     */
    private func refreshAppleMusicCredentialsIfNeeded(force: Bool = false) async {
        guard !isRefreshingAppleMusicCredentials else { return }
        // 后台绝不请求授权，没批准就什么都不做 —— 从循环里弹系统弹窗是不能接受的
        guard MusicAuthorization.currentStatus == .authorized else { return }
        guard force || Date() >= nextAppleMusicCredentialsRefreshAt else { return }
        isRefreshingAppleMusicCredentials = true
        defer { isRefreshingAppleMusicCredentials = false }
        guard let credentials = await appleMusicAuthorization.mintCredentials() else {
            appleMusicCredentialsUploadError = appleMusicAuthorization.lastError
            nextAppleMusicCredentialsRefreshAt = Date().addingTimeInterval(Self.appleMusicRetryDelay)
            return
        }
        appleMusicCredentials = credentials
        appleMusicCredentialsUploadError = nil
        nextAppleMusicCredentialsRefreshAt = Date().addingTimeInterval(
            Self.appleMusicCredentialsRefreshInterval
        )
    }

    private func moduleIsEnabled(_ module: TelemetryModule) -> Bool {
        switch module {
        case .desktop: settings.desktopModuleEnabled
        case .appleMusic: settings.appleMusicModuleEnabled
        case .charger: settings.chargerModuleEnabled
        case .powerBank: settings.powerBankModuleEnabled
        case .timezone: settings.timezoneModuleEnabled
        case .vibeCoding, .vibeCodingYear: settings.vibeCodingModuleEnabled
        }
    }

    private func moduleHasData(_ module: TelemetryModule) -> Bool {
        switch module {
        case .desktop:
            desktopActivity.snapshot.map {
                !settings.isDesktopReportingBlocked(bundleIdentifier: $0.bundleIdentifier)
            } ?? false
        case .appleMusic: appleMusic.snapshot != nil
        case .charger: chargerLink.hasTelemetry
        case .powerBank: powerBankLink.hasTelemetry
        case .timezone: timeZone.snapshot != nil
        // 两个模块任一有值就能发：用量还没采到时，「此刻在不在用」也值得单独发
        case .vibeCoding:
            vibeCodingUsageCollector.uploadPayload != nil
                || codingSessions.uploadPayload != nil
        case .vibeCodingYear:
            vibeCodingYearCollector.uploadPayload != nil
        }
    }

    /// 所有已启用、且真的收到过遥测的充电设备。一台都没有就返回 nil，
    /// 上报信封里那个键整个不出现。
    var chargingDevicesPayload: ChargingDevicesPayload? {
        let devices = chargingLinks.compactMap { link -> ChargingDevicePayload? in
            guard link.slot.isEnabled(settings) else { return nil }
            return devicePayload(for: link)
        }
        return devices.isEmpty ? nil : ChargingDevicesPayload(devices: devices)
    }

    private func devicePayload(for link: BluetoothService) -> ChargingDevicePayload? {
        guard var device = link.devicePayload else { return nil }
        if link.slot == .charger {
            let source = covers.coverUploadSource
            let key = coverIconObjectKeyIfReady(source)
            device = device.withCover(covers.coverPayload(objectKey: key))
        }
        return device
    }

    private func streamEvent(for link: BluetoothService) -> ChargingStreamEvent {
        ChargingStreamEvent(
            phase: link.phase.label,
            connected: link.isConnected,
            lastError: link.lastError,
            device: devicePayload(for: link)
        )
    }

    private func publishChargingStream(_ link: BluetoothService) {
        chargingSSE.publish(streamEvent(for: link), slot: link.slot)
    }

    /**
     * 一条充电链路要不要拆掉重连，只看它自己的会话身份。
     *
     * 开关、配对 UUID、账号 ID 变了才动这一条。保存别的设置（黑名单、上报地址、
     * HTTP 端口）不应该把已经连上的充电头和充电宝一起踢掉 —— 那是充电头监测
     * App 留下的「保存并重连」。
     */
    private struct ChargingLinkSession: Equatable {
        var enabled: Bool
        var peripheralID: String
        var userID: String
    }

    private var lastAppliedChargingSession: [ChargingDeviceSlot: ChargingLinkSession] = [:]

    private func chargingSession(for slot: ChargingDeviceSlot) -> ChargingLinkSession {
        ChargingLinkSession(
            enabled: slot.isEnabled(settings),
            peripheralID: slot.peripheralIDString(settings),
            userID: settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /**
     * 挂上或摘掉一条充电设备链路。
     *
     * 只有结构性变化才叫醒循环：采集是 1 Hz 推流，每帧都叫醒的话循环会从 5 秒
     * 一转变成 1 秒一转，而其中绝大多数帧只是功率在滚动，本来就该等节流窗口。
     * 指纹比对是纯本地的，1 Hz 跑它远比白转一圈循环便宜。
     */
    private func configure(link: BluetoothService) {
        let session = chargingSession(for: link.slot)
        let previous = lastAppliedChargingSession[link.slot]
        lastAppliedChargingSession[link.slot] = session

        guard session.enabled else {
            link.onStateChange = nil
            link.disconnect()
            publishChargingStream(link)
            return
        }
        link.onStateChange = { [weak self] in
            guard let self else { return }
            publishChargingStream(link)
            if link.slot == .charger {
                covers.chargerStateDidChange()
            }
            guard let payload = chargingDevicesPayload else { return }
            let signature = ChargingDevicesStructuralSignature(payload)
            guard signature != lastPostedChargingStructural else { return }
            wakeReporter()
        }
        if previous == session {
            link.refreshIdleSleepPolicy()
            return
        }
        if previous == nil || previous?.enabled == false {
            link.start()
            return
        }
        link.reconnect()
    }

    private func wakeReporter() {
        if let continuation = wakeContinuation {
            wakeContinuation = nil
            continuation.resume()
        } else {
            pendingWake = true
        }
    }

    /// 等到下一个周期，或者被事件提前叫醒 —— 谁先来算谁
    /**
     * 等到下一个周期，或者被事件提前叫醒 —— 谁先来算谁。
     *
     * `cycleStart` 是本轮开始的时刻，睡眠时间从它算起扣掉本轮已经花掉的时间。
     * 原来是「干完活再睡满 5 秒」，于是实际周期变成 5 秒加上本轮耗时 —— 一次
     * 上报要一两秒，追发就从 5 秒一次变成 7 秒一次。要求是 5 秒，那就得按周期
     * 算而不是按间隔算。
     *
     * 本轮耗时超过一个周期时不补睡，直接进入下一轮：追进度没有意义，只会让
     * 循环一直欠着时间往前赶。
     */
    private func waitForNextTick(since cycleStart: ContinuousClock.Instant) async {
        if pendingWake {
            pendingWake = false
            return
        }
        let elapsed = ContinuousClock.now - cycleStart
        let remaining = Self.tickInterval - elapsed
        guard remaining > .zero else { return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            // 被 cancel 说明已经有事件把循环叫醒了，别再多放行一次
            guard !Task.isCancelled else { return }
            self?.wakeReporter()
        }
        await withCheckedContinuation { continuation in
            wakeContinuation = continuation
        }
        timer.cancel()
    }

    private func configureModules() {
        for link in chargingLinks {
            configure(link: link)
        }
        covers.onChange = { [weak self] in self?.wakeReporter() }

        if settings.desktopModuleEnabled {
            desktopActivity.setWindowTitleApplicationWhitelist(
                settings.normalizedWindowTitleApplicationWhitelist
            )
            // 每次激活都重排，连续 Cmd-Tab 只在最后停下的那个应用上叫醒一次。
            // 开着远端上报时，图标在这 400ms 里先走后台 resolver；名称上报不等它。
            desktopActivity.onChange = { [weak self] in
                guard let self else { return }
                desktopSettleTask?.cancel()
                if settings.postEnabled,
                   let snapshot = desktopActivity.snapshot,
                   !settings.isDesktopReportingBlocked(bundleIdentifier: snapshot.bundleIdentifier) {
                    startDesktopIconResolution(snapshot)
                }
                desktopSettleTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.desktopSettleDelay)
                    guard !Task.isCancelled else { return }
                    self?.wakeReporter()
                }
            }
            desktopActivity.start()
        } else {
            desktopActivity.onChange = nil
            desktopSettleTask?.cancel()
            desktopSettleTask = nil
            desktopActivity.stop()
            desktopActivity.setWindowTitleApplicationWhitelist(
                settings.normalizedWindowTitleApplicationWhitelist
            )
        }

        if settings.timezoneModuleEnabled {
            timeZone.onChange = { [weak self] in self?.wakeReporter() }
            timeZone.start()
        } else {
            timeZone.onChange = nil
            timeZone.stop()
        }

        if settings.appleMusicModuleEnabled {
            // 音乐不用防抖：playerInfo 的竞态已经由 monitor 内部那次确认读消掉了
            appleMusic.onChange = { [weak self] in self?.wakeReporter() }
            appleMusic.start()
        } else {
            appleMusic.onChange = nil
            appleMusic.stop()
        }
        if settings.vibeCodingModuleEnabled {
            codingSessions.onChange = { [weak self] in self?.wakeReporter() }
            vibeCodingUsageCollector.onChange = { [weak self] in self?.wakeReporter() }
            vibeCodingYearCollector.onChange = { [weak self] in self?.wakeReporter() }
            startVibeCodingCollection()
        } else {
            codingSessions.onChange = nil
            vibeCodingUsageCollector.onChange = nil
            vibeCodingYearCollector.onChange = nil
            vibeCodingCollectionTask?.cancel()
            vibeCodingSessionsTask?.cancel()
            vibeCodingCollectionTask = nil
            vibeCodingSessionsTask = nil
            vibeCodingUsageCollector.stop()
            codingSessions.stop()
            vibeCodingYearCollector.stop()
        }
    }

    /**
     * 全历史采集与会话采集独立运行，云端分页不会阻塞会话或设备遥测。
     *
     * 现在采集完由各自的 onChange 叫醒循环，跟前台应用、音乐同一条路：循环只读
     * 它们留下的载荷，唯一还会阻塞的就是那次 POST 本身。
     *
     * 这里按 tickInterval 转只是「问一句该不该采」，真正的节流是采集器自己的
     * 间隔门闩；单飞门闩也在采集器里，所以问得勤一点是安全的。
     */
    private func startVibeCodingCollection() {
        vibeCodingCollectionTask?.cancel()
        vibeCodingSessionsTask?.cancel()
        vibeCodingUsageCollector.invalidateSchedule()
        codingSessions.invalidateSchedule()
        vibeCodingYearCollector.invalidateSchedule()
        vibeCodingCollectionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, settings.vibeCodingModuleEnabled else { return }
                // 先刷新持久账本，再从同一份数据生成年度图。
                await self.vibeCodingUsageCollector.refreshIfNeeded(
                    ccusageCLIPath: settings.ccusageCLIPath,
                    interval: settings.vibeCodingUsageRefreshInterval
                )
                await self.vibeCodingYearCollector.refreshIfNeeded(
                    interval: settings.vibeCodingYearRefreshInterval
                )
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
        vibeCodingSessionsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, settings.vibeCodingModuleEnabled else { return }
                await self.codingSessions.refreshIfNeeded(
                    ccusageCLIPath: settings.ccusageCLIPath,
                    interval: settings.codingSessionRefreshInterval
                )
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    private func restartReporter() {
        reporterTask?.cancel()
        // 旧循环可能还挂在等待上，先放行让它认领 cancel 并退出
        wakeReporter()
        reporterTask = nil
        // 上一轮遗留的唤醒标记不能带进新循环，否则第一圈会白转一次
        pendingWake = false
        reporterLastError = nil
        lastPostedVibeCodingUsageAt = nil
        lastPostedVibeCodingNowAt = nil
        lastPostedVibeCodingYearAt = nil
        lastPostedChargingDevices = nil
        lastPostedChargingStructural = nil
        lastPostedDesktop = nil
        lastPostedDesktopWasHidden = false
        uploadedDesktopIconHashes.removeAll(keepingCapacity: true)
        uploadedDesktopIconOrder.removeAll(keepingCapacity: true)
        iconUploadAttempts.removeAll(keepingCapacity: true)
        desktopIconVerifiedAt.removeAll(keepingCapacity: true)
        cancelDesktopIconResolvers()
        lastPostedTimeZone = nil
        lastPostedAppleMusic = nil
        lastPostedMusicAnchor = nil
        // 每个上报会话都完整发一次，之后两个 token 才分别判变。
        lastPostedAppleMusicDeveloperToken = nil
        lastPostedAppleMusicUserToken = nil
        lastHeartbeatAt = nil
        pendingManualReports.removeAll()
        lastManualReportError.removeAll()
        let url = settings.postEnabled ? URL(string: settings.postURL) : nil
        let interval = settings.postInterval
        let timeout = settings.postTimeout
        reporterTask = Task { [weak self] in
            guard let self else { return }
            var nextPostAt = Date.distantPast
            /// 上报失败后的退避截止时刻，只用来挡住即时上报的绕行
            var backoffUntil = Date.distantPast
            /// 充电设备追发还剩几次、下一次什么时候到点
            var chargingBurstRemaining = 0
            var chargingBurstAt = Date.distantPast
            while !Task.isCancelled {
                let cycleStart = ContinuousClock.now
                var manualModulesForAttempt: Set<TelemetryModule> = []
                var attemptedAppleMusicCredentials = false
                do {
                    if settings.timezoneModuleEnabled { timeZone.refresh() }
                    // 前台应用和 Apple Music 都不在这里采集：前者完全由 NSWorkspace
                    // 的激活通知驱动，后者由 Music.app 的 playerInfo 跨进程通知驱动、
                    // 另带一个兜底重读补上不发通知的 seek。循环只管读它们留下的
                    // snapshot —— 变化时它们会把循环叫醒，没事件时按 tickInterval 转。
                    // vibe coding 那三条 CLI 不在这里采：它们在 startVibeCodingCollection
                    // 里自己转，采完叫醒这条循环。最慢那条要 25 秒，等它跑完的话这
                    // 25 秒内切换的应用会被合并掉。

                    // token 检测属于这条主循环，但用五分钟闸门避免每圈都问 MusicKit。
                    await refreshAppleMusicCredentialsIfNeeded()

                    // 变化判断全是本地计算，每圈都做；nextPostAt 只管「什么时候允许发」。
                    // 两台设备一起算：任意一台插拔都该立刻发，功率滚动都该等窗口。
                    let charger = chargingDevicesPayload
                    let chargerSignature = charger
                    let chargerStructural = charger.map(ChargingDevicesStructuralSignature.init)
                    let capturedDesktop = settings.desktopModuleEnabled ? desktopActivity.snapshot : nil
                    let desktopBlocked = capturedDesktop.map {
                        settings.isDesktopReportingBlocked(bundleIdentifier: $0.bundleIdentifier)
                    } ?? false
                    // 黑名单只切断远端载荷；monitor 的本机快照继续保留给界面和本地 API。
                    let desktop = desktopBlocked ? nil : capturedDesktop
                    let desktopSignature = desktop.map(DesktopUploadSignature.init)
                    let timezone = settings.timezoneModuleEnabled ? timeZone.snapshot : nil
                    let timezoneSignature = timezone.map(TimeZoneUploadSignature.init)
                    let music = settings.appleMusicModuleEnabled ? appleMusic.snapshot : nil
                    let musicSignature = music.map(AppleMusicUploadSignature.init)
                    let credentials = appleMusicCredentials
                    let developerTokenChanged = credentials.map {
                        $0.developerToken != lastPostedAppleMusicDeveloperToken
                    } ?? false
                    let musicUserTokenChanged = credentials.map {
                        $0.musicUserToken != lastPostedAppleMusicUserToken
                    } ?? false
                    let chargerChanged = chargerSignature != nil && chargerSignature != lastPostedChargingDevices
                    let desktopChanged = capturedDesktop != nil && (
                        desktopBlocked
                            ? !lastPostedDesktopWasHidden
                            : desktopSignature != nil && (
                                lastPostedDesktopWasHidden || desktopSignature != lastPostedDesktop
                            )
                    )
                    let timezoneChanged = timezoneSignature != nil && timezoneSignature != lastPostedTimeZone
                    // 进度不参与变化判断，只在它偏离网页的预测值时才重新对锚点，
                    // 否则播放中每一轮都会「有变化」，按需上报就退化成了定时轮询。
                    // 单曲循环时 trackID 不变，靠进度跳回开头被这里认出来。
                    let musicSeeked = music.map {
                        guard let anchor = lastPostedMusicAnchor else { return true }
                        let drift = $0.positionMs - anchor.predicted(at: $0.observedAt)
                        return abs(drift) > Self.musicSeekToleranceMs
                    } ?? false
                    // snapshot 从有值变成 nil 时也要发送一次 null，避免网页保留旧歌曲。
                    let musicChanged = settings.appleMusicModuleEnabled &&
                        (musicSignature != lastPostedAppleMusic || musicSeeked)
                    /// 两个模块各判各的变化。门闩看的是载荷**变化**的时刻而不是采集
                    /// 成功的时刻 —— 会话状态 60 秒扫一次，绝大多数轮次什么都没变，拿
                    /// lastSuccess 当门闩会把每一轮扫描都变成一次上报。
                    let vibeCodingEnabled = settings.vibeCodingModuleEnabled
                    func vibeCodingChanged(_ updatedAt: Date?, _ lastPosted: Date?) -> Bool {
                        guard vibeCodingEnabled, let updatedAt else { return false }
                        return lastPosted.map { updatedAt > $0 } ?? true
                    }
                    let usageChanged = vibeCodingChanged(
                        vibeCodingUsageCollector.payloadUpdatedAt, lastPostedVibeCodingUsageAt
                    )
                    let nowChanged = vibeCodingChanged(
                        codingSessions.payloadUpdatedAt, lastPostedVibeCodingNowAt
                    )
                    let yearChanged = vibeCodingChanged(
                        vibeCodingYearCollector.payloadUpdatedAt, lastPostedVibeCodingYearAt
                    )
                    let manualModules = pendingManualReports
                    manualModulesForAttempt = manualModules
                    let manualMode = !manualModules.isEmpty
                    // A manual request is intentionally module-scoped. Automatic changes are
                    // left pending for the next regular reporter pass instead of hitching a
                    // ride on the user's selected module.
                    let chargerToSend = manualMode
                        ? manualModules.contains(.charger) && charger != nil
                        : chargerChanged
                    let desktopToSend = manualMode
                        ? manualModules.contains(.desktop) && desktop != nil
                        : desktopChanged
                    let timezoneToSend = manualMode
                        ? manualModules.contains(.timezone) && timezone != nil
                        : timezoneChanged
                    let musicToSend = manualMode
                        ? manualModules.contains(.appleMusic) && music != nil
                        : musicChanged
                    // 手动上报按整个 vibe coding 走：信封只有一个，用量和此刻
                    // 手上有什么就一起发什么。年度热力图间隔不同，单独一门。
                    let manualVibeCoding = manualModules.contains(.vibeCoding)
                    let usageToSend = manualMode
                        ? manualVibeCoding && vibeCodingUsageCollector.uploadPayload != nil
                        : usageChanged
                    let nowToSend = manualMode
                        ? manualVibeCoding && codingSessions.uploadPayload != nil
                        : nowChanged
                    let yearToSend = manualMode
                        ? manualModules.contains(.vibeCodingYear)
                            && vibeCodingYearCollector.uploadPayload != nil
                        : yearChanged
                    let credentialsToSend: AppleMusicCredentialsPayload?
                    // 手动上报只发用户选中的模块；token 的自动变化留到下一轮。
                    if !manualMode,
                       let credentials,
                       developerTokenChanged || musicUserTokenChanged {
                        credentialsToSend = AppleMusicCredentialsPayload(
                            musicUserToken: musicUserTokenChanged ? credentials.musicUserToken : nil,
                            developerToken: developerTokenChanged ? credentials.developerToken : nil,
                            expiresAt: developerTokenChanged
                                ? Int(credentials.expiresAt.timeIntervalSince1970)
                                : nil
                        )
                    } else {
                        credentialsToSend = nil
                    }
                    let heartbeatDue = lastHeartbeatAt
                        .map { Date().timeIntervalSince($0) >= Self.heartbeatInterval } ?? true
                    let dataChanged = chargerToSend || desktopToSend || timezoneToSend ||
                        musicToSend || usageToSend || nowToSend || yearToSend ||
                        credentialsToSend != nil
                    /**
                     * 只在没有数据要发的时候才补心跳 —— 有数据时那个包本身就证明
                     * 活着，再补一条是白发。
                     *
                     * 心跳和数据走同一个端点、同一个 v4 信封，区别只在 modules 空不空。
                     * 于是「这台 Mac 还活着」在接收端只有一个写入点。
                     */
                    // sendHeartbeat 自己也会拦住睡眠期间的在线心跳；这里再判一次
                    // 只是别让门闩白推进 —— 否则醒来后还得再等满一个间隔。
                    if heartbeatDue, !dataChanged, !suspended {
                        sendHeartbeat("online")
                        lastHeartbeatAt = Date()
                    }
                    let anythingChanged = dataChanged

                    // 播放/暂停、换歌、换前台应用是用户正盯着的事，不值得为它们等满节流窗口。
                    // 这些变化本来也会上报，即时化只是把等待砍掉，不增加请求总数；
                    // 同一个 envelope 会把此刻待发的充电器 / 用量一起捎走。
                    // 进度跳变也算紧急。单曲循环时曲目和状态都没变，只有进度
                    // 从结尾跳回开头 —— 不放行的话网页会把进度条钉在 100%，
                    // 一直等到下一个节流窗口（实测 postInterval=30 时要等 30 秒）。
                    // 拖动进度条同理。这不会变吵：seek 只在通知或兜底重读时才
                    // 被发现，而通知只在换歌/播放状态变化时来。
                    let musicUrgent = !manualMode && musicChanged && (
                        musicSeeked ||
                        music?.state != lastPostedAppleMusic?.state ||
                        music?.trackID != lastPostedAppleMusic?.trackID ||
                        musicSignature?.queueIndex != lastPostedAppleMusic?.queueIndex ||
                        musicSignature?.queueTrackIDs != lastPostedAppleMusic?.queueTrackIDs
                    )
                    // 只认应用身份：图标变了（同一个 App 换了图标）也算 desktopChanged，
                    // 但不值得为它绕过节流窗口。
                    // Cmd-Tab 路过的中间应用一般不会把循环叫醒 —— 激活通知那侧压了
                    // 400ms 的 desktopSettleDelay，只有最后停下的那个才放行。
                    // 但那只防住「叫醒」这条路：tick 恰好落在切换途中时照样会采到中间
                    // 那个应用。真要根治得在这里再比一次，眼下不值当。
                    let desktopUrgent = !manualMode && desktopChanged && (
                        desktopBlocked ||
                        lastPostedDesktopWasHidden ||
                        desktop?.bundleIdentifier != lastPostedDesktop?.bundleIdentifier ||
                        desktop?.applicationName != lastPostedDesktop?.applicationName
                    )
                    let timezoneUrgent = !manualMode && timezoneChanged
                    // 插拔和换设备也是用户正盯着的事，跟播放/前台应用同一档。
                    // 只认结构性指纹：功率、电压、电流的滚动照旧等节流窗口，
                    // 否则充电中每一轮都「有变化」，即时上报就退化成 5 秒一次的轮询。
                    let chargerStructuralChanged =
                        chargerStructural != nil && chargerStructural != lastPostedChargingStructural
                    /**
                     * 追发的排期。
                     *
                     * 结构一变就把计数重置满 —— 拔了又插算两次独立的接入，第二次
                     * 同样需要完整的观察窗口，不该沿用上一次剩下的额度。
                     *
                     * 到点就扣，不管这一圈最后有没有真发出去（比如退避期内）。
                     * 否则服务端一直失败时，这个计数会一直挂着，等退避结束后突然
                     * 补发一串早就过时的追发。
                     */
                    if chargerStructuralChanged {
                        chargingBurstRemaining = Self.chargingBurstCount
                        chargingBurstAt = Date().addingTimeInterval(Self.chargingBurstInterval)
                    }
                    let chargingBurstDue = chargingBurstRemaining > 0 && Date() >= chargingBurstAt
                    if chargingBurstDue {
                        chargingBurstRemaining -= 1
                        chargingBurstAt = Date().addingTimeInterval(Self.chargingBurstInterval)
                    }
                    let chargerUrgent = !manualMode && (chargerStructuralChanged || chargingBurstDue)
                    // 退避期内一律不放行。否则服务端挂掉时，未推进的 lastPosted 会让
                    // urgent 一直为真，即时上报就变成每圈一次的重试风暴。
                    let urgent = (manualMode || musicUrgent || desktopUrgent || timezoneUrgent ||
                        chargerUrgent || credentialsToSend != nil) && Date() >= backoffUntil
                    // 宣告过离线就不再发数据包。跳过不丢东西：lastPosted 门闩没推进，
                    // 醒来那一下这些变化仍然是 urgent，会立刻补发。
                    let shouldPost = !suspended && Date() >= backoffUntil &&
                        (manualMode || urgent || Date() >= nextPostAt)

                    if let url, anythingChanged, shouldPost {
                        let desktopPayload: DesktopActivitySnapshot?
                        if desktopBlocked, let capturedDesktop {
                            desktopPayload = .hidden(observedAt: capturedDesktop.observedAt)
                        } else if let desktop {
                            // 名称不等图标：对象已经确认好就顺手带上，否则先发无图状态，
                            // 后台 resolver 成功后再叫醒一轮补对象键。
                            let iconObjectKey = desktopIconObjectKeyIfReady(desktop)
                            desktopPayload = desktop.withIconData(nil, iconObjectKey: iconObjectKey)
                        } else {
                            desktopPayload = nil
                        }
                        // 封面不再由这边送：网页那边为了拿曲目链接本来就要查一次
                        // Apple Music 目录，那次查询的结果自带封面 URL。
                        let musicPayload = music
                        // 用量与会话累计来自同一持久账本。
                        let vibeCodingUsagePayload = vibeCodingUsageCollector.uploadPayload
                        // POST 等待期间可以继续采集；成功只确认这封信实际携带的版本。
                        let sentUsageAt = vibeCodingUsageCollector.payloadUpdatedAt
                        let sentNowAt = codingSessions.payloadUpdatedAt
                        let sentYearAt = vibeCodingYearCollector.payloadUpdatedAt
                        let envelope = makeTelemetryEnvelope(
                            chargingDevices: chargerToSend ? charger : nil,
                            desktop: desktopToSend ? desktopPayload : nil,
                            timezone: timezoneToSend ? timezone : nil,
                            appleMusic: musicToSend ? musicPayload : nil,
                            appleMusicCredentials: credentialsToSend,
                            vibeCodingUsage: usageToSend ? vibeCodingUsagePayload : nil,
                            vibeCodingNow: nowToSend ? codingSessions.uploadPayload : nil,
                            vibeCodingYear: yearToSend ? vibeCodingYearCollector.uploadPayload : nil,
                            includeDesktop: desktopToSend,
                            includeAppleMusic: musicToSend
                        )
                        var request = URLRequest(url: url)
                        request.httpMethod = "POST"
                        request.httpBody = try JSONCoding.encoder().encode(envelope)
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.setValue("mac-telemetry-hub/4", forHTTPHeaderField: "User-Agent")
                        if !settings.telemetrySecret.isEmpty {
                            request.setValue("Bearer \(settings.telemetrySecret)", forHTTPHeaderField: "Authorization")
                        }
                        request.timeoutInterval = timeout
                        attemptedAppleMusicCredentials = credentialsToSend != nil
                        let (responseData, response) = try await IsolatedHTTPClient.data(for: request)
                        try Task.checkCancellation()
                        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                            throw ReporterError.httpStatus(
                                response.statusCode,
                                detail: Self.ingestErrorDetail(responseData)
                            )
                        }
                        let responsePayload = try JSONDecoder()
                            .decode(TelemetryIngestResponse.self, from: responseData)
                        let desktopIconAvailable = responsePayload.data.desktopIconAvailable
                        let chargerCoverIconAvailable = responsePayload.data.chargerCoverIconAvailable
                        if desktopToSend, desktopIconAvailable == nil {
                            throw ReporterError.invalidTelemetryResponse
                        }
                        reporterLastSuccess = Date()
                        reporterLastError = nil
                        lastHeartbeatAt = Date()
                        if chargerToSend {
                            lastPostedChargingDevices = chargerSignature
                            if chargerCoverIconAvailable == false,
                               let source = covers.coverUploadSource,
                               let iconHash = source.iconHash {
                                if charger?.devices.first(where: { $0.kind == .charger })?.cover?.iconObjectKey != nil {
                                    forgetUploadedDesktopIcon(iconHash)
                                }
                                startCoverIconResolution(source)
                                if uploadedDesktopIconHashes.contains(iconHash) {
                                    lastPostedChargingDevices = nil
                                    wakeReporter()
                                }
                            }
                        }
                        // 结构指纹跟着每次成功发送推进，跟 chargerChanged 无关：
                        // 结构变了完整指纹必然也变，反过来不成立。
                        if let chargerStructural { lastPostedChargingStructural = chargerStructural }
                        if desktopToSend {
                            if desktopBlocked {
                                // 进入黑名单应用时只发一次虚拟应用；真实身份和图标都不进载荷。
                                lastPostedDesktop = nil
                                lastPostedDesktopWasHidden = true
                            } else if desktopIconAvailable == false,
                               let desktop,
                               let iconHash = desktop.iconHash {
                                // false 只说明这次信封没有可用对象键。先把名称门闩推进，
                                // 不在这里自唤醒；否则 R2 未配置 / PNG 编码失败会打成热循环。
                                lastPostedDesktop = desktopSignature
                                if desktopPayload?.iconObjectKey != nil {
                                    // 兼容服务端今后恢复对象校验：带了键仍返回 false，说明
                                    // 这份本地“已上传”记忆失效，后台重新 HEAD/PUT。
                                    forgetUploadedDesktopIcon(iconHash)
                                }
                                startDesktopIconResolution(desktop)
                                // resolver 可能在 POST 飞行期间已经完成；补上那次竞态唤醒。
                                if uploadedDesktopIconHashes.contains(iconHash) {
                                    lastPostedDesktop = nil
                                    wakeReporter()
                                }
                                lastPostedDesktopWasHidden = false
                            } else {
                                lastPostedDesktop = desktopSignature
                                lastPostedDesktopWasHidden = false
                                // 服务端可能只是命中了自己的旧 iconHash 映射；只有这次
                                // 信封真的带了对象键，才把本地状态记成已确认。
                                if let desktop, desktopPayload?.iconObjectKey != nil {
                                    rememberUploadedDesktopIcon(desktop)
                                }
                            }
                        }
                        if timezoneToSend { lastPostedTimeZone = timezoneSignature }
                        if musicToSend {
                            lastPostedAppleMusic = musicSignature
                            lastPostedMusicAnchor = music.map(AppleMusicPositionAnchor.init)
                        }
                        if let credentialsToSend {
                            if credentialsToSend.developerToken != nil {
                                lastPostedAppleMusicDeveloperToken = credentials?.developerToken
                            }
                            if credentialsToSend.musicUserToken != nil {
                                lastPostedAppleMusicUserToken = credentials?.musicUserToken
                            }
                            appleMusicCredentialsUploadAt = Date()
                            appleMusicCredentialsUploadError = nil
                        }
                        if usageToSend {
                            lastPostedVibeCodingUsageAt = sentUsageAt
                        }
                        if nowToSend { lastPostedVibeCodingNowAt = sentNowAt }
                        if yearToSend {
                            lastPostedVibeCodingYearAt = sentYearAt
                        }
                        if !manualModulesForAttempt.isEmpty {
                            pendingManualReports.subtract(manualModulesForAttempt)
                            let now = Date()
                            for module in manualModulesForAttempt {
                                lastManualReportAt[module] = now
                                lastManualReportError[module] = nil
                            }
                        }
                        backoffUntil = .distantPast
                        // 即时上报同样重置整个窗口，免得「刚提前发过一次、转头又到点发一次」
                        nextPostAt = Date().addingTimeInterval(interval)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    reporterLastError = error.localizedDescription
                    if attemptedAppleMusicCredentials {
                        appleMusicCredentialsUploadError = error.localizedDescription
                    }
                    if !manualModulesForAttempt.isEmpty {
                        pendingManualReports.subtract(manualModulesForAttempt)
                        for module in manualModulesForAttempt {
                            lastManualReportError[module] = error.localizedDescription
                        }
                    }
                    backoffUntil = Date().addingTimeInterval(min(interval, 10))
                    nextPostAt = backoffUntil
                }
                // 采集和发送解耦：前台应用和音乐由各自的通知驱动，变化时会把
                // 这里提前叫醒；没有事件时按 tickInterval 转一圈照顾充电器和心跳。
                // 远端 POST 仍按用户设置的 interval 节流。
                await waitForNextTick(since: cycleStart)
            }
        }
    }

    /**
     * 返回已经确认存在的对象键；没有准备好就启动后台 resolver 并立即返回 nil。
     *
     * 名称上报从此不 await R2。resolver 先 HEAD：对象还在就复用，被清掉就 PUT；
     * 同一枚图标五分钟内不重复检查。成功时若网页已经收过无图版本，再叫醒一轮
     * 补对象键。失败最多试三次，但绝不靠反复 POST 遥测来驱动重试。
     */
    private func desktopIconObjectKeyIfReady(_ desktop: DesktopActivitySnapshot) -> String? {
        guard let iconHash = desktop.iconHash, let iconData = desktop.iconData else { return nil }
        startDesktopIconResolution(desktop)
        return uploadedDesktopIconHashes.contains(iconHash)
            ? R2IconUploader.objectKey(for: iconData)
            : nil
    }

    private func startDesktopIconResolution(_ desktop: DesktopActivitySnapshot) {
        guard settings.postEnabled,
              let iconHash = desktop.iconHash,
              let iconData = desktop.iconData,
              let r2Configuration = R2IconUploader.configuration(settings: settings),
              iconUploadAttempts[iconHash, default: 0] < Self.maxIconUploadAttempts,
              iconResolvers[iconHash] == nil else {
            return
        }

        if uploadedDesktopIconHashes.contains(iconHash),
           let verifiedAt = desktopIconVerifiedAt[iconHash],
           Date().timeIntervalSince(verifiedAt) < Self.desktopIconVerificationInterval {
            return
        }

        let signature = DesktopUploadSignature(desktop)
        let objectKey = R2IconUploader.objectKey(for: iconData)
        let timeout = min(settings.postTimeout, 3)
        let resolverID = UUID()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled,
                  self.iconUploadAttempts[iconHash, default: 0] < Self.maxIconUploadAttempts {
                do {
                    let exists = try await R2IconUploader.exists(
                        objectKey: objectKey,
                        configuration: r2Configuration,
                        timeout: timeout
                    )
                    if !exists {
                        self.forgetUploadedDesktopIcon(iconHash)
                        try await R2IconUploader.upload(
                            data: iconData,
                            contentHash: R2IconUploader.contentHash(of: iconData),
                            objectKey: objectKey,
                            configuration: r2Configuration,
                            timeout: timeout
                        )
                    }
                    guard !Task.isCancelled else { break }
                    self.iconUploadAttempts[iconHash] = 0
                    self.desktopIconVerifiedAt[iconHash] = Date()
                    self.rememberUploadedDesktopIcon(desktop)

                    // resolver 早于首包完成时，400ms 防抖会自然把键带上，不额外叫醒。
                    // 只有无图版本已经成功发过，才需要补发同一应用的对象键。
                    if self.lastPostedDesktop == signature,
                       self.desktopActivity.snapshot.map(DesktopUploadSignature.init) == signature {
                        self.lastPostedDesktop = nil
                        self.wakeReporter()
                    }
                    break
                } catch is CancellationError {
                    break
                } catch {
                    if Task.isCancelled { break }
                    self.iconUploadAttempts[iconHash, default: 0] += 1
                    self.reporterLastError = "图标上传失败：\(error.localizedDescription)"
                }
            }

            if self.iconResolvers[iconHash]?.id == resolverID {
                self.iconResolvers.removeValue(forKey: iconHash)
            }
        }
        iconResolvers[iconHash] = (resolverID, task)
    }

    private func cancelDesktopIconResolvers() {
        for resolver in iconResolvers.values { resolver.task.cancel() }
        iconResolvers.removeAll(keepingCapacity: true)
    }

    private func rememberUploadedDesktopIcon(_ snapshot: DesktopActivitySnapshot) {
        guard let iconHash = snapshot.iconHash else { return }
        uploadedDesktopIconHashes.insert(iconHash)
        uploadedDesktopIconOrder.removeAll { $0 == iconHash }
        uploadedDesktopIconOrder.append(iconHash)
        if uploadedDesktopIconOrder.count > Self.uploadedDesktopIconLimit {
            let evicted = uploadedDesktopIconOrder.removeFirst()
            uploadedDesktopIconHashes.remove(evicted)
            desktopIconVerifiedAt.removeValue(forKey: evicted)
        }
    }

    private func forgetUploadedDesktopIcon(_ iconHash: String) {
        uploadedDesktopIconHashes.remove(iconHash)
        uploadedDesktopIconOrder.removeAll { $0 == iconHash }
        desktopIconVerifiedAt.removeValue(forKey: iconHash)
    }

    private func coverIconObjectKeyIfReady(_ source: CoverUploadSource?) -> String? {
        guard let source, let iconHash = source.iconHash, let iconData = source.iconData else {
            return nil
        }
        startCoverIconResolution(source)
        return uploadedDesktopIconHashes.contains(iconHash)
            ? R2IconUploader.objectKey(for: iconData, ext: "jpg")
            : nil
    }

    private func startCoverIconResolution(_ source: CoverUploadSource) {
        guard settings.postEnabled,
              let iconHash = source.iconHash,
              let iconData = source.iconData,
              let r2Configuration = R2IconUploader.configuration(settings: settings),
              iconUploadAttempts[iconHash, default: 0] < Self.maxIconUploadAttempts,
              iconResolvers[iconHash] == nil else {
            return
        }

        if uploadedDesktopIconHashes.contains(iconHash),
           let verifiedAt = desktopIconVerifiedAt[iconHash],
           Date().timeIntervalSince(verifiedAt) < Self.desktopIconVerificationInterval {
            return
        }

        let objectKey = R2IconUploader.objectKey(for: iconData, ext: "jpg")
        let timeout = min(settings.postTimeout, 3)
        let resolverID = UUID()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  self.iconUploadAttempts[iconHash, default: 0] < Self.maxIconUploadAttempts {
                do {
                    let exists = try await R2IconUploader.exists(
                        objectKey: objectKey,
                        configuration: r2Configuration,
                        timeout: timeout
                    )
                    if !exists {
                        self.forgetUploadedDesktopIcon(iconHash)
                        try await R2IconUploader.upload(
                            data: iconData,
                            contentHash: R2IconUploader.contentHash(of: iconData),
                            objectKey: objectKey,
                            configuration: r2Configuration,
                            timeout: timeout
                        )
                    }
                    guard !Task.isCancelled else { break }
                    self.iconUploadAttempts[iconHash] = 0
                    self.desktopIconVerifiedAt[iconHash] = Date()
                    self.rememberUploadedCoverIcon(iconHash)
                    if self.lastPostedChargerCover(hash: iconHash, hasObjectKey: false) {
                        self.lastPostedChargingDevices = nil
                        self.wakeReporter()
                    }
                    break
                } catch is CancellationError {
                    break
                } catch {
                    if Task.isCancelled { break }
                    self.iconUploadAttempts[iconHash, default: 0] += 1
                    self.reporterLastError = "封面上传失败：\(error.localizedDescription)"
                }
            }
            if self.iconResolvers[iconHash]?.id == resolverID {
                self.iconResolvers.removeValue(forKey: iconHash)
            }
        }
        iconResolvers[iconHash] = (resolverID, task)
    }

    private func rememberUploadedCoverIcon(_ iconHash: String) {
        uploadedDesktopIconHashes.insert(iconHash)
        uploadedDesktopIconOrder.removeAll { $0 == iconHash }
        uploadedDesktopIconOrder.append(iconHash)
        if uploadedDesktopIconOrder.count > Self.uploadedDesktopIconLimit {
            let evicted = uploadedDesktopIconOrder.removeFirst()
            uploadedDesktopIconHashes.remove(evicted)
            desktopIconVerifiedAt.removeValue(forKey: evicted)
        }
    }

    private func lastPostedChargerCover(hash: String, hasObjectKey: Bool) -> Bool {
        guard let cover = lastPostedChargingDevices?.devices.first(where: { $0.kind == .charger })?.cover
        else { return false }
        return cover.iconHash == hash && (cover.iconObjectKey != nil) == hasObjectKey
    }

    var telemetryEnvelope: TelemetryEnvelope {
        let credentialsPayload = appleMusicCredentials.map {
            AppleMusicCredentialsPayload(
                musicUserToken: $0.musicUserToken,
                developerToken: $0.developerToken,
                expiresAt: Int($0.expiresAt.timeIntervalSince1970)
            )
        }
        return makeTelemetryEnvelope(
            chargingDevices: chargingDevicesPayload,
            desktop: settings.desktopModuleEnabled ? desktopActivity.snapshot : nil,
            timezone: settings.timezoneModuleEnabled ? timeZone.snapshot : nil,
            appleMusic: settings.appleMusicModuleEnabled ? appleMusic.snapshot : nil,
            appleMusicCredentials: credentialsPayload,
            vibeCodingUsage: settings.vibeCodingModuleEnabled
                ? vibeCodingUsageCollector.uploadPayload
                : nil,
            vibeCodingNow: settings.vibeCodingModuleEnabled ? codingSessions.uploadPayload : nil,
            vibeCodingYear: settings.vibeCodingModuleEnabled ? vibeCodingYearCollector.uploadPayload : nil,
            includeDesktop: settings.desktopModuleEnabled,
            includeAppleMusic: settings.appleMusicModuleEnabled
        )
    }

    private func makeTelemetryEnvelope(
        chargingDevices: ChargingDevicesPayload?,
        desktop: DesktopActivitySnapshot?,
        timezone: TimeZoneSnapshot?,
        appleMusic: AppleMusicSnapshot?,
        appleMusicCredentials: AppleMusicCredentialsPayload?,
        vibeCodingUsage: JSONValue?,
        vibeCodingNow: JSONValue?,
        vibeCodingYear: JSONValue? = nil,
        includeDesktop: Bool,
        includeAppleMusic: Bool,
        presence: String = "online"
    ) -> TelemetryEnvelope {
        return TelemetryEnvelope(
            heartbeatAt: Int64(Date().timeIntervalSince1970 * 1_000),
            activeModules: activeModuleNames,
            modules: TelemetryModulesPayload(
                chargingDevices: chargingDevices,
                desktop: desktop,
                appleMusic: appleMusic,
                appleMusicCredentials: appleMusicCredentials,
                timezone: timezone,
                vibeCodingUsage: vibeCodingUsage,
                vibeCodingNow: vibeCodingNow,
                vibeCodingYear: vibeCodingYear,
                includeDesktop: includeDesktop,
                includeAppleMusic: includeAppleMusic
            ),
            presence: presence
        )
    }

    /**
     * 发一条不带任何模块的信封：只声明在离线，不刷新任何模块的时间戳。
     *
     * 和数据上报走同一个端点、同一个 v4 信封 —— 空 `modules` 就是心跳的全部
     * 含义，接收端不需要为它准备第二条路。从前这条走独立的 presence 端点、
     * 发的是另一种 JSON，两边各维护一套。
     *
     * `blocking` 那条路的超时给得很短：睡眠前系统只留很窄的一个窗口，宁可这条
     * 发丢，也不能把睡眠拖住。发丢了还有心跳超时兜底，那条路本来就没拆。
     */
    private func sendHeartbeat(_ presence: String, blocking: Bool = false) {
        // 宣告过离线之后只剩 offline 能发。这是「闭嘴」的唯一落实处，
        // 拦得住上报循环的补心跳，也拦得住此后任何一条想说在线的路。
        guard presence == "offline" || !suspended else { return }
        guard settings.postEnabled, let url = URL(string: settings.postURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONCoding.encoder().encode(
            makeTelemetryEnvelope(
                chargingDevices: nil,
                desktop: nil,
                timezone: nil,
                appleMusic: nil,
                appleMusicCredentials: nil,
                vibeCodingUsage: nil,
                vibeCodingNow: nil,
                includeDesktop: false,
                includeAppleMusic: false,
                presence: presence
            )
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("mac-telemetry-hub/4", forHTTPHeaderField: "User-Agent")
        if !settings.telemetrySecret.isEmpty {
            request.setValue("Bearer \(settings.telemetrySecret)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 3

        guard blocking else {
            Task { _ = try? await IsolatedHTTPClient.data(for: request) }
            return
        }
        /**
         * 睡眠和退出这两条路必须同步等。
         *
         * `willSleepNotification` 的观察者返回后系统就接着睡了，异步任务根本
         * 来不及跑完；退出同理，进程先没了。所以这里用信号量把主线程挡住 ——
         * 上限 3 秒，且 URLSession 的回调在后台队列，不会和主线程互锁。
         */
        let done = DispatchSemaphore(value: 0)
        let session = IsolatedHTTPClient.session(for: request)
        session.dataTask(with: request) { _, _, _ in
            session.finishTasksAndInvalidate()
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
    }

    /// 站点 4xx 的 JSON 是 `{ ok: false, error: "…" }`。只显示状态码的话，
    /// 年度热力图校验失败会看起来像信封改坏了。
    private static func ingestErrorDetail(_ data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            return error
        }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    /**
     * 信封里的 `activeModules`：站点拿它决定这一轮心跳该给哪些模块续期。
     *
     * 充电头和充电宝比别的模块多一道连接判断。其余模块的数据源和上报器是同一个
     * 进程 —— 这份信封能发出去，就说明前台应用、时区、Vibe Coding 的来源都还在，
     * 开关本身已经是充分的存活证明。这两个不是：读数从 BLE 那头来，链路断了 App
     * 照样活着、照样发心跳，于是「开关开着」被站点读成「设备在线」，`charger:latest`
     * 早就过期了，`charger:lastPush` 还在被每一轮心跳顶新，断流那条判断永远不成立。
     *
     * 「连着但安静」和「没连上」是两回事，只有后者该从这个清单里消失。充电头空载
     * 时本来就没有新读数可发，心跳续期正是为这段安静时间准备的，把它一起摘掉会让
     * 站点误判成拔线；而没连上时摘掉它，站点那边的过期计时才真的开始走。
     */
    private var activeModuleNames: [String] {
        var names: [String] = []
        if settings.chargerModuleEnabled, chargerLink.isConnected {
            names.append(TelemetryModule.charger.rawValue)
        }
        if settings.powerBankModuleEnabled, powerBankLink.isConnected {
            names.append(TelemetryModule.powerBank.rawValue)
        }
        if settings.desktopModuleEnabled { names.append(TelemetryModule.desktop.rawValue) }
        if settings.appleMusicModuleEnabled { names.append(TelemetryModule.appleMusic.rawValue) }
        if settings.timezoneModuleEnabled { names.append(TelemetryModule.timezone.rawValue) }
        if settings.vibeCodingModuleEnabled {
            names.append(TelemetryModule.vibeCoding.rawValue)
            names.append(TelemetryModule.vibeCodingYear.rawValue)
        }
        return names
    }

    private func route(_ request: HTTPRequest) async -> HTTPHandlerResult {
        if request.method == "OPTIONS" { return json(EmptyObject()) }
        switch (request.method, request.path) {
        case ("GET", "/"):
            return json([
                "health": "/health",
                "charger": "/sse/charger",
                "powerBank": "/sse/powerbank",
            ])
        case ("GET", "/health"):
            return json(HealthPayload(
                ok: true,
                charger: .init(
                    enabled: settings.chargerModuleEnabled,
                    connected: chargerLink.isConnected,
                    phase: chargerLink.phase.label
                ),
                powerBank: .init(
                    enabled: settings.powerBankModuleEnabled,
                    connected: powerBankLink.isConnected,
                    phase: powerBankLink.phase.label
                )
            ))
        case ("GET", "/sse/charger"):
            return chargingStream(.charger)
        case ("GET", "/sse/powerbank"):
            return chargingStream(.powerBank)
        default:
            return json(["detail": "not found"], status: 404, reason: "Not Found")
        }
    }

    /**
     * 订阅一条充电设备的推流。
     *
     * 先把当前快照发出去，之后每一帧蓝牙遥测（约 1 Hz）再跟一帧。没有本地定时器，
     * 设备不推这边就不发。连上瞬间那一次也走这条路，因为断开之后没有帧再来。
     */
    private func chargingStream(_ slot: ChargingDeviceSlot) -> HTTPHandlerResult {
        .stream { [weak self] stream in
            guard let self, stream.isOpen,
                  let link = chargingLinks.first(where: { $0.slot == slot }) else {
                stream.close()
                return
            }
            chargingSSE.attach(stream, slot: slot)
            chargingSSE.send(streamEvent(for: link), to: stream)
        }
    }

    private func json<T: Encodable>(
        _ value: T,
        status: Int = 200,
        reason: String = "OK"
    ) -> HTTPHandlerResult {
        do {
            return .response(.json(try JSONCoding.encoder().encode(value), status: status, reason: reason))
        } catch {
            return .response(.text(
                "{\"detail\":\"encoding failed\"}",
                contentType: "application/json",
                status: 500,
                reason: "Internal Server Error"
            ))
        }
    }
}

private struct EmptyObject: Encodable {}

private struct HealthPayload: Encodable {
    struct Device: Encodable {
        let enabled: Bool
        let connected: Bool
        let phase: String
    }

    let ok: Bool
    let charger: Device
    let powerBank: Device
}

private struct ChargingStreamEvent: Encodable {
    let phase: String
    let connected: Bool
    let lastError: String?
    let device: ChargingDevicePayload?
}

@MainActor
private final class ChargingSSEBroker {
    private var streams: [ChargingDeviceSlot: [ObjectIdentifier: HTTPStream]] = [:]

    func attach(_ stream: HTTPStream, slot: ChargingDeviceSlot) {
        let id = ObjectIdentifier(stream)
        streams[slot, default: [:]][id] = stream
        let previous = stream.onClose
        stream.onClose = { [weak self] in
            previous?()
            self?.streams[slot]?[id] = nil
        }
    }

    func send(_ event: ChargingStreamEvent, to stream: HTTPStream) {
        guard let data = try? JSONCoding.encoder().encode(event) else { return }
        stream.send(json: data)
    }

    func publish(_ event: ChargingStreamEvent, slot: ChargingDeviceSlot) {
        guard let data = try? JSONCoding.encoder().encode(event) else { return }
        for stream in (streams[slot] ?? [:]).values where stream.isOpen {
            stream.send(json: data)
        }
    }

    func closeAll() {
        let open = streams.values.flatMap(\.values)
        streams.removeAll()
        for stream in open { stream.close() }
    }
}

private enum ReporterError: LocalizedError {
    case httpStatus(Int, detail: String?)
    case invalidTelemetryResponse
    var errorDescription: String? {
        switch self {
        case let .httpStatus(code, detail):
            if let detail, !detail.isEmpty { return "POST 端点返回 HTTP \(code)：\(detail)" }
            return "POST 端点返回 HTTP \(code)"
        case .invalidTelemetryResponse:
            return "遥测端点响应缺少图标确认状态。"
        }
    }
}
