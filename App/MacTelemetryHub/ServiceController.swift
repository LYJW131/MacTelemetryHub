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
        let host = hostHeader(for: objectURL)
        let payloadHash = actualHash
        let amzDate = timestamp()
        let shortDate = String(amzDate.prefix(8))
        let scope = "\(shortDate)/auto/s3/aws4_request"
        let signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        let canonicalPath = URLComponents(url: objectURL, resolvingAgainstBaseURL: false)?.percentEncodedPath
            ?? objectURL.path
        let canonicalHeaders = [
            "content-type:image/webp",
            "host:\(host)",
            "x-amz-content-sha256:\(payloadHash)",
            "x-amz-date:\(amzDate)",
        ].joined(separator: "\n") + "\n"
        let canonicalRequest = [
            "PUT",
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

        var request = URLRequest(url: objectURL)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.timeoutInterval = timeout
        request.setValue("image/webp", forHTTPHeaderField: "Content-Type")
        request.setValue("public, max-age=31536000, immutable", forHTTPHeaderField: "Cache-Control")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(configuration.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.httpStatus(0, "R2 返回了无效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: responseData.prefix(512), encoding: .utf8) ?? ""
            throw UploadError.httpStatus(http.statusCode, detail)
        }
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
    case timezone
    case vibeCoding

    var displayName: String {
        switch self {
        case .desktop: "前台应用"
        case .appleMusic: "Apple Music"
        case .charger: "充电设备"
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
    let bluetooth: BluetoothService
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
    @Published private(set) var isRefreshingCodexBar = false
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
    private var lastPostedCodexBarCostAt: Date?
    private var lastPostedCharger: ChargerUploadSignature?
    /// 只跟结构性变化比，管的是「要不要即时发」，不管「要不要带 charger 模块」
    private var lastPostedChargerStructural: ChargerStructuralSignature?
    private var lastPostedDesktop: DesktopUploadSignature?
    /// 这个上报会话里服务端已经确认保存的图标内容指纹。
    private var uploadedDesktopIconHashes: Set<String> = []
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
        bluetooth = BluetoothService(settings: settings)
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
        desktopActivity.stop()
        timeZone.stop()
        appleMusic.stop()
        codexBarCost.stop()
        agentLimits.stop()
        codingSessions.stop()
        httpServer.stop()
        bluetooth.shutdown()
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

    /// Re-runs the two CodexBar commands plus the lightweight ccusage session scan, then
    /// immediately queues the fresh snapshot for upload.
    /// The monitors retain their own single-flight guards; this flag only owns the button state.
    func refreshCodexBarNow() async {
        guard settings.codexBarModuleEnabled, !isRefreshingCodexBar else { return }
        isRefreshingCodexBar = true
        defer { isRefreshingCodexBar = false }

        async let sessionRefresh = codingSessions.refreshNow(cliPath: settings.ccusageCLIPath)
        async let limitsRefresh: Void = agentLimits.refreshNow(codexBarPath: settings.codexBarCLIPath)
        _ = await (sessionRefresh, limitsRefresh)
        let refreshed = await codexBarCost.refreshNow(
            cliPath: settings.codexBarCLIPath,
            plans: agentLimits.plans,
            limitErrors: agentLimits.limitErrors,
            sessions: codingSessions.snapshots
        )
        guard refreshed else { return }
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
        case .timezone: settings.timezoneModuleEnabled
        case .vibeCoding: settings.codexBarModuleEnabled
        }
    }

    private func moduleHasData(_ module: TelemetryModule) -> Bool {
        switch module {
        case .desktop: desktopActivity.snapshot != nil
        case .appleMusic: appleMusic.snapshot != nil
        case .charger: statusPayload.updatedAt != nil
        case .timezone: timeZone.snapshot != nil
        case .vibeCoding: codexBarCost.uploadPayload != nil
        }
    }

    var statusPayload: StatusPayload {
        StatusPayload(connected: bluetooth.isConnected, state: bluetooth.state)
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
    private func waitForNextTick() async {
        if pendingWake {
            pendingWake = false
            return
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: Self.tickInterval)
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
        if settings.chargerModuleEnabled {
            /**
             * 只有结构性变化才叫醒循环。
             *
             * 采集层是设备主动推流，约 1 Hz —— 每帧都叫醒的话循环就从 5 秒一转
             * 变成 1 秒一转，而其中绝大多数帧只是功率在滚动，本来就该等节流窗口。
             * 这里先拿结构指纹比一次，插拔和换设备才放行；比对是纯本地的，
             * 1 Hz 跑它的代价远小于白转一圈循环。
             */
            bluetooth.onStateChange = { [weak self] in
                guard let self else { return }
                let signature = ChargerStructuralSignature(
                    connected: bluetooth.isConnected,
                    state: bluetooth.state
                )
                guard signature != lastPostedChargerStructural else { return }
                wakeReporter()
            }
            bluetooth.start()
            bluetooth.reconnect()
        } else {
            bluetooth.onStateChange = nil
            bluetooth.disconnect()
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
        if !settings.codexBarModuleEnabled {
            codexBarCost.stop()
            agentLimits.stop()
            codingSessions.stop()
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
        lastPostedCodexBarCostAt = nil
        lastPostedCharger = nil
        lastPostedChargerStructural = nil
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
            while !Task.isCancelled {
                var manualModulesForAttempt: Set<TelemetryModule> = []
                var attemptedAppleMusicCredentials = false
                do {
                    if settings.timezoneModuleEnabled { timeZone.refresh() }
                    // 前台应用和 Apple Music 都不在这里采集：前者完全由 NSWorkspace
                    // 的激活通知驱动，后者由 Music.app 的 playerInfo 跨进程通知驱动、
                    // 另带一个兜底重读补上不发通知的 seek。循环只管读它们留下的
                    // snapshot —— 变化时它们会把循环叫醒，没事件时按 tickInterval 转。
                    if settings.codexBarModuleEnabled {
                        let sessionChanged = await codingSessions.refreshIfNeeded(
                            cliPath: settings.ccusageCLIPath,
                            interval: settings.codingSessionRefreshInterval
                        )
                        if sessionChanged {
                            _ = codexBarCost.applySessions(codingSessions.snapshots)
                        }
                        // 先刷限额：本地用量上传载荷要把 plan/limits 并进去。
                        await agentLimits.refreshIfNeeded(
                            codexBarPath: settings.codexBarCLIPath,
                            interval: settings.agentLimitsRefreshInterval
                        )
                        await codexBarCost.refreshIfNeeded(
                            cliPath: settings.codexBarCLIPath,
                            interval: settings.codexBarCostRefreshInterval,
                            plans: agentLimits.plans,
                            limitErrors: agentLimits.limitErrors,
                            sessions: codingSessions.snapshots
                        )
                    }

                    // token 检测属于这条主循环，但用五分钟闸门避免每圈都问 MusicKit。
                    await refreshAppleMusicCredentialsIfNeeded()

                    // 变化判断全是本地计算，每圈都做；nextPostAt 只管「什么时候允许发」。
                    let charger = settings.chargerModuleEnabled && statusPayload.updatedAt != nil
                        ? statusPayload
                        : nil
                    let chargerSignature = charger.map(ChargerUploadSignature.init)
                    let chargerStructural = charger.map { _ in
                        ChargerStructuralSignature(
                            connected: bluetooth.isConnected,
                            state: bluetooth.state
                        )
                    }
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
                    let chargerChanged = chargerSignature != nil && chargerSignature != lastPostedCharger
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
                    let codexBarCostChanged: Bool
                    if settings.codexBarModuleEnabled, let refreshedAt = codexBarCost.lastSuccess {
                        codexBarCostChanged = lastPostedCodexBarCostAt.map { refreshedAt > $0 } ?? true
                    } else {
                        codexBarCostChanged = false
                    }
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
                    let codexBarCostToSend = manualMode
                        ? manualModules.contains(.vibeCoding) && codexBarCost.uploadPayload != nil
                        : codexBarCostChanged
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
                        musicToSend || codexBarCostToSend || credentialsToSend != nil
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
                    let chargerUrgent = !manualMode && chargerStructural != nil &&
                        chargerStructural != lastPostedChargerStructural
                    // 退避期内一律不放行。否则服务端挂掉时，未推进的 lastPosted 会让
                    // urgent 一直为真，即时上报就变成每圈一次的重试风暴。
                    let urgent = (manualMode || musicUrgent || desktopUrgent || timezoneUrgent ||
                        chargerUrgent || credentialsToSend != nil) && Date() >= backoffUntil
                    let shouldPost = Date() >= backoffUntil && (manualMode || urgent || Date() >= nextPostAt)

                    if let url, anythingChanged, shouldPost {
                        let desktopPayload: DesktopActivitySnapshot?
                        if let desktop {
                            let shouldSendIcon = desktop.iconHash.map {
                                !uploadedDesktopIconHashes.contains($0)
                            } ?? false
                            if let iconHash = desktop.iconHash,
                               let iconData = desktop.iconData,
                               let r2Configuration = R2IconUploader.configuration(settings: settings) {
                                let iconObjectKey = "\(iconHash).webp"
                                if shouldSendIcon {
                                    try await R2IconUploader.upload(
                                        data: iconData,
                                        contentHash: iconHash,
                                        objectKey: iconObjectKey,
                                        configuration: r2Configuration,
                                        timeout: timeout
                                    )
                                }
                                // R2 已经由本机直传；网站端只接收对象键，不再接收图片二进制。
                                desktopPayload = desktop.withIconData(nil, iconObjectKey: iconObjectKey)
                            } else {
                                // 图片只允许上报器直传 R2；未配置时不再回退成 base64 交给站点处理。
                                desktopPayload = desktop.withIconData(nil)
                            }
                        } else {
                            desktopPayload = nil
                        }
                        // 封面不再由这边送：网页那边为了拿曲目链接本来就要查一次
                        // Apple Music 目录，那次查询的结果自带封面 URL。
                        let musicPayload = music
                        let envelope = makeTelemetryEnvelope(
                            charger: chargerToSend ? charger : nil,
                            desktop: desktopToSend ? desktopPayload : nil,
                            timezone: timezoneToSend ? timezone : nil,
                            appleMusic: musicToSend ? musicPayload : nil,
                            appleMusicCredentials: credentialsToSend,
                            vibeCoding: codexBarCostToSend ? codexBarCost.uploadPayload : nil,
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
                        let (responseData, response) = try await URLSession.shared.data(for: request)
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
                        if chargerToSend { lastPostedCharger = chargerSignature }
                        // 结构指纹跟着每次成功发送推进，跟 chargerChanged 无关：
                        // 结构变了完整指纹必然也变，反过来不成立。
                        if let chargerStructural { lastPostedChargerStructural = chargerStructural }
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
                        if codexBarCostToSend { lastPostedCodexBarCostAt = codexBarCost.lastSuccess }
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
                await waitForNextTick()
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
            charger: settings.chargerModuleEnabled && statusPayload.updatedAt != nil ? statusPayload : nil,
            desktop: settings.desktopModuleEnabled ? desktopActivity.snapshot : nil,
            timezone: settings.timezoneModuleEnabled ? timeZone.snapshot : nil,
            appleMusic: settings.appleMusicModuleEnabled ? appleMusic.snapshot : nil,
            appleMusicCredentials: credentialsPayload,
            vibeCoding: settings.codexBarModuleEnabled ? codexBarCost.uploadPayload : nil,
            includeDesktop: settings.desktopModuleEnabled,
            includeAppleMusic: settings.appleMusicModuleEnabled
        )
    }

    private func makeTelemetryEnvelope(
        charger: StatusPayload?,
        desktop: DesktopActivitySnapshot?,
        timezone: TimeZoneSnapshot?,
        appleMusic: AppleMusicSnapshot?,
        appleMusicCredentials: AppleMusicCredentialsPayload?,
        vibeCoding: JSONValue?,
        includeDesktop: Bool,
        includeAppleMusic: Bool,
        presence: String = "online"
    ) -> TelemetryEnvelope {
        return TelemetryEnvelope(
            heartbeatAt: Int64(Date().timeIntervalSince1970 * 1_000),
            activeModules: activeModuleNames,
            modules: TelemetryModulesPayload(
                charger: charger,
                desktop: desktop,
                appleMusic: appleMusic,
                appleMusicCredentials: appleMusicCredentials,
                timezone: timezone,
                vibeCoding: vibeCoding,
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
                charger: nil,
                desktop: nil,
                timezone: nil,
                appleMusic: nil,
                appleMusicCredentials: nil,
                vibeCoding: nil,
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
            URLSession.shared.dataTask(with: request).resume()
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
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 3)
    }

    private var activeModuleNames: [String] {
        var names: [String] = []
        if settings.chargerModuleEnabled { names.append(TelemetryModule.charger.rawValue) }
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
                connected: bluetooth.isConnected,
                autoConnect: bluetooth.desiredConnection,
                lastError: bluetooth.lastError,
                updatedAt: bluetooth.state.updatedAt
            ))
        case ("GET", "/debug/status"):
            return encode(DebugPayload(
                connected: bluetooth.isConnected,
                autoConnect: bluetooth.desiredConnection,
                lastError: bluetooth.lastError,
                phase: bluetooth.phase.label,
                state: bluetooth.state
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
                "bluetooth": bluetooth.lastError,
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
            bluetooth.disconnect()
            return encode(ActionPayload(ok: true, connected: false, autoConnect: false, lastError: bluetooth.lastError))
        case ("POST", "/reconnect"):
            bluetooth.reconnect()
            return encode(ActionPayload(ok: true, connected: bluetooth.isConnected, autoConnect: true, lastError: bluetooth.lastError))
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
