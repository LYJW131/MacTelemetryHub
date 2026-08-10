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
