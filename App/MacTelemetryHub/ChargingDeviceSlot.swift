import Foundation

/**
 * 一台被这个 app 管理的充电设备。
 *
 * 把「哪台设备」这件事收成一个值：从设置里读哪个配对 UUID、开关是哪一个、用哪个
 * 解码器、界面上叫什么。`BluetoothService` 拿着一个 slot 就够了，不用再知道对面
 * 具体是什么；`ServiceController` 也就能一视同仁地持有两条链路。
 *
 * 连接节奏两边一样。传输层也一样；不一样的只有解码和配对过滤，都在 decoder 里。
 *
 * 加第三台设备：这里加一个 case，加一个解码器，其余不动。
 */
enum ChargingDeviceSlot: String, CaseIterable, Identifiable, Sendable {
    case charger
    case powerBank

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .charger: "充电头"
        case .powerBank: "充电宝"
        }
    }

    var icon: String {
        switch self {
        case .charger: "bolt.horizontal"
        case .powerBank: "minus.plus.batteryblock"
        }
    }

    func makeDecoder() -> ChargingDeviceDecoder {
        switch self {
        case .charger: ChargerDecoder()
        case .powerBank: PowerBankDecoder()
        }
    }

    @MainActor
    func isEnabled(_ settings: AppSettings) -> Bool {
        switch self {
        case .charger: settings.chargerModuleEnabled
        case .powerBank: settings.powerBankModuleEnabled
        }
    }

    @MainActor
    func peripheralID(_ settings: AppSettings) -> UUID? {
        switch self {
        case .charger: settings.normalizedPeripheralID
        case .powerBank: settings.normalizedPowerBankPeripheralID
        }
    }

    @MainActor
    func peripheralIDString(_ settings: AppSettings) -> String {
        switch self {
        case .charger: settings.peripheralID
        case .powerBank: settings.powerBankPeripheralID
        }
    }

    @MainActor
    func storePeripheralID(_ value: String, in settings: AppSettings) {
        switch self {
        case .charger: settings.peripheralID = value
        case .powerBank: settings.powerBankPeripheralID = value
        }
    }

    /**
     * 掉线后多久重新挂上定向连接。
     *
     * 两边同一套：定向 connect 挂在控制器上，不轮询、不耗电，短退避不会变成忙循环。
     * 设备睡着或拔掉时也只是静静等着。
     */
    var reconnectDelay: Duration { .seconds(5) }

    /**
     * 推流静默多久算「该催一下」和「这条会话没救了」。
     *
     * 两台都是约 1 Hz。充电头实测最坏间隔 1.24 秒；充电宝同样 1 Hz 推 0x0300。
     * 10/20 秒远在抖动之外，只兜「链路还在但流停了」。
     */
    var streamIdleTimeout: Duration { .seconds(10) }
    var streamStallTimeout: Duration { .seconds(20) }
}
