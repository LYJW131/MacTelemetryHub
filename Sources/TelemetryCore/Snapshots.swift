import Foundation

struct DesktopActivitySnapshot: Codable, Equatable, Sendable {
    let applicationName: String
    let bundleIdentifier: String?
    /**
     * 这个应用的图标身份，取自**源图标**而不是编码产物。
     *
     * 关键在于：应用有图标它就非空，哪怕缩放/编码失败、哪怕还没传上 R2。
     * 从前它取自编码后的字节，于是「这个应用没有图标」和「图标没准备好」在
     * 协议上长得一模一样，站点把后者也当成一切正常，补传信号永远发不出来 ——
     * 实测因此整批图标静默消失，且不报错、不重试。
     */
    let iconHash: String?
    /// 待上传的编码产物。只在本机流转，发出去之前一定被置空。
    let iconData: Data?
    /// 直传 R2 成功后的对象键（`<sha256>.png`），是那份字节的内容地址。
    let iconObjectKey: String?
    let observedAt: Int64
}

extension DesktopActivitySnapshot {
    /// 黑名单命中时发送的虚拟应用身份。站点像处理 Codex / Claude 一样按 Bundle ID
    /// 替换名称和图标；载荷里不保留真实应用的任何身份或图标信息。
    static let hiddenBundleIdentifier = "com.liangyangjunwei.MacTelemetryHub.hidden"

    static func hidden(observedAt: Int64) -> DesktopActivitySnapshot {
        DesktopActivitySnapshot(
            applicationName: "Hidden Application",
            bundleIdentifier: hiddenBundleIdentifier,
            iconHash: nil,
            iconData: nil,
            iconObjectKey: nil,
            observedAt: observedAt
        )
    }

    func withIconData(_ iconData: Data?, iconObjectKey: String? = nil) -> DesktopActivitySnapshot {
        DesktopActivitySnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            iconHash: iconHash,
            iconData: iconData,
            iconObjectKey: iconObjectKey,
            observedAt: observedAt
        )
    }
}

struct AppleMusicQueueTrack: Codable, Equatable, Sendable {
    let title: String
    let artist: String?
    let album: String?
    let trackID: String?
}

/**
 * Music.app 的 Playing Next。
 *
 * 公开脚本接口只有 `current track` / `current playlist`。后者是点播放时的源列表
 * （从资料库点一首就是整份「音乐」），不是面板上那条队列。真正的 Playing Next
 * 落在资料库旁的 `Queue.dat` 里，没有文档，随 Music.app 改版可能变。所以整份
 * 对象带 `beta: true`，站点不该当稳定契约。
 *
 * 文件里只有歌名和 persistent ID。艺人、专辑用一次 Apple Event 把资料库
 * `{persistent ID, artist, album}` 拉齐，按 ID 拼回去，不逐首问。
 */
struct AppleMusicQueueSnapshot: Codable, Equatable, Sendable {
    let beta: Bool
    let source: String?
    /// 当前曲在 `tracks` 里的位置。对不上 persistent ID 时为 nil。
    let index: Int?
    let tracks: [AppleMusicQueueTrack]
}

struct AppleMusicSnapshot: Codable, Equatable, Sendable {
    let state: String
    let title: String?
    let artist: String?
    let album: String?
    let trackID: String?
    let positionMs: Int
    let durationMs: Int
    /**
     * 单曲循环。
     *
     * Music.app 在循环绕回时**不发** playerInfo 通知（实测跳到距结尾 4 秒，
     * 16 秒观测窗口里绕回那一刻一条都没有），上报器因此不知道进度归零了。
     * 兜底重读已经会掐着曲目结束的点去看（见 `nextPollDelay`），但那也要等上
     * 一秒多；把循环状态告诉网页，它就能按 elapsed % duration 自己绕回开头，
     * 那一秒里进度条不会先钉在 100%。
     */
    let repeatOne: Bool
    let observedAt: Int64
    /// Playing Next。来源不是公开 API，字段本身带 `beta: true`。
    let queue: AppleMusicQueueSnapshot?
}

/**
 * 并入统一遥测信封的 Apple Music user token 增量。
 *
 * developer token 归后端 —— Worker 自己拿 .p8 私钥签，这台机器不再上报它，带上
 * 它的信封会因为字段已停用而整封被退。这里只剩用户那份授权，变了才带这一格，
 * 所以字段是非可选的。本机不再另开遥测 HTTP。
 */
struct AppleMusicCredentialsPayload: Encodable, Sendable {
    let musicUserToken: String
}

struct TimeZoneSnapshot: Codable, Equatable, Sendable {
    let identifier: String
    let abbreviation: String?
    let secondsFromGMT: Int
    let observedAt: Int64
}
