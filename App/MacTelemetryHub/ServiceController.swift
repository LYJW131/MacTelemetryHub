import AppKit
import Foundation

@MainActor
final class ServiceController: ObservableObject {
    let settings: AppSettings
    /// 每台设备一条独立链路：各自的 CBCentralManager、各自的配对 UUID。
    /// 连接节奏两边一样：定向连接、同一套重连和推流 watchdog。
    ///
    /// 两条链路各自存一份，`chargingLinks` 由它们拼出来 —— 从前反过来，
    /// 于是「哪条是充电头」靠 `chargingLinks[0]` 这样一个不检查的下标表达。
    let chargerLink: BluetoothService
    let powerBankLink: BluetoothService
    let chargingLinks: [BluetoothService]
    let covers: ChargerCoverController
    let desktopActivity = DesktopActivityMonitor()
    /// 窗口标题的三档规则、Jev 判断、缓存和通知。设置页和仪表盘都直接订阅它。
    let windowTitleJudge = WindowTitleJudge()
    let timeZone = TimeZoneMonitor()
    let appleMusic = AppleMusicMonitor()
    let appleMusicAuthorization = AppleMusicAuthorizationManager()
    /// 一个模块一个采集器：长间隔那份（token / 费用）和
    /// 短间隔那份（此刻在不在用）。年度热力图另走一块，间隔更长、按周切片。
    let vibeCodingUsageCollector = VibeCodingUsageMonitor()
    let codingSessions = CodingSessionMonitor()
    let vibeCodingYearCollector = VibeCodingYearMonitor()
    /// 本机推流的订阅者。ServiceController+LocalAPI 要用，所以不是 private。
    let chargingSSE = ChargingSSEBroker()
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
    /// 两个 token 本身、续期节奏、已上报记录都归它。上面三个 @Published 是 UI 状态，
    /// 留在这里 —— 转发成计算属性的话 SwiftUI 的观察会静默失效。
    let appleMusicCredentialStore: AppleMusicCredentialStore
    @Published private(set) var pendingManualReports: Set<TelemetryModule> = []
    @Published private(set) var lastManualReportError: [TelemetryModule: String] = [:]
    @Published private(set) var lastManualReportAt: [TelemetryModule: Date] = [:]

    private var reporterTask: Task<Void, Never>?
    /// 非阻塞心跳。宣告离线时先取消，避免 online 还在队列里、offline 已经返回。
    private var presenceTask: Task<Void, Never>?
    /// 图标直传在 POST 飞行期间可能作废门闩。commit 之后代次变了，作废仍然有效。
    private var desktopLatchGeneration = 0
    private var chargingLatchGeneration = 0
    private var reporterGeneration = 0
    private var tickTimer: Task<Void, Never>?
    /// vibe coding 的采集循环，跟上报循环各转各的
    private var vibeCodingCollectionTask: Task<Void, Never>?
    private var vibeCodingSessionsTask: Task<Void, Never>?
    /// 每个模块「已经发出去的是什么」。规则和推进方式都在 TelemetryCore，有单测；
    /// 重开一轮上报会话就是 `lastPosted = .init()`。
    private var lastPosted = LastPostedState()
    /// 桌面图标和充电头封面共用的那份「已确认在 R2」的记忆、重试额度、
    /// 在飞的后台解析。本机 /health 会读它的三个查询方法，所以不是 private。
    lazy private(set) var icons = IconUploadCoordinator { [weak self] message in
        self?.reporterLastError = message
    }
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
    /// 心跳间隔、追发节奏、进度容差都跟着判断逻辑搬进了 `ReportDecision`：
    /// 它们只被那段纯计算读，留在这里就得两处对照着看。

    /**
     * 前台应用的防抖窗口。
     *
     * 每收到一次激活通知就重新计时，所以连续 Cmd-Tab 只会在最后停下来的那个
     * 应用上触发一次上报 —— 路过的应用停留远不到这个时长。
     * 从前这个防抖是 2 秒采样「顺便」带来的，把延迟和防抖强度焊死成了同一个
     * 数字；拆开之后延迟降到这个量级，而防抖强度可以单独调。
     */
    private static let desktopSettleDelay = Duration.milliseconds(400)

    init() {
        let settings = AppSettings()
        self.settings = settings
        let charger = BluetoothService(settings: settings, slot: .charger)
        let powerBank = BluetoothService(settings: settings, slot: .powerBank)
        chargerLink = charger
        powerBankLink = powerBank
        chargingLinks = [charger, powerBank]
        covers = ChargerCoverController(settings: settings, chargerLink: charger)
        appleMusicCredentialStore = AppleMusicCredentialStore(authorization: appleMusicAuthorization)
    }

    deinit {
        reporterTask?.cancel()
        vibeCodingCollectionTask?.cancel()
        vibeCodingSessionsTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        // 通知的 delegate 和那个「公开」动作必须在任何一条判断回来之前装好，
        // 否则第一条「待确认」弹出来时点按钮没有落点。
        windowTitleJudge.installNotificationHandling()
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
        icons.cancelAll()
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
        presenceTask?.cancel()
        presenceTask = nil
        sendHeartbeat("offline", blocking: true)
    }

    /**
     * 拨窗口标题的总开关。
     *
     * 设置页那个 Toggle 和菜单栏那个走的都是这里：只落这一个键，只把这一件事
     * 推给 judge。不走整页 `applySettings()` —— 那会连带把设置页里还没保存的
     * 黑名单、三条线一起应用，而菜单栏上拨一下不该有这种副作用。
     *
     * `judge.setReportingEnabled` 里的 `configure` 末尾会叫 `onVerdict`，桌面
     * 监视器立刻重采一次：关掉时远端马上收到一条 null 标题，开回来时当场开始
     * 判断，不用等下一次标题变化。
     */
    func setWindowTitleReporting(_ enabled: Bool) {
        guard settings.windowTitleReportingEnabled != enabled else { return }
        settings.persistWindowTitleReporting(enabled)
        windowTitleJudge.setReportingEnabled(enabled)
    }

    func applySettings() throws {
        let previousReporter = reporterRestartKey
        let previousCoding = codingScheduleKey
        let previousIcons = iconUploadKey
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
        // 黑名单、窗口标题的三档规则和 TypeSafe key、HTTP 端口都**不**进
        // ReporterRestartKey：重开会话会把已确认的图标和已经发出去的门闩一起
        // 擦掉，对端再收一整轮「首次」信封。标题规则改了只要重判一次，
        // 由 configureModules 里的 judge.configure 顺手完成。
        configureModules(restartCodingCollection: previousCoding != codingScheduleKey)
        if previousIcons != iconUploadKey {
            icons.reset()
            desktopLatchGeneration += 1
            chargingLatchGeneration += 1
            lastPosted.desktop = nil
            lastPosted.chargingDevices = nil
            lastPosted.chargingContent = nil
            wakeReporter()
        }
        if previousReporter != reporterRestartKey {
            restartReporter()
        }
    }

    /// 改了这些才需要把上报会话从头发一遍。
    private var reporterRestartKey: ReporterRestartKey {
        ReporterRestartKey(
            postEnabled: settings.postEnabled,
            postURL: settings.postURL,
            telemetryClientID: settings.telemetryClientID,
            telemetrySecret: settings.telemetrySecret,
            postInterval: settings.postInterval,
            postTimeout: settings.postTimeout,
            chargerModuleEnabled: settings.chargerModuleEnabled,
            powerBankModuleEnabled: settings.powerBankModuleEnabled,
            desktopModuleEnabled: settings.desktopModuleEnabled,
            appleMusicModuleEnabled: settings.appleMusicModuleEnabled,
            timezoneModuleEnabled: settings.timezoneModuleEnabled,
            vibeCodingModuleEnabled: settings.vibeCodingModuleEnabled,
            userID: settings.userID
        )
    }

    private var codingScheduleKey: CodingScheduleKey {
        CodingScheduleKey(
            enabled: settings.vibeCodingModuleEnabled,
            cliPath: settings.ccusageCLIPath,
            sessionInterval: settings.codingSessionRefreshInterval,
            usageInterval: settings.vibeCodingUsageRefreshInterval,
            yearInterval: settings.vibeCodingYearRefreshInterval
        )
    }

    private var iconUploadKey: IconUploadKey {
        IconUploadKey(
            endpoint: settings.r2Endpoint,
            bucket: settings.r2Bucket,
            accessKeyID: settings.r2AccessKeyID,
            secretAccessKey: settings.r2SecretAccessKey
        )
    }

    /// 把一个模块排进「立刻发一封只带它的信封」的队列。
    /// 真正发请求的仍然只有那条常规上报循环，这里不另开网络路径。
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

    /// 这份快照的应用是否命中前台上报黑名单。空快照按未命中处理。
    /// 判断散在四处过，全部收到这里 —— 黑名单的语义只该有一个落点。
    private func isDesktopReportingBlocked(_ snapshot: DesktopActivitySnapshot?) -> Bool {
        settings.isDesktopReportingBlocked(bundleIdentifier: snapshot?.bundleIdentifier)
    }

    var currentDesktopReportingIsBlocked: Bool {
        isDesktopReportingBlocked(desktopActivity.snapshot)
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
     * 授权和取 token 都在 AppleMusicCredentialStore 里；这里只管按钮的三个
     * UI 状态，以及授权成功后叫醒循环。网络请求仍只有主循环那一条路径。
     */
    func authorizeAppleMusic() async {
        guard !isUploadingAppleMusicCredentials else { return }
        isUploadingAppleMusicCredentials = true
        appleMusicCredentialsUploadError = nil
        defer { isUploadingAppleMusicCredentials = false }

        switch await appleMusicCredentialStore.authorize() {
        case let .failed(message):
            appleMusicCredentialsUploadError = message
        case let .ready(error):
            appleMusicCredentialsUploadError = error
            guard settings.postEnabled else {
                appleMusicCredentialsUploadError = "Apple Music 已授权；开启远端上报后会自动发送 token。"
                return
            }
            wakeReporter()
        }
    }

    /// 循环每圈问一次「该不该重读 token」。门闩、退避、不让旧的顶掉新的都在
    /// store 里，这里只把结果落到 UI 的错误文案上。
    private func refreshAppleMusicCredentialsIfNeeded() async {
        switch await appleMusicCredentialStore.refreshIfNeeded() {
        case .skipped: break
        case let .failed(message): appleMusicCredentialsUploadError = message
        case .refreshed: appleMusicCredentialsUploadError = nil
        }
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
            // 黑名单前台仍然要发一次隐藏态，和 ReportDecision.hasPayload 同一套。
            desktopActivity.snapshot != nil
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

    /// slot 到链路的唯一映射。加第三台设备时这里跟着 enum 一起加一个 case。
    func link(for slot: ChargingDeviceSlot) -> BluetoothService {
        switch slot {
        case .charger: chargerLink
        case .powerBank: powerBankLink
        }
    }

    /**
     * 所有已启用、且真的收到过遥测的充电设备。一台都没有就返回 nil，
     * 上报信封里那个键整个不出现。
     *
     * 这条路是纯读取：不启动 R2 resolver、不动重试额度。SSE 推流每秒都要走它，
     * 从前顺手启动的后台解析于是被 1 Hz 驱动着跑。发起解析改由上报侧的
     * `kickCoverIconResolution()` 显式负责。
     */
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
            let key = confirmedCoverIconObjectKey(covers.coverUploadSource)
            device = device.withCover(covers.coverPayload(objectKey: key))
        }
        return device
    }

    /// 组装待上报载荷之前叫一次：封面还没确认就在后台 HEAD / PUT。
    /// 条件跟从前埋在 `devicePayload(for:)` 里的那次完全一致。
    private func kickCoverIconResolution() {
        guard ChargingDeviceSlot.charger.isEnabled(settings),
              chargerLink.devicePayload != nil,
              let source = covers.coverUploadSource else { return }
        startCoverIconResolution(source)
    }

    /// SSE 订阅时的首帧由 ServiceController+LocalAPI 发，所以不是 private。
    func streamEvent(for link: BluetoothService) -> ChargingStreamEvent {
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
    private struct ReporterRestartKey: Equatable {
        var postEnabled: Bool
        var postURL: String
        var telemetryClientID: String
        var telemetrySecret: String
        var postInterval: Double
        var postTimeout: Double
        var chargerModuleEnabled: Bool
        var powerBankModuleEnabled: Bool
        var desktopModuleEnabled: Bool
        var appleMusicModuleEnabled: Bool
        var timezoneModuleEnabled: Bool
        var vibeCodingModuleEnabled: Bool
        var userID: String
    }

    private struct CodingScheduleKey: Equatable {
        var enabled: Bool
        var cliPath: String
        var sessionInterval: Double
        var usageInterval: Double
        var yearInterval: Double
    }

    private struct IconUploadKey: Equatable {
        var endpoint: String
        var bucket: String
        var accessKeyID: String
        var secretAccessKey: String
    }

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
            guard signature != lastPosted.chargingStructural else { return }
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
    private func waitForNextTick(since cycleStart: ContinuousClock.Instant, generation: Int) async {
        if pendingWake {
            pendingWake = false
            return
        }
        let elapsed = ContinuousClock.now - cycleStart
        let remaining = Self.tickInterval - elapsed
        guard remaining > .zero else { return }
        tickTimer?.cancel()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            // 被 cancel 说明已经有事件把循环叫醒了，别再多放行一次。
            // 代次对不上说明这是上一轮会话留下的定时器。
            guard !Task.isCancelled, let self, self.reporterGeneration == generation else { return }
            self.wakeReporter()
        }
        tickTimer = timer
        await withCheckedContinuation { continuation in
            wakeContinuation = continuation
        }
        timer.cancel()
    }

    private func configureModules(restartCodingCollection: Bool = true) {
        for link in chargingLinks {
            configure(link: link)
        }
        covers.onChange = { [weak self] in self?.wakeReporter() }

        desktopActivity.judge = windowTitleJudge
        windowTitleJudge.onVerdict = { [weak self] in
            // 判断回来之后重采一次：标题进了快照，走的还是原来那条
            // 「快照变化 → 400ms 防抖 → 叫醒上报循环」。
            self?.desktopActivity.refreshAfterJudgment()
        }
        windowTitleJudge.configure(WindowTitleJudge.Rules(
            reportingEnabled: settings.windowTitleReportingEnabled,
            blacklist: settings.normalizedWindowTitleBlacklist,
            trusted: settings.normalizedWindowTitleTrustedApplications,
            // 远端隐藏的应用一条标题都不许送去 TypeSafe。
            hiddenApplications: settings.normalizedDesktopReportingBlacklist,
            apiKey: settings.typesafeAPIKey,
            thresholds: settings.windowTitleJudgmentThresholds
        ))

        if settings.desktopModuleEnabled {
            // 每次激活都重排，连续 Cmd-Tab 只在最后停下的那个应用上叫醒一次。
            // 开着远端上报时，图标在这 400ms 里先走后台 resolver；名称上报不等它。
            desktopActivity.onChange = { [weak self] in
                guard let self else { return }
                desktopSettleTask?.cancel()
                if settings.postEnabled,
                   let snapshot = desktopActivity.snapshot,
                   !isDesktopReportingBlocked(snapshot) {
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
            if restartCodingCollection || vibeCodingCollectionTask == nil {
                startVibeCodingCollection()
            }
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
                // 先刷新持久账本，再从同一份数据生成年度图：完整采集一跑完就重算，
                // 不必再等年度图自己的间隔
                let fullRound = await self.vibeCodingUsageCollector.refreshIfNeeded(
                    ccusageCLIPath: settings.ccusageCLIPath,
                    interval: settings.vibeCodingUsageRefreshInterval,
                    fullInterval: settings.vibeCodingYearRefreshInterval
                )
                if fullRound {
                    await self.vibeCodingYearCollector.refreshNow()
                } else {
                    await self.vibeCodingYearCollector.refreshIfNeeded(
                        interval: settings.vibeCodingYearRefreshInterval
                    )
                }
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
        reporterGeneration += 1
        reporterTask?.cancel()
        // 旧循环可能还挂在等待上，先放行让它认领 cancel 并退出
        wakeReporter()
        reporterTask = nil
        // 上一轮的 tick 定时器不属于新会话，否则它会在 pendingWake 清掉之后再置上。
        tickTimer?.cancel()
        tickTimer = nil
        // 上一轮遗留的唤醒标记不能带进新循环，否则第一圈会白转一次
        pendingWake = false
        reporterLastError = nil
        lastPosted = .init()
        icons.reset()
        // 每个上报会话都完整发一次，之后两个 token 才分别判变。
        appleMusicCredentialStore.resetPostedTokens()
        pendingManualReports.removeAll()
        lastManualReportError.removeAll()
        let url = settings.postEnabled ? URL(string: settings.postURL) : nil
        let interval = settings.postInterval
        let timeout = settings.postTimeout
        let generation = reporterGeneration
        reporterTask = Task { [weak self] in
            guard let self else { return }
            var nextPostAt = Date.distantPast
            /// 上报失败后的退避截止时刻，只用来挡住即时上报的绕行
            var backoffUntil = Date.distantPast
            /// 充电设备追发还剩几次、下一次什么时候到点
            var chargingBurst = ChargingBurstState()
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
                    // 封面对象的后台解析由上报侧显式发起。读载荷的那条路是纯的，
                    // 1 Hz 的 SSE 推流不会再顺手启动 resolver、也不会动重试额度。
                    kickCoverIconResolution()
                    /**
                     * 一次性把这一圈要看的东西全捕获下来。
                     *
                     * 从这里到 POST 之间没有挂起点，所以「判断依据」和「实际发出去
                     * 的内容」必然是同一份 —— 从前这靠一长串同名局部变量维持，现在
                     * 靠这个快照。判断本身（发什么、发不发、急不急）搬进了
                     * `ReportDecision`：纯函数，规则可以被单测直接钉住。
                     */
                    let capturedDesktop = settings.desktopModuleEnabled
                        ? desktopActivity.snapshot : nil
                    // POST 飞行期间可能又刷了一次 token，notePosted 要的是这一份。
                    let credentials = appleMusicCredentialStore.credentials
                    let inputs = ReportInputs(
                        now: Date(),
                        suspended: suspended,
                        appleMusicModuleEnabled: settings.appleMusicModuleEnabled,
                        vibeCodingModuleEnabled: settings.vibeCodingModuleEnabled,
                        charger: chargingDevicesPayload,
                        capturedDesktop: capturedDesktop,
                        desktopBlocked: isDesktopReportingBlocked(capturedDesktop),
                        timezone: settings.timezoneModuleEnabled ? timeZone.snapshot : nil,
                        music: settings.appleMusicModuleEnabled ? appleMusic.snapshot : nil,
                        credentials: credentials.map {
                            AppleMusicCredentialsSnapshot(musicUserToken: $0.musicUserToken)
                        },
                        musicUserTokenChanged: appleMusicCredentialStore.musicUserTokenChanged,
                        vibeCodingUsagePayload: vibeCodingUsageCollector.uploadPayload,
                        vibeCodingNowPayload: codingSessions.uploadPayload,
                        vibeCodingYearPayload: vibeCodingYearCollector.uploadPayload,
                        vibeCodingUsageUpdatedAt: vibeCodingUsageCollector.payloadUpdatedAt,
                        vibeCodingNowUpdatedAt: codingSessions.payloadUpdatedAt,
                        vibeCodingYearUpdatedAt: vibeCodingYearCollector.payloadUpdatedAt,
                        manualModules: pendingManualReports
                    )
                    let decision = ReportDecision(
                        inputs: inputs,
                        lastPosted: lastPosted,
                        backoffUntil: backoffUntil,
                        nextPostAt: nextPostAt,
                        chargingBurst: chargingBurst
                    )
                    // 追发到点就扣，不管这一圈最后有没有真发出去（比如退避期内）。
                    chargingBurst = decision.chargingBurst
                    manualModulesForAttempt = decision.manualModules
                    // 按下按钮之后数据才消失的（切进黑名单、蓝牙断了）当场摘掉。
                    // 摘不掉的话 pending 只会在真发出去时才清，于是 manualMode
                    // 一直为真、自动上报全被挡住，按钮永远停在「正在上报…」。
                    if !decision.unsatisfiableManualModules.isEmpty {
                        pendingManualReports.subtract(decision.unsatisfiableManualModules)
                        for module in decision.unsatisfiableManualModules {
                            lastManualReportError[module] = "该模块此刻没有可上报的数据"
                        }
                    }

                    if decision.shouldSendHeartbeat {
                        sendHeartbeat("online")
                        lastPosted.heartbeatAt = inputs.now
                    }

                    if let url, decision.dataChanged, decision.shouldPost {
                        let desktopGeneration = desktopLatchGeneration
                        let chargingGeneration = chargingLatchGeneration
                        let desktopPayload: DesktopActivitySnapshot?
                        if inputs.desktopBlocked, let capturedDesktop = inputs.capturedDesktop {
                            desktopPayload = .hidden(observedAt: capturedDesktop.observedAt)
                        } else if let desktop = inputs.desktop {
                            // 名称不等图标：对象已经确认好就顺手带上，否则先发无图状态，
                            // 后台 resolver 成功后再叫醒一轮补对象键。
                            let iconObjectKey = desktopIconObjectKeyIfReady(desktop)
                            desktopPayload = desktop.withIconData(nil, iconObjectKey: iconObjectKey)
                        } else {
                            desktopPayload = nil
                        }
                        // 封面不再由这边送：网页那边为了拿曲目链接本来就要查一次
                        // Apple Music 目录，那次查询的结果自带封面 URL。
                        // 三份 vibe coding 载荷和它们的更新时刻都在 inputs 里 ——
                        // POST 等待期间可以继续采集，成功只确认这封信实际携带的版本。
                        let envelope = TelemetryEnvelope.make(
                            chargingDevices: decision.chargerToSend ? inputs.charger : nil,
                            desktop: decision.desktopToSend ? desktopPayload : nil,
                            timezone: decision.timezoneToSend ? inputs.timezone : nil,
                            appleMusic: decision.musicToSend ? inputs.music : nil,
                            appleMusicCredentials: decision.credentialsToSend,
                            vibeCodingUsage: decision.usageToSend ? inputs.vibeCodingUsagePayload : nil,
                            vibeCodingNow: decision.nowToSend ? inputs.vibeCodingNowPayload : nil,
                            vibeCodingYear: decision.yearToSend ? inputs.vibeCodingYearPayload : nil,
                            includeDesktop: decision.desktopToSend,
                            includeAppleMusic: decision.musicToSend,
                            activeModules: activeModuleNames,
                            now: inputs.now
                        )
                        let request = TelemetryPoster.request(
                            url: url,
                            body: try JSONCoding.encoder().encode(envelope),
                            clientID: settings.telemetryClientID,
                            secret: settings.telemetrySecret,
                            timeout: timeout
                        )
                        attemptedAppleMusicCredentials = decision.credentialsToSend != nil
                        let responsePayload = try await TelemetryPoster.post(request)
                        try Task.checkCancellation()
                        if decision.desktopToSend, responsePayload.data.desktopIconAvailable == nil {
                            throw ReporterError.invalidTelemetryResponse
                        }
                        reporterLastSuccess = Date()
                        reporterLastError = nil
                        // 门闩推进是纯的；余下三件要读此刻的活状态（封面来源、已确认
                        // 的图标记忆）或动后台 resolver，只能留在主 actor 上。
                        let effects = lastPosted.commit(
                            decision: decision,
                            response: responsePayload.data,
                            desktopPayloadHasObjectKey: desktopPayload?.iconObjectKey != nil
                        )
                        // 飞行期间图标回调清过门闩的话，commit 会把它写回去。代次变了就再清一次。
                        if desktopLatchGeneration != desktopGeneration {
                            lastPosted.desktop = nil
                        }
                        if chargingLatchGeneration != chargingGeneration {
                            lastPosted.chargingDevices = nil
                            lastPosted.chargingContent = nil
                        }
                        if effects.coverIconRejected,
                           let source = covers.coverUploadSource,
                           let iconHash = source.iconHash {
                            if effects.sentCoverHadObjectKey { icons.forget(iconHash) }
                            startCoverIconResolution(source)
                            if icons.isConfirmed(iconHash) {
                                chargingLatchGeneration += 1
                                lastPosted.chargingDevices = nil
                                lastPosted.chargingContent = nil
                                wakeReporter()
                            }
                        }
                        if let rejected = effects.desktopIconRejected,
                           let iconHash = rejected.iconHash {
                            if desktopPayload?.iconObjectKey != nil {
                                // 兼容服务端今后恢复对象校验：带了键仍返回 false，说明
                                // 这份本地“已上传”记忆失效，后台重新 HEAD/PUT。
                                icons.forget(iconHash)
                            }
                            startDesktopIconResolution(rejected)
                            // resolver 可能在 POST 飞行期间已经完成；补上那次竞态唤醒。
                            if icons.isConfirmed(iconHash) {
                                desktopLatchGeneration += 1
                                lastPosted.desktop = nil
                                wakeReporter()
                            }
                        }
                        if let iconHash = effects.desktopIconConfirmed?.iconHash {
                            icons.remember(iconHash)
                        }
                        if decision.credentialsToSend != nil {
                            appleMusicCredentialStore.notePosted(credentials)
                            appleMusicCredentialsUploadAt = Date()
                            appleMusicCredentialsUploadError = nil
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
                await waitForNextTick(since: cycleStart, generation: generation)
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
        return icons.objectKeyIfConfirmed(hash: iconHash, data: iconData, ext: "png")
    }

    /**
     * 桌面图标的直传由 coordinator 跑，这里只提供成功之后那件跟桌面有关的事。
     *
     * 两个条件缺一不可：门闩里那份说明网页收到的正是这个应用的无图版本，
     * 而当前前台应用仍是它说明补发不会发出一个用户早就切走的应用。少了后一个
     * 条件就是历史上那次热循环 —— 门闩清成 nil、循环被叫醒、发出旧应用、
     * resolver 再触发，来回打转。
     *
     * 比的是 `identity` 而不是整份签名：窗口标题也在签名里，而它在这段上传
     * 期间本来就会变（判断回来了、用户切了标签页）。拿整份比的话，补对象键
     * 那一下会在恰好上传期间换了标题时永远不触发，图标停在无图版本。
     */
    private func startDesktopIconResolution(_ desktop: DesktopActivitySnapshot) {
        guard settings.postEnabled,
              let iconHash = desktop.iconHash,
              let iconData = desktop.iconData,
              let r2Configuration = settings.r2UploadConfiguration else {
            return
        }

        let identity = DesktopUploadSignature(desktop).identity
        icons.resolve(
            kind: .desktop,
            hash: iconHash,
            data: iconData,
            ext: "png",
            configuration: r2Configuration,
            timeout: min(settings.postTimeout, 3)
        ) { [weak self] in
            guard let self else { return }
            // resolver 早于首包完成时，400ms 防抖会自然把键带上，不额外叫醒。
            // 只有无图版本已经成功发过，才需要补发同一应用的对象键。
            guard lastPosted.desktop?.identity == identity,
                  desktopActivity.snapshot.map({ DesktopUploadSignature($0).identity }) == identity else {
                return
            }
            desktopLatchGeneration += 1
            lastPosted.desktop = nil
            wakeReporter()
        }
    }

    /// 已经确认在 R2 的封面对象键；没确认好就是 nil。纯读取，不发起解析。
    private func confirmedCoverIconObjectKey(_ source: CoverUploadSource?) -> String? {
        guard let source, let iconHash = source.iconHash, let iconData = source.iconData else {
            return nil
        }
        return icons.objectKeyIfConfirmed(hash: iconHash, data: iconData, ext: "jpg")
    }

    /**
     * 封面的直传同样由 coordinator 跑，成功之后这件事跟桌面图标不一样。
     *
     * 桌面比的是「此刻的前台应用」，封面比的是「上一次发出去的那张封面」——
     * 封面不会像前台应用那样被用户随手切走，能跑到这里就说明网页手上那份
     * 无图版本还是当前这张，只差一个对象键。
     */
    private func startCoverIconResolution(_ source: CoverUploadSource) {
        guard settings.postEnabled,
              let iconHash = source.iconHash,
              let iconData = source.iconData,
              let r2Configuration = settings.r2UploadConfiguration else {
            return
        }

        icons.resolve(
            kind: .cover,
            hash: iconHash,
            data: iconData,
            ext: "jpg",
            configuration: r2Configuration,
            timeout: min(settings.postTimeout, 3)
        ) { [weak self] in
            guard let self,
                  lastPostedChargerCover(hash: iconHash, hasObjectKey: false) else { return }
            chargingLatchGeneration += 1
            lastPosted.chargingDevices = nil
            lastPosted.chargingContent = nil
            wakeReporter()
        }
    }

    private func lastPostedChargerCover(hash: String, hasObjectKey: Bool) -> Bool {
        guard let cover = lastPosted.chargingDevices?.devices.first(where: { $0.kind == .charger })?.cover
        else { return false }
        return cover.iconHash == hash && (cover.iconObjectKey != nil) == hasObjectKey
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
        let body = (try? JSONCoding.encoder().encode(
            TelemetryEnvelope.make(
                includeDesktop: false,
                includeAppleMusic: false,
                activeModules: activeModuleNames,
                now: Date(),
                presence: presence
            )
        )) ?? Data()
        let request = TelemetryPoster.request(
            url: url,
            body: body,
            clientID: settings.telemetryClientID,
            secret: settings.telemetrySecret,
            timeout: 3
        )

        guard blocking else {
            presenceTask?.cancel()
            presenceTask = TelemetryPoster.send(request)
            return
        }
        // 睡眠和退出必须同步等。观察者返回后系统就接着睡了，异步任务来不及跑完。
        // 上限 3 秒，URLSession 的回调在后台队列，不会和主线程互锁。
        TelemetryPoster.sendBlocking(request)
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
}
