import Foundation
import Testing

@testable import ChargerTelemetryKit

/**
 * 一致性测试：拿真机抓包喂进 Swift 解码器，输出必须和调试仓库的标准解码一致。
 *
 * 为什么需要这个：协议有两份实现（这里的 Swift 和调试仓库的 Python），而且没法
 * 共享代码 —— 这个 app 在进程内跑 CoreBluetooth。常量写错了当场就连不上，很好
 * 发现；真正危险的是**对某个字节的理解不一样**，那会安静地产生一堆看着合理的
 * 错数字。调试仓库的 NOTES.md 里记着五个这样的错误假设，每一个当时都很有说服力。
 *
 * 所以契约是行为性的：`Contract/captures/` 是原始帧，`Contract/fixtures/` 是每
 * 一帧之后应有的解码状态。两边都由 `Tools/sync-protocol-contract.sh` 从调试仓库
 * 同步，不要手改。
 */
private struct Fixture: Decodable {
    struct Frame: Decodable {
        let command: UInt16
        let state: FixtureState
    }
    let capture: String
    let device: String
    let frames: [Frame]
}

/// 只解出这份实现该负责的字段。Python 那边的 `unknown` 原始字节不参与比对 ——
/// 那是给继续解协议用的，不是给上报用的。
private struct FixtureState: Decodable {
    let serial: String?
    let firmware: String?
    let battery_percent: Double?
    let charging: Bool?
    let thermal_state: Int?
    let thermal_limited: Bool?
    let time_left_hours: Int?
    let time_left_minutes: Int?
    let input_power_w: Double?
    let output_power_w: Double?
    let temperature_1_c: Int?
    let temperature_2_c: Int?
    let pomodoro_seconds: Int?
    let battery_health_percent: Int?
    let pomodoro_enabled: Bool?
    let ports: [FixturePort]
}

private struct FixturePort: Decodable {
    let name: String
    let mode: Int
    let direction: String?
    let active: Bool
    let attached: Bool
    let energized: Bool
    let voltage_v: Double?
    let current_a: Double?
    let power_w: Double?
}

private struct CaptureFrame: Decodable {
    let dir: String
    let cmd: UInt16
    let plain: String?
}

private enum Contract {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Contract")
    }

    static func fixtures(device: String) throws -> [Fixture] {
        let directory = Self.directory.appendingPathComponent("fixtures")
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        return try files.compactMap { url in
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
            return fixture.device == device ? fixture : nil
        }
    }

    /// 抓包里只有解密后的 rx 帧参与回放；tx 帧是密文，对解码器没有意义。
    static func decodedFrames(_ capture: String) throws -> [(command: UInt16, payload: Data)] {
        let url = Self.directory.appendingPathComponent("captures").appendingPathComponent(capture)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let frame = try? JSONDecoder().decode(CaptureFrame.self, from: data),
                  frame.dir == "rx", let plain = frame.plain, let payload = Data(hex: plain)
            else { return nil }
            return (frame.cmd, payload)
        }
    }
}

private extension Data {
    init?(hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard next > index, let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

private func expectClose(_ actual: Double?, _ expected: Double?, _ label: String) {
    switch (actual, expected) {
    case (nil, nil):
        break
    case let (actual?, expected?):
        #expect(abs(actual - expected) < 0.051, "\(label): \(actual) vs \(expected)")
    default:
        Issue.record("\(label): \(String(describing: actual)) vs \(String(describing: expected))")
    }
}

/**
 * 电池健康度走到线上的名字。
 *
 * 站点按 `battery.healthPercent` 取值，改了这个键名它就静默变成「未知」——
 * 不会报错，只会永远显示一个破折号。所以键名本身要有测试钉着。
 */
@Test func batteryHealthReachesThePayloadUnderItsWireName() throws {
    var state = PowerBankState()
    for (command, payload) in try Contract.decodedFrames("powerbank-01.jsonl") {
        if PowerBankProtocol.snapshotCommands.contains(command) {
            PowerBankProtocol.parseSnapshot(payload, state: &state)
        }
    }
    #expect(state.batteryHealthPercent == 100, "抓包里这台的健康度是 100%")

    let encoded = try JSONCoding.encoder().encode(
        ChargingDevicePayload(powerBank: state, connected: true)
    )
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let battery = try #require(object["battery"] as? [String: Any])
    #expect(battery["healthPercent"] as? Int == 100)
}

@Test func powerBankMatchesRecordedContract() throws {
    let fixtures = try Contract.fixtures(device: "powerbank")
    #expect(!fixtures.isEmpty, "no power bank fixtures — run Tools/sync-protocol-contract.sh")

    for fixture in fixtures {
        var state = PowerBankState()
        let frames = try Contract.decodedFrames(fixture.capture)
        var expectedIndex = 0

        for (command, payload) in frames {
            if command == 0x0029 {
                PowerBankProtocol.parseHandshakeInfo(payload, state: &state)
            } else if PowerBankProtocol.snapshotCommands.contains(command) {
                PowerBankProtocol.parseSnapshot(payload, state: &state)
            } else if PowerBankProtocol.realtimeCommands.contains(command) {
                PowerBankProtocol.parseRealtime(payload, state: &state)
            } else {
                continue
            }

            guard expectedIndex < fixture.frames.count else { break }
            let expected = fixture.frames[expectedIndex].state
            expectedIndex += 1
            let where_ = "\(fixture.capture) frame \(expectedIndex)"

            #expect(state.serialNumber == expected.serial, "\(where_) serial")
            #expect(state.firmwareVersion == expected.firmware, "\(where_) firmware")
            expectClose(state.batteryPercent, expected.battery_percent, "\(where_) battery")
            #expect(state.charging == expected.charging, "\(where_) charging")
            #expect(state.thermalState.map(Int.init) == expected.thermal_state, "\(where_) thermal")
            #expect(state.isThermallyLimited == (expected.thermal_limited ?? false),
                    "\(where_) thermalLimited")
            #expect(state.timeToFullHours == expected.time_left_hours, "\(where_) hours")
            #expect(state.timeToFullMinutes == expected.time_left_minutes, "\(where_) minutes")
            expectClose(state.inputPowerW, expected.input_power_w, "\(where_) input")
            expectClose(state.outputPowerW, expected.output_power_w, "\(where_) output")
            #expect(state.temperature1C == expected.temperature_1_c, "\(where_) temp1")
            #expect(state.temperature2C == expected.temperature_2_c, "\(where_) temp2")
            #expect(state.pomodoroSeconds == expected.pomodoro_seconds, "\(where_) pomodoro")
            #expect(
                state.batteryHealthPercent == expected.battery_health_percent,
                "\(where_) battery health"
            )
            #expect(state.pomodoroEnabled == expected.pomodoro_enabled, "\(where_) pomodoroOn")

            let expectedPorts = expected.ports.filter { $0.name != "DOCK" }
            let normalPorts = state.ports.filter { $0.name != "B" }
            #expect(normalPorts.count == expectedPorts.count, "\(where_) port count")
            for (port, want) in zip(normalPorts, expectedPorts) {
                let label = "\(where_) \(want.name)"
                #expect(port.name == want.name, "\(label) name")
                #expect(Int(port.mode) == want.mode, "\(label) mode")
                #expect(port.direction == want.direction, "\(label) direction")
                #expect(port.isActive == want.active, "\(label) active")
                #expect(port.attached == want.attached, "\(label) attached")
                #expect(port.isEnergized == want.energized, "\(label) energized")
                expectClose(port.voltageV, want.voltage_v, "\(label) volts")
                expectClose(port.currentA, want.current_a, "\(label) amps")
                expectClose(port.powerW, want.power_w, "\(label) watts")
            }
        }
        #expect(expectedIndex == fixture.frames.count, "\(fixture.capture) frame count")
    }
}

@Test func generatedConstantsMatchTheDecoder() {
    // 生成的常量和手写的解码器必须指向同一批 TLV。生成文件是从 Python 投影出来
    // 的，所以这条测试实际上是在问「Swift 这边有没有偷偷改过号」。
    #expect(AnkerPrimeSpec.PowerBank.batteryTLV == PowerBankProtocol.tlvBattery)
    #expect(AnkerPrimeSpec.PowerBank.thermalStateTLV == PowerBankProtocol.tlvThermalState)
    #expect(AnkerPrimeSpec.PowerBank.inputTotalTLV == PowerBankProtocol.tlvInputTotal)
    #expect(AnkerPrimeSpec.PowerBank.outputTotalTLV == PowerBankProtocol.tlvOutputTotal)
    #expect(AnkerPrimeSpec.PowerBank.dockTLV == PowerBankProtocol.tlvDock)
    #expect(AnkerPrimeSpec.PowerBank.portC1TLV == PowerBankProtocol.tlvPortC1)
    #expect(AnkerPrimeSpec.PowerBank.portC2TLV == PowerBankProtocol.tlvPortC2)
    #expect(AnkerPrimeSpec.PowerBank.portATLV == PowerBankProtocol.tlvPortA)
    #expect(AnkerPrimeSpec.PowerBank.snapshotShift == PowerBankProtocol.snapshotShift)
    #expect(AnkerPrimeSpec.Transport.serviceUUID == A2687Protocol.serviceUUID)
    #expect(AnkerPrimeSpec.Charger.namePrefix == A2687Protocol.deviceNamePrefix)
}

/**
 * 充电宝的遥测帧是**明文**的，充电头的是加密的。
 *
 * 这条差异曾经让上报器「已连接但一帧数据都没有」：接收路径上有个
 * `guard frame.encrypted`，把充电宝每一帧都丢掉了，而握手帧确实加密所以连接看
 * 起来是成功的。fixture 抓不到这类问题 —— 它回放的是已解密的载荷，整个帧层都被
 * 绕过去了。所以这里直接用一段真实的原始帧钉住这个事实。
 */
@Test func powerBankTelemetryFramesArriveUnencrypted() throws {
    // 真机 0x0300 帧，取自 captures/powerbank-11.jsonl 的 rx.raw
    let raw = try #require(Data(hex:
        "FF0973000301110300A10131A203043B55A30404010000A4020101A50404" +
        "01E803A60404000000A7080400000000000000A80F040000000000E803FF" +
        "00FFFFFFFF00A90F0400000000000000FF00FFFFFFFF00AC090400000000" +
        "00000000AF02012DB002012EB103020600FE05030000000000"
    ))
    let frame = try #require(A2687Protocol.parseFrame(raw))
    #expect(frame.command == 0x0300)
    #expect(frame.encrypted == false, "充电宝的遥测帧不加密；接收路径不能只收加密帧")
    // 帧体直接就是 TLV，不用解密就能解出电量
    var state = PowerBankState()
    PowerBankProtocol.parseRealtime(frame.body, state: &state)
    #expect(state.batteryPercent != nil, "明文帧体应当能直接解出遥测")

    // 接收路径本身也要走明文分支。只钉 parseFrame 挡不住有人再写回「非加密就丢弃」。
    var pipeline = A2687NotificationPipeline()
    let ingested = pipeline.ingest(raw)
    let decoded = try #require(ingested.frames.first)
    #expect(ingested.failures.isEmpty)
    #expect(decoded.encrypted == false)
    #expect(decoded.command == 0x0300)
    var ingestedState = PowerBankState()
    PowerBankProtocol.parseRealtime(decoded.payload, state: &ingestedState)
    #expect(ingestedState.batteryPercent == state.batteryPercent)
}
