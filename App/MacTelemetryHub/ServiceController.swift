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
     * 先问一句桶里有没有。
     *
     * 上报器手上本来就有写凭据，一个图标一辈子只问这一次（问过就记在
     * uploadedDesktopIconHashes 里），代价可以忽略；换来的是桶被清空、
     * 换机器、重启之后不必依赖站点回执就能自己发现要补传。
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

    /// 编码产物的内容地址。身份哈希标识「哪个应用的图标」，这个标识「哪份字节」
    static func objectKey(for data: Data) -> String { "\(sha256Hex(data)).png" }

    static func contentHash(of data: Data) -> String { sha256Hex(data) }

    /// 空请求体的 payload 哈希，SigV4 里 HEAD/GET 用它
    private static let emptyPayloadHash =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// 对象键的扩展名决定 Content-Type；键本身是内容地址，扩展名就是事实
    private static func contentType(for objectKey: String) -> String {
        objectKey.hasSuffix(".png") ? "image/png" : "image/webp"
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

    var displayName: String {
        switch self {
        case .desktop: "前台应用"
        case .appleMusic: "Apple Music"
        case .charger: "充电头"
        case .powerBank: "充电宝"
        case .timezone: "Mac 时区"
        case .vibeCoding: "Vibe Coding"
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

        init(_ device: ChargingDevicePayload) {
            id = device.id
            kind = device.kind
            connected = device.connected
            thermalLimited = device.battery?.thermalLimited
            onDock = device.ports.first(where: { $0.name == "B" })?.active ?? false
            ports = device.ports.map(Port.init)
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

    init(_ snapshot: AppleMusicSnapshot) {
        state = snapshot.state
        title = snapshot.title
        artist = snapshot.artist
        album = snapshot.album
        trackID = snapshot.trackID
        durationMs = snapshot.durationMs
        repeatOne = snapshot.repeatOne
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
    /// 每台设备一条独立链路：各自的 CBCentralManager、各自的配对 UUID、各自的
    /// 重连退避。充电头一直通电、断了就是拔了插座；充电宝空闲会自己睡、还会被
    /// 手机 app 抢走连接 —— 共用一套超时必然有一边不合适。
    let chargingLinks: [BluetoothService]
    var chargerLink: BluetoothService { chargingLinks[0] }
    var powerBankLink: BluetoothService { chargingLinks[1] }
    let desktopActivity = DesktopActivityMonitor()
    let timeZone = TimeZoneMonitor()
    let appleMusic = AppleMusicMonitor()
    let appleMusicAuthorization = AppleMusicAuthorizationManager()
    let codexBarCost = CodexBarCostMonitor()
    let agentLimits = AgentLimitsMonitor()
    let codingSessions = CodingSessionMonitor()
    lazy private(set) var httpServer = LocalHTTPServer { [weak self] request in
        guard let self else { return .text("Unavailable\n", status: 503, reason: "Service Unavailable") }
        return await self.route(request)
    }

    @Published private(set) var reporterLastSuccess: Date?
    @Published private(set) var reporterLastError: String?
    /// 三个采集器各有各的按钮，所以在飞状态也各记各的 —— 重取限额不该把
    /// 那个十几秒的用量扫描按钮也一起变灰。
    @Published private(set) var isRefreshingVibeCodingUsage = false
    @Published private(set) var isRefreshingVibeCodingLimits = false
    @Published private(set) var isRefreshingVibeCodingSessions = false
    @Published private(set) var appleMusicCredentialsUploadAt: Date?
    @Published private(set) var appleMusicCredentialsUploadError: String?
    @Published private(set) var isUploadingAppleMusicCredentials = false
    /// MusicKit 最近一次返回的缓存值；本机 /telemetry 也直接暴露这一份。
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
    private var lastPostedVibeCodingUsageAt: Date?
    private var lastPostedVibeCodingLimitsAt: Date?
    private var lastPostedVibeCodingSessionsAt: Date?
    private var lastPostedChargingDevices: ChargingDevicesPayload?
    /// 只跟结构性变化比，管的是「要不要即时发」，不管「要不要带 charger 模块」
    private var lastPostedChargingStructural: ChargingDevicesStructuralSignature?
    private var lastPostedDesktop: DesktopUploadSignature?
    /// 这个上报会话里服务端已经确认保存的图标内容指纹。
    private var uploadedDesktopIconHashes: Set<String> = []
    /// 图标直传连续失败次数，按身份哈希记。到上限就不再试，避免打成热循环
    private var iconUploadAttempts: [String: Int] = [:]
    private static let maxIconUploadAttempts = 3
    private var uploadedDesktopIconOrder: [String] = []
    private var lastPostedTimeZone: TimeZoneUploadSignature?
    private var lastPostedAppleMusic: AppleMusicUploadSignature?
    private var lastPostedMusicAnchor: AppleMusicPositionAnchor?
    private var lastHeartbeatAt: Date?
    private var started = false
    private var observesPower = false

    /// 事件驱动的模块用它把上报循环提前叫醒，不必干等到下一个周期
    private var wakeContinuation: CheckedContinuation<Void, Never>?
    /// 事件发生在循环正忙的时候，等待还没开始 —— 记下来，下次别睡
    private var pendingWake = false
    private var desktopSettleTask: Task<Void, Never>?

    /// 循环的常规周期。前台应用、音乐、充电器插拔都会提前叫醒它，所以这个只
    /// 用来照顾没有事件放行的活：充电器功率滚动这类按节流窗口发的变化、
    /// 30 秒心跳、CodexBar 的刷新间隔检查。
    private static let tickInterval = Duration.seconds(5)
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
    }

    deinit {
        reporterTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        configureModules()
        if settings.httpServerEnabled {
            httpServer.start(port: settings.httpPort)
        }
        restartReporter()
        observePowerTransitions()
        sendHeartbeat("online")
    }

    func stop() {
        // 抢在拆掉一切之前声明离线。同步发 —— 调用方紧接着就要退出进程了。
        sendHeartbeat("offline", blocking: true)
        reporterTask?.cancel()
        // 循环可能正挂在 waitForNextTick 上，叫醒它才能立刻看到 cancel 并退出
        wakeReporter()
        reporterTask = nil
        desktopSettleTask?.cancel()
        desktopSettleTask = nil
        vibeCodingCollectionTask?.cancel()
        vibeCodingCollectionTask = nil
        desktopActivity.stop()
        timeZone.stop()
        appleMusic.stop()
        codexBarCost.stop()
        agentLimits.stop()
        codingSessions.stop()
        httpServer.stop()
        chargerLink.shutdown()
    }

    /**
     * 睡眠 / 唤醒时声明在离线。
     *
     * 挂在 ServiceController 而不是 BluetoothService 上：那边那两个观察者只在
     * 充电器模块开着时才注册，而在线状态跟开了哪些模块无关。
     */
    private func observePowerTransitions() {
        guard !observesPower else { return }
        observesPower = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            // 必须同步：观察者一返回系统就接着睡了
            MainActor.assumeIsolated { self?.sendHeartbeat("offline", blocking: true) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendHeartbeat("online") }
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
            MainActor.assumeIsolated { self?.sendHeartbeat("offline", blocking: true) }
        }
    }

    func applySettings() throws {
        let oldPort = httpServer.listeningURL?.port
        try settings.save()
        if settings.httpServerEnabled {
            if oldPort != settings.httpPort {
                httpServer.start(port: settings.httpPort)
            }
        } else {
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
     * 三个采集器各自的「立刻重取」，互不牵连。
     *
     * 拆开之前只有一个按钮，按一下三条命令全跑一遍 —— 想看看限额掉到多少，
     * 就得连带等 `codexbar cost` 那十几秒的全量扫描。
     *
     * 采集器自己带单飞门闩，这里的标志只管按钮状态。即时上报仍是一次：
     * 信封只有一个，`requestImmediateReport` 也只按模块开关走一遍。
     */
    func refreshVibeCodingUsageNow() async {
        guard settings.codexBarModuleEnabled, !isRefreshingVibeCodingUsage else { return }
        isRefreshingVibeCodingUsage = true
        defer { isRefreshingVibeCodingUsage = false }
        guard await codexBarCost.refreshNow(cliPath: settings.codexBarCLIPath) else { return }
        _ = requestImmediateReport(.vibeCoding)
    }

    func refreshVibeCodingLimitsNow() async {
        guard settings.codexBarModuleEnabled, !isRefreshingVibeCodingLimits else { return }
        isRefreshingVibeCodingLimits = true
        defer { isRefreshingVibeCodingLimits = false }
        await agentLimits.refreshNow(codexBarPath: settings.codexBarCLIPath)
        _ = requestImmediateReport(.vibeCoding)
    }

    func refreshVibeCodingSessionsNow() async {
        guard settings.codexBarModuleEnabled, !isRefreshingVibeCodingSessions else { return }
        isRefreshingVibeCodingSessions = true
        defer { isRefreshingVibeCodingSessions = false }
        await codingSessions.refreshNow(cliPath: settings.ccusageCLIPath)
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
        case .vibeCoding: settings.codexBarModuleEnabled
        }
    }

    private func moduleHasData(_ module: TelemetryModule) -> Bool {
        switch module {
        case .desktop: desktopActivity.snapshot != nil
        case .appleMusic: appleMusic.snapshot != nil
        case .charger: chargerLink.hasTelemetry
        case .powerBank: powerBankLink.hasTelemetry
        case .timezone: timeZone.snapshot != nil
        // 三份任一有值就能发。从前只看用量那份，于是那个扫描一失败，
        // 刚取到的限额连发都发不出去。
        case .vibeCoding:
            codexBarCost.uploadPayload != nil
                || agentLimits.uploadPayload != nil
                || codingSessions.uploadPayload != nil
        }
    }

    /// 所有已启用、且真的收到过遥测的充电设备。一台都没有就返回 nil，
    /// 上报信封里那个键整个不出现。
    var chargingDevicesPayload: ChargingDevicesPayload? {
        let devices = chargingLinks.compactMap { link -> ChargingDevicePayload? in
            guard link.slot.isEnabled(settings) else { return nil }
            return link.devicePayload
        }
        return devices.isEmpty ? nil : ChargingDevicesPayload(devices: devices)
    }

    /// 本地 HTTP 的充电头视图。它服务的是本机状态页，那页只画充电头。
    var statusPayload: StatusPayload {
        StatusPayload(connected: chargerLink.isConnected, state: chargerLink.chargerStateForDisplay)
    }

    /**
     * 挂上或摘掉一条充电设备链路。
     *
     * 只有结构性变化才叫醒循环：采集是 1 Hz 推流，每帧都叫醒的话循环会从 5 秒
     * 一转变成 1 秒一转，而其中绝大多数帧只是功率在滚动，本来就该等节流窗口。
     * 指纹比对是纯本地的，1 Hz 跑它远比白转一圈循环便宜。
     */
    private func configure(link: BluetoothService) {
        guard link.slot.isEnabled(settings) else {
            link.onStateChange = nil
            link.disconnect()
            return
        }
        link.onStateChange = { [weak self] in
            guard let self, let payload = chargingDevicesPayload else { return }
            let signature = ChargingDevicesStructuralSignature(payload)
            guard signature != lastPostedChargingStructural else { return }
            wakeReporter()
        }
        link.start()
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

        if settings.desktopModuleEnabled {
            // 每次激活都重排，连续 Cmd-Tab 只在最后停下的那个应用上叫醒一次
            desktopActivity.onChange = { [weak self] in
                guard let self else { return }
                desktopSettleTask?.cancel()
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
        if settings.codexBarModuleEnabled {
            codingSessions.onChange = { [weak self] in self?.wakeReporter() }
            agentLimits.onChange = { [weak self] in self?.wakeReporter() }
            codexBarCost.onChange = { [weak self] in self?.wakeReporter() }
            startVibeCodingCollection()
        } else {
            codingSessions.onChange = nil
            agentLimits.onChange = nil
            codexBarCost.onChange = nil
            vibeCodingCollectionTask?.cancel()
            vibeCodingCollectionTask = nil
            codexBarCost.stop()
            agentLimits.stop()
            codingSessions.stop()
        }
    }

    /**
     * vibe coding 那三条 CLI 自己转一条循环，不再挂在上报循环上。
     *
     * 从前它们在上报循环发包之前被 await 掉，而最慢那条（`cost --days 365 --refresh`）
     * 实测要 25 秒 —— 这 25 秒里循环停在原地，切换应用的通知只能立个 pendingWake
     * 的旗，切过去又切走的那个应用根本发不出去，不是晚发是没发。
     *
     * 现在采集完由各自的 onChange 叫醒循环，跟前台应用、音乐同一条路：循环只读
     * 它们留下的载荷，唯一还会阻塞的就是那次 POST 本身。
     *
     * 这里按 tickInterval 转只是「问一句该不该采」，真正的节流是采集器自己的
     * 间隔门闩；单飞门闩也在采集器里，所以问得勤一点是安全的。
     */
    private func startVibeCodingCollection() {
        vibeCodingCollectionTask?.cancel()
        vibeCodingCollectionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, settings.codexBarModuleEnabled else { return }
                // 三份互不喂料，所以并发跑
                async let sessions: Void = self.codingSessions.refreshIfNeeded(
                    cliPath: settings.ccusageCLIPath,
                    interval: settings.codingSessionRefreshInterval
                )
                async let limits: Void = self.agentLimits.refreshIfNeeded(
                    codexBarPath: settings.codexBarCLIPath,
                    interval: settings.agentLimitsRefreshInterval
                )
                async let usage: Void = self.codexBarCost.refreshIfNeeded(
                    cliPath: settings.codexBarCLIPath,
                    interval: settings.codexBarCostRefreshInterval
                )
                _ = await (sessions, limits, usage)
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
        lastPostedVibeCodingLimitsAt = nil
        lastPostedVibeCodingSessionsAt = nil
        lastPostedChargingDevices = nil
        lastPostedChargingStructural = nil
        lastPostedDesktop = nil
        uploadedDesktopIconHashes.removeAll(keepingCapacity: true)
        uploadedDesktopIconOrder.removeAll(keepingCapacity: true)
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
                    let desktop = settings.desktopModuleEnabled ? desktopActivity.snapshot : nil
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
                    let desktopChanged = desktopSignature != nil && desktopSignature != lastPostedDesktop
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
                    /// 三份各判各的变化。门闩看的是载荷**变化**的时刻而不是采集成功的
                    /// 时刻 —— 会话状态 60 秒扫一次，绝大多数轮次什么都没变，拿
                    /// lastSuccess 当门闩会把每一轮扫描都变成一次上报。
                    let vibeCodingEnabled = settings.codexBarModuleEnabled
                    func vibeCodingChanged(_ updatedAt: Date?, _ lastPosted: Date?) -> Bool {
                        guard vibeCodingEnabled, let updatedAt else { return false }
                        return lastPosted.map { updatedAt > $0 } ?? true
                    }
                    let usageChanged = vibeCodingChanged(
                        codexBarCost.payloadUpdatedAt, lastPostedVibeCodingUsageAt
                    )
                    let limitsChanged = vibeCodingChanged(
                        agentLimits.payloadUpdatedAt, lastPostedVibeCodingLimitsAt
                    )
                    let sessionsChanged = vibeCodingChanged(
                        codingSessions.payloadUpdatedAt, lastPostedVibeCodingSessionsAt
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
                    // 手动上报按整个 vibe coding 模块走：信封只有一个，三份手上
                    // 有什么就一起发什么。
                    let manualVibeCoding = manualModules.contains(.vibeCoding)
                    let usageToSend = manualMode
                        ? manualVibeCoding && codexBarCost.uploadPayload != nil
                        : usageChanged
                    let limitsToSend = manualMode
                        ? manualVibeCoding && agentLimits.uploadPayload != nil
                        : limitsChanged
                    let sessionsToSend = manualMode
                        ? manualVibeCoding && codingSessions.uploadPayload != nil
                        : sessionsChanged
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
                    let heartbeatDue = lastHeartbeatAt.map { Date().timeIntervalSince($0) >= 30 } ?? true
                    let dataChanged = chargerToSend || desktopToSend || timezoneToSend ||
                        musicToSend || usageToSend || limitsToSend || sessionsToSend ||
                        credentialsToSend != nil
                    /**
                     * 只在没有数据要发的时候才补心跳 —— 有数据时那个包本身就证明
                     * 活着，再补一条是白发。
                     *
                     * 心跳和数据走同一个端点、同一个 v4 信封，区别只在 modules 空不空。
                     * 于是「这台 Mac 还活着」在接收端只有一个写入点。
                     */
                    if heartbeatDue, !dataChanged {
                        sendHeartbeat("online")
                        lastHeartbeatAt = Date()
                    }
                    let anythingChanged = dataChanged

                    // 播放/暂停、换歌、换前台应用是用户正盯着的事，不值得为它们等满节流窗口。
                    // 这些变化本来也会上报，即时化只是把等待砍掉，不增加请求总数；
                    // 而且同一个 envelope 会把此刻待发的充电器 / CodexBar 一起捎走。
                    // 进度跳变也算紧急。单曲循环时曲目和状态都没变，只有进度
                    // 从结尾跳回开头 —— 不放行的话网页会把进度条钉在 100%，
                    // 一直等到下一个节流窗口（实测 postInterval=30 时要等 30 秒）。
                    // 拖动进度条同理。这不会变吵：seek 只在通知或兜底重读时才
                    // 被发现，而通知只在换歌/播放状态变化时来。
                    let musicUrgent = !manualMode && musicChanged && (
                        musicSeeked ||
                        music?.state != lastPostedAppleMusic?.state ||
                        music?.trackID != lastPostedAppleMusic?.trackID
                    )
                    // 只认应用身份：图标变了（同一个 App 换了图标）也算 desktopChanged，
                    // 但不值得为它绕过节流窗口。
                    // Cmd-Tab 路过的中间应用一般不会把循环叫醒 —— 激活通知那侧压了
                    // 400ms 的 desktopSettleDelay，只有最后停下的那个才放行。
                    // 但那只防住「叫醒」这条路：tick 恰好落在切换途中时照样会采到中间
                    // 那个应用。真要根治得在这里再比一次，眼下不值当。
                    let desktopUrgent = !manualMode && desktopChanged && (
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
                    let shouldPost = Date() >= backoffUntil && (manualMode || urgent || Date() >= nextPostAt)

                    if let url, anythingChanged, shouldPost {
                        let desktopPayload: DesktopActivitySnapshot?
                        if let desktop {
                            /*
                             * 图标直传。三条铁律：
                             *
                             * 1. 传失败不许连累整份遥测 —— 图片是这里面最不重要的一块，
                             *    没有权力否决充电头、时区、音乐和 vibe coding 的上报。
                             *    所以整段包在 do/catch 里，失败就是「这轮没有对象键」。
                             * 2. 传之前先问桶里有没有。对象是内容寻址的，桶里已经有就直接用，
                             *    一个图标一辈子只问这一次。
                             * 3. 反复失败要收手。站点收不到图会回 desktopIconAvailable=false，
                             *    那条路会把 lastPostedDesktop 清空并立刻叫醒下一轮；真要是
                             *    永远成功不了（比如凭据错了），不设上限就是一个打站点的热循环。
                             */
                            var iconObjectKey: String?
                            if let iconHash = desktop.iconHash,
                               let iconData = desktop.iconData,
                               let r2Configuration = R2IconUploader.configuration(settings: settings),
                               iconUploadAttempts[iconHash, default: 0] < Self.maxIconUploadAttempts {
                                let objectKey = "\(R2IconUploader.objectKey(for: iconData))"
                                do {
                                    if uploadedDesktopIconHashes.contains(iconHash) {
                                        iconObjectKey = objectKey
                                    } else if try await R2IconUploader.exists(
                                        objectKey: objectKey,
                                        configuration: r2Configuration,
                                        timeout: min(timeout, 3)
                                    ) {
                                        iconObjectKey = objectKey
                                    } else {
                                        try await R2IconUploader.upload(
                                            data: iconData,
                                            contentHash: R2IconUploader.contentHash(of: iconData),
                                            objectKey: objectKey,
                                            configuration: r2Configuration,
                                            timeout: min(timeout, 3)
                                        )
                                        iconObjectKey = objectKey
                                    }
                                    iconUploadAttempts[iconHash] = 0
                                } catch {
                                    iconUploadAttempts[iconHash, default: 0] += 1
                                    reporterLastError = "图标上传失败：\(error.localizedDescription)"
                                }
                            }
                            // 站点只收对象键，二进制一律不进遥测 JSON
                            desktopPayload = desktop.withIconData(nil, iconObjectKey: iconObjectKey)
                        } else {
                            desktopPayload = nil
                        }
                        // 封面不再由这边送：网页那边为了拿曲目链接本来就要查一次
                        // Apple Music 目录，那次查询的结果自带封面 URL。
                        let musicPayload = music
                        let envelope = makeTelemetryEnvelope(
                            chargingDevices: chargerToSend ? charger : nil,
                            desktop: desktopToSend ? desktopPayload : nil,
                            timezone: timezoneToSend ? timezone : nil,
                            appleMusic: musicToSend ? musicPayload : nil,
                            appleMusicCredentials: credentialsToSend,
                            vibeCodingUsage: usageToSend ? codexBarCost.uploadPayload : nil,
                            vibeCodingLimits: limitsToSend ? agentLimits.uploadPayload : nil,
                            vibeCodingSessions: sessionsToSend ? codingSessions.uploadPayload : nil,
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
                        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                            throw ReporterError.httpStatus(response.statusCode)
                        }
                        let responsePayload = try JSONDecoder()
                            .decode(TelemetryIngestResponse.self, from: responseData)
                        let desktopIconAvailable = responsePayload.data.desktopIconAvailable
                        if desktopToSend, desktopIconAvailable == nil {
                            throw ReporterError.invalidTelemetryResponse
                        }
                        reporterLastSuccess = Date()
                        reporterLastError = nil
                        lastHeartbeatAt = Date()
                        if chargerToSend { lastPostedChargingDevices = chargerSignature }
                        // 结构指纹跟着每次成功发送推进，跟 chargerChanged 无关：
                        // 结构变了完整指纹必然也变，反过来不成立。
                        if let chargerStructural { lastPostedChargingStructural = chargerStructural }
                        if desktopToSend {
                            if desktopIconAvailable == false, let iconHash = desktop?.iconHash {
                                forgetUploadedDesktopIcon(iconHash)
                                // 服务端缓存可能刚被清空；下一圈立即补发完整图标。
                                lastPostedDesktop = nil
                                wakeReporter()
                            } else {
                                lastPostedDesktop = desktopSignature
                                if let desktop { rememberUploadedDesktopIcon(desktop) }
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
                        if usageToSend { lastPostedVibeCodingUsageAt = codexBarCost.payloadUpdatedAt }
                        if limitsToSend { lastPostedVibeCodingLimitsAt = agentLimits.payloadUpdatedAt }
                        if sessionsToSend {
                            lastPostedVibeCodingSessionsAt = codingSessions.payloadUpdatedAt
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

    private func rememberUploadedDesktopIcon(_ snapshot: DesktopActivitySnapshot) {
        guard let iconHash = snapshot.iconHash else { return }
        uploadedDesktopIconHashes.insert(iconHash)
        uploadedDesktopIconOrder.removeAll { $0 == iconHash }
        uploadedDesktopIconOrder.append(iconHash)
        if uploadedDesktopIconOrder.count > Self.uploadedDesktopIconLimit {
            let evicted = uploadedDesktopIconOrder.removeFirst()
            uploadedDesktopIconHashes.remove(evicted)
        }
    }

    private func forgetUploadedDesktopIcon(_ iconHash: String) {
        uploadedDesktopIconHashes.remove(iconHash)
        uploadedDesktopIconOrder.removeAll { $0 == iconHash }
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
            vibeCodingUsage: settings.codexBarModuleEnabled ? codexBarCost.uploadPayload : nil,
            vibeCodingLimits: settings.codexBarModuleEnabled ? agentLimits.uploadPayload : nil,
            vibeCodingSessions: settings.codexBarModuleEnabled ? codingSessions.uploadPayload : nil,
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
        vibeCodingLimits: JSONValue?,
        vibeCodingSessions: JSONValue?,
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
                vibeCodingLimits: vibeCodingLimits,
                vibeCodingSessions: vibeCodingSessions,
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
                vibeCodingLimits: nil,
                vibeCodingSessions: nil,
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

    private var activeModuleNames: [String] {
        var names: [String] = []
        if settings.chargerModuleEnabled { names.append(TelemetryModule.charger.rawValue) }
        if settings.powerBankModuleEnabled { names.append(TelemetryModule.powerBank.rawValue) }
        if settings.desktopModuleEnabled { names.append(TelemetryModule.desktop.rawValue) }
        if settings.appleMusicModuleEnabled { names.append(TelemetryModule.appleMusic.rawValue) }
        if settings.timezoneModuleEnabled { names.append(TelemetryModule.timezone.rawValue) }
        if settings.codexBarModuleEnabled { names.append(TelemetryModule.vibeCoding.rawValue) }
        return names
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "OPTIONS" { return .text("") }
        switch (request.method, request.path) {
        case ("GET", "/"):
            if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
               let data = try? Data(contentsOf: url) {
                return HTTPResponse(status: 200, reason: "OK", contentType: "text/html; charset=utf-8", body: data)
            }
            return .text("Mac Telemetry Hub\n", contentType: "text/plain; charset=utf-8")
        case ("GET", "/status"):
            return encode(statusPayload)
        case ("GET", "/activity"):
            return encode(ActivityLocalPayload(
                desktop: desktopActivity.snapshot,
                appleMusic: appleMusic.snapshot
            ))
        case ("GET", "/apple-music/authorization"):
            return encode(AppleMusicAuthorizationPayload(
                status: appleMusicAuthorization.statusDescription,
                authorized: appleMusicAuthorization.authorizationStatus == .authorized,
                hasUserToken: appleMusicAuthorization.hasUserToken,
                lastError: appleMusicAuthorization.lastError,
                lastUploadAt: appleMusicCredentialsUploadAt
            ))
        case ("GET", "/telemetry"):
            return encode(telemetryEnvelope)
        case ("GET", "/health"):
            return encode(HealthPayload(
                ok: true,
                connected: chargerLink.isConnected,
                autoConnect: chargerLink.desiredConnection,
                lastError: chargerLink.lastError,
                updatedAt: chargerLink.chargerStateForDisplay.updatedAt
            ))
        case ("GET", "/debug/status"):
            return encode(DebugPayload(
                connected: chargerLink.isConnected,
                autoConnect: chargerLink.desiredConnection,
                lastError: chargerLink.lastError,
                phase: chargerLink.phase.label,
                state: chargerLink.chargerStateForDisplay
            ))
        /**
         * 采集侧各模块最近一次的失败原因。
         *
         * CodexBar Web 的某个 provider 可能单独失败；采集器会保留该 provider
         * 上一次的好值，并把本轮错误留在这里。没有这个端点就只能靠猜。
         */
        case ("GET", "/debug/errors"):
            return encode([
                "agentLimits": agentLimits.lastError,
                "codexbar": codexBarCost.lastError,
                "ccusageSessions": codingSessions.lastError,
                "appleMusic": appleMusic.lastError,
                "bluetooth": chargerLink.lastError,
                "reporter": reporterLastError,
            ])
        case ("GET", "/ports"):
            return encode(statusPayload.ports)
        case ("GET", let path) where path.hasPrefix("/ports/"):
            let key = String(path.dropFirst("/ports/".count)).uppercased()
            guard let port = statusPayload.ports[key] else {
                return .text("{\"detail\":\"unknown port\"}", contentType: "application/json", status: 404, reason: "Not Found")
            }
            return encode(port)
        case ("GET", "/metrics"):
            return .text(metrics(), contentType: "text/plain; version=0.0.4; charset=utf-8")
        case ("POST", "/disconnect"):
            chargerLink.disconnect()
            return encode(ActionPayload(ok: true, connected: false, autoConnect: false, lastError: chargerLink.lastError))
        case ("POST", "/reconnect"):
            chargerLink.reconnect()
            return encode(ActionPayload(ok: true, connected: chargerLink.isConnected, autoConnect: true, lastError: chargerLink.lastError))
        default:
            return .text("{\"detail\":\"not found\"}", contentType: "application/json", status: 404, reason: "Not Found")
        }
    }

    private func encode<T: Encodable>(_ value: T) -> HTTPResponse {
        do { return .json(try JSONCoding.encoder().encode(value)) }
        catch { return .text("{\"detail\":\"encoding failed\"}", contentType: "application/json", status: 500, reason: "Internal Server Error") }
    }

    private func metrics() -> String {
        let payload = statusPayload
        var lines = [
            "# HELP a2687_connected Charger BLE session is live.",
            "# TYPE a2687_connected gauge",
            "a2687_connected \(payload.connected ? 1 : 0)",
            "# HELP a2687_total_output_power_watts Total output power across all ports.",
            "# TYPE a2687_total_output_power_watts gauge",
        ]
        if let total = payload.totalOutputPowerW { lines.append("a2687_total_output_power_watts \(total)") }
        for (field, unit, value) in [
            ("voltage", "volts", { (port: StatusPortPayload) in port.voltageV }),
            ("current", "amperes", { (port: StatusPortPayload) in port.currentA }),
            ("power", "watts", { (port: StatusPortPayload) in port.powerW }),
        ] as [(String, String, (StatusPortPayload) -> Double?)] {
            let metric = "a2687_port_\(field)_\(unit)"
            lines.append("# TYPE \(metric) gauge")
            for key in ["C1", "C2", "C3"] {
                if let port = payload.ports[key], let number = value(port) {
                    lines.append("\(metric){port=\"\(key)\"} \(number)")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private struct HealthPayload: Encodable {
    let ok: Bool
    let connected: Bool
    let autoConnect: Bool
    let lastError: String?
    let updatedAt: TimeInterval?
}

private struct DebugPayload: Encodable {
    let connected: Bool
    let autoConnect: Bool
    let lastError: String?
    let phase: String
    let state: ChargerState
}

private struct ActionPayload: Encodable {
    let ok: Bool
    let connected: Bool
    let autoConnect: Bool
    let lastError: String?
}

private struct ActivityLocalPayload: Encodable {
    let desktop: DesktopActivitySnapshot?
    let appleMusic: AppleMusicSnapshot?
}

private enum ReporterError: LocalizedError {
    case httpStatus(Int)
    case invalidTelemetryResponse
    var errorDescription: String? {
        switch self {
        case let .httpStatus(code): "POST 端点返回 HTTP \(code)"
        case .invalidTelemetryResponse: "遥测端点响应缺少图标确认状态。"
        }
    }
}

private struct AppleMusicAuthorizationPayload: Encodable, Sendable {
    let status: String
    let authorized: Bool
    let hasUserToken: Bool
    let lastError: String?
    let lastUploadAt: Date?

    private enum CodingKeys: String, CodingKey {
        case status, authorized
        case hasUserToken, lastError, lastUploadAt
    }
}
