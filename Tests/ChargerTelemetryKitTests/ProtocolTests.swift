import Foundation
import Testing
@testable import ChargerTelemetryKit

@Test func initialCryptoMatchesPythonImplementation() throws {
    let plaintext = try A2687Protocol.buildTLV([
        TLVField(0xA1, Data([0x21])),
        TLVField(0xFE, Data([0x01, 0x02, 0x03, 0x04])),
    ])
    let crypto = A2687CryptoContext()
    let ciphertext = try crypto.encrypt(plaintext)
    #expect(ciphertext.uppercaseHex == "0A871E2CE23B2BB1FA61FE8562D3A86DA44F5E62BC5C2FB0A2")
    #expect(try crypto.decrypt(ciphertext) == plaintext)

    let frame = A2687Protocol.buildFrame(
        group: A2687Protocol.groupTelemetry,
        command: A2687Protocol.commandStatus,
        ciphertext: ciphertext
    )
    #expect(frame.uppercaseHex == "FF09230003000F42000A871E2CE23B2BB1FA61FE8562D3A86DA44F5E62BC5C2FB0A2F9")
    #expect(A2687Protocol.parseFrame(frame)?.command == 0x0200)
}

@Test func assemblerHandlesSplitAndOutOfSyncFrames() throws {
    let ciphertext = try A2687CryptoContext().encrypt(Data([0xA1, 0x01, 0x21]))
    let frame = A2687Protocol.buildFrame(group: 0x0F, command: 0x0200, ciphertext: ciphertext)
    var assembler = FrameAssembler()
    #expect(assembler.feed(Data([0x00, 0x99]) + frame.prefix(7)).isEmpty)
    let result = assembler.feed(Data(frame.dropFirst(7)))
    #expect(result == [frame])
}

@Test func userIdentityIsInjectedIntoBothAuthenticatedCommands() throws {
    let userID = String(repeating: "a", count: 40)
    let steps = try A2687Protocol.postSessionSteps(userID: userID, date: Date(timeIntervalSince1970: 1))
    let auth = try #require(steps.first(where: { $0.command == 0x0027 }))
    #expect(auth.fields.contains(TLVField(0xA2, Data(userID.utf8))))

    let probe = try A2687Protocol.realtimeProbe(userID: userID, date: Date(timeIntervalSince1970: 1))
    #expect(probe.contains(TLVField(0xA3, Data([0x04]) + Data(userID.utf8))))
    #expect(throws: ProtocolError.self) {
        try A2687Protocol.realtimeProbe(userID: "wrong")
    }
}

@Test func statusPayloadUsesMinimalShapeAndTwoDecimalNumbers() throws {
    var state = ChargerState()
    state.updatedAt = 123.5
    state.totalOutputPowerW = 15.095
    state.device.serialNumber = "ASHDJW7CF49200487"
    var c3 = PortState()
    c3.mode = "Output"
    c3.voltageV = 19.864
    c3.currentA = 0.765
    c3.powerW = 15.095
    c3.cable = "EPR-240W MAX"
    c3.chargingInfo = "Apple PD Fast Charging"
    c3.deviceModel = "MacBook Pro series"
    c3.vendor = "Apple"
    state.ports["C3"] = c3

    let payload = StatusPayload(connected: true, state: state)
    #expect(payload.totalOutputPowerW == 15.1)
    #expect(payload.ports["C3"]?.voltageV == 19.86)
    #expect(payload.ports["C3"]?.currentA == 0.77)
    let object = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(payload)) as? [String: Any])
    #expect(Set(object.keys) == ["connected", "updatedAt", "totalOutputPowerW", "device", "ports"])
    let port = try #require((object["ports"] as? [String: Any])?["C3"] as? [String: Any])
    #expect(Set(port.keys) == ["mode", "voltageV", "currentA", "powerW", "cable", "chargingInfo", "model", "vendor"])
}

@Test func disconnectedStatusStillContainsEveryNullableField() throws {
    let object = try #require(JSONSerialization.jsonObject(
        with: JSONCoding.encoder().encode(StatusPayload(connected: false, state: ChargerState()))
    ) as? [String: Any])
    #expect(Set(object.keys) == ["connected", "updatedAt", "totalOutputPowerW", "device", "ports"])
    #expect(object["updatedAt"] is NSNull)
    #expect(object["totalOutputPowerW"] is NSNull)
    let device = try #require(object["device"] as? [String: Any])
    #expect(Set(device.keys) == ["serialNumber", "macAddress", "firmwareVersion"])
    let c1 = try #require((object["ports"] as? [String: Any])?["C1"] as? [String: Any])
    #expect(Set(c1.keys) == ["mode", "voltageV", "currentA", "powerW", "cable", "chargingInfo", "model", "vendor"])
}

@Test func realtimeParserDecodesPortCableAndObservedAppleIdentity() throws {
    var payload = Data([0x00])
    payload.append(try A2687Protocol.buildTLV([
        TLVField(0xA7, Data([0x04, 0x01, 0x98, 0x4D, 0xFD, 0x02, 0xE5, 0x05])),
        TLVField(0xAE, Data([0x04, 0x02, 0x01])),
        TLVField(0xB4, Data([0x04]) + Data(hex: "FAFFFBFFFAFFFBFFAC051973")!),
    ]))
    var state = ChargerState()
    let changed = A2687Protocol.parseRealtime(
        payload,
        command: 0x0300,
        state: &state,
        now: Date(timeIntervalSince1970: 456)
    )
    #expect(changed)
    #expect(state.updatedAt == 456)
    #expect(state.ports["C3"]?.mode == "Output")
    #expect(state.ports["C3"]?.voltageV == 19.864)
    #expect(state.ports["C3"]?.currentA == 0.765)
    #expect(state.ports["C3"]?.powerW == 15.09)
    #expect(state.ports["C3"]?.cable == "EPR-240W MAX")
    #expect(state.ports["C3"]?.chargingInfo == "Apple PD Fast Charging")
    #expect(state.ports["C3"]?.vendor == "Apple")
    #expect(state.ports["C3"]?.deviceModel == "MacBook Pro series")
}

@Test func screensaverSelectBodyMatchesOfficial47ByteLayout() throws {
    let fields = A2687Protocol.screensaverSelectFields(
        pictureID: 24551,
        hashCode: 0x1DA2DDCA,
        date: Date(timeIntervalSince1970: 1)
    )
    let body = try A2687Protocol.buildTLV(fields)
    #expect(body.count == 47)
    #expect(
        body.uppercaseHex ==
        "A10121A3020103A40504E75F0000A50504CADDA21DFD1100536D616C6C4368617267696E6755726CFE050301000000"
    )
}

@Test func screensaverFieldDecodesCloudID() throws {
    let typed = Data(hex: "048003E75F000000000000")!
    let parsed = A2687Protocol.parseScreensaverField(typed)
    #expect(parsed?.id == 24551)
    #expect(parsed?.flags == 0x0380)

    var payload = Data([0x00])
    payload.append(try A2687Protocol.buildTLV([
        TLVField(0xE1, typed),
        TLVField(0xA7, Data([0x04, 0x01, 0x98, 0x4D, 0xFD, 0x02, 0xE5, 0x05])),
    ]))
    var state = ChargerState()
    #expect(A2687Protocol.parseRealtime(payload, command: 0x0300, state: &state))
    #expect(state.screensaverId == 24551)
    #expect(state.screensaverFlags == 0x0380)
}

@Test func screensaverTransferBodiesMatchOfficialLayouts() throws {
    let start = try A2687Protocol.buildTLV(
        A2687Protocol.screensaverTransferStartFields(
            pictureID: 45470,
            hashCode: 0xC126BFEF,
            fileSize: 25397,
            chunkCount: 163,
            date: Date(timeIntervalSince1970: 1)
        )
    )
    #expect(start.count == 49)
    #expect(
        start.uppercaseHex ==
        "A10121A2020101A305049EB10000A40504EFBF26C1A5050335630000A602010AA703029C00A80302A300FE050301000000"
    )

    let last = Data([0xFF])
    let chunk = try A2687Protocol.buildTLV(A2687Protocol.screensaverChunkFields(seq: 162, data: last))
    #expect(chunk.count == 167)
    #expect(chunk[0] == 0xA1)
    #expect(Array(chunk[3..<8]) == [0xA2, 0x03, 0x02, 0xA2, 0x00])
    #expect(chunk[8] == 0xA3)
    #expect(chunk[9] == 0x9D)
    #expect(chunk[10] == 0x04)
    #expect(chunk[11] == 0xFF)
    #expect(chunk.suffix(155).allSatisfy { $0 == 0 })

    let slices = A2687Protocol.screensaverChunks(Data(count: 25397))
    #expect(slices.count == 163)
    #expect(slices.last?.count == 25397 - 162 * 156)
    #expect(A2687Protocol.isCloudOnlySelectAck(Data([0x11, 0xA1, 0x01, 0x31])))
    #expect(!A2687Protocol.isCloudOnlySelectAck(Data([0x00, 0xA1, 0x01, 0x31])))
}

@Test func passportPasswordUsesAES256CBCWithSharedSecretPrefixIV() throws {
    let key = Data((0 as UInt8)..<32)
    let ciphertext = try AnkerPassportCrypto.aes256CBCEncrypt(
        key: key,
        iv: key.prefix(16),
        plaintext: Data("test-password".utf8)
    )
    #expect(ciphertext.base64EncodedString() == "/pwCUy+lmRxTF2oWJX1Qrg==")
    #expect(AnkerPassportCrypto.parseHashCode("0x1da2ddca") == 0x1DA2DDCA)
    #expect(AnkerPassportCrypto.parseHashCode("43B2E02C") == 0x43B2E02C)
}

@Test func powerBankIdleIgnoresStaleVoltageAndCountsChargeOrDischarge() {
    var idle = PowerBankState()
    idle.batteryPercent = 80
    idle.inputPowerW = 0
    idle.outputPowerW = 0
    idle.charging = false
    idle.ports = [
        PowerBankPort(name: "A", mode: 0, voltageV: 5.1, attached: true),
        PowerBankPort(name: "B", mode: 0, voltageV: 12, attached: false),
    ]
    #expect(!idle.isBusy)
    #expect(idle.ports[0].isEnergized)

    var charging = idle
    charging.inputPowerW = 30
    charging.charging = true
    charging.ports[0].mode = 2
    #expect(charging.isBusy)

    var discharging = idle
    discharging.outputPowerW = 12
    discharging.ports = [PowerBankPort(name: "C1", mode: 1, powerW: 12)]
    #expect(discharging.isBusy)
}
