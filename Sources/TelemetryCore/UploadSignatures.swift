import Foundation

#if TELEMETRY_CORE_SPM
import ChargerTelemetryKit
#endif

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
struct ChargingDevicesStructuralSignature: Equatable {
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
        let coverName: String?
        let coverIconHash: String?

        init(_ device: ChargingDevicePayload) {
            id = device.id
            kind = device.kind
            connected = device.connected
            thermalLimited = device.battery?.thermalLimited
            ports = device.ports.map(Port.init)
            coverName = device.cover?.name
            coverIconHash = device.cover?.iconHash
        }
    }

    private let devices: [Device]

    init(_ payload: ChargingDevicesPayload) {
        devices = payload.devices.map(Device.init)
    }
}

/**
 * 「显示内容变了没有」。
 *
 * 节流窗口看的是这一份，不看整份 `ChargingDevicesPayload`。载荷里的
 * `updatedAt` 每一帧都在走，拿结构体相等当变化会让安静的连接也每到
 * 发送间隔就打一包。功率、电压、电流、电量、温度、封面对象键都算显示
 * 内容；时间戳和只在连接时出现一次的电池健康度不算。
 *
 * 插拔仍然只看 `ChargingDevicesStructuralSignature`，不进这里。
 */
struct ChargingDevicesContentSignature: Equatable {
    private struct Port: Equatable {
        let name: String
        let active: Bool
        let direction: String?
        let voltageV: Double?
        let currentA: Double?
        let powerW: Double?
        let attached: Bool?
        let cable: String?
        let chargingInfo: String?
        let deviceModel: String?
        let vendor: String?

        init(_ port: DevicePortPayload) {
            name = port.name
            active = port.active
            direction = port.direction
            voltageV = port.voltageV
            currentA = port.currentA
            powerW = port.powerW
            attached = port.attached
            cable = port.cable
            chargingInfo = port.chargingInfo
            deviceModel = port.attachedDevice?.model
            vendor = port.attachedDevice?.vendor
        }
    }

    private struct Battery: Equatable {
        let percent: Double?
        let charging: Bool?
        let timeToFullMinutes: Int?
        let thermalLimited: Bool?

        init(_ battery: BatteryPayload) {
            percent = battery.percent
            charging = battery.charging
            timeToFullMinutes = battery.timeToFullMinutes
            thermalLimited = battery.thermalLimited
        }
    }

    private struct Device: Equatable {
        let id: String
        let kind: ChargingDeviceKind
        let model: String?
        let connected: Bool
        let firmware: String?
        let totalInputW: Double?
        let totalOutputW: Double?
        let battery: Battery?
        let temperaturesC: [Int]?
        let ports: [Port]
        let coverName: String?
        let coverIconHash: String?
        let coverIconObjectKey: String?

        init(_ device: ChargingDevicePayload) {
            id = device.id
            kind = device.kind
            model = device.model
            connected = device.connected
            firmware = device.firmware
            totalInputW = device.totalInputW
            totalOutputW = device.totalOutputW
            battery = device.battery.map(Battery.init)
            temperaturesC = device.temperaturesC
            ports = device.ports.map(Port.init)
            coverName = device.cover?.name
            coverIconHash = device.cover?.iconHash
            coverIconObjectKey = device.cover?.iconObjectKey
        }
    }

    private let devices: [Device]

    init(_ payload: ChargingDevicesPayload) {
        devices = payload.devices.map(Device.init)
    }
}

struct DesktopUploadSignature: Equatable {
    let applicationName: String
    let bundleIdentifier: String?
    let iconHash: String?

    init(_ snapshot: DesktopActivitySnapshot) {
        applicationName = snapshot.applicationName
        bundleIdentifier = snapshot.bundleIdentifier
        iconHash = snapshot.iconHash
    }
}

struct TimeZoneUploadSignature: Equatable {
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
struct AppleMusicUploadSignature: Equatable {
    let state: String
    let title: String?
    let artist: String?
    let album: String?
    let trackID: String?
    let durationMs: Int
    /// 切换循环模式要让网页知道，所以它进签名
    let repeatOne: Bool
    let queueSource: String?
    let queueIndex: Int?
    let queueTrackIDs: [String]

    init(_ snapshot: AppleMusicSnapshot) {
        state = snapshot.state
        title = snapshot.title
        artist = snapshot.artist
        album = snapshot.album
        trackID = snapshot.trackID
        durationMs = snapshot.durationMs
        repeatOne = snapshot.repeatOne
        queueSource = snapshot.queue?.source
        queueIndex = snapshot.queue?.index
        queueTrackIDs = snapshot.queue?.tracks.map {
            "\($0.trackID ?? "")\t\($0.title)\t\($0.artist ?? "")\t\($0.album ?? "")"
        } ?? []
    }
}

/// 上一次发出去的播放锚点。网页就是照这个往前推的，
/// 所以「要不要重新发」等价于「网页现在推出来的值还准不准」。
struct AppleMusicPositionAnchor {
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
