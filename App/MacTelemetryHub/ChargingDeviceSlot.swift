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
     * 充电头一直通电，断了基本就是拔了插座，五秒后重试没有代价。
     *
     * 充电宝空闲时会自己休眠、停止广播，手机 app 一连它也会把连接抢走，所以
     * 掉线比充电头频繁。（曾经它每 26 秒断一次 —— 那是没带账号 ID 的未认证
     * 会话到期，不是设备脾气；见 needsAccountID。）
     *
     * 定向连接本身不花电、也不轮询：请求挂在蓝牙控制器那一层等着，所以短退避
     * 不会变成忙循环，设备睡着时同样只是静静等着。
     */
    var reconnectDelay: Duration {
        switch self {
        case .charger: .seconds(5)
        case .powerBank: .seconds(2)
        }
    }

    /**
     * 推流静默多久算「该催一下」和「这条会话没救了」。
     *
     * 充电头稳定 1 Hz，实测最坏间隔 1.24 秒，10/20 秒远在抖动之外。
     *
     * 充电宝也是 1 Hz，但它每 26 秒就自己断链，断开回调来得比这个 watchdog 早，
     * 所以对它来说这套阈值基本用不上 —— 留着只是兜住「链路还在但流停了」这种
     * 罕见情况，给的值比充电头短一点，免得白等。
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
