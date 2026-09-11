import Foundation

#if TELEMETRY_CORE_SPM
import ChargerTelemetryKit
#endif

/**
 * 一个模块的手动上报最终落到信封里的哪一格载荷。
 *
 * 模块和载荷不是一一对应的：充电头和充电宝共用 `chargingDevices` 那一格。
 * 从前手写的 switch 只认 `.charger`，于是点「立刻上报充电宝」什么都不会发，
 * 而 pending 只在发出去之后才清 —— 结果是永远清不掉，manualMode 一直为真，
 * 所有自动上报被挡住，按钮停在「正在上报…」直到重新保存设置。
 *
 * 加设备、加模块时改这里，不要再展开一遍 switch。
 */
enum ReportPayloadKind: Hashable, Sendable {
    case chargingDevices
    case desktop
    case timezone
    case appleMusic
    case vibeCoding
    case vibeCodingYear
}

extension TelemetryModule {
    var payloadKind: ReportPayloadKind {
        switch self {
        case .desktop: .desktop
        case .appleMusic: .appleMusic
        case .charger, .powerBank: .chargingDevices
        case .timezone: .timezone
        case .vibeCoding: .vibeCoding
        case .vibeCodingYear: .vibeCodingYear
        }
    }
}

/**
 * 上报循环这一圈的输入快照。
 *
 * 全部在主 actor 上一次性捕获：从捕获到发出去中间没有挂起点，所以这一圈里
 * 「判断用的值」和「实际发出去的值」必然是同一份。判断逻辑因此可以是纯的 ——
 * 它只看这份快照和上一次发出去的门闩，不再自己去问 monitor 和 settings。
 *
 * 模块开关的过滤发生在捕获侧：关掉的模块这里直接是 nil，判断不必再问一次。
 * 只有两处例外留了显式开关 —— 音乐要区分「关了」和「停了」（后者要发一次
 * null），vibe coding 的三份摘要按更新时刻判变、拿不到开关就没法短路。
 */
struct ReportInputs: Sendable {
    var now: Date = .distantPast
    /// 已宣告离线。跳过不丢东西：门闩没推进，醒来那一下仍然是 urgent。
    var suspended = false

    var appleMusicModuleEnabled = false
    var vibeCodingModuleEnabled = false

    var charger: ChargingDevicesPayload?
    /// 黑名单过滤**之前**的前台应用快照。三态判断要靠它区分「没有前台应用」
    /// 和「前台应用被黑名单挡住了」。
    var capturedDesktop: DesktopActivitySnapshot?
    var desktopBlocked = false
    var timezone: TimeZoneSnapshot?
    var music: AppleMusicSnapshot?

    var credentials: AppleMusicCredentialsSnapshot?
    var musicUserTokenChanged = false

    var vibeCodingUsagePayload: JSONValue?
    var vibeCodingNowPayload: JSONValue?
    var vibeCodingYearPayload: JSONValue?
    var vibeCodingUsageUpdatedAt: Date?
    var vibeCodingNowUpdatedAt: Date?
    var vibeCodingYearUpdatedAt: Date?

    var manualModules: Set<TelemetryModule> = []

    /// 黑名单只切断远端载荷；monitor 的本机快照继续保留给界面和本地 API。
    var desktop: DesktopActivitySnapshot? { desktopBlocked ? nil : capturedDesktop }

    var chargerStructural: ChargingDevicesStructuralSignature? {
        charger.map(ChargingDevicesStructuralSignature.init)
    }
    var desktopSignature: DesktopUploadSignature? { desktop.map(DesktopUploadSignature.init) }
    var timezoneSignature: TimeZoneUploadSignature? { timezone.map(TimeZoneUploadSignature.init) }
    var musicSignature: AppleMusicUploadSignature? { music.map(AppleMusicUploadSignature.init) }
}

/**
 * 手里那份 Apple Music user token。
 *
 * App 那侧的 `AppleMusicCredentials` 拖着 MusicKit，判断逻辑用不上；这里只留
 * 信封真正要写出去的那一个值。developer token 由 Worker 自己签，不经过这里。
 */
struct AppleMusicCredentialsSnapshot: Equatable, Sendable {
    let musicUserToken: String

    init(musicUserToken: String) {
        self.musicUserToken = musicUserToken
    }
}

/**
 * 充电设备结构变化后的追发排期。
 *
 * 插上负载的头几十秒功率还在剧烈变化 —— PD 协商完成、设备自己调整取电，
 * 都要一会儿才稳。即时上报只发出去插拔那一瞬间的那一帧，那一帧往往还是
 * 0W 或者一个中间值，然后要等满一个节流窗口（本机 30 秒）才更新，站点上
 * 就会挂着一个明显不对的读数。
 *
 * 所以结构变化后按这个节奏追发几次。次数是有限的：功率滚动本来就该等节流
 * 窗口，追发只是覆盖「刚接入」这段不稳定期，不是把上报变成 5 秒一次的轮询。
 */
struct ChargingBurstState: Equatable, Sendable {
    var remaining = 0
    var dueAt: Date = .distantPast

    init(remaining: Int = 0, dueAt: Date = .distantPast) {
        self.remaining = remaining
        self.dueAt = dueAt
    }
}

/**
 * 这一圈发什么、发不发、急不急。
 *
 * 从上报循环里抽出来的唯一理由是它能被单独钉住：黑名单三态、进度容差、
 * 追发计数、退避期不放行 —— 这些规则从前只存在于一段两百行的循环体里，
 * 改动它们只能靠通读。现在它们是一个纯函数，测试直接喂快照。
 */
struct ReportDecision: Sendable {
    /// 进度偏离预测多少才算被拖过。留 2.5 秒，既不会把采样抖动当 seek，
    /// 也接得住真的拖动。
    static let musicSeekToleranceMs = 2_500
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
    static let heartbeatInterval: TimeInterval = 90
    static let chargingBurstInterval: TimeInterval = 5
    static let chargingBurstCount = 5

    /// 判断所依据的那份快照。commit 要照它推进门闩，所以跟着决定一起走。
    let inputs: ReportInputs

    var chargerToSend = false
    var desktopToSend = false
    var timezoneToSend = false
    var musicToSend = false
    var usageToSend = false
    var nowToSend = false
    var yearToSend = false
    var credentialsToSend: AppleMusicCredentialsPayload?

    /// 这一圈实际按手动上报处理的模块。成功或失败后从 pending 里摘掉的就是它们。
    var manualModules: Set<TelemetryModule> = []
    /**
     * 用户点了、但此刻这一格载荷是空的，怎么发都发不出去。
     *
     * 调用方必须当场把它们从 pending 里摘掉并写一句错误 —— 留着的话
     * manualMode 会一直为真，自动上报全被挡住。按下按钮时 canRequestImmediateReport
     * 已经查过有没有数据，所以进到这里的都是那之后才消失的：前台应用切进了
     * 黑名单、蓝牙断了、采集器把载荷清了。
     */
    var unsatisfiableManualModules: Set<TelemetryModule> = []
    var manualMode: Bool { !manualModules.isEmpty }

    var dataChanged = false
    var urgent = false
    var shouldPost = false
    /// 这一圈该不该补一条纯心跳。
    var shouldSendHeartbeat = false
    /// 扣过之后的追发状态。到点就扣，不管这一圈最后有没有真发出去。
    var chargingBurst = ChargingBurstState()

    /**
     * 算出这一圈的决定。
     *
     * `backoffUntil` / `nextPostAt` / `chargingBurst` 是循环自己攒的节奏状态，
     * 由调用方带进来；追发状态算完要写回去（见 `chargingBurst`）。
     */
    init(
        inputs: ReportInputs,
        lastPosted: LastPostedState,
        backoffUntil: Date,
        nextPostAt: Date,
        chargingBurst: ChargingBurstState
    ) {
        self.inputs = inputs
        let now = inputs.now
        let charger = inputs.charger
        let chargerStructural = inputs.chargerStructural
        let desktop = inputs.desktop
        let desktopSignature = inputs.desktopSignature
        let timezone = inputs.timezone
        let timezoneSignature = inputs.timezoneSignature
        let music = inputs.music
        let musicSignature = inputs.musicSignature

        let chargerChanged = charger != nil && charger != lastPosted.chargingDevices
        // 三态：没有前台应用 / 命中黑名单（只发一次虚拟应用）/ 正常身份变化。
        // 单靠 Optional 分不出「尚未发过」和「已发隐藏态」，所以另有一个标志位。
        let desktopChanged = inputs.capturedDesktop != nil && (
            inputs.desktopBlocked
                ? !lastPosted.desktopWasHidden
                : desktopSignature != nil && (
                    lastPosted.desktopWasHidden || desktopSignature != lastPosted.desktop
                )
        )
        let timezoneChanged = timezoneSignature != nil && timezoneSignature != lastPosted.timeZone
        // 进度不参与变化判断，只在它偏离网页的预测值时才重新对锚点，
        // 否则播放中每一轮都会「有变化」，按需上报就退化成了定时轮询。
        // 单曲循环时 trackID 不变，靠进度跳回开头被这里认出来。
        let musicSeeked = music.map {
            guard let anchor = lastPosted.musicAnchor else { return true }
            let drift = $0.positionMs - anchor.predicted(at: $0.observedAt)
            return abs(drift) > Self.musicSeekToleranceMs
        } ?? false
        // snapshot 从有值变成 nil 时也要发送一次 null，避免网页保留旧歌曲。
        let musicChanged = inputs.appleMusicModuleEnabled &&
            (musicSignature != lastPosted.appleMusic || musicSeeked)
        /// 两个模块各判各的变化。门闩看的是载荷**变化**的时刻而不是采集
        /// 成功的时刻 —— 会话状态 60 秒扫一次，绝大多数轮次什么都没变，拿
        /// lastSuccess 当门闩会把每一轮扫描都变成一次上报。
        let vibeCodingEnabled = inputs.vibeCodingModuleEnabled
        func vibeCodingChanged(_ updatedAt: Date?, _ lastPostedAt: Date?) -> Bool {
            guard vibeCodingEnabled, let updatedAt else { return false }
            return lastPostedAt.map { updatedAt > $0 } ?? true
        }
        let usageChanged = vibeCodingChanged(
            inputs.vibeCodingUsageUpdatedAt, lastPosted.vibeCodingUsageAt
        )
        let nowChanged = vibeCodingChanged(
            inputs.vibeCodingNowUpdatedAt, lastPosted.vibeCodingNowAt
        )
        let yearChanged = vibeCodingChanged(
            inputs.vibeCodingYearUpdatedAt, lastPosted.vibeCodingYearAt
        )

        /// 这一格此刻有没有东西可发。手动上报的可满足性只看这个。
        func hasPayload(_ kind: ReportPayloadKind) -> Bool {
            switch kind {
            case .chargingDevices: charger != nil
            case .desktop: desktop != nil
            case .timezone: timezone != nil
            case .appleMusic: music != nil
            // 两份任一有值就能发：用量还没采到时，「此刻在不在用」也值得单独发
            case .vibeCoding:
                inputs.vibeCodingUsagePayload != nil || inputs.vibeCodingNowPayload != nil
            case .vibeCodingYear: inputs.vibeCodingYearPayload != nil
            }
        }
        // 发不出去的当场摘掉，剩下的才算这一圈的手动上报。全都发不出去时
        // manualMode 直接为假，这一圈照常走自动判断，不白白空转一个 tick。
        unsatisfiableManualModules = inputs.manualModules.filter { !hasPayload($0.payloadKind) }
        let manualModules = inputs.manualModules.subtracting(unsatisfiableManualModules)
        self.manualModules = manualModules
        let manualMode = !manualModules.isEmpty
        let manualKinds = Set(manualModules.map(\.payloadKind))
        // 手动上报有意只发用户选中的那个模块。自动攒下的变化留给下一轮
        // 常规上报，不搭这封信的便车。
        chargerToSend = manualMode ? manualKinds.contains(.chargingDevices) : chargerChanged
        desktopToSend = manualMode ? manualKinds.contains(.desktop) : desktopChanged
        timezoneToSend = manualMode ? manualKinds.contains(.timezone) : timezoneChanged
        musicToSend = manualMode ? manualKinds.contains(.appleMusic) : musicChanged
        // 手动上报按整个 vibe coding 走：信封只有一个，用量和此刻
        // 手上有什么就一起发什么。年度热力图间隔不同，单独一门。
        let manualVibeCoding = manualKinds.contains(.vibeCoding)
        usageToSend = manualMode
            ? manualVibeCoding && inputs.vibeCodingUsagePayload != nil
            : usageChanged
        nowToSend = manualMode
            ? manualVibeCoding && inputs.vibeCodingNowPayload != nil
            : nowChanged
        yearToSend = manualMode ? manualKinds.contains(.vibeCodingYear) : yearChanged
        // 手动上报只发用户选中的模块；token 的自动变化留到下一轮。
        if !manualMode, let credentials = inputs.credentials, inputs.musicUserTokenChanged {
            credentialsToSend = AppleMusicCredentialsPayload(musicUserToken: credentials.musicUserToken)
        } else {
            credentialsToSend = nil
        }

        let heartbeatDue = lastPosted.heartbeatAt
            .map { now.timeIntervalSince($0) >= Self.heartbeatInterval } ?? true
        dataChanged = chargerToSend || desktopToSend || timezoneToSend ||
            musicToSend || usageToSend || nowToSend || yearToSend ||
            credentialsToSend != nil
        /**
         * 只在没有数据要发的时候才补心跳 —— 有数据时那个包本身就证明
         * 活着，再补一条是白发。
         *
         * 心跳和数据走同一个端点、同一个 v4 信封，区别只在 modules 空不空。
         * 于是「这台 Mac 还活着」在接收端只有一个写入点。
         *
         * 睡眠期间不补：sendHeartbeat 自己也会拦，这里判一次只是别让门闩白推进，
         * 否则醒来后还得再等满一个间隔。
         */
        shouldSendHeartbeat = heartbeatDue && !dataChanged && !inputs.suspended

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
            music?.state != lastPosted.appleMusic?.state ||
            music?.trackID != lastPosted.appleMusic?.trackID ||
            musicSignature?.queueIndex != lastPosted.appleMusic?.queueIndex ||
            musicSignature?.queueTrackIDs != lastPosted.appleMusic?.queueTrackIDs
        )
        // 只认应用身份：图标变了（同一个 App 换了图标）也算 desktopChanged，
        // 但不值得为它绕过节流窗口。
        // Cmd-Tab 路过的中间应用一般不会把循环叫醒 —— 激活通知那侧压了
        // 400ms 的 desktopSettleDelay，只有最后停下的那个才放行。
        // 但那只防住「叫醒」这条路：tick 恰好落在切换途中时照样会采到中间
        // 那个应用。真要根治得在这里再比一次，眼下不值当。
        let desktopUrgent = !manualMode && desktopChanged && (
            inputs.desktopBlocked ||
            lastPosted.desktopWasHidden ||
            desktop?.bundleIdentifier != lastPosted.desktop?.bundleIdentifier ||
            desktop?.applicationName != lastPosted.desktop?.applicationName
        )
        let timezoneUrgent = !manualMode && timezoneChanged
        // 插拔和换设备也是用户正盯着的事，跟播放/前台应用同一档。
        // 只认结构性指纹：功率、电压、电流的滚动照旧等节流窗口，
        // 否则充电中每一轮都「有变化」，即时上报就退化成 5 秒一次的轮询。
        let chargerStructuralChanged =
            chargerStructural != nil && chargerStructural != lastPosted.chargingStructural
        /**
         * 结构一变就把计数重置满 —— 拔了又插算两次独立的接入，第二次
         * 同样需要完整的观察窗口，不该沿用上一次剩下的额度。
         *
         * 到点就扣，不管这一圈最后有没有真发出去（比如退避期内）。
         * 否则服务端一直失败时，这个计数会一直挂着，等退避结束后突然
         * 补发一串早就过时的追发。
         */
        var burst = chargingBurst
        if chargerStructuralChanged {
            burst.remaining = Self.chargingBurstCount
            burst.dueAt = now.addingTimeInterval(Self.chargingBurstInterval)
        }
        let chargingBurstDue = burst.remaining > 0 && now >= burst.dueAt
        if chargingBurstDue {
            burst.remaining -= 1
            burst.dueAt = now.addingTimeInterval(Self.chargingBurstInterval)
        }
        self.chargingBurst = burst
        let chargerUrgent = !manualMode && (chargerStructuralChanged || chargingBurstDue)
        // 退避期内一律不放行。否则服务端挂掉时，未推进的 lastPosted 会让
        // urgent 一直为真，即时上报就变成每圈一次的重试风暴。
        urgent = (manualMode || musicUrgent || desktopUrgent || timezoneUrgent ||
            chargerUrgent || credentialsToSend != nil) && now >= backoffUntil
        // 宣告过离线就不再发数据包。跳过不丢东西：lastPosted 门闩没推进，
        // 醒来那一下这些变化仍然是 urgent，会立刻补发。
        shouldPost = !inputs.suspended && now >= backoffUntil &&
            (manualMode || urgent || now >= nextPostAt)
    }
}
