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
        coding: [CodingModule: CodingPayload] = [:],
        manualModules: Set<TelemetryModule> = []
    ) -> ReportInputs {
        ReportInputs(
            now: now,
            appleMusicModuleEnabled: true,
            codingModuleEnabled: true,
            charger: charger,
            capturedDesktop: capturedDesktop,
            desktopBlocked: desktopBlocked,
            timezone: timezone,
            music: music,
            credentials: credentials,
            musicUserTokenChanged: musicUserTokenChanged,
            coding: coding,
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
     * 冷却里再次拔插：不即时发、不重置追发，还在跑的追发把它捎走。
     *
     * 追发到点就扣，不管这一圈最后有没有真发出去。
     */
    @Test func replugInsideTheCooldownRidesTheRunningBurst() {
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

        // 拔线：还在冷却里，不催发，追发额度也不动
        let unplugged = charger(attached: false, powerW: 0)
        decision = decide(
            inputs(now: due.addingTimeInterval(1), charger: unplugged),
            lastPosted: lastPosted,
            nextPostAt: due.addingTimeInterval(30),
            chargingBurst: burst
        )
        #expect(decision.chargerToSend)
        #expect(!decision.urgent)
        #expect(decision.chargingBurst.remaining == ReportDecision.chargingBurstCount - 1)
        burst = decision.chargingBurst

        // 下一次追发到点，把拔线捎走
        decision = decide(
            inputs(now: due.addingTimeInterval(ReportDecision.chargingBurstInterval), charger: unplugged),
            lastPosted: lastPosted,
            nextPostAt: due.addingTimeInterval(30),
            chargingBurst: burst
        )
        #expect(decision.chargerToSend)
        #expect(decision.urgent)
        _ = lastPosted.commit(decision: decision, response: ok, desktopPayloadHasObjectKey: false)
        #expect(lastPosted.chargingStructural == ChargingDevicesStructuralSignature(unplugged))
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

    // MARK: - coding

    private func activity(_ collectedAt: Int, model: String = "claude-opus-5") -> JSONValue {
        .object([
            "collectedAt": .number(Double(collectedAt)),
            "agents": .array([.object(["id": .string("claude"), "model": .string(model)])]),
        ])
    }

    private func usage(_ collectedAt: Int, tokens: Int = 10) -> JSONValue {
        .object(["agents": .array([.object([
            "id": .string("claude"), "state": .string("ok"), "collectedAt": .number(Double(collectedAt)),
            "days": .array([.object(["date": .string("2026-09-05"), "totalTokens": .number(Double(tokens))])]),
        ])])])
    }

    /// 按采集器的做法一轮一轮地换载荷
    private func collected(_ previous: CodingPayload?, _ value: JSONValue, _ module: CodingModule, at: Date) -> CodingPayload {
        CodingPayload.next(after: previous, value: value, module: module, at: at)
    }

    private func post(_ decision: ReportDecision, into lastPosted: inout LastPostedState,
                      response: TelemetryIngestResponse.Result? = nil) -> PostCommitEffects {
        lastPosted.commit(decision: decision, response: response ?? ok, desktopPayloadHasObjectKey: false)
    }

    /// 采集时刻不算内容：只换了时刻，内容变化时刻不动；整份一样就什么都不动
    @Test func codingPayloadSeparatesContentFromCollectionClock() {
        let first = collected(nil, activity(1), .activity, at: t0)
        #expect(first.contentChangedAt == t0 && first.updatedAt == t0)
        let clockOnly = collected(first, activity(2), .activity, at: t0.addingTimeInterval(60))
        #expect(clockOnly.contentChangedAt == t0)
        #expect(clockOnly.updatedAt == t0.addingTimeInterval(60))
        #expect(collected(clockOnly, activity(2), .activity, at: t0.addingTimeInterval(120)) == clockOnly)
        let changed = collected(clockOnly, activity(3, model: "claude-fable-5"), .activity, at: t0.addingTimeInterval(180))
        #expect(changed.contentChangedAt == t0.addingTimeInterval(180))
        // 用量报告里每个 agent 的 collectedAt 也是时钟
        let usageFirst = collected(nil, usage(1), .usage, at: t0)
        #expect(collected(usageFirst, usage(2), .usage, at: t0.addingTimeInterval(1)).contentChangedAt == t0)
        // 桶报告的滚动窗口起止同理
        let buckets: (Int) -> JSONValue = { at in
            .object(["from": .number(Double(at - 1)), "to": .number(Double(at)), "collectedAt": .number(Double(at)),
                     "windows": .array([])])
        }
        let bucketsFirst = collected(nil, buckets(10), .buckets, at: t0)
        #expect(collected(bucketsFirst, buckets(20), .buckets, at: t0.addingTimeInterval(1)).contentChangedAt == t0)
    }

    /**
     * 活动内容不变时至少五分钟发一封：站点靠采集时刻前进判断采集器还活着，
     * 超过十分钟没前进，Pulse 就把 agent 当成未知。内容变了立刻（按节流窗口）发。
     */
    @Test func codingActivityKeepsAliveEveryFiveMinutes() {
        var lastPosted = LastPostedState()
        var payload = collected(nil, activity(1), .activity, at: t0)
        var decision = decide(inputs(now: t0, coding: [.activity: payload]))
        #expect(decision.codingToSend == [.activity])
        _ = post(decision, into: &lastPosted)

        // 一分钟后的扫描：只有采集时刻变了，不发
        payload = collected(payload, activity(2), .activity, at: t0.addingTimeInterval(60))
        decision = decide(inputs(now: t0.addingTimeInterval(61), coding: [.activity: payload]), lastPosted: lastPosted)
        #expect(decision.codingToSend.isEmpty)
        #expect(!decision.dataChanged)

        // 五分钟到了：发最新那一份，站点看得见采集时刻前进
        payload = collected(payload, activity(5), .activity, at: t0.addingTimeInterval(299))
        decision = decide(inputs(now: t0.addingTimeInterval(300), coding: [.activity: payload]), lastPosted: lastPosted)
        #expect(decision.codingToSend == [.activity])
        _ = post(decision, into: &lastPosted)
        #expect(lastPosted.coding[.activity]?.postedAt == t0.addingTimeInterval(300))

        // 内容变了不等五分钟
        payload = collected(payload, activity(6, model: "claude-fable-5"), .activity, at: t0.addingTimeInterval(330))
        decision = decide(inputs(now: t0.addingTimeInterval(331), coding: [.activity: payload]), lastPosted: lastPosted)
        #expect(decision.codingToSend == [.activity])
    }

    /// 采集停了（没有新的一份）就不保活：同一份旧的重发只会让站点以为采集器还活着
    @Test func codingKeepaliveNeedsAFreshCollection() {
        var lastPosted = LastPostedState()
        let payload = collected(nil, activity(1), .activity, at: t0)
        _ = post(decide(inputs(now: t0, coding: [.activity: payload])), into: &lastPosted)
        let later = decide(inputs(now: t0.addingTimeInterval(3_600), coding: [.activity: payload]), lastPosted: lastPosted)
        #expect(later.codingToSend.isEmpty)
    }

    /// 用量每轮新采的都发：采集时刻前进本身就是站点要的事实。同一份失败状态不重发
    @Test func codingUsageIsSentOnEveryFreshRound() {
        var lastPosted = LastPostedState()
        var payload = collected(nil, usage(1), .usage, at: t0)
        _ = post(decide(inputs(now: t0, coding: [.usage: payload])), into: &lastPosted)
        payload = collected(payload, usage(2), .usage, at: t0.addingTimeInterval(600))
        let fresh = decide(inputs(now: t0.addingTimeInterval(601), coding: [.usage: payload]), lastPosted: lastPosted)
        #expect(fresh.codingToSend == [.usage])
        _ = post(fresh, into: &lastPosted)
        payload = collected(payload, usage(2), .usage, at: t0.addingTimeInterval(1_200))
        let same = decide(inputs(now: t0.addingTimeInterval(1_201), coding: [.usage: payload]), lastPosted: lastPosted)
        #expect(same.codingToSend.isEmpty)
    }

    /**
     * 站点拒收（`rejected`）或不认识（`ignored`）的那一格：门闩照样推进、原因交给卡片，
     * 之后保活不再重发同一份，内容再变才发。别的模块照常收下。
     */
    @Test func refusedCodingModuleAdvancesTheLatchAndWaitsForNewContent() {
        var lastPosted = LastPostedState()
        var activityPayload = collected(nil, activity(1), .activity, at: t0)
        var usagePayload = collected(nil, usage(1), .usage, at: t0)
        let first = decide(inputs(now: t0, coding: [.activity: activityPayload, .usage: usagePayload]))
        #expect(first.codingToSend == [.activity, .usage])
        let effects = post(first, into: &lastPosted, response: TelemetryIngestResponse.Result(
            desktopIconAvailable: nil, chargerCoverIconAvailable: nil,
            ignored: ["codingUsage"],
            rejected: [TelemetryIngestResponse.Rejection(module: "codingActivity", error: "agents[0].model 超过 200 个字符")]
        ))
        #expect(effects.codingAccepted.isEmpty)
        #expect(effects.codingRefused == [
            .activity: "站点拒收：agents[0].model 超过 200 个字符",
            .usage: "站点不认识这个模块，没有收下",
        ])
        #expect(lastPosted.coding[.activity]?.refused == true)
        #expect(lastPosted.coding[.usage]?.refused == true)

        // 十分钟后又采了一轮，内容没变：两格都不发
        activityPayload = collected(activityPayload, activity(2), .activity, at: t0.addingTimeInterval(600))
        usagePayload = collected(usagePayload, usage(2), .usage, at: t0.addingTimeInterval(600))
        let quiet = decide(inputs(now: t0.addingTimeInterval(601), coding: [.activity: activityPayload, .usage: usagePayload]),
                           lastPosted: lastPosted)
        #expect(quiet.codingToSend.isEmpty)

        // 内容变了：再试一次；这回收下了，拒收标记清掉，保活恢复
        activityPayload = collected(activityPayload, activity(3, model: "claude-fable-5"), .activity, at: t0.addingTimeInterval(660))
        let retry = decide(inputs(now: t0.addingTimeInterval(661), coding: [.activity: activityPayload, .usage: usagePayload]),
                           lastPosted: lastPosted)
        #expect(retry.codingToSend == [.activity])
        let accepted = post(retry, into: &lastPosted)
        #expect(accepted.codingAccepted == [.activity])
        #expect(accepted.codingRefused.isEmpty)
        #expect(lastPosted.coding[.activity]?.refused == false)
    }

    /// 手动上报：coding 手上有的几份全发，内容没变、被拒过的也发 —— 用户按按钮就是要再试一次
    @Test func manualCodingReportSendsEveryPayloadAtHand() {
        var lastPosted = LastPostedState()
        let payload = collected(nil, activity(1), .activity, at: t0)
        _ = post(decide(inputs(now: t0, coding: [.activity: payload])), into: &lastPosted,
                 response: TelemetryIngestResponse.Result(desktopIconAvailable: nil, chargerCoverIconAvailable: nil,
                                                          ignored: ["codingActivity"]))
        let buckets = collected(nil, .object(["windows": .array([])]), .buckets, at: t0)
        let manual = decide(inputs(now: t0.addingTimeInterval(1), timezone: timezone(),
                                   coding: [.activity: payload, .buckets: buckets], manualModules: [.coding]),
                            lastPosted: lastPosted)
        #expect(manual.codingToSend == [.activity, .buckets])
        #expect(!manual.timezoneToSend)
        #expect(manual.shouldPost)
        // 一份都还没采到时按下按钮：当场摘掉，不挂着
        let empty = decide(inputs(now: t0, manualModules: [.coding]))
        #expect(empty.unsatisfiableManualModules == [.coding])
    }

    @Test func disabledCodingModuleSendsNothing() {
        var disabled = inputs(now: t0, coding: [.activity: collected(nil, activity(1), .activity, at: t0)])
        disabled.codingModuleEnabled = false
        #expect(decide(disabled).codingToSend.isEmpty)
    }

    private func chargerPort(
        active: Bool,
        currentA: Double,
        model: String? = "iPhone",
        updatedAt: TimeInterval
    ) -> ChargingDevicesPayload {
        ChargingDevicesPayload(devices: [
            ChargingDevicePayload(
                id: "SN-1",
                kind: .charger,
                model: "A2687",
                connected: true,
                updatedAt: updatedAt,
                firmware: "1.0.0",
                totalOutputW: active ? currentA * 5 : 0,
                ports: [
                    DevicePortPayload(
                        name: "C1",
                        active: active,
                        direction: active ? "out" : nil,
                        voltageV: 5,
                        currentA: currentA,
                        powerW: currentA * 5,
                        cable: "5A",
                        chargingInfo: active ? "PD" : nil,
                        attachedDevice: AttachedDevicePayload(model: model, vendor: "Apple")
                    ),
                ],
            ),
        ])
    }

    /// 照真循环的样子推进：发不发看 `dataChanged && shouldPost`，发了就 commit 并把节流窗口推后 30 秒。
    private struct ReporterLoop {
        static let postInterval: TimeInterval = 30
        var lastPosted = LastPostedState()
        var burst = ChargingBurstState()
        var nextPostAt = Date.distantPast
        var posts: [Date] = []

        mutating func tick(_ inputs: ReportInputs) -> ReportDecision {
            let decision = ReportDecision(
                inputs: inputs,
                lastPosted: lastPosted,
                backoffUntil: .distantPast,
                nextPostAt: nextPostAt,
                chargingBurst: burst
            )
            burst = decision.chargingBurst
            if decision.shouldSendHeartbeat { lastPosted.heartbeatAt = inputs.now }
            if decision.dataChanged, decision.shouldPost {
                _ = lastPosted.commit(
                    decision: decision,
                    response: TelemetryIngestResponse.Result(desktopIconAvailable: true, chargerCoverIconAvailable: true),
                    desktopPayloadHasObjectKey: false
                )
                nextPostAt = inputs.now.addingTimeInterval(Self.postInterval)
                posts.append(inputs.now)
            }
            return decision
        }
    }

    /// 先让设备静静插着，追发跑完、冷却过去，再开始测。
    private func settledLoop(on payload: ChargingDevicesPayload, until end: Date) -> ReporterLoop {
        var loop = ReporterLoop()
        var now = end.addingTimeInterval(-120)
        while now < end {
            _ = loop.tick(inputs(now: now, charger: payload))
            now = now.addingTimeInterval(1)
        }
        loop.posts.removeAll()
        return loop
    }

    /**
     * 0 A 时端口开关位 1 Hz 来回翻，设备一直插着。
     *
     * 这不是插拔，只按节流窗口发；从前每翻一次就即时上报一封并重置追发。
     * 停下来之后最后那个状态要在一个节流窗口内送到。
     */
    @Test func zeroAmpPortFlappingOnlyPostsOnTheThrottle() {
        let idle = chargerPort(active: false, currentA: 0, updatedAt: 0)
        var loop = settledLoop(on: idle, until: t0)
        let seconds = 600
        for second in 0..<seconds {
            let now = t0.addingTimeInterval(TimeInterval(second))
            let decision = loop.tick(inputs(
                now: now,
                charger: chargerPort(active: second % 2 == 0, currentA: 0, updatedAt: TimeInterval(second))
            ))
            #expect(!decision.urgent)
        }
        #expect(loop.posts.count <= seconds / Int(ReporterLoop.postInterval) + 1, "posts: \(loop.posts.count)")

        let final = chargerPort(active: true, currentA: 0, updatedAt: TimeInterval(seconds))
        let stop = t0.addingTimeInterval(TimeInterval(seconds))
        for second in 0...Int(ReporterLoop.postInterval) {
            _ = loop.tick(inputs(now: stop.addingTimeInterval(TimeInterval(second)), charger: final))
        }
        #expect(lastPostedPortsMatch(loop.lastPosted, final))
    }

    /**
     * 真正的结构字段来回翻（这里是设备身份）：冷却把它压成每个冷却期一封。
     *
     * 第一下是新的接入，即时发、追发排满；之后不再重置追发，冷却结束那一圈把
     * 期间攒下的变化合并成一封，最终状态不丢。
     */
    @Test func structuralFlappingIsCoalescedByTheCooldown() {
        let plugged = chargerPort(active: true, currentA: 2, updatedAt: 0)
        var loop = settledLoop(on: plugged, until: t0)
        let cooldown = ReportDecision.chargingStructuralCooldown
        let burstSpan = ReportDecision.chargingBurstInterval * Double(ReportDecision.chargingBurstCount)
        let seconds = 300
        for second in 0..<seconds {
            let now = t0.addingTimeInterval(TimeInterval(second))
            let decision = loop.tick(inputs(
                now: now,
                charger: chargerPort(
                    active: true,
                    currentA: 2,
                    model: second % 2 == 0 ? nil : "iPhone",
                    updatedAt: TimeInterval(second)
                )
            ))
            if second == 0 {
                #expect(decision.urgent)
                #expect(decision.chargingBurst.remaining == ReportDecision.chargingBurstCount)
            }
            if TimeInterval(second) > burstSpan {
                #expect(decision.chargingBurst.remaining == 0)
            }
        }
        let afterBurst = loop.posts.filter { $0.timeIntervalSince(t0) > burstSpan }
        for (earlier, later) in zip(afterBurst, afterBurst.dropFirst()) {
            #expect(later.timeIntervalSince(earlier) >= cooldown)
        }
        let bound = 1 + ReportDecision.chargingBurstCount + Int(Double(seconds) / cooldown)
        #expect(loop.posts.count <= bound, "posts: \(loop.posts.count)")

        let final = chargerPort(active: true, currentA: 2, model: "MacBook Pro", updatedAt: TimeInterval(seconds))
        let stop = t0.addingTimeInterval(TimeInterval(seconds))
        for second in 0...Int(cooldown) {
            _ = loop.tick(inputs(now: stop.addingTimeInterval(TimeInterval(second)), charger: final))
        }
        #expect(loop.lastPosted.chargingStructural == ChargingDevicesStructuralSignature(final))
        #expect(lastPostedPortsMatch(loop.lastPosted, final))
    }

    /// 安静了一阵之后的插上、拔下都即时发，各自排满追发。
    @Test func plugAndUnplugAfterQuietAreImmediate() {
        let idle = chargerPort(active: false, currentA: 0, model: nil, updatedAt: 0)
        var loop = settledLoop(on: idle, until: t0)

        let plugged = chargerPort(active: true, currentA: 2, updatedAt: 1)
        var decision = loop.tick(inputs(now: t0, charger: plugged))
        #expect(decision.urgent)
        #expect(decision.shouldPost)
        #expect(decision.chargingBurst.remaining == ReportDecision.chargingBurstCount)
        #expect(loop.posts == [t0])

        let later = t0.addingTimeInterval(2 * ReportDecision.chargingStructuralCooldown)
        var now = t0.addingTimeInterval(1)
        while now < later {
            _ = loop.tick(inputs(now: now, charger: plugged))
            now = now.addingTimeInterval(1)
        }
        decision = loop.tick(inputs(now: later, charger: idle))
        #expect(decision.urgent)
        #expect(decision.shouldPost)
        #expect(decision.chargingBurst.remaining == ReportDecision.chargingBurstCount)
        #expect(loop.posts.last == later)
    }

    /// 退避和离线时结构变化发不出去，不能白白耗掉冷却；能发的那一圈仍是即时的。
    @Test func backoffAndSuspensionDoNotConsumeTheCooldown() {
        let plugged = chargerPort(active: true, currentA: 2, updatedAt: 1)
        let blocked = decide(inputs(now: t0, charger: plugged), backoffUntil: t0.addingTimeInterval(10))
        #expect(!blocked.urgent)
        #expect(blocked.chargingBurst.structuralPostedAt == .distantPast)

        var asleep = inputs(now: t0, charger: plugged)
        asleep.suspended = true
        #expect(decide(asleep).chargingBurst.structuralPostedAt == .distantPast)

        let awake = decide(inputs(now: t0.addingTimeInterval(10), charger: plugged), chargingBurst: blocked.chargingBurst)
        #expect(awake.urgent)
        #expect(awake.shouldPost)
    }

    private func lastPostedPortsMatch(_ lastPosted: LastPostedState, _ payload: ChargingDevicesPayload) -> Bool {
        lastPosted.chargingContent == ChargingDevicesContentSignature(payload)
    }
}
