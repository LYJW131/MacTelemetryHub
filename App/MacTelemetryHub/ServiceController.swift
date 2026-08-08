import AppKit
import Foundation
import MusicKit

enum TelemetryModule: String, CaseIterable, Hashable, Sendable {
    case desktop
    case appleMusic = "apple_music"
    case charger
    case vibeCoding = "vibe_coding"

    var displayName: String {
        switch self {
        case .desktop: "前台应用"
        case .appleMusic: "Apple Music"
        case .charger: "充电设备"
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
    let iconData: Data?

    init(_ snapshot: DesktopActivitySnapshot) {
        applicationName = snapshot.applicationName
        bundleIdentifier = snapshot.bundleIdentifier
        iconData = snapshot.iconData
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
    let appleMusic = AppleMusicMonitor()
    let appleMusicAuthorization = AppleMusicAuthorizationManager()
    let ccusage = CcusageMonitor()
    let agentLimits = AgentLimitsMonitor()
    lazy private(set) var httpServer = LocalHTTPServer { [weak self] request in
        guard let self else { return .text("Unavailable\n", status: 503, reason: "Service Unavailable") }
        return await self.route(request)
    }

    @Published private(set) var reporterLastSuccess: Date?
    @Published private(set) var reporterLastError: String?
    @Published private(set) var isRefreshingVibeCoding = false
    @Published private(set) var vibeCodingRefreshError: String?
    @Published private(set) var appleMusicCredentialsUploadAt: Date?
    @Published private(set) var appleMusicCredentialsUploadError: String?
    @Published private(set) var isUploadingAppleMusicCredentials = false
    /**
     * 上次成功上报的那份 developer token 的到期时刻和上报时刻，用来算续期时机。
     *
     * 只在内存里。重启后重签一份发一次就行 —— 那份按定义是新鲜的，为省这一次
     * 请求去持久化不划算，况且要存的还是个跟着 token 走的时间戳。
     */
    private var uploadedCredentials: (expiresAt: Date, uploadedAt: Date)?
    private var appleMusicCredentialsRetryAfter = Date.distantPast
    @Published private(set) var pendingManualReports: Set<TelemetryModule> = []
    @Published private(set) var lastManualReportError: [TelemetryModule: String] = [:]
    @Published private(set) var lastManualReportAt: [TelemetryModule: Date] = [:]

    private var reporterTask: Task<Void, Never>?
    private var lastPostedCcusageAt: Date?
    private var lastPostedCharger: ChargerUploadSignature?
    /// 只跟结构性变化比，管的是「要不要即时发」，不管「要不要带 charger 模块」
    private var lastPostedChargerStructural: ChargerStructuralSignature?
    private var lastPostedDesktop: DesktopUploadSignature?
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
    /// 30 秒心跳、ccusage 的刷新间隔检查。
    private static let tickInterval = Duration.seconds(5)

    /// Apple Music 凭据签发或上报失败后的退避。凭据不像遥测那样有时效压力，
    /// 等一分钟再试足够了。
    private static let appleMusicRetryDelay: TimeInterval = 60

    /**
     * 前台应用的防抖窗口。
     *
     * 每收到一次激活通知就重新计时，所以连续 Cmd-Tab 只会在最后停下来的那个
     * 应用上触发一次上报 —— 路过的应用停留远不到这个时长。
     * 从前这个防抖是 2 秒采样「顺便」带来的，把延迟和防抖强度焊死成了同一个
     * 数字；拆开之后延迟降到这个量级，而防抖强度可以单独调。
     */
    private static let desktopSettleDelay = Duration.milliseconds(400)

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
        httpServer.start(port: settings.httpPort)
        restartReporter()
        observePowerTransitions()
        sendPresence("online")
    }

    func stop() {
        // 抢在拆掉一切之前声明离线。同步发 —— 调用方紧接着就要退出进程了。
        sendPresence("offline", blocking: true)
        reporterTask?.cancel()
        // 循环可能正挂在 waitForNextTick 上，叫醒它才能立刻看到 cancel 并退出
        wakeReporter()
        reporterTask = nil
        desktopSettleTask?.cancel()
        desktopSettleTask = nil
        desktopActivity.stop()
        appleMusic.stop()
        ccusage.stop()
        agentLimits.stop()
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
            MainActor.assumeIsolated { self?.sendPresence("offline", blocking: true) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendPresence("online") }
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
            MainActor.assumeIsolated { self?.sendPresence("offline", blocking: true) }
        }
    }

    func applySettings() throws {
        let oldPort = httpServer.listeningURL?.port
        try settings.save()
        if oldPort != settings.httpPort { httpServer.start(port: settings.httpPort) }
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

    /// Refreshes both local usage aggregation and server-side agent limits once.
    /// Each monitor owns its own non-reentrancy guard; this method only coordinates order.
    func refreshVibeCodingNow() async {
        guard settings.ccusageModuleEnabled, !isRefreshingVibeCoding else { return }
        isRefreshingVibeCoding = true
        vibeCodingRefreshError = nil
        defer { isRefreshingVibeCoding = false }

        await agentLimits.refreshNow(codexPath: settings.codexCLIPath)
        await ccusage.refreshNow(
            nodePath: settings.nodePath,
            cliPath: settings.ccusageCLIPath,
            plans: agentLimits.plans,
            limitErrors: agentLimits.limitErrors
        )
        let errors = [agentLimits.lastError, ccusage.lastError].compactMap { $0 }
        vibeCodingRefreshError = errors.isEmpty ? nil : errors.joined(separator: "；")
        wakeReporter()
    }

    /**
     * 首次授权，由用户在设置页点出来 —— 只有这条路径会弹系统对话框。
     *
     * 授权成功就立刻签一份发过去，不等循环下一圈：用户刚点完按钮，要的就是
     * 当场看到结果。此后的续期全自动，不再需要碰这个按钮。
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
        guard settings.postEnabled else {
            appleMusicCredentialsUploadError = "Apple Music 已授权；开启远端上报后会自动发送 token。"
            return
        }
        await mintAndUploadAppleMusicCredentials()
    }

    /**
     * 到期前把 Apple Music 凭据续上。每圈循环调一次。
     *
     * 和别的模块不一样：这里没有「变化」可以观察 —— token 不会变，只会过期。
     * 所以触发条件是时间，过了「上次上报时刻」到「到期时刻」的中点就重签一份。
     *
     * 用相对寿命而不是写死的提前量：MusicKit 签出来的 token 能活多久 Apple 没有
     * 承诺，写死一个提前量在两个方向上都可能错 —— 短寿命时来不及续，长寿命时
     * 天天白续。取中点则不管它是几小时还是几个月都成立。
     */
    private func refreshAppleMusicCredentialsIfNeeded() async {
        guard settings.postEnabled, !isUploadingAppleMusicCredentials else { return }
        // 后台绝不请求授权，没批准就什么都不做 —— 从循环里弹系统弹窗是不能接受的
        guard MusicAuthorization.currentStatus == .authorized else { return }
        // 失败后退避。上报失败时 uploadedCredentials 不动，不挡一下的话
        // 每圈都会重签重发，和 ccusage 判废那处是同一个坑。
        guard Date() >= appleMusicCredentialsRetryAfter else { return }
        if let uploaded = uploadedCredentials {
            let lifetime = uploaded.expiresAt.timeIntervalSince(uploaded.uploadedAt)
            guard Date() >= uploaded.uploadedAt.addingTimeInterval(lifetime / 2) else { return }
        }
        await mintAndUploadAppleMusicCredentials()
    }

    /// 现签一对再发。新鲜由 mintCredentials 的 `.ignoreCache` 保证。
    private func mintAndUploadAppleMusicCredentials() async {
        guard let credentials = await appleMusicAuthorization.mintCredentials() else {
            appleMusicCredentialsUploadError = appleMusicAuthorization.lastError
            appleMusicCredentialsRetryAfter = Date().addingTimeInterval(Self.appleMusicRetryDelay)
            return
        }
        do {
            try await uploadAppleMusicCredentials(credentials)
            let now = Date()
            appleMusicCredentialsUploadAt = now
            appleMusicCredentialsUploadError = nil
            appleMusicCredentialsRetryAfter = .distantPast
            uploadedCredentials = (expiresAt: credentials.expiresAt, uploadedAt: now)
        } catch {
            appleMusicCredentialsUploadError = error.localizedDescription
            appleMusicCredentialsRetryAfter = Date().addingTimeInterval(Self.appleMusicRetryDelay)
        }
    }

    private func moduleIsEnabled(_ module: TelemetryModule) -> Bool {
        switch module {
        case .desktop: settings.desktopModuleEnabled
        case .appleMusic: settings.appleMusicModuleEnabled
        case .charger: settings.chargerModuleEnabled
        case .vibeCoding: settings.ccusageModuleEnabled
        }
    }

    private func moduleHasData(_ module: TelemetryModule) -> Bool {
        switch module {
        case .desktop: desktopActivity.snapshot != nil
        case .appleMusic: appleMusic.snapshot != nil
        case .charger: statusPayload.updatedAt != nil
        case .vibeCoding: ccusage.uploadPayload != nil
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

        if settings.appleMusicModuleEnabled {
            // 音乐不用防抖：playerInfo 的竞态已经由 monitor 内部那次确认读消掉了
            appleMusic.onChange = { [weak self] in self?.wakeReporter() }
            appleMusic.start()
        } else {
            appleMusic.onChange = nil
            appleMusic.stop()
        }
        if !settings.ccusageModuleEnabled {
            ccusage.stop()
            agentLimits.stop()
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
        lastPostedCcusageAt = nil
        lastPostedCharger = nil
        lastPostedChargerStructural = nil
        lastPostedDesktop = nil
        lastPostedAppleMusic = nil
        lastPostedMusicAnchor = nil
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
                do {
                    // 前台应用和 Apple Music 都不在这里采集：前者完全由 NSWorkspace
                    // 的激活通知驱动，后者由 Music.app 的 playerInfo 跨进程通知驱动、
                    // 另带一个兜底重读补上不发通知的 seek。循环只管读它们留下的
                    // snapshot —— 变化时它们会把循环叫醒，没事件时按 tickInterval 转。
                    if settings.ccusageModuleEnabled {
                        // 先刷限额：ccusage 的上传载荷要把 plan/limits 并进去，
                        // 顺序反了这一轮发出去的就是上一轮的套餐快照。
                        await agentLimits.refreshIfNeeded(
                            codexPath: settings.codexCLIPath,
                            interval: settings.agentLimitsRefreshInterval
                        )
                        await ccusage.refreshIfNeeded(
                            nodePath: settings.nodePath,
                            cliPath: settings.ccusageCLIPath,
                            interval: settings.ccusageRefreshInterval,
                            plans: agentLimits.plans,
                            limitErrors: agentLimits.limitErrors
                        )
                    }

                    // 凭据走自己的端点，不进遥测信封 —— 信封里的东西最终都会经
                    // telemetryState 流到网站的 /api/status/*，凭据不能沾那条路。
                    // 所以它也不参与下面的 anythingChanged，续期不会捎带一次遥测。
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
                    let music = settings.appleMusicModuleEnabled ? appleMusic.snapshot : nil
                    let musicSignature = music.map(AppleMusicUploadSignature.init)
                    let chargerChanged = chargerSignature != nil && chargerSignature != lastPostedCharger
                    let desktopChanged = desktopSignature != nil && desktopSignature != lastPostedDesktop
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
                    let ccusageChanged: Bool
                    if settings.ccusageModuleEnabled, let refreshedAt = ccusage.lastSuccess {
                        ccusageChanged = lastPostedCcusageAt.map { refreshedAt > $0 } ?? true
                    } else {
                        ccusageChanged = false
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
                    let musicToSend = manualMode
                        ? manualModules.contains(.appleMusic) && music != nil
                        : musicChanged
                    let ccusageToSend = manualMode
                        ? manualModules.contains(.vibeCoding) && ccusage.uploadPayload != nil
                        : ccusageChanged
                    let heartbeatDue = lastHeartbeatAt.map { Date().timeIntervalSince($0) >= 30 } ?? true
                    let dataChanged = chargerToSend || desktopToSend || musicToSend || ccusageToSend
                    /**
                     * 心跳不再借数据端点发。
                     *
                     * 从前没有数据变化时会发一个空模块的信封，接收端得先解析完整
                     * 信封才能看出「这只是一次心跳」。现在心跳走 presence 端点，
                     * 数据端点就变成纯粹的「有变化才发」。
                     *
                     * 只在没有数据要发的时候才走这条 —— 有数据时那个包本身就证明
                     * 活着，再补一条心跳是白发。
                     */
                    if heartbeatDue, !dataChanged {
                        sendPresence("online")
                        lastHeartbeatAt = Date()
                    }
                    let anythingChanged = dataChanged

                    // 播放/暂停、换歌、换前台应用是用户正盯着的事，不值得为它们等满节流窗口。
                    // 这些变化本来也会上报，即时化只是把等待砍掉，不增加请求总数；
                    // 而且同一个 envelope 会把此刻待发的充电器 / ccusage 一起捎走。
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
                    // 插拔和换设备也是用户正盯着的事，跟播放/前台应用同一档。
                    // 只认结构性指纹：功率、电压、电流的滚动照旧等节流窗口，
                    // 否则充电中每一轮都「有变化」，即时上报就退化成 5 秒一次的轮询。
                    let chargerUrgent = !manualMode && chargerStructural != nil &&
                        chargerStructural != lastPostedChargerStructural
                    // 退避期内一律不放行。否则服务端挂掉时，未推进的 lastPosted 会让
                    // urgent 一直为真，即时上报就变成每圈一次的重试风暴。
                    let urgent = (manualMode || musicUrgent || desktopUrgent || chargerUrgent) && Date() >= backoffUntil
                    let shouldPost = Date() >= backoffUntil && (manualMode || urgent || Date() >= nextPostAt)

                    if let url, anythingChanged, shouldPost {
                        let desktopPayload = desktop.map {
                            let shouldSendIcon =
                                $0.bundleIdentifier != lastPostedDesktop?.bundleIdentifier ||
                                $0.iconData != lastPostedDesktop?.iconData
                            return $0.withIconData(shouldSendIcon ? $0.iconData : nil)
                        }
                        // 封面不再由这边送：网页那边为了拿曲目链接本来就要查一次
                        // Apple Music 目录，那次查询的结果自带封面 URL。
                        let musicPayload = music
                        let envelope = makeTelemetryEnvelope(
                            charger: chargerToSend ? charger : nil,
                            desktop: desktopToSend ? desktopPayload : nil,
                            appleMusic: musicToSend ? musicPayload : nil,
                            vibeCoding: ccusageToSend ? ccusage.uploadPayload : nil,
                            includeDesktop: desktopToSend,
                            includeAppleMusic: musicToSend
                        )
                        var request = URLRequest(url: url)
                        request.httpMethod = "POST"
                        request.httpBody = try JSONCoding.encoder().encode(envelope)
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.setValue("mac-telemetry-hub/2", forHTTPHeaderField: "User-Agent")
                        if !settings.telemetrySecret.isEmpty {
                            request.setValue("Bearer \(settings.telemetrySecret)", forHTTPHeaderField: "Authorization")
                        }
                        request.timeoutInterval = timeout
                        let (_, response) = try await URLSession.shared.data(for: request)
                        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                            throw ReporterError.httpStatus(response.statusCode)
                        }
                        reporterLastSuccess = Date()
                        reporterLastError = nil
                        lastHeartbeatAt = Date()
                        if chargerToSend { lastPostedCharger = chargerSignature }
                        // 结构指纹跟着每次成功发送推进，跟 chargerChanged 无关：
                        // 结构变了完整指纹必然也变，反过来不成立。
                        if let chargerStructural { lastPostedChargerStructural = chargerStructural }
                        if desktopToSend { lastPostedDesktop = desktopSignature }
                        if musicToSend {
                            lastPostedAppleMusic = musicSignature
                            lastPostedMusicAnchor = music.map(AppleMusicPositionAnchor.init)
                        }
                        if ccusageToSend { lastPostedCcusageAt = ccusage.lastSuccess }
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

    var telemetryEnvelope: TelemetryEnvelope {
        makeTelemetryEnvelope(
            charger: settings.chargerModuleEnabled && statusPayload.updatedAt != nil ? statusPayload : nil,
            desktop: settings.desktopModuleEnabled ? desktopActivity.snapshot : nil,
            appleMusic: settings.appleMusicModuleEnabled ? appleMusic.snapshot : nil,
            vibeCoding: settings.ccusageModuleEnabled ? ccusage.uploadPayload : nil,
            includeDesktop: settings.desktopModuleEnabled,
            includeAppleMusic: settings.appleMusicModuleEnabled
        )
    }

    private func makeTelemetryEnvelope(
        charger: StatusPayload?,
        desktop: DesktopActivitySnapshot?,
        appleMusic: AppleMusicSnapshot?,
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
                vibeCoding: vibeCoding,
                includeDesktop: includeDesktop,
                includeAppleMusic: includeAppleMusic
            ),
            presence: presence
        )
    }

    /**
     * 存活声明走自己的端点，从遥测 URL 上换掉最后一段推出来。
     *
     * 跟已有的「旧版 /api/ingest/charger 自动迁移到 /telemetry」是同一种做法：
     * 用户只配一个地址，其余路由由它派生，不再多加一项设置。
     */
    private var presenceURL: URL? {
        guard let url = URL(string: settings.postURL) else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent("presence")
    }

    /// Derived from the configured telemetry URL. For example,
    /// `/api/ingest/telemetry` becomes `/api/ingest/apple-music/credentials`.
    private var appleMusicCredentialsURL: URL? {
        guard let url = URL(string: settings.postURL) else { return nil }
        return url
            .deletingLastPathComponent()
            .appendingPathComponent("apple-music")
            .appendingPathComponent("credentials")
    }

    private func uploadAppleMusicCredentials(_ credentials: AppleMusicCredentials) async throws {
        guard let url = appleMusicCredentialsURL else {
            throw ReporterError.invalidAppleMusicCredentialsURL
        }
        // 不校验 scheme：凭据跟遥测走同一个部署形态 —— 容器网络内直连，不对外
        // 暴露。在这里单独要求 HTTPS 只会让明文的本机和容器部署一条都发不出去，
        // 而它挡不住的那种对手早就在这个网络里了。
        let payload = AppleMusicCredentialsUploadPayload(
            version: 1,
            deviceID: settings.deviceID,
            musicUserToken: credentials.musicUserToken,
            developerToken: credentials.developerToken,
            expiresAt: Int(credentials.expiresAt.timeIntervalSince1970)
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONCoding.encoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("mac-telemetry-hub/2", forHTTPHeaderField: "User-Agent")
        if !settings.telemetrySecret.isEmpty {
            request.setValue("Bearer \(settings.telemetrySecret)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = settings.postTimeout
        let (_, response) = try await URLSession.shared.data(for: request)
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw ReporterError.httpStatus(response.statusCode)
        }
    }

    /**
     * 发一条只声明在线状态的请求：`{state, active_modules}`，不带任何模块数据。
     *
     * 这条是状态声明，不是数据上报，所以既不走遥测端点也不带模块 —— 混进模块
     * 会让接收端把它当成一次正常上报、白白刷新那些模块的时间戳。
     *
     * `blocking` 那条路的超时给得很短：睡眠前系统只留很窄的一个窗口，宁可这条
     * 发丢，也不能把睡眠拖住。发丢了还有心跳超时兜底，那条路本来就没拆。
     */
    private func sendPresence(_ presence: String, blocking: Bool = false) {
        guard settings.postEnabled, let url = presenceURL else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "state": presence,
            "active_modules": activeModuleNames,
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("mac-telemetry-hub/2", forHTTPHeaderField: "User-Agent")
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
        if settings.chargerModuleEnabled { names.append("charger") }
        if settings.desktopModuleEnabled { names.append("desktop") }
        if settings.appleMusicModuleEnabled { names.append("apple_music") }
        if settings.ccusageModuleEnabled { names.append("vibe_coding") }
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
         * 限额那条会静默失败 —— 凭据被拒、接口限流、token 过期，表现都只是
         * 「limits 变成空数组」，套餐等级还在（它是本地文件读的）。没有这个
         * 端点就只能靠猜。
         */
        case ("GET", "/debug/errors"):
            return encode([
                "agentLimits": agentLimits.lastError,
                "ccusage": ccusage.lastError,
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
    case invalidAppleMusicCredentialsURL
    var errorDescription: String? {
        switch self {
        case let .httpStatus(code): "POST 端点返回 HTTP \(code)"
        case .invalidAppleMusicCredentialsURL: "Apple Music 凭据上报地址无效。"
        }
    }
}

private struct AppleMusicCredentialsUploadPayload: Encodable, Sendable {
    let version: Int
    let deviceID: String
    let musicUserToken: String
    let developerToken: String
    /// developer token 的到期时刻（Unix 秒）。不是秘密，从 token 自己的 JWT 解出来的，
    /// 带上是为了让后端能在失效时给一句说得清的话，而不是干等 Apple 回 401。
    let expiresAt: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case deviceID = "device_id"
        case musicUserToken = "music_user_token"
        case developerToken = "developer_token"
        case expiresAt = "expires_at"
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
        case hasUserToken = "has_user_token"
        case lastError = "last_error"
        case lastUploadAt = "last_upload_at"
    }
}
