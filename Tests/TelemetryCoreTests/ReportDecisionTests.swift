import ChargerTelemetryKit
import Foundation
import Testing

@testable import TelemetryCore

/**
 * 上报循环这一圈「发什么、发不发、急不急」的规则。
 *
 * 这些规则从前只存在于一段两百行的循环体里：黑名单三态靠一个额外的标志位、
 * 进度容差靠一个魔法数、追发计数靠两个循环外的局部变量。它们全都是踩过坑
 * 才长成现在这样的，而任何一条被无意改掉都不会报错，只会让某个模块安静地
 * 少发或狂发。所以这里逐条钉住。
 */
struct ReportDecisionTests {
    private let t0 = Date(timeIntervalSince1970: 1_789_099_506)
    private let ok = TelemetryIngestResponse.Result(
        desktopIconAvailable: true,
        chargerCoverIconAvailable: true
    )

    private func desktop(
        name: String = "Xcode",
        bundle: String? = "com.apple.dt.Xcode",
        iconHash: String? = nil,
        windowTitle: String? = nil
    ) -> DesktopActivitySnapshot {
        DesktopActivitySnapshot(
            applicationName: name,
            bundleIdentifier: bundle,
            iconHash: iconHash,
            iconData: nil,
            iconObjectKey: nil,
            windowTitle: windowTitle,
            observedAt: 1_789_099_506_000
        )
    }

    private func music(
        state: String = "playing",
        trackID: String? = "T1",
        positionMs: Int,
        observedAt: Int64
    ) -> AppleMusicSnapshot {
        AppleMusicSnapshot(
            state: state,
            title: "歌",
            artist: "人",
            album: "碟",
            trackID: trackID,
            positionMs: positionMs,
            durationMs: 240_000,
            repeatOne: false,
            observedAt: observedAt,
            queue: nil
        )
    }

    private func timezone(identifier: String = "Asia/Shanghai") -> TimeZoneSnapshot {
        TimeZoneSnapshot(
            identifier: identifier,
            abbreviation: "GMT+8",
            secondsFromGMT: 28_800,
            observedAt: 1_789_099_506_000
        )
    }

    /// 只有 `attached` 这类会跳变的字段进结构指纹，功率不进。
    private func charger(
        kind: ChargingDeviceKind = .charger,
        attached: Bool = true,
        powerW: Double = 45,
        updatedAt: TimeInterval = 1_789_099_506,
        cover: CoverPayload? = nil
    ) -> ChargingDevicesPayload {
        ChargingDevicesPayload(devices: [
            ChargingDevicePayload(
                id: "SN-1",
                kind: kind,
                model: "A2687",
                connected: true,
                updatedAt: updatedAt,
                firmware: "1.0.0",
                totalOutputW: powerW,
                ports: [
                    DevicePortPayload(
                        name: "C1",
                        active: attached,
                        direction: "out",
                        voltageV: 9,
                        currentA: powerW / 9,
                        powerW: powerW,
                        attached: attached,
                        cable: "5A",
                        chargingInfo: "PD",
                        attachedDevice: AttachedDevicePayload(model: "iPhone", vendor: "Apple")
                    ),
                ],
                cover: cover
            ),
        ])
    }

    private func inputs(
        now: Date,
        charger: ChargingDevicesPayload? = nil,
        capturedDesktop: DesktopActivitySnapshot? = nil,
        desktopBlocked: Bool = false,
        timezone: TimeZoneSnapshot? = nil,
        music: AppleMusicSnapshot? = nil,
        credentials: AppleMusicCredentialsSnapshot? = nil,
        musicUserTokenChanged: Bool = false,
        manualModules: Set<TelemetryModule> = []
    ) -> ReportInputs {
        ReportInputs(
            now: now,
            appleMusicModuleEnabled: true,
            vibeCodingModuleEnabled: true,
            charger: charger,
            capturedDesktop: capturedDesktop,
            desktopBlocked: desktopBlocked,
            timezone: timezone,
            music: music,
            credentials: credentials,
            musicUserTokenChanged: musicUserTokenChanged,
            manualModules: manualModules
        )
    }

    private func decide(
        _ inputs: ReportInputs,
        lastPosted: LastPostedState = LastPostedState(),
        backoffUntil: Date = .distantPast,
        nextPostAt: Date = .distantPast,
        chargingBurst: ChargingBurstState = ChargingBurstState()
    ) -> ReportDecision {
        ReportDecision(
            inputs: inputs,
            lastPosted: lastPosted,
            backoffUntil: backoffUntil,
            nextPostAt: nextPostAt,
            chargingBurst: chargingBurst
        )
    }

    /**
     * 黑名单三态：没有前台应用 / 命中黑名单 / 正常身份。
     *
     * 命中黑名单只发一次虚拟应用，之后在黑名单应用之间切换一概不发；离开黑名单
     * 时必须再发一次真身份。单靠 `lastPosted.desktop` 的 Optional 分不出「尚未
     * 发过」和「已发隐藏态」，所以另有一个标志位 —— 这个测试就是它的理由。
     */
    @Test func blacklistedForegroundAppIsReportedExactlyOnce() {
        var lastPosted = LastPostedState()

        // 命中黑名单：发一次虚拟应用
        let blocked = inputs(now: t0, capturedDesktop: desktop(name: "1Password"), desktopBlocked: true)
        var decision = decide(blocked, lastPosted: lastPosted)
        #expect(decision.desktopToSend)
        #expect(decision.urgent)
        _ = lastPosted.commit(decision: decision, response: ok, desktopPayloadHasObjectKey: false)
        #expect(lastPosted.desktopWasHidden)
        #expect(lastPosted.desktop == nil)

        // 还在黑名单里（哪怕换了另一个黑名单应用）：不再发
        let stillBlocked = inputs(
            now: t0.addingTimeInterval(1),
            capturedDesktop: desktop(name: "Keychain Access"),
            desktopBlocked: true
        )
        decision = decide(stillBlocked, lastPosted: lastPosted)
        #expect(!decision.desktopToSend)

        // 离开黑名单：真身份要补一次，而且是紧急的
        let visible = inputs(now: t0.addingTimeInterval(2), capturedDesktop: desktop())
        decision = decide(visible, lastPosted: lastPosted)
        #expect(decision.desktopToSend)
        #expect(decision.urgent)
        _ = lastPosted.commit(decision: decision, response: ok, desktopPayloadHasObjectKey: false)
        #expect(!lastPosted.desktopWasHidden)

        // 同一个应用再来一轮：没变化就不发
        decision = decide(
            inputs(now: t0.addingTimeInterval(3), capturedDesktop: desktop()),
            lastPosted: lastPosted
        )
        #expect(!decision.desktopToSend)
    }

    /**
     * 标题补发是即时的，两个方向都算。
     *
     * 应用名先发、标题后补是设计好的：判断要花时间，名字不等它。那条补发要是
     * 得等满节流窗口，网页上就挂着一个「应用对了、标题空着」的中间态。撤回
     * 同理 —— 用户在通知里点了锁定，标题必须马上从网页上消失。
     */
    @Test func windowTitleChangeIsImmediate() {
        var lastPosted = LastPostedState()

        // 第一轮：只有应用名，判断还没回来
        var decision = decide(inputs(now: t0, capturedDesktop: desktop()))
        #expect(decision.desktopToSend)
        _ = lastPosted.commit(decision: decision, response: ok, desktopPayloadHasObjectKey: false)

        // 判断放行，标题补上来：同一个应用，只有标题变了，仍然要立刻发
        let titled = inputs(
            now: t0.addingTimeInterval(3),
            capturedDesktop: desktop(windowTitle: "ReportDecision.swift — MacTelemetryHub")
        )
        decision = decide(titled, lastPosted: lastPosted)
        #expect(decision.desktopToSend)
        #expect(decision.urgent)
        _ = lastPosted.commit(decision: decision, response: ok, desktopPayloadHasObjectKey: false)

        // 没再变就不发
        decision = decide(
            inputs(
                now: t0.addingTimeInterval(4),
                capturedDesktop: desktop(windowTitle: "ReportDecision.swift — MacTelemetryHub")
            ),
            lastPosted: lastPosted
        )
        #expect(!decision.desktopToSend)

        // 撤回：标题变回 nil 同样是紧急的
        decision = decide(
            inputs(now: t0.addingTimeInterval(5), capturedDesktop: desktop()),
            lastPosted: lastPosted
        )
        #expect(decision.desktopToSend)
        #expect(decision.urgent)
    }

    /// 图标换了仍然只算普通变化：它等节流窗口，不占即时上报的额度。
    @Test func iconOnlyChangeStaysThrottled() {
        var lastPosted = LastPostedState()
        let first = decide(inputs(now: t0, capturedDesktop: desktop(iconHash: "a")))
        _ = lastPosted.commit(decision: first, response: ok, desktopPayloadHasObjectKey: false)

        let decision = decide(
            inputs(now: t0.addingTimeInterval(1), capturedDesktop: desktop(iconHash: "b")),
            lastPosted: lastPosted
        )
        #expect(decision.desktopToSend)
        #expect(!decision.urgent)
    }

    /// 没有前台应用（模块关着或还没采到）时不发，也不会把隐藏态当成变化。
    @Test func absentForegroundAppSendsNothing() {
        let decision = decide(inputs(now: t0))
        #expect(!decision.desktopToSend)
        #expect(!decision.urgent)
    }

    /**
     * 进度容差。
     *
     * 播放中每次采集进度都在变，进度本身不进签名；只有它偏离网页的预测值
     * 超过容差才算被拖过。容差调小就等于把按需上报变回定时轮询。
     */
    @Test func playbackDriftWithinToleranceIsNotASeek() {
        var lastPosted = LastPostedState()
        let anchor = music(positionMs: 10_000, observedAt: 1_000)
        lastPosted.appleMusic = AppleMusicUploadSignature(anchor)
        lastPosted.musicAnchor = AppleMusicPositionAnchor(anchor)

        // 十秒后进度正好走了十秒：网页自己推得出来，不必发
        let onTrack = music(positionMs: 20_000, observedAt: 11_000)
        #expect(!decide(inputs(now: t0, music: onTrack), lastPosted: lastPosted).musicToSend)

        // 容差边界上仍然不算 seek
        let atTolerance = music(
            positionMs: 20_000 + ReportDecision.musicSeekToleranceMs,
            observedAt: 11_000
        )
        #expect(!decide(inputs(now: t0, music: atTolerance), lastPosted: lastPosted).musicToSend)

        // 越过容差：重新对锚点，而且是紧急的 —— 否则进度条要钉到下一个节流窗口
        let seeked = music(
            positionMs: 20_000 + ReportDecision.musicSeekToleranceMs + 1,
            observedAt: 11_000
        )
        let decision = decide(inputs(now: t0, music: seeked), lastPosted: lastPosted)
        #expect(decision.musicToSend)
        #expect(decision.urgent)
    }

    /**
     * 追发计数在结构再次变化时重置。
     *
     * 拔了又插算两次独立的接入，第二次同样需要完整的观察窗口。到点就扣，
     * 不管这一圈最后有没有真发出去。
     */
    @Test func chargingBurstResetsWhenTheStructureChangesAgain() {
        var lastPosted = LastPostedState()
        var burst = ChargingBurstState()

        var decision = decide(
            inputs(now: t0, charger: charger(attached: true)),
            lastPosted: lastPosted,
            chargingBurst: burst
        )
        #expect(decision.chargingBurst.remaining == ReportDecision.chargingBurstCount)
        #expect(decision.urgent)
        burst = decision.chargingBurst
        _ = lastPosted.commit(decision: decision, response: ok, desktopPayloadHasObjectKey: false)

        // 功率滚动不是结构变化，但追发到点了：扣一次，照发
        let due = t0.addingTimeInterval(ReportDecision.chargingBurstInterval)
        decision = decide(
            inputs(now: due, charger: charger(attached: true, powerW: 12)),
            lastPosted: lastPosted,
            chargingBurst: burst
        )
        #expect(decision.chargingBurst.remaining == ReportDecision.chargingBurstCount - 1)
        #expect(decision.urgent)
        burst = decision.chargingBurst
        _ = lastPosted.commit(decision: decision, response: ok, desktopPayloadHasObjectKey: false)

        // 拔线：结构又变了，额度重新满上而不是沿用剩下的四次
        decision = decide(
            inputs(now: due.addingTimeInterval(1), charger: charger(attached: false, powerW: 0)),
            lastPosted: lastPosted,
            chargingBurst: burst
        )
        #expect(decision.chargingBurst.remaining == ReportDecision.chargingBurstCount)
    }

    /// 每帧都会变的时间戳不是显示内容。安静连接靠心跳续期，不按发送间隔轮询。
    @Test func chargingTimestampAloneDoesNotPost() {
        var lastPosted = LastPostedState()
        let first = decide(inputs(now: t0, charger: charger(updatedAt: 1)))
        #expect(first.chargerToSend)
        _ = lastPosted.commit(decision: first, response: ok, desktopPayloadHasObjectKey: false)

        let later = t0.addingTimeInterval(1)
        let decision = decide(
            inputs(now: later, charger: charger(updatedAt: 2)),
            lastPosted: lastPosted,
            nextPostAt: t0.addingTimeInterval(30)
        )
        #expect(!decision.chargerToSend)
        #expect(!decision.urgent)
        #expect(!decision.shouldPost)
        #expect(!decision.shouldSendHeartbeat)
    }

    /// 瓦数变了要发，但要等节流窗口，不走插拔那条紧急路径。
    @Test func chargingPowerChangeWaitsForTheThrottle() {
        var lastPosted = LastPostedState()
        let first = decide(inputs(now: t0, charger: charger(powerW: 45)))
        _ = lastPosted.commit(decision: first, response: ok, desktopPayloadHasObjectKey: false)

        let decision = decide(
            inputs(now: t0.addingTimeInterval(1), charger: charger(powerW: 12)),
            lastPosted: lastPosted,
            nextPostAt: t0.addingTimeInterval(30)
        )
        #expect(decision.chargerToSend)
        #expect(!decision.urgent)
        #expect(!decision.shouldPost)
    }

    /// 封面对象键从无到有要立刻补发，不必等功率那种节流窗口。
    @Test func chargerCoverObjectKeyArrivingIsUrgent() {
        var lastPosted = LastPostedState()
        let bare = charger(cover: CoverPayload(name: "猫", iconHash: "abc", iconObjectKey: nil))
        let keyed = charger(cover: CoverPayload(name: "猫", iconHash: "abc", iconObjectKey: "abc.jpg"))
        let first = decide(inputs(now: t0, charger: bare))
        _ = lastPosted.commit(decision: first, response: ok, desktopPayloadHasObjectKey: false)

        let decision = decide(
            inputs(now: t0.addingTimeInterval(1), charger: keyed),
            lastPosted: lastPosted,
            nextPostAt: t0.addingTimeInterval(30)
        )
        #expect(decision.chargerToSend)
        #expect(decision.urgent)
        #expect(decision.shouldPost)
    }

    /// 黑名单前台的手动上报和自动路径一样，发的是隐藏态，不是「没有数据」。
    @Test func manualDesktopOnABlacklistedAppIsSatisfiable() {
        let decision = decide(inputs(
            now: t0,
            capturedDesktop: desktop(name: "1Password"),
            desktopBlocked: true,
            manualModules: [.desktop]
        ))
        #expect(decision.desktopToSend)
        #expect(decision.unsatisfiableManualModules.isEmpty)
        #expect(decision.manualModules == [.desktop])
    }

    /**
     * 退避期内一律不放行紧急上报。
     *
     * 服务端挂掉时门闩推不进去，urgent 会一直为真；不挡住的话即时上报就变成
     * 每圈一次的重试风暴。
     */
    @Test func backoffBlocksUrgentAndPosting() {
        let changed = inputs(now: t0, timezone: timezone())
        let allowed = decide(changed)
        #expect(allowed.urgent)
        #expect(allowed.shouldPost)

        let blocked = decide(changed, backoffUntil: t0.addingTimeInterval(10))
        #expect(blocked.timezoneToSend)
        #expect(!blocked.urgent)
        #expect(!blocked.shouldPost)
    }

    /// 宣告过离线之后不再发数据包，但门闩没推进，醒来那一下会补上。
    @Test func suspendedStopsPostingButKeepsTheLatches() {
        var suspendedInputs = inputs(now: t0, timezone: timezone())
        suspendedInputs.suspended = true
        let decision = decide(suspendedInputs)
        #expect(decision.timezoneToSend)
        #expect(!decision.shouldPost)
        #expect(!decision.shouldSendHeartbeat)
    }

    /**
     * 手动上报只发用户点的那个模块。
     *
     * 自动攒下的变化留给下一轮常规上报，不搭这封信的便车 —— 否则用户点一次
     * 「上报音乐」会把还没到节流窗口的充电器读数一起送出去。
     */
    @Test func manualModeOnlySendsTheRequestedModule() {
        let decision = decide(inputs(
            now: t0,
            charger: charger(),
            capturedDesktop: desktop(),
            timezone: timezone(),
            music: music(positionMs: 0, observedAt: 1_000),
            manualModules: [.appleMusic]
        ))
        #expect(decision.musicToSend)
        #expect(!decision.chargerToSend)
        #expect(!decision.desktopToSend)
        #expect(!decision.timezoneToSend)
        #expect(decision.shouldPost)
    }

    /**
     * 点「立刻上报充电宝」要真的发出去。
     *
     * 充电头和充电宝共用 `chargingDevices` 那一格，从前手写的 switch 只认
     * `.charger`：点充电宝什么都不发，而 pending 只在发出去之后才清，于是永远
     * 清不掉 —— manualMode 一直为真，所有自动上报被挡住，按钮停在「正在上报…」
     * 直到重新保存设置。
     */
    @Test func manualPowerBankSendsTheSharedChargingPayload() {
        let decision = decide(inputs(
            now: t0,
            charger: charger(),
            manualModules: [.powerBank]
        ))
        #expect(decision.chargerToSend)
        #expect(decision.shouldPost)
        #expect(decision.unsatisfiableManualModules.isEmpty)
        #expect(decision.manualModules == [.powerBank])
    }

    /**
     * 只连着充电宝、充电头没连时同样要发得出去。
     *
     * 这才是这个 bug 的实际现场：载荷里一台 `.charger` 都没有。收尾时那句
     * 「这封信的充电头封面带没带对象键」查不到充电头，得老实返回 false 而不是
     * 把整条路带偏。
     */
    @Test func manualPowerBankWorksWhenOnlyThePowerBankIsConnected() {
        var lastPosted = LastPostedState()
        let decision = decide(inputs(
            now: t0,
            charger: charger(kind: .powerBank),
            manualModules: [.powerBank]
        ))
        #expect(decision.chargerToSend)
        #expect(decision.manualModules == [.powerBank])

        let effects = lastPosted.commit(
            decision: decision,
            response: TelemetryIngestResponse.Result(
                desktopIconAvailable: nil,
                chargerCoverIconAvailable: false
            ),
            desktopPayloadHasObjectKey: false
        )
        #expect(effects.coverIconRejected)
        #expect(!effects.sentCoverHadObjectKey)
        #expect(lastPosted.chargingDevices != nil)
    }

    /**
     * 载荷在按下按钮之后才消失的，当场报「没有可上报的数据」而不是挂着。
     *
     * 按钮那侧的 canRequestImmediateReport 已经查过一遍，所以能走到这里的都是
     * 那之后才变的：蓝牙断了、采集器把载荷清了。切进黑名单不是这种消失 ——
     * 那一格改发隐藏态，和自动路径同一封信。
     */
    @Test func manualRequestWithoutAPayloadIsReportedUnsatisfiable() {
        let decision = decide(inputs(now: t0, manualModules: [.powerBank]))
        #expect(decision.unsatisfiableManualModules == [.powerBank])
        #expect(!decision.chargerToSend)
        #expect(!decision.manualMode)
    }

    /// 一个能发一个不能发时，能发的照发，不能发的当场摘掉。
    @Test func unsatisfiableManualModulesDoNotBlockTheSatisfiableOnes() {
        let decision = decide(inputs(
            now: t0,
            charger: charger(),
            manualModules: [.charger, .timezone]
        ))
        #expect(decision.chargerToSend)
        #expect(!decision.timezoneToSend)
        #expect(decision.manualModules == [.charger])
        #expect(decision.unsatisfiableManualModules == [.timezone])
    }

    /**
     * Apple Music 凭据只在 user token 变了的时候发，而且只发那一个值。
     *
     * developer token 现在由 Worker 自己签，带上它的信封会被整封退回，所以这一格
     * 没有别的字段可判 —— 唯一的门就是 user token 有没有变。
     */
    @Test func appleMusicCredentialsFollowTheUserTokenOnly() {
        let credentials = AppleMusicCredentialsSnapshot(musicUserToken: "mut")

        let changed = decide(inputs(now: t0, credentials: credentials, musicUserTokenChanged: true))
        #expect(changed.credentialsToSend?.musicUserToken == "mut")
        #expect(changed.dataChanged)

        // 没变就不发，也不该把这一圈算成有数据
        let unchanged = decide(inputs(now: t0, credentials: credentials))
        #expect(unchanged.credentialsToSend == nil)
        #expect(!unchanged.dataChanged)

        // 手动上报只发用户选中的模块，token 的变化留到下一轮
        let manual = decide(inputs(
            now: t0,
            charger: charger(),
            credentials: credentials,
            musicUserTokenChanged: true,
            manualModules: [.charger]
        ))
        #expect(manual.credentialsToSend == nil)
    }

    /// 没有数据要发的时候才补心跳 —— 有数据时那个包本身就证明活着。
    @Test func heartbeatOnlyFillsQuietRounds() {
        #expect(decide(inputs(now: t0)).shouldSendHeartbeat)
        #expect(!decide(inputs(now: t0, timezone: timezone())).shouldSendHeartbeat)

        var lastPosted = LastPostedState()
        lastPosted.heartbeatAt = t0
        let tooSoon = t0.addingTimeInterval(ReportDecision.heartbeatInterval - 1)
        #expect(!decide(inputs(now: tooSoon), lastPosted: lastPosted).shouldSendHeartbeat)
        let dueAt = t0.addingTimeInterval(ReportDecision.heartbeatInterval)
        #expect(decide(inputs(now: dueAt), lastPosted: lastPosted).shouldSendHeartbeat)
    }
}
