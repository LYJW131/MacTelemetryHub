import Foundation

#if TELEMETRY_CORE_SPM
import ChargerTelemetryKit
#endif

/**
 * 「已经发出去的是什么」的全部门闩。
 *
 * 每个字段单独判变，所以从前它们是 ServiceController 上十来个平行的
 * `lastPosted*` 属性，重开一轮上报会话要挨个清一遍 —— 漏掉一个不会报错，
 * 只会让某个模块的第一封信悄悄不发。收成一个结构体之后重置就是 `.init()`，
 * 而「成功之后怎么推进」也有了唯一落点（`commit`）。
 */
struct LastPostedState {
    /// 三类载荷独立判断是否需要上报。
    var vibeCodingUsageAt: Date?
    var vibeCodingNowAt: Date?
    var vibeCodingYearAt: Date?
    var chargingDevices: ChargingDevicesPayload?
    /// 显示内容门闩。和上面那份载荷分开，是为了不让 `updatedAt` 参与「变没变」。
    var chargingContent: ChargingDevicesContentSignature?
    /// 只跟结构性变化比，管的是「要不要即时发」，不管「要不要带 charger 模块」
    var chargingStructural: ChargingDevicesStructuralSignature?
    var desktop: DesktopUploadSignature?
    /// 隐藏虚拟应用已成功发出。单靠 Optional 无法区分“尚未发过”和“已发隐藏态”。
    var desktopWasHidden = false
    var timeZone: TimeZoneUploadSignature?
    var appleMusic: AppleMusicUploadSignature?
    var musicAnchor: AppleMusicPositionAnchor?
    /// 最近一次「证明还活着」的时刻，数据包和纯心跳都算。
    var heartbeatAt: Date?

    init() {}
}

/**
 * 上报成功之后还剩下的、必须回到主 actor 才能做的那几件事。
 *
 * 它们都要读此刻的活状态（封面来源、`uploadedIconHashes`），或者要动
 * 后台 resolver，所以进不了纯函数。`commit` 只负责把它们指出来。
 */
struct PostCommitEffects {
    /// 服务端说这次封面对象不可用：要重新 HEAD / PUT。
    var coverIconRejected = false
    /// 这封信里的充电头封面确实带了对象键。带了还被拒，说明本地那份
    /// 「已上传」的记忆失效了，要先忘掉再重传。
    var sentCoverHadObjectKey = false
    /// 服务端说这次桌面图标对象不可用，附上信封里那份快照。
    var desktopIconRejected: DesktopActivitySnapshot?
    /// 这封信真的带了对象键且服务端认了：可以记成已确认。
    var desktopIconConfirmed: DesktopActivitySnapshot?
}

extension LastPostedState {
    /**
     * 把这一封信的成果记进门闩。
     *
     * `desktopPayloadHasObjectKey` 是信封里那份桌面载荷到底带没带对象键 ——
     * 服务端只是命中了自己的旧 iconHash 映射时也会说「可用」，只有这次真的
     * 带了键，本地才能记成已确认。
     */
    mutating func commit(
        decision: ReportDecision,
        response: TelemetryIngestResponse.Result,
        desktopPayloadHasObjectKey: Bool
    ) -> PostCommitEffects {
        let inputs = decision.inputs
        var effects = PostCommitEffects()
        heartbeatAt = inputs.now

        if decision.chargerToSend {
            chargingDevices = inputs.charger
            chargingContent = inputs.chargerContent
            if response.chargerCoverIconAvailable == false {
                effects.coverIconRejected = true
                effects.sentCoverHadObjectKey = inputs.charger?.devices
                    .first(where: { $0.kind == .charger })?.cover?.iconObjectKey != nil
            }
        }
        // 结构指纹跟着每次成功发送推进，跟 chargerToSend 无关：
        // 结构变了完整指纹必然也变，反过来不成立。
        if let chargerStructural = inputs.chargerStructural {
            chargingStructural = chargerStructural
        }
        if decision.desktopToSend {
            if inputs.desktopBlocked {
                // 进入黑名单应用时只发一次虚拟应用；真实身份和图标都不进载荷。
                desktop = nil
                desktopWasHidden = true
            } else if response.desktopIconAvailable == false,
                      let sent = inputs.desktop,
                      sent.iconHash != nil {
                // false 只说明这次信封没有可用对象键。先把名称门闩推进，
                // 不在这里自唤醒；否则 R2 未配置 / PNG 编码失败会打成热循环。
                desktop = inputs.desktopSignature
                effects.desktopIconRejected = sent
                desktopWasHidden = false
            } else {
                desktop = inputs.desktopSignature
                desktopWasHidden = false
                if let sent = inputs.desktop, desktopPayloadHasObjectKey {
                    effects.desktopIconConfirmed = sent
                }
            }
        }
        if decision.timezoneToSend { timeZone = inputs.timezoneSignature }
        if decision.musicToSend {
            appleMusic = inputs.musicSignature
            musicAnchor = inputs.music.map(AppleMusicPositionAnchor.init)
        }
        if decision.usageToSend { vibeCodingUsageAt = inputs.vibeCodingUsageUpdatedAt }
        if decision.nowToSend { vibeCodingNowAt = inputs.vibeCodingNowUpdatedAt }
        if decision.yearToSend { vibeCodingYearAt = inputs.vibeCodingYearUpdatedAt }
        return effects
    }
}
