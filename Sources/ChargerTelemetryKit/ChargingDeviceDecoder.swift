import Foundation

/**
 * 一条 BLE 链路需要知道的、关于「对面是哪台设备」的全部信息。
 *
 * 传输层两台设备完全一样，不一样的只有 TLV 里的内容和几个连接习惯。把这些差异
 * 收进一个解码器对象之后，链路那边就不用再关心对面是充电头还是充电宝 —— 它只
 * 负责连上、握手、把帧丢进来，然后问一句「有没有可上报的东西」。
 *
 * 加第三台设备就是再写一个实现，链路、上报、界面都不用动。
 */
public protocol ChargingDeviceDecoder: AnyObject {
    var kind: ChargingDeviceKind { get }
    /// 界面上的名字，也用在错误提示里。
    var displayName: String { get }
    /// 型号，进上报负载。
    var model: String { get }
    /// 广播里的名字前缀，配对扫描用来过滤。充电宝没有（它直接播序列号），
    /// 那种情况下只能靠 ff09 服务 UUID 认。
    var namePrefix: String? { get }
    /// 0x0027 是否要带上 Anker 账号 ID。
    ///
    /// 两台设备都要，但原因不同：充电头没有它根本不推流；充电宝**会**推，然后
    /// 26 秒后把链路断掉。带上它会话才能一直维持。
    var needsAccountID: Bool { get }
    /// 是否发 0x020A 实时探测。充电头要，充电宝从 0x0022 之后就自己推了。
    var needsRealtimeProbe: Bool { get }

    /// 断开重连时清空，避免把上一段会话的读数当成新的。
    func reset()
    func handleHandshakeInfo(_ payload: Data)
    /// 返回 true 表示这一帧带来了新的遥测数据（用来叫醒上报循环）。
    func handleFrame(command: UInt16, payload: Data) -> Bool
    /// 已经收到过至少一帧遥测。没有的话不该往上报里塞一个空壳。
    var hasTelemetry: Bool { get }
    func payload(connected: Bool) -> ChargingDevicePayload?
}

// MARK: - 充电头

public final class ChargerDecoder: ChargingDeviceDecoder {
    public private(set) var state = ChargerState()

    public init() {}

    public let kind = ChargingDeviceKind.charger
    public let displayName = "充电头"
    public let model = "A2687"
    public let namePrefix: String? = A2687Protocol.deviceNamePrefix
    public let needsAccountID = true
    public let needsRealtimeProbe = true

    public func reset() { state = ChargerState() }

    public func handleHandshakeInfo(_ payload: Data) {
        A2687Protocol.parseHandshakeInfo(payload, device: &state.device)
    }

    public func handleFrame(command: UInt16, payload: Data) -> Bool {
        switch command {
        case 0x0200, 0x0A00:
            A2687Protocol.parseStatusSnapshot(payload, state: &state)
            return A2687Protocol.parseRealtime(payload, command: command, state: &state)
        case 0x020A, 0x0207, 0x0206, 0x4300, 0x0300, 0x0303, 0x0410:
            return A2687Protocol.parseRealtime(payload, command: command, state: &state)
        default:
            return false
        }
    }

    public var hasTelemetry: Bool { state.updatedAt != nil }

    public func payload(connected: Bool) -> ChargingDevicePayload? {
        guard hasTelemetry else { return nil }
        return ChargingDevicePayload(charger: state, connected: connected, model: model)
    }
}

// MARK: - 充电宝

public final class PowerBankDecoder: ChargingDeviceDecoder {
    public private(set) var state = PowerBankState()

    public init() {}

    public let kind = ChargingDeviceKind.powerBank
    public let displayName = "充电宝"
    public let model = "A110G"
    /// 充电宝广播的是自己的序列号，没有稳定前缀，所以配对扫描只能认 ff09 服务，
    /// 再把名字以充电头前缀开头的排除掉。
    public let namePrefix: String? = nil
    /// 不带它只能拿到 26 秒的未认证会话，到点断链。
    public let needsAccountID = true
    public let needsRealtimeProbe = false

    public func reset() { state = PowerBankState() }

    public func handleHandshakeInfo(_ payload: Data) {
        PowerBankProtocol.parseHandshakeInfo(payload, state: &state)
    }

    public func handleFrame(command: UInt16, payload: Data) -> Bool {
        if PowerBankProtocol.snapshotCommands.contains(command) {
            PowerBankProtocol.parseSnapshot(payload, state: &state)
            return true
        }
        if PowerBankProtocol.realtimeCommands.contains(command) {
            PowerBankProtocol.parseRealtime(payload, state: &state)
            return true
        }
        return false
    }

    public var hasTelemetry: Bool { state.updatedAt != nil }

    public func payload(connected: Bool) -> ChargingDevicePayload? {
        guard hasTelemetry else { return nil }
        return ChargingDevicePayload(powerBank: state, connected: connected, model: model)
    }
}
