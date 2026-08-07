import Foundation

public struct PortState: Codable, Equatable, Sendable {
    public var mode = "N/A"
    public var voltageV: Double?
    public var currentA: Double?
    public var powerW: Double?
    public var cableCode: String?
    public var cable = "N/A"
    public var chargingInfo = "N/A"
    public var vendorID: UInt16?
    public var productID: UInt16?
    public var vendor: String?
    public var brandCode: UInt8?
    public var brand: String?
    public var modelCode: UInt16?
    public var deviceModel: String?
    public var identityRaw: String?
    public var brandModelRaw: String?

    public init() {}

    public var connected: Bool {
        if mode == "Output" || mode == "Input" { return true }
        if let powerW, powerW > 0.2 { return true }
        if let currentA, let voltageV { return currentA > 0.02 && voltageV > 3 }
        return false
    }
}

public struct DeviceInfo: Codable, Equatable, Sendable {
    public var macAddress: String?
    public var serialNumber: String?
    public var firmwareVersion: String?
    public var productCode: String?
    public var firmwareTag: String?

    public init() {}
}

public struct ChargerState: Codable, Equatable, Sendable {
    public var device = DeviceInfo()
    public var ports: [String: PortState] = [
        "C1": PortState(),
        "C2": PortState(),
        "C3": PortState(),
    ]
    public var totalOutputPowerW: Double?
    public var rawStatus: [String: String] = [:]
    public var updatedAt: TimeInterval?
    /// `rawStatus` is not on a timer — it holds whatever the last 0x0200 reply
    /// carried, normally the one the handshake asked for. Ports refresh ~1 Hz
    /// from the pushed stream, so the two ages are not interchangeable.
    public var rawStatusUpdatedAt: TimeInterval?

    public init() {}
}

public struct StatusPortPayload: Encodable, Equatable, Sendable {
    public let mode: Bool
    public let voltageV: Double?
    public let currentA: Double?
    public let powerW: Double?
    public let cable: String
    public let chargingInfo: String
    public let model: String?
    public let vendor: String?

    private enum CodingKeys: String, CodingKey {
        case mode, voltageV, currentA, powerW, cable, chargingInfo, model, vendor
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encodeOptional(voltageV, forKey: .voltageV)
        try container.encodeOptional(currentA, forKey: .currentA)
        try container.encodeOptional(powerW, forKey: .powerW)
        try container.encode(cable, forKey: .cable)
        try container.encode(chargingInfo, forKey: .chargingInfo)
        try container.encodeOptional(model, forKey: .model)
        try container.encodeOptional(vendor, forKey: .vendor)
    }
}

public struct StatusDevicePayload: Encodable, Equatable, Sendable {
    public let serialNumber: String?
    public let macAddress: String?
    public let firmwareVersion: String?

    private enum CodingKeys: String, CodingKey {
        case serialNumber, macAddress, firmwareVersion
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeOptional(serialNumber, forKey: .serialNumber)
        try container.encodeOptional(macAddress, forKey: .macAddress)
        try container.encodeOptional(firmwareVersion, forKey: .firmwareVersion)
    }
}

public struct StatusPayload: Encodable, Equatable, Sendable {
    public let connected: Bool
    public let updatedAt: TimeInterval?
    public let totalOutputPowerW: Double?
    public let device: StatusDevicePayload
    public let ports: [String: StatusPortPayload]

    private enum CodingKeys: String, CodingKey {
        case connected, updatedAt, totalOutputPowerW, device, ports
    }

    public init(connected: Bool, state: ChargerState) {
        self.connected = connected
        updatedAt = state.updatedAt
        totalOutputPowerW = state.totalOutputPowerW.map(Self.twoDecimals)
        device = StatusDevicePayload(
            serialNumber: state.device.serialNumber,
            macAddress: state.device.macAddress,
            firmwareVersion: state.device.firmwareVersion
        )
        ports = state.ports.mapValues { port in
            StatusPortPayload(
                mode: port.mode == "Output",
                voltageV: port.voltageV.map(Self.twoDecimals),
                currentA: port.currentA.map(Self.twoDecimals),
                powerW: port.powerW.map(Self.twoDecimals),
                cable: port.cable,
                chargingInfo: port.chargingInfo,
                model: port.deviceModel,
                vendor: port.vendor
            )
        }
    }

    private static func twoDecimals(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(connected, forKey: .connected)
        try container.encodeOptional(updatedAt, forKey: .updatedAt)
        try container.encodeOptional(totalOutputPowerW, forKey: .totalOutputPowerW)
        try container.encode(device, forKey: .device)
        try container.encode(ports, forKey: .ports)
    }
}

public enum JSONCoding {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        }
        return encoder
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeOptional<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) }
        else { try encodeNil(forKey: key) }
    }
}
