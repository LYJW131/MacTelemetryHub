import Foundation

/**
 * 上报给站点的充电设备负载 —— 多设备通用形状。
 *
 * 从前这里只有充电头一台，`StatusPayload` 的字段就直接是它的字段：三个端口、
 * 一个总输出、按端口名索引的字典。加进充电宝之后那套形状撑不住了 —— 它有电量、
 * 温度、热控、输入方向，端口名也不同（C1/C2/A 对 C1/C2/C3）。
 *
 * 所以拆成两层：**公共字段拍平在顶层**，任何一台设备都有 id、kind、连接状态、
 * 端口和总量，站点可以完全通用地渲染；**设备特有的收进子对象**（`battery`、
 * `temperaturesC`），没有就不出现。`kind` 是判别字段，以后加第三台设备只是多一
 * 个枚举值，结构不用动。
 *
 * 端口用数组不用字典：JSON 对象无序，而两台设备的端口名还不一样，字典会逼着
 * 站点去猜顺序或者硬编码名字。
 */
public enum ChargingDeviceKind: String, Codable, Sendable {
    case charger
    case powerBank
}

public struct AttachedDevicePayload: Codable, Equatable, Sendable {
    public let model: String?
    public let vendor: String?

    public init(model: String?, vendor: String?) {
        self.model = model
        self.vendor = vendor
    }

    /// 两个字段都空就别占位了，站点少一层判断。
    public var isEmpty: Bool { model == nil && vendor == nil }
}

public struct DevicePortPayload: Codable, Equatable, Sendable {
    public let name: String
    /// 真的有功率在流。**不要**拿 `powerW > 0` 反推 —— 充电宝那个槽位是粘滞的，
    /// 端口空闲后仍然留着上一次的读数。这个字段已经是解码层判断过的结果。
    public let active: Bool
    /// `"in"` / `"out"`，只有双向端口才有。充电头永远是 `"out"`。
    public let direction: String?
    public let voltageV: Double?
    public let currentA: Double?
    public let powerW: Double?
    /// 插着线但没协商上（充电宝的 5V 待机态）。充电头不上报这个。
    public let attached: Bool?
    public let cable: String?
    public let chargingInfo: String?
    public let attachedDevice: AttachedDevicePayload?

    public init(
        name: String,
        active: Bool,
        direction: String? = nil,
        voltageV: Double? = nil,
        currentA: Double? = nil,
        powerW: Double? = nil,
        attached: Bool? = nil,
        cable: String? = nil,
        chargingInfo: String? = nil,
        attachedDevice: AttachedDevicePayload? = nil
    ) {
        self.name = name
        self.active = active
        self.direction = direction
        self.voltageV = voltageV
        self.currentA = currentA
        self.powerW = powerW
        self.attached = attached
        self.cable = cable
        self.chargingInfo = chargingInfo
        self.attachedDevice = attachedDevice.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct BatteryPayload: Codable, Equatable, Sendable {
    public let percent: Double?
    public let charging: Bool?
    /// 只在充电时有意义。放电时固件发的是 0h00m，不会切成「还能用多久」。
    public let timeToFullMinutes: Int?
    /// 机身过热、拒绝充电。插着线也不进电，所以这个要单独暴露，
    /// 否则站点只会看到「插着但功率是 0」，看起来像故障。
    public let thermalLimited: Bool?
    /// 电池健康度（剩余容量 / 出厂容量）。设备只在连接时发一次，之后不会再变，
    /// 所以它按整数百分比发，也不参与「有没有变化」的判断。
    public let healthPercent: Int?

    public init(
        percent: Double?,
        charging: Bool?,
        timeToFullMinutes: Int?,
        thermalLimited: Bool?,
        healthPercent: Int? = nil
    ) {
        self.percent = percent
        self.charging = charging
        self.timeToFullMinutes = timeToFullMinutes
        self.thermalLimited = thermalLimited
        self.healthPercent = healthPercent
    }
}

public struct ChargingDevicePayload: Codable, Equatable, Sendable {
    /// 设备序列号。同一类设备可能有多台，所以身份不能靠 `kind`。
    public let id: String
    public let kind: ChargingDeviceKind
    /// 型号，例如 `A2687` / `A110G`。
    public let model: String?
    public let connected: Bool
    public let updatedAt: TimeInterval?
    public let firmware: String?
    public let totalInputW: Double?
    public let totalOutputW: Double?
    public let battery: BatteryPayload?
    public let temperaturesC: [Int]?
    /// 端口列表（充电头为 C1/C2/C3，充电宝为 C1/C2/A/B，其中 B 为底座 Pogo Pin 进电口）。
    public let ports: [DevicePortPayload]

    public init(
        id: String,
        kind: ChargingDeviceKind,
        model: String?,
        connected: Bool,
        updatedAt: TimeInterval?,
        firmware: String?,
        totalInputW: Double? = nil,
        totalOutputW: Double? = nil,
        battery: BatteryPayload? = nil,
        temperaturesC: [Int]? = nil,
        ports: [DevicePortPayload]
    ) {
        self.id = id
        self.kind = kind
        self.model = model
        self.connected = connected
        self.updatedAt = updatedAt
        self.firmware = firmware
        self.totalInputW = totalInputW
        self.totalOutputW = totalOutputW
        self.battery = battery
        self.temperaturesC = temperaturesC
        self.ports = ports
    }
}

public struct ChargingDevicesPayload: Codable, Equatable, Sendable {
    public let devices: [ChargingDevicePayload]

    public init(devices: [ChargingDevicePayload]) {
        self.devices = devices
    }

    public var isEmpty: Bool { devices.isEmpty }
}

// MARK: - 从各设备状态构造

public enum TelemetryRounding {
    /// 上报统一保留两位小数。原始读数本来就只有一位（充电宝）或三位（充电头
    /// 的毫伏毫安），两位既不丢真实精度，也不会让指纹被浮点尾巴搅得每帧都变。
    public static func twoDecimals(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

public extension ChargingDevicePayload {
    /// 充电头。端口顺序按 C1/C2/C3 固定，不跟着字典顺序跑。
    init(charger state: ChargerState, connected: Bool, model: String? = "A2687") {
        let order = ["C1", "C2", "C3"]
        let ports = order.compactMap { key -> DevicePortPayload? in
            guard let port = state.ports[key] else { return nil }
            let isActive = port.mode == "Output"
            return DevicePortPayload(
                name: key,
                active: isActive,
                direction: isActive ? "out" : nil,
                voltageV: port.voltageV.map(TelemetryRounding.twoDecimals),
                currentA: port.currentA.map(TelemetryRounding.twoDecimals),
                powerW: port.powerW.map(TelemetryRounding.twoDecimals),
                attached: nil,
                cable: port.cable,
                chargingInfo: port.chargingInfo,
                attachedDevice: AttachedDevicePayload(
                    model: port.deviceModel, vendor: port.vendor
                )
            )
        }
        self.init(
            id: state.device.serialNumber ?? "charger",
            kind: .charger,
            model: model,
            connected: connected,
            updatedAt: state.updatedAt,
            firmware: state.device.firmwareVersion,
            totalOutputW: state.totalOutputPowerW.map(TelemetryRounding.twoDecimals),
            ports: ports
        )
    }
}
