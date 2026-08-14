import Foundation

/**
 * 一台被这个 app 管理的充电设备。
 *
 * 把「哪台设备」这件事收成一个值：从设置里读哪个配对 UUID、开关是哪一个、用哪个
 * 解码器、界面上叫什么。`BluetoothService` 拿着一个 slot 就够了，不用再知道对面
 * 具体是什么；`ServiceController` 也就能一视同仁地持有两条链路。
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
    func storePeripheralID(_ value: String, in settings: AppSettings) {
        switch self {
        case .charger: settings.peripheralID = value
        case .powerBank: settings.powerBankPeripheralID = value
        }
    }

    /**
     * 这台设备掉线后多久重挂定向连接。
     *
     * 充电头一直通电，断了基本就是拔了插座，五秒后重试没有代价。充电宝不一样：
     * 它空闲会自己睡、睡了不广播，手机 app 一连它更是直接把连接抢走。对着一台
     * 睡着的设备每五秒重挂一次没有意义，退避拉长一些。
     */
    var reconnectDelay: Duration {
        switch self {
        case .charger: .seconds(5)
        case .powerBank: .seconds(20)
        }
    }

    /**
     * 推流静默多久算「该催一下」和「这条会话没救了」。
     *
     * 充电头稳定 1 Hz，实测最坏间隔 1.24 秒，10/20 秒远在抖动之外。充电宝同样
     * 是 1 Hz，但它会在空闲时主动断链 —— 那种情况下催也没用，不如早点放手让
     * 重连逻辑接管，所以停等阈值给得更短。
     */
    var streamIdleTimeout: Duration {
        switch self {
        case .charger: .seconds(10)
        case .powerBank: .seconds(8)
        }
    }

    var streamStallTimeout: Duration {
        switch self {
        case .charger: .seconds(20)
        case .powerBank: .seconds(14)
        }
    }
}
