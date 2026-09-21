import Foundation

#if TELEMETRY_CORE_SPM
import ChargerTelemetryKit
#endif

struct EmptyObject: Encodable {}

struct HealthPayload: Encodable {
    struct Device: Encodable {
        let enabled: Bool
        let connected: Bool
        let phase: String
        let lastError: String?
    }

    /** 远端上报循环的状态。排查「网页上少了什么」先看这里，不用开设置窗口 */
    struct Reporter: Encodable {
        let postEnabled: Bool
        /** 上次成功 POST 的时刻，Unix 毫秒 */
        let lastSuccessAt: Int?
        let lastError: String?
        /** R2 直传的四项配置是否齐全；缺一项图标 resolver 会静默不跑 */
        let r2Configured: Bool
    }

    /** 当前前台应用的图标交付状态。哈希是内容地址，不是秘密 */
    struct DesktopIcon: Encodable {
        let applicationName: String
        let iconHash: String?
        /** PNG 编码是否成功；失败时 resolver 没东西可传 */
        let iconEncoded: Bool
        /** 本地是否已确认对象在 R2 里，确认后下一次信封才会带对象键 */
        let objectKeyConfirmed: Bool
        let uploadAttempts: Int
        let resolving: Bool
    }

    /**
     * 当前前台窗口标题的判断状态。
     *
     * `title` 只有在这一档真的会上报时才有值 —— 本地接口可以绑到 0.0.0.0，
     * 锁定和待确认的标题不该从这里漏出去。`status` 永远都在，排查
     * 「网页上为什么没有标题」看它就够。
     */
    struct WindowTitle: Encodable {
        let status: String
        /** 会不会随前台应用一起上报 */
        let reportable: Bool
        /** 只有 reportable 为真时才有值 */
        let title: String?
    }

    let ok: Bool
    let reporter: Reporter
    let desktopIcon: DesktopIcon?
    let windowTitle: WindowTitle
    let charger: Device
    let powerBank: Device
}

/** 本地状态接口的 Apple Music 授权一栏。只有状态和时刻，没有 token 值 */
struct AppleMusicAuthorizationPayload: Encodable {
    let status: String
    let authorized: Bool
    let hasUserToken: Bool
    /** 上次成功把 token 送到后端的时刻，Unix 毫秒 */
    let lastUploadAt: Int?
    let lastError: String?
}

struct ChargingStreamEvent: Encodable {
    let phase: String
    let connected: Bool
    let lastError: String?
    let device: ChargingDevicePayload?
}
