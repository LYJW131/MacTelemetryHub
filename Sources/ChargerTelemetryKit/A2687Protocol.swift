import Foundation

public struct TLVField: Equatable, Sendable {
    public let type: UInt8
    public let value: Data

    public init(_ type: UInt8, _ value: Data) {
        self.type = type
        self.value = value
    }
}

public struct A2687Frame: Equatable, Sendable {
    public let command: UInt16
    public let encrypted: Bool
    public let acknowledged: Bool
    public let body: Data
    public let raw: Data
}

public struct FrameAssembler: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while buffer.count >= 4 {
            guard buffer[0] == 0xFF, buffer[1] == 0x09 else {
                buffer = Data(buffer.dropFirst())
                continue
            }
            let frameLength = Int(buffer.readUInt16LE(at: 2))
            guard (10...4096).contains(frameLength) else {
                buffer = Data(buffer.dropFirst())
                continue
            }
            guard buffer.count >= frameLength else { break }
            frames.append(Data(buffer.prefix(frameLength)))
            buffer = Data(buffer.dropFirst(frameLength))
        }
        return frames
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}

public enum A2687Protocol {
    public static let serviceUUID = "8C850001-0302-41C5-B46E-CF057C562025"
    public static let writeCharacteristicUUID = "8C850002-0302-41C5-B46E-CF057C562025"
    public static let notifyCharacteristicUUID = "8C850003-0302-41C5-B46E-CF057C562025"
    public static let advertisedServiceUUID = "0000FF09-0000-1000-8000-00805F9B34FB"
    public static let deviceNamePrefix = "ASHDJW"

    public static let groupSession: UInt8 = 0x01
    public static let groupTelemetry: UInt8 = 0x0F
    public static let commandStatus: UInt16 = 0x0200
    public static let commandRealtime: UInt16 = 0x020A

    private static let flagEncrypted: UInt8 = 0x40
    private static let flagAcknowledged: UInt8 = 0x08
    private static let statusSnapshotCommands: Set<UInt16> = [0x0200, 0x0A00, 0x0040, 0x0405]
    private static let identitySentinels: Set<UInt16> = [
        0x0000, 0xFFFA, 0xFFFB, 0xFFFC, 0xFFFD, 0xFFFE, 0xFFFF,
    ]

    private static let cableProfiles: [String: (String, String?)] = [
        "0100": ("5A-100W MAX", nil),
        "0200": ("EPR-240W MAX", nil),
        "0201": ("EPR-240W MAX", "Apple PD Fast Charging"),
    ]
    private static let cableCapabilityLabels = [
        "00": "3A-60W MAX", "01": "5A-100W MAX", "02": "EPR-240W MAX",
    ]
    private static let chargingInfoLabels = [
        "01": "Apple PD Fast Charging",
        "02": "Samsung Fast Charging",
        "03": "Samsung Super Fast Charging",
    ]
    private static let vendorNames: [UInt16: String] = [
        0x05AC: "Apple", 0x04E8: "Samsung", 0x2717: "Xiaomi", 0x12D1: "Huawei",
        0x18D1: "Google", 0x1004: "LG", 0x0451: "Texas Instruments",
        0x291A: "Anker", 0x03F0: "HP", 0x413C: "Dell", 0x17EF: "Lenovo",
        0x045E: "Microsoft", 0x0B05: "ASUS", 0x0DB0: "MSI", 0x1532: "Razer",
    ]
    private static let deviceModels: [UInt32: String] = [
        modelKey(0x05AC, 0x7519): "iPhone 17 series",
        modelKey(0x05AC, 0x7319): "MacBook Pro series",
        modelKey(0x05AC, 0x7117): "iPad Pro series",
        modelKey(0x291A, 0x110B): "20K Prime Power Bank",
    ]
    private static let brandNames: [UInt8: String] = [
        0x01: "Apple", 0x02: "Samsung", 0x03: "Xiaomi", 0x04: "Huawei",
        0x05: "Google", 0x06: "LG", 0x07: "IDT", 0x08: "TI", 0x09: "YBZ",
        0x0A: "Anker", 0x0B: "Honor", 0x0C: "HP", 0x0D: "Dell",
        0x0E: "Lenovo", 0x0F: "Microsoft", 0x10: "ASUS", 0x11: "ASUS",
        0x12: "MSI", 0x13: "Razer",
    ]

    public static func buildTLV(_ fields: [TLVField]) throws -> Data {
        var result = Data()
        for field in fields {
            guard field.value.count <= 0xFF else {
                throw ProtocolError.valueTooLong(field.type, field.value.count)
            }
            result.append(field.type)
            result.append(UInt8(field.value.count))
            result.append(field.value)
        }
        return result
    }

    public static func parseTLV(_ payload: Data, offset: Int = 0) -> [TLVField] {
        guard offset >= 0, offset <= payload.count else { return [] }
        var fields: [TLVField] = []
        var index = offset
        while index + 1 < payload.count {
            let type = payload[index]
            let length = Int(payload[index + 1])
            guard index + 2 + length <= payload.count else { break }
            fields.append(TLVField(type, Data(payload[(index + 2)..<(index + 2 + length)])))
            index += 2 + length
        }
        return fields
    }

    public static func buildFrame(group: UInt8, command: UInt16, ciphertext: Data) -> Data {
        let high = UInt8((command >> 8) & 0xFF) | flagEncrypted
        let low = UInt8(command & 0xFF)
        var payload = Data([0x03, 0x00, group, high, low])
        payload.append(ciphertext)
        var message = Data([0xFF, 0x09])
        message.appendUInt16LE(UInt16(payload.count + 5))
        message.append(payload)
        message.append(message.reduce(0, ^))
        return message
    }

    public static func parseFrame(_ raw: Data) -> A2687Frame? {
        guard raw.count >= 10 else { return nil }
        let payload = raw.dropFirst(4).dropLast()
        guard payload.count >= 5 else { return nil }
        let high = payload[payload.startIndex + 3]
        let low = payload[payload.startIndex + 4]
        let commandHigh = high & ~(flagEncrypted | flagAcknowledged)
        return A2687Frame(
            command: UInt16(commandHigh) << 8 | UInt16(low),
            encrypted: high & flagEncrypted != 0,
            acknowledged: high & flagAcknowledged != 0,
            body: Data(payload.dropFirst(5)),
            raw: raw
        )
    }

    public static func epochBytes(date: Date = Date()) -> Data {
        var data = Data()
        data.appendUInt32LE(UInt32(truncatingIfNeeded: Int64(date.timeIntervalSince1970)))
        return data
    }

    public static func handshakeSteps(date: Date = Date()) -> [HandshakeStep] {
        let timestamp = epochBytes(date: date)
        return [
            HandshakeStep(command: 0x0001, fields: [TLVField(0xA1, timestamp)], expectsResponse: true),
            HandshakeStep(
                command: 0x0003,
                fields: [TLVField(0xA1, timestamp), TLVField(0xA3, Data([0x20])), TLVField(0xA4, Data([0x00, 0xF0]))],
                expectsResponse: true
            ),
            HandshakeStep(command: 0x0029, fields: [TLVField(0xA1, timestamp)], expectsResponse: true),
            HandshakeStep(
                command: 0x0005,
                fields: [
                    TLVField(0xA1, timestamp), TLVField(0xA3, Data([0x20])),
                    TLVField(0xA4, Data([0x29, 0x01])), TLVField(0xA5, Data([0x44])),
                    TLVField(0xA6, Data([0x02])),
                ],
                expectsResponse: true
            ),
        ]
    }

    public static func postSessionSteps(userID: String, date: Date = Date()) throws -> [HandshakeStep] {
        let encoded = try validateUserID(userID)
        return [
            HandshakeStep(
                command: 0x0022,
                fields: [
                    TLVField(0xA1, epochBytes(date: date)),
                    TLVField(0xA3, Data([0x80, 0x8F, 0xFF, 0xFF])),
                    TLVField(0xA5, Data("CST-8".utf8)),
                ],
                expectsResponse: false
            ),
            HandshakeStep(
                command: 0x0027,
                fields: [TLVField(0xA1, epochBytes(date: date)), TLVField(0xA2, encoded)],
                expectsResponse: false
            ),
        ]
    }

    public static func statusProbe(date: Date = Date()) -> [TLVField] {
        [TLVField(0xA1, Data([0x21])), TLVField(0xFE, epochBytes(date: date))]
    }

    public static func realtimeProbe(userID: String, date: Date = Date()) throws -> [TLVField] {
        let encoded = try validateUserID(userID)
        var identity = Data([0x04])
        identity.append(encoded)
        return [
            TLVField(0xA1, Data([0x21])),
            TLVField(0xA2, Data([0x04, 0x55, 0x53])),
            TLVField(0xA3, identity),
            TLVField(0xA5, Data([0x01, 0x01])),
            TLVField(0xFE, epochBytes(date: date)),
        ]
    }

    public static func findDevicePublicKey(in payload: Data) -> Data? {
        parseTLV(payload, offset: tlvOffset(payload)).first { $0.type == 0xA1 && $0.value.count == 64 }?.value
    }

    @discardableResult
    public static func parseRealtime(
        _ payload: Data,
        command: UInt16,
        state: inout ChargerState,
        now: Date = Date()
    ) -> Bool {
        let fields = Dictionary(uniqueKeysWithValues: parseTLV(payload, offset: tlvOffset(payload)).map { ($0.type, TypedValue($0.value)) })
        let portTypes: [(UInt8, String)] = [(0xA5, "C1"), (0xA6, "C2"), (0xA7, "C3")]
        let cableTypes: [(UInt8, String)] = [(0xAC, "C1"), (0xAD, "C2"), (0xAE, "C3")]
        // 0xA5/0xA6/0xA7 是端口结构体，用到的是前 7 字节：第 1 字节是端口开关位，
        // 其后依次是电压、电流、功率各两字节小端。没有这个结构就是这帧不带端口数据。
        let hasPortStruct = portTypes.contains { type, _ in
            guard let value = fields[type] else { return false }
            return value.tag == 0x04 && value.payload.count >= 7
        }
        guard hasPortStruct else { return false }

        var changed = false
        if !statusSnapshotCommands.contains(command) {
            var total = 0.0
            for (type, key) in portTypes {
                guard let decoded = fields[type], decoded.tag == 0x04, decoded.payload.count >= 7 else { continue }
                let bytes = decoded.payload
                var port = state.ports[key] ?? PortState()
                port.mode = bytes[0] == 0 ? "Off" : "Output"
                port.voltageV = Double(bytes.readUInt16LE(at: 1)) / 1000
                port.currentA = Double(bytes.readUInt16LE(at: 3)) / 1000
                port.powerW = Double(bytes.readUInt16LE(at: 5)) / 100
                if bytes[0] != 0 { total += port.powerW ?? 0 }
                state.ports[key] = port
                changed = true
            }
            if changed { state.totalOutputPowerW = (total * 100).rounded() / 100 }
        }

        for (type, key) in cableTypes where fields[type] != nil {
            var port = state.ports[key] ?? PortState()
            applyCable(to: &port, typedValue: fields[type])
            state.ports[key] = port
            changed = true
        }
        if applyIdentity(fields, state: &state) { changed = true }
        if changed { state.updatedAt = now.timeIntervalSince1970 }
        return changed
    }

    public static func parseStatusSnapshot(_ payload: Data, state: inout ChargerState, now: Date = Date()) {
        let names: [UInt8: String] = [
            0xA1: "state_code", 0xA2: "serial_or_identifier", 0xA4: "product_code",
            0xD0: "port_config_0", 0xD1: "port_config_1", 0xFD: "firmware_tag",
        ]
        var snapshot: [String: String] = [:]
        for field in parseTLV(payload, offset: tlvOffset(payload)) {
            let decoded = TypedValue(field.value)
            let name = names[field.type] ?? String(format: "field_0x%02X", field.type)
            if let text = decoded.text {
                snapshot[name] = text
            } else if let unsigned = decoded.unsigned {
                snapshot[name] = String(unsigned)
            } else {
                snapshot[name] = field.value.hex
            }
            if field.type == 0xA2, let text = decoded.text, state.device.serialNumber == nil {
                state.device.serialNumber = text
            } else if field.type == 0xA4, let text = decoded.text {
                state.device.productCode = text
            } else if field.type == 0xFD, let text = decoded.text {
                state.device.firmwareTag = text
            }
        }
        state.rawStatus = snapshot
        state.rawStatusUpdatedAt = now.timeIntervalSince1970
        state.updatedAt = now.timeIntervalSince1970
    }

    public static func parseHandshakeInfo(_ payload: Data, device: inout DeviceInfo) {
        let offset: Int
        if payload.first == 0x00 {
            offset = 1
        } else if payload.count > 5, payload[0] == 0x03, payload[1] == 0x00 {
            offset = 6
        } else {
            offset = 0
        }
        for field in parseTLV(payload, offset: offset) {
            let text = printableASCII(field.value).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if field.type == 0xA3, looksLikeFirmware(text) { device.firmwareVersion = text }
            if field.type == 0xA4, looksLikeSerial(text) { device.serialNumber = text }
            if field.type == 0xA5, let mac = macAddress(field.value) { device.macAddress = mac }
            if device.firmwareVersion == nil, looksLikeFirmware(text) { device.firmwareVersion = text }
            if device.serialNumber == nil, looksLikeSerial(text) { device.serialNumber = text }
            if device.macAddress == nil, field.value.count >= 6,
               !(0x20...0x7E).contains(field.value[0]) || !(0x20...0x7E).contains(field.value[1]),
               let mac = macAddress(field.value) {
                device.macAddress = mac
            }
        }
    }

    private static func validateUserID(_ userID: String) throws -> Data {
        guard userID.utf8.count == 40, userID.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw ProtocolError.invalidUserID
        }
        return Data(userID.utf8)
    }

    private static func tlvOffset(_ payload: Data) -> Int { payload.first == 0x00 ? 1 : 0 }

    private static func cableProfile(_ code: String?) -> (String, String?)? {
        guard let code else { return nil }
        if let profile = cableProfiles[code] { return profile }
        let normalized = code.uppercased()
        guard normalized.count == 4, normalized.allSatisfy({ $0.isHexDigit }),
              let label = cableCapabilityLabels[String(normalized.prefix(2))] else { return nil }
        return (label, chargingInfoLabels[String(normalized.suffix(2))])
    }

    private static func cableCode(_ value: TypedValue?) -> String? {
        guard let value, value.tag == 0x04, value.payload.count >= 2 else { return nil }
        return value.payload.suffix(2).map { String(format: "%02X", $0) }.joined()
    }

    private static func applyCable(to port: inout PortState, typedValue: TypedValue?) {
        let code = cableCode(typedValue)
        port.cableCode = code
        if let code {
            if code.uppercased().hasPrefix("03") {
                port.cable = nil
            } else {
                port.cable = cableProfile(code)?.0 ?? "UNKNOWN (\(code))"
            }
        } else {
            port.cable = port.connected ? "Connected" : nil
        }
        port.chargingInfo = port.connected ? cableProfile(code)?.1 : nil
    }

    private static func applyIdentity(_ fields: [UInt8: TypedValue], state: inout ChargerState) -> Bool {
        let order = ["C1", "C2", "C3"]
        var changed = false
        if let decoded = fields[0xB4], decoded.tag == 0x04, decoded.payload.count >= 12 {
            for (index, key) in order.enumerated() {
                let offset = index * 4
                let slot = Data(decoded.payload[offset..<(offset + 4)])
                let vendorID = slot.readUInt16LE(at: 0)
                let productID = slot.readUInt16LE(at: 2)
                var port = state.ports[key] ?? PortState()
                port.identityRaw = slot.hex
                if identitySentinels.contains(vendorID) {
                    port.vendorID = nil
                    port.productID = nil
                    port.vendor = nil
                    port.deviceModel = nil
                } else {
                    port.vendorID = vendorID
                    port.productID = identitySentinels.contains(productID) ? nil : productID
                    port.vendor = vendorNames[vendorID]
                    port.deviceModel = port.productID.flatMap { deviceModels[modelKey(vendorID, $0)] }
                }
                state.ports[key] = port
                changed = true
            }
        }
        if let decoded = fields[0xB5], decoded.tag == 0x04, decoded.payload.count >= 12 {
            for (index, key) in order.enumerated() {
                let offset = index * 4
                let slot = Data(decoded.payload[offset..<(offset + 4)])
                var port = state.ports[key] ?? PortState()
                port.brandModelRaw = slot.hex
                if slot.allSatisfy({ $0 == 0xFF }) || slot.allSatisfy({ $0 == 0 }) {
                    port.brandCode = nil
                    port.brand = nil
                    port.modelCode = nil
                } else {
                    port.brandCode = slot[0]
                    port.brand = brandNames[slot[0]]
                    port.modelCode = slot.readUInt16LE(at: 1)
                }
                state.ports[key] = port
                changed = true
            }
        }
        return changed
    }


    private static func modelKey(_ vendor: UInt16, _ product: UInt16) -> UInt32 {
        UInt32(vendor) << 16 | UInt32(product)
    }

    private static func printableASCII(_ data: Data) -> String {
        String(data.map { (0x20..<0x7F).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }

    private static func looksLikeFirmware(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.filter({ !$0.isEmpty }).allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private static func looksLikeSerial(_ text: String) -> Bool {
        (10...30).contains(text.count) &&
            text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } &&
            !looksLikeFirmware(text)
    }

    private static func macAddress(_ data: Data) -> String? {
        guard data.count >= 6 else { return nil }
        let bytes = data.prefix(6)
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

public struct HandshakeStep: Sendable {
    public let command: UInt16
    public let fields: [TLVField]
    public let expectsResponse: Bool

    public init(command: UInt16, fields: [TLVField], expectsResponse: Bool) {
        self.command = command
        self.fields = fields
        self.expectsResponse = expectsResponse
    }
}

public enum ProtocolError: LocalizedError, Equatable {
    case invalidUserID
    case valueTooLong(UInt8, Int)

    public var errorDescription: String? {
        switch self {
        case .invalidUserID:
            "Anker 用户 ID 必须是正好 40 个 ASCII 字符"
        case let .valueTooLong(type, length):
            String(format: "TLV 0x%02X 过长：%d 字节", type, length)
        }
    }
}

private struct TypedValue {
    let tag: UInt8
    let payload: Data
    let text: String?
    let unsigned: UInt64?
    let signed: Int64?

    init(_ raw: Data) {
        guard let first = raw.first else {
            tag = 0xFF; payload = Data(); text = nil; unsigned = nil; signed = nil
            return
        }
        tag = first
        payload = Data(raw.dropFirst())
        switch tag {
        case 0x00:
            text = A2687ProtocolText.ascii(payload).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            unsigned = nil; signed = nil
        case 0x01 where payload.count >= 1:
            text = nil; unsigned = UInt64(payload[0]); signed = Int64(Int8(bitPattern: payload[0]))
        case 0x02 where payload.count >= 2:
            text = nil; unsigned = UInt64(payload.readUInt16LE(at: 0)); signed = Int64(Int16(bitPattern: payload.readUInt16LE(at: 0)))
        case 0x03 where payload.count >= 4:
            text = nil; unsigned = UInt64(payload.readUInt32LE(at: 0)); signed = Int64(Int32(bitPattern: payload.readUInt32LE(at: 0)))
        default:
            text = nil; unsigned = nil; signed = nil
        }
    }
}

private enum A2687ProtocolText {
    static func ascii(_ data: Data) -> String {
        String(data.map { (0x20..<0x7F).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }
}

extension Data {
    fileprivate mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8(value >> 8))
    }

    fileprivate mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF)); append(UInt8((value >> 24) & 0xFF))
    }

    fileprivate func readUInt16LE(at offset: Int) -> UInt16 {
        let first = self[index(startIndex, offsetBy: offset)]
        let second = self[index(startIndex, offsetBy: offset + 1)]
        return UInt16(first) | UInt16(second) << 8
    }

    fileprivate func readUInt32LE(at offset: Int) -> UInt32 {
        let b0 = self[index(startIndex, offsetBy: offset)]
        let b1 = self[index(startIndex, offsetBy: offset + 1)]
        let b2 = self[index(startIndex, offsetBy: offset + 2)]
        let b3 = self[index(startIndex, offsetBy: offset + 3)]
        return UInt32(b0) | UInt32(b1) << 8 | UInt32(b2) << 16 | UInt32(b3) << 24
    }

    fileprivate var hex: String { map { String(format: "%02X", $0) }.joined() }
}
