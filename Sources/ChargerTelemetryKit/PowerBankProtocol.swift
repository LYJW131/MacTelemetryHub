import Foundation

/**
 * Anker Prime Power Bank（20K, 220W，型号 A110G）的遥测解码。
 *
 * 传输层和充电头**完全一样** —— 同一个 GATT 服务、同一套 FF09 帧、同样的固定密钥
 * AES-GCM、同样的 ECDH 握手，所以这里只解 TLV 里的内容，握手照用 `A2687Protocol`。
 *
 * 两处和充电头不同，写反了会得到一个看着合理的错数：
 *
 * - **标度**：充电宝的电压电流功率全是「u16 小端 ÷10」。充电头是毫伏/毫安/厘瓦。
 * - **两位十进制对**：电量和剩余时间是 `[整数, 百分位]` 两个字节，不是 u16。
 *   当 u16 读会得到一个很大的、看起来像那么回事的错误数字。
 *
 * 字段依据见调试仓库 anker-prime-ble 的 `docs/powerbank.md`；那边的
 * `spec/fixtures/` 是这份实现的一致性契约 —— 同样的抓包字节喂进来，输出必须逐
 * 字段相等。改这个文件之后跑 `PowerBankConformanceTests`。
 */
public struct PowerBankPort: Codable, Equatable, Sendable {
    public var name: String
    /// 0 空闲 / 1 在供电 / 2 在取电。
    public var mode: UInt8 = 0
    public var voltageV: Double?
    public var currentA: Double?
    /// **粘滞**：端口空闲后仍保留上一次的功率读数，不会归零（重启才清）。
    /// 所以只有 `mode != 0` 时这个值才有意义，判断活跃一律看 `isActive`。
    public var powerW: Double?
    /// 线插着，不管有没有协商上 PD。
    public var attached: Bool = false

    public var isActive: Bool { mode != 0 }
    public var direction: String? {
        switch mode {
        case 1: "out"
        case 2: "in"
        default: nil
        }
    }
    /// 通电但没有负载 —— A 口开涓流模式时就是这个样子。
    public var isEnergized: Bool { !isActive && (voltageV ?? 0) > 0.1 }
}

public struct PowerBankState: Codable, Equatable, Sendable {
    public var serialNumber: String?
    public var firmwareVersion: String?
    public var macAddress: String?
    /// 0x0029 里那个字符串。放电时它也读作 "Charging"，是固定产品标签，不是状态。
    public var label: String?

    public var batteryPercent: Double?
    public var charging: Bool?
    public var timeToFullHours: Int?
    public var timeToFullMinutes: Int?
    /// 1 正常 / 2 过热受限。受限时插着线也不进电。
    public var thermalState: UInt8?

    public var inputPowerW: Double?
    public var outputPowerW: Double?
    /// 充电底座（Pogo Pin）。和 C 口一样会粘滞，`mode == 0` 时读数是过期的。
    public var dock: PowerBankPort?
    public var ports: [PowerBankPort] = []

    public var temperature1C: Int?
    public var temperature2C: Int?

    public var pomodoroSeconds: Int?
    public var pomodoroEnabled: Bool?

    public var updatedAt: TimeInterval?

    public init() {}

    public var isThermallyLimited: Bool { thermalState == 2 }

    public var temperatures: [Int] {
        [temperature1C, temperature2C].compactMap { $0 }
    }
}

public enum PowerBankProtocol {
    /// 广播里没有稳定的名字前缀 —— 充电宝直接播序列号，所以扫描只能靠 ff09 服务。
    public static let realtimeCommands: Set<UInt16> = [0x0300]
    public static let snapshotCommands: Set<UInt16> = [0x0200]

    static let tlvState: UInt8 = 0xA1
    static let tlvBattery: UInt8 = 0xA2
    static let tlvTimeLeft: UInt8 = 0xA3
    static let tlvThermalState: UInt8 = 0xA4
    static let tlvInputTotal: UInt8 = 0xA5
    static let tlvOutputTotal: UInt8 = 0xA6
    static let tlvDock: UInt8 = 0xA7
    static let tlvPortC1: UInt8 = 0xA8
    static let tlvPortC2: UInt8 = 0xA9
    static let tlvPortA: UInt8 = 0xAC
    static let tlvTemperature1: UInt8 = 0xAF
    static let tlvTemperature2: UInt8 = 0xB0

    /// 实时块也出现在 0x0200 快照里，TLV 号整体 +0x0D。移回去就能共用一个解码器。
    static let snapshotShift: UInt8 = 0x0D
    static let snapshotState: UInt8 = 0xA1
    static let snapshotBattery: UInt8 = 0xA6
    static let snapshotTimeLeft: UInt8 = 0xA7
    static let snapshotPomodoroSeconds: UInt8 = 0xAC
    static let snapshotPomodoroEnable: UInt8 = 0xE2

    // MARK: - 解码

    public static func parseRealtime(
        _ payload: Data,
        state: inout PowerBankState,
        now: Date = Date()
    ) {
        let fields = Dictionary(
            uniqueKeysWithValues: A2687Protocol.parseTLV(payload, offset: tlvOffset(payload))
                .map { ($0.type, TypedValue($0.value).payload) }
        )

        if let raw = fields[tlvState], let first = raw.first {
            _ = first  // 每次抓包都是 0x31，含义未知，留着不用
        }
        if let raw = fields[tlvThermalState], let first = raw.first {
            state.thermalState = first
        }
        if let raw = fields[tlvBattery] {
            state.batteryPercent = decimalPair(raw)
        }
        if let raw = fields[tlvTimeLeft], raw.count >= 3 {
            state.timeToFullHours = Int(raw[raw.startIndex + 1])
            state.timeToFullMinutes = Int(raw[raw.startIndex + 2])
        }
        if let raw = fields[tlvInputTotal] {
            state.inputPowerW = tenths(raw, at: 1)
        }
        if let raw = fields[tlvOutputTotal] {
            state.outputPowerW = tenths(raw, at: 1)
        }
        if let raw = fields[tlvDock] {
            state.dock = port(named: "DOCK", body: raw)
        }

        // 方向取自总输入功率。0xA4 是热控不是方向，底座那块会过期 —— 两个都不能用。
        state.charging = (state.inputPowerW ?? 0) > 0.05

        var decoded: [PowerBankPort] = []
        for (name, type) in [("C1", tlvPortC1), ("C2", tlvPortC2), ("A", tlvPortA)] {
            if let raw = fields[type] {
                decoded.append(port(named: name, body: raw))
            }
        }
        if !decoded.isEmpty { state.ports = decoded }

        if let raw = fields[tlvTemperature1], let first = raw.first {
            state.temperature1C = Int(first)
        }
        if let raw = fields[tlvTemperature2], let first = raw.first {
            state.temperature2C = Int(first)
        }
        state.updatedAt = now.timeIntervalSince1970
    }

    public static func parseSnapshot(
        _ payload: Data,
        state: inout PowerBankState,
        now: Date = Date()
    ) {
        var shifted = Data()
        for field in A2687Protocol.parseTLV(payload, offset: tlvOffset(payload)) {
            let mapped: UInt8
            switch field.type {
            case snapshotBattery: mapped = tlvBattery
            case snapshotTimeLeft: mapped = tlvTimeLeft
            case snapshotState: mapped = tlvState
            case snapshotPomodoroEnable:
                let decoded = TypedValue(field.value)
                if decoded.payload.count >= 3 {
                    state.pomodoroEnabled = decoded.payload[decoded.payload.startIndex] != 0
                    state.pomodoroSeconds = Int(decoded.payload.readUInt16LE(at: 1))
                }
                continue
            case snapshotPomodoroSeconds:
                if let unsigned = TypedValue(field.value).unsigned {
                    state.pomodoroSeconds = Int(unsigned)
                }
                continue
            case 0xB2...0xBE: mapped = field.type - snapshotShift
            default: continue
            }
            shifted.append(mapped)
            shifted.append(UInt8(field.value.count))
            shifted.append(field.value)
        }
        parseRealtime(shifted, state: &state, now: now)
    }

    public static func parseHandshakeInfo(_ payload: Data, state: inout PowerBankState) {
        var info = DeviceInfo()
        A2687Protocol.parseHandshakeInfo(payload, device: &info)
        state.serialNumber = info.serialNumber ?? state.serialNumber
        state.firmwareVersion = info.firmwareVersion ?? state.firmwareVersion
        state.macAddress = info.macAddress ?? state.macAddress
        for field in A2687Protocol.parseTLV(payload, offset: tlvOffset(payload))
        where field.type == 0xA2 {
            let text = A2687ProtocolText.ascii(field.value).trimmingCharacters(in: CharacterSet.whitespaces)
            if !text.isEmpty { state.label = text }
        }
    }

    // MARK: - 私有

    /// 端口块：`[模式, 电压, 电流, 功率]`，C 口后面还有一段尾巴。
    static func port(named name: String, body: Data) -> PowerBankPort {
        var reading = PowerBankPort(name: name)
        guard body.count >= 7 else { return reading }
        let base = body.startIndex
        reading.mode = body[base]
        reading.voltageV = tenths(body, at: 1)
        reading.currentA = tenths(body, at: 3)
        reading.powerW = tenths(body, at: 5)
        if body.count >= 9 {
            // [8] 是插线标志：0x07 有线、0x00 空。这是区分「插着但没协商」和
            // 「什么都没插」的唯一办法。A 口那个 8 字节块没有这一位。
            reading.attached = body[base + 8] == 0x07
        }
        return reading
    }

    static func tenths(_ data: Data, at offset: Int) -> Double? {
        guard data.count >= offset + 2 else { return nil }
        return Double(data.readUInt16LE(at: offset)) / 10.0
    }

    /// `[整数, 百分位]`。当 u16 读会得到看似合理的错误数字，所以单独成函数。
    static func decimalPair(_ data: Data) -> Double? {
        guard data.count >= 2 else { return nil }
        let base = data.startIndex
        let remainder = data[base + 1]
        guard remainder <= 99 else { return nil }
        return Double(data[base]) + Double(remainder) / 100.0
    }

    static func tlvOffset(_ payload: Data) -> Int { payload.first == 0x00 ? 1 : 0 }
}

// MARK: - 上报负载

public extension ChargingDevicePayload {
    init(powerBank state: PowerBankState, connected: Bool, model: String? = "A110G") {
        let ports = state.ports.map { port in
            DevicePortPayload(
                name: port.name,
                active: port.isActive,
                direction: port.direction,
                // 端口不活跃时不发电压电流功率 —— 那个功率槽是粘滞的，发出去
                // 站点会把几分钟前的读数当成现在的。
                voltageV: port.isActive || port.isEnergized
                    ? port.voltageV.map(TelemetryRounding.twoDecimals) : nil,
                currentA: port.isActive ? port.currentA.map(TelemetryRounding.twoDecimals) : nil,
                powerW: port.isActive ? port.powerW.map(TelemetryRounding.twoDecimals) : nil,
                attached: port.attached
            )
        }
        let minutes: Int? = {
            guard let hours = state.timeToFullHours, let mins = state.timeToFullMinutes else {
                return nil
            }
            let total = hours * 60 + mins
            // 放电时固件发 0h00m，那不是「零分钟充满」，是「不适用」。
            return total > 0 ? total : nil
        }()
        self.init(
            id: state.serialNumber ?? "powerbank",
            kind: .powerBank,
            model: model,
            connected: connected,
            updatedAt: state.updatedAt,
            firmware: state.firmwareVersion,
            totalInputW: state.inputPowerW.map(TelemetryRounding.twoDecimals),
            totalOutputW: state.outputPowerW.map(TelemetryRounding.twoDecimals),
            battery: BatteryPayload(
                percent: state.batteryPercent,
                charging: state.charging,
                timeToFullMinutes: minutes,
                thermalLimited: state.isThermallyLimited
            ),
            temperaturesC: state.temperatures.isEmpty ? nil : state.temperatures,
            // 底座那块和端口块一样是粘滞的：不在用时留着上一次的读数。
            // 所以只有 mode != 0 才发，否则会报出一个几分钟前的底座功率。
            dock: state.dock.flatMap { dock in
                dock.isActive
                    ? DevicePortPayload(
                        name: "DOCK",
                        active: true,
                        direction: dock.direction,
                        voltageV: dock.voltageV.map(TelemetryRounding.twoDecimals),
                        currentA: dock.currentA.map(TelemetryRounding.twoDecimals),
                        powerW: dock.powerW.map(TelemetryRounding.twoDecimals)
                    )
                    : nil
            },
            ports: ports
        )
    }
}
