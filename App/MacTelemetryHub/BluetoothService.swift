@preconcurrency import CoreBluetooth
import AppKit
import Foundation

@MainActor
final class BluetoothService: NSObject, ObservableObject {
    enum Phase: Equatable {
        case stopped
        case bluetoothUnavailable(String)
        /// 没有存下设备 UUID，或者系统不认识存下的那个。要用户去设置里配对一次。
        case awaitingPairing
        case connecting(String)
        case handshaking
        case connected
        case disconnected
        /// 充电宝空闲，GATT 已拆掉，过一会儿会再连上去看一眼。
        case idleSleeping

        var label: String {
            switch self {
            case .stopped: "已停止"
            case let .bluetoothUnavailable(reason): reason
            case .awaitingPairing: "未配对"
            case .connecting: "正在连接"
            case .handshaking: "正在认证"
            case .connected: "已连接"
            case .disconnected: "未连接"
            case .idleSleeping: "智能休眠"
            }
        }
    }

    /// 配对扫描里看到的一台候选设备。
    struct DiscoveredDevice: Identifiable, Equatable {
        let id: UUID
        let name: String
        var rssi: Int
    }

    /// 这条链路对面是哪台设备。决定用哪个解码器、读哪个配对 UUID。
    let slot: ChargingDeviceSlot
    /// 解码器自己持有状态。它是个类，改动不会触发 @Published，所以每次解出新
    /// 数据都要显式 objectWillChange.send() —— 和原来手动发通知的做法一致。
    private(set) var decoder: ChargingDeviceDecoder

    /// 给仪表盘和本地 HTTP 用的具体状态；类型不对就是 nil。
    var chargerState: ChargerState? { (decoder as? ChargerDecoder)?.state }
    var powerBankState: PowerBankState? { (decoder as? PowerBankDecoder)?.state }
    /// 给充电头那几张卡片用。这条链路不是充电头就给个空状态 —— 那些视图只会
    /// 挂在充电头链路上，真取到空值说明调用点接错了，空状态会立刻显示出来。
    var chargerStateForDisplay: ChargerState { chargerState ?? ChargerState() }
    /// 上报用的通用负载。没收到过遥测就是 nil，不塞空壳。
    var devicePayload: ChargingDevicePayload? { decoder.payload(connected: isConnected) }
    var hasTelemetry: Bool { decoder.hasTelemetry }
    var lastTelemetryAt: TimeInterval? { chargerState?.updatedAt ?? powerBankState?.updatedAt }
    /**
     * 解出新的端口数据时通知上报循环。
     *
     * 采集层已经是设备主动推流（约 1 Hz），但上报循环自己只有 5 秒一转的 tick，
     * 不叫醒它的话插拔要白等最多 5 秒才被看见。跟前台应用和播放同一个做法。
     *
     * 这里不做「变没变」的判断 —— 那是上报侧的事，它有结构指纹能分清插拔和
     * 功率滚动；这边只负责说「有新帧了」。1 Hz 唤醒一个本来就在转的循环，
     * 代价可以忽略，而且循环里那些判断全是本地比对。
     */
    var onStateChange: (() -> Void)?
    /**
     * 连接状态变化也要叫醒上报循环。
     *
     * 唤醒钩子挂在解帧上，但断开之后根本没有帧再来 —— 只靠那条路的话，掉线要
     * 等循环自己的 5 秒 tick 才被发现。连接与否本身就在结构指纹里，和插拔同一档，
     * 所以在这里补一次。只认「是不是 connected」的翻转，中间那些扫描、握手阶段
     * 不必惊动上报。
     */
    @Published private(set) var phase: Phase = .stopped {
        didSet {
            guard (oldValue == .connected) != (phase == .connected) else { return }
            onStateChange?()
        }
    }
    @Published private(set) var lastError: String?
    @Published private(set) var desiredConnection = true
    /// 配对扫描的结果，只在设置面板里用。平时是空的。
    @Published private(set) var discovered: [DiscoveredDevice] = []
    @Published private(set) var isPairingScan = false

    var isConnected: Bool { phase == .connected }

    private let settings: AppSettings
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var streamIdleTimeout: Duration { slot.streamIdleTimeout }
    private var streamStallTimeout: Duration { slot.streamStallTimeout }

    private var crypto = A2687CryptoContext()
    private var assembler = FrameAssembler()
    private var handshakeTask: Task<Void, Never>?
    private var streamWatchdogTask: Task<Void, Never>?
    /// Monotonic stamp of the last decoded frame — the only liveness signal
    /// once nothing is polled. `ContinuousClock` so that a system clock change
    /// cannot make a healthy stream look stalled.
    private var lastFrameAt = ContinuousClock.now
    private var retryTask: Task<Void, Never>?
    private var pairingScanTask: Task<Void, Never>?
    private var idleSleepTask: Task<Void, Never>?
    private var pending: PendingResponse?
    private var observesWorkspacePower = false
    private var isSystemSleeping = false
    /// 正在空闲休眠：GATT 已拆，不要走掉线那条 5 秒定向重连。
    private var isIdleSleeping = false
    /// 这一次连接是休眠后的探视，连上后只看 `idleProbeHold`，不是再等五分钟。
    private var probingAfterNap = false
    private var idleSince: ContinuousClock.Instant?
    private var idleProbeDeadline: ContinuousClock.Instant?
    private var nextNapDuration: Duration
    /// 配对扫描开着的时长。够走完一轮广播间隔，又不至于让用户对着列表干等。
    private static let pairingScanWindow = Duration.seconds(15)
    private var reconnectDelay: Duration { slot.reconnectDelay }

    /**
     * 诊断用的原始帧抓取。
     *
     * 格式和 anker-prime-ble 那边的 `--record` 完全一致，所以抓出来的文件可以直接
     * 丢给 `python -m anker_prime_ble replay` 去解 —— 排查「设备到底发没发」这类
     * 问题时，唯一有意义的证据就是原始字节，看代码看不出来。
     *
     * 默认关，靠 defaults 开：
     *   defaults write com.liangyangjunwei.MacTelemetryHub bleCaptureEnabled -bool YES
     * 写到 ~/Library/Logs/MacTelemetryHub/<设备>.jsonl，重连不清空、追加。
     */
    private lazy var captureURL: URL? = {
        guard UserDefaults.standard.bool(forKey: "bleCaptureEnabled") else { return nil }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacTelemetryHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(slot.rawValue).jsonl")
    }()

    private func capture(_ direction: String, command: UInt16, _ extra: [String: Any]) {
        guard let captureURL else { return }
        var row: [String: Any] = [
            "t": Date().timeIntervalSince1970,
            "dir": direction,
            "cmd": Int(command),
        ]
        row.merge(extra) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let handle = try? FileHandle(forWritingTo: captureURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: captureURL)
        }
    }

    init(settings: AppSettings, slot: ChargingDeviceSlot) {
        self.settings = settings
        self.slot = slot
        decoder = slot.makeDecoder()
        nextNapDuration = slot.idleNapStart
        super.init()
    }

    func start() {
        guard central == nil else { return }
        desiredConnection = true
        resetIdleSleep()
        if !observesWorkspacePower {
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(workspaceScreensDidWake(_:)),
                name: NSWorkspace.screensDidWakeNotification,
                object: nil
            )
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(workspaceWillSleep(_:)),
                name: NSWorkspace.willSleepNotification,
                object: nil
            )
            observesWorkspacePower = true
        }
        startCentralIfNeeded()
    }

    func disconnect() {
        desiredConnection = false
        lastError = "已手动断开"
        resetIdleSleep()
        destroyBluetoothSession()
    }

    func reconnect() {
        desiredConnection = true
        lastError = nil
        resetIdleSleep()
        destroyBluetoothSession()
        scheduleRetry(after: .seconds(1))
    }

    /// 开关变了：关掉就取消休眠并连回去，开着则等现有连接自己进入待机计时。
    func refreshIdleSleepPolicy() {
        guard slot.supportsIdleSleep else { return }
        guard settings.powerBankIdleSleepEnabled else {
            let wasSleeping = isIdleSleeping
            resetIdleSleep()
            if wasSleeping, desiredConnection, !isSystemSleeping {
                scheduleRetry(after: .seconds(1))
            }
            return
        }
    }

    /// Official `0x021F`. Returns the ACK payload — `11 A1 01 31` means pixels are not on the charger.
    func selectScreensaver(pictureID: UInt32, hashCode: UInt32) async throws -> Data {
        guard phase == .connected else { throw BLEError.disconnected }
        return try await sendExpect(
            group: A2687Protocol.groupTelemetry,
            command: A2687Protocol.commandSetScreensaver,
            fields: A2687Protocol.screensaverSelectFields(pictureID: pictureID, hashCode: hashCode)
        )
    }

    /// Official pixel path: `0x021F` → `0x0220` → `0x0221` slices (156 bytes, ACK every 10).
    func transferScreensaver(
        jpeg: Data,
        pictureID: UInt32,
        hashCode: UInt32,
        progress: (@MainActor (Int, Int) -> Void)? = nil
    ) async throws {
        guard phase == .connected else { throw BLEError.disconnected }
        let chunks = A2687Protocol.screensaverChunks(jpeg)
        guard !chunks.isEmpty else { throw BLEError.emptyJPEG }

        _ = try await sendExpect(
            group: A2687Protocol.groupTelemetry,
            command: A2687Protocol.commandSetScreensaver,
            fields: A2687Protocol.screensaverSelectFields(pictureID: pictureID, hashCode: hashCode)
        )
        try await Task.sleep(for: .milliseconds(150))
        _ = try await sendExpect(
            group: A2687Protocol.groupTelemetry,
            command: A2687Protocol.commandTransferStart,
            fields: A2687Protocol.screensaverTransferStartFields(
                pictureID: pictureID,
                hashCode: hashCode,
                fileSize: jpeg.count,
                chunkCount: chunks.count
            )
        )
        try await Task.sleep(for: .milliseconds(200))

        let every = A2687Protocol.screensaverAckEvery
        for (seq, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            guard phase == .connected else { throw BLEError.disconnected }
            progress?(seq + 1, chunks.count)
            let fields = try A2687Protocol.screensaverChunkFields(seq: seq, data: chunk)
            let last = seq + 1 == chunks.count
            if last || (seq + 1) % every == 0 {
                _ = try await sendExpect(
                    group: A2687Protocol.groupTelemetry,
                    command: A2687Protocol.commandTransferData,
                    fields: fields,
                    timeout: .seconds(5)
                )
            } else {
                try send(
                    group: A2687Protocol.groupTelemetry,
                    command: A2687Protocol.commandTransferData,
                    fields: fields
                )
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        try await Task.sleep(for: .milliseconds(400))
    }

    func shutdown() {
        desiredConnection = false
        resetIdleSleep()
        destroyBluetoothSession()
        if observesWorkspacePower {
            NSWorkspace.shared.notificationCenter.removeObserver(
                self,
                name: NSWorkspace.screensDidWakeNotification,
                object: nil
            )
            NSWorkspace.shared.notificationCenter.removeObserver(
                self,
                name: NSWorkspace.willSleepNotification,
                object: nil
            )
            observesWorkspacePower = false
        }
    }

    /**
     * 配对扫描：唯一还会开扫描的地方。
     *
     * 平时一律按存下的 UUID 定向连接，从不扫描。只有还没配对过（或者存的 UUID
     * 系统已经不认识）时，用户在设置里按一下才扫这 15 秒，挑一台存下 UUID，
     * 之后再也不扫。
     */
    func startPairingScan() {
        guard !isSystemSleeping else {
            lastError = "Mac 正在睡眠，无法扫描"
            return
        }
        discovered = []
        isPairingScan = true
        // 想配对就是想连，刚点过「断开」也一样
        desiredConnection = true
        startCentralIfNeeded()
        // 蓝牙还没就绪时先立旗，等 poweredOn 回调接手
        guard let central, central.state == .poweredOn else { return }
        runPairingScan(on: central)
    }

    private func runPairingScan(on central: CBCentralManager) {
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        pairingScanTask?.cancel()
        pairingScanTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pairingScanWindow)
            guard !Task.isCancelled, let self else { return }
            stopPairingScan()
        }
    }

    func stopPairingScan() {
        pairingScanTask?.cancel()
        pairingScanTask = nil
        guard isPairingScan else { return }
        isPairingScan = false
        central?.stopScan()
    }

    @objc private func workspaceWillSleep(_ notification: Notification) {
        isSystemSleeping = true
        guard desiredConnection else { return }
        lastError = "Mac 正在睡眠，已释放蓝牙连接"
        destroyBluetoothSession()
    }

    @objc private func workspaceScreensDidWake(_ notification: Notification) {
        guard isSystemSleeping else { return }
        isSystemSleeping = false
        guard desiredConnection else { return }
        if isIdleSleeping {
            lastError = "Mac 已唤醒，正在检查充电宝"
            beginIdleProbe()
            return
        }
        lastError = "Mac 已唤醒，正在重新建立蓝牙会话"
        scheduleRetry(after: .seconds(1))
    }

    private func startCentralIfNeeded() {
        guard desiredConnection, !isSystemSleeping, !isIdleSleeping, central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func destroyBluetoothSession() {
        cancelSessionTasks()
        stopPairingScan()
        discovered = []
        let manager = central
        manager?.stopScan()
        if let peripheral {
            peripheral.delegate = nil
            if peripheral.state != .disconnected {
                manager?.cancelPeripheralConnection(peripheral)
            }
        }
        self.peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        assembler.reset()
        manager?.delegate = nil
        central = nil
        if !isIdleSleeping {
            phase = .disconnected
        }
    }

    /**
     * 挂一个指向存下那台设备的定向连接，然后就不管了。
     *
     * CoreBluetooth 的 connect 没有超时：请求挂在那里，交给蓝牙控制器去等，设备
     * 一上电就连上。这比「扫 15 秒 → 拆掉会话 → 退避 → 再扫」省得多，也不会漏掉
     * 两次尝试之间那段空窗 —— 本进程根本不收广播，等待是控制器那一层的事。
     *
     * 代价是必须先有 UUID。没有就停在 .awaitingPairing 等用户去设置里配对一次，
     * 绝不自己开扫描。充电头和充电宝走同一条路。
     */
    private func beginConnect() {
        guard desiredConnection,
              !isSystemSleeping,
              !isIdleSleeping,
              let central,
              central.state == .poweredOn else { return }
        do {
            try settings.validate()
        } catch {
            phase = .disconnected
            lastError = error.localizedDescription
            return
        }

        retryTask?.cancel()
        retryTask = nil
        guard let identifier = slot.peripheralID(settings) else {
            phase = .awaitingPairing  // 还没配对过，这是正常状态，不算错误
            return
        }
        guard let known = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            phase = .awaitingPairing
            lastError = "系统里没有这台\(slot.displayName)的记录，请在设置里重新扫描配对"
            return
        }
        connect(to: known)
    }

    private func connect(to candidate: CBPeripheral) {
        guard desiredConnection, !isSystemSleeping, let central else { return }
        stopPairingScan()
        peripheral = candidate
        candidate.delegate = self
        phase = .connecting(candidate.name ?? candidate.identifier.uuidString)
        central.connect(candidate, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func scheduleRetry(after delay: Duration = .seconds(5)) {
        guard desiredConnection, !isSystemSleeping, !isIdleSleeping else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if central == nil {
                startCentralIfNeeded()
            } else {
                beginConnect()
            }
        }
    }

    private func cancelSessionTasks() {
        handshakeTask?.cancel()
        handshakeTask = nil
        streamWatchdogTask?.cancel()
        streamWatchdogTask = nil
        retryTask?.cancel()
        retryTask = nil
        if let pending {
            pending.timeout.cancel()
            pending.continuation.resume(throwing: BLEError.disconnected)
            self.pending = nil
        }
    }

    private func startHandshake() {
        guard handshakeTask == nil else { return }
        phase = .handshaking
        crypto = A2687CryptoContext()
        assembler.reset()
        handshakeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await performHandshake()
                guard !Task.isCancelled else { return }
                phase = .connected
                lastError = nil
                armIdleProbeHoldIfNeeded()
                startStreamWatchdog()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
                if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            }
            handshakeTask = nil
        }
    }

    private func performHandshake() async throws {
        // 两台设备都要账号 ID：充电头没有它不推流，充电宝没有它 26 秒后断链。
        // 先验一次格式，免得走完整个握手才在最后一步炸。
        let userID = decoder.needsAccountID ? accountID() : nil
        if let userID { _ = try A2687Protocol.validatedAccountID(userID) }

        for step in A2687Protocol.handshakeSteps() {
            if step.expectsResponse {
                let payload = try await sendExpect(group: A2687Protocol.groupSession, command: step.command, fields: step.fields)
                if step.command == 0x0029 {
                    decoder.handleHandshakeInfo(payload)
                    objectWillChange.send()
                }
            } else {
                try send(group: A2687Protocol.groupSession, command: step.command, fields: step.fields)
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let ecdh = A2687ECDHSession()
        let keyResponse = try await sendExpect(
            group: A2687Protocol.groupSession,
            command: 0x0021,
            fields: [TLVField(0xA1, ecdh.publicCoordinates)]
        )
        guard let deviceKey = A2687Protocol.findDevicePublicKey(in: keyResponse) else {
            throw BLEError.missingDeviceKey
        }
        let material = try ecdh.derive(deviceCoordinates: deviceKey)
        try crypto.setSession(key: material.key, nonce: material.nonce)
        try await Task.sleep(for: .milliseconds(120))

        for step in try A2687Protocol.postSessionSteps(userID: userID) {
            try send(group: A2687Protocol.groupSession, command: step.command, fields: step.fields)
            try await Task.sleep(for: .milliseconds(120))
        }
        try armTelemetry()
    }

    /// Ask for one snapshot and one realtime frame.
    ///
    /// Sent once at the end of the handshake, and again only if the watchdog
    /// finds the stream quiet — never on a repeating timer. The charger keeps
    /// pushing `0x0300` at ~1 Hz on its own once `0x0022`/`0x0027` have armed
    /// it, so nothing has to be requested to keep telemetry flowing.
    private func armTelemetry() throws {
        try send(
            group: A2687Protocol.groupTelemetry,
            command: A2687Protocol.commandStatus,
            fields: A2687Protocol.statusProbe()
        )
        // 0x020A 只有充电头要。充电宝 0x0022 之后就自己推 0x0300，从来没给它发过。
        guard decoder.needsRealtimeProbe else { return }
        try send(
            group: A2687Protocol.groupTelemetry,
            command: A2687Protocol.commandRealtime,
            fields: A2687Protocol.realtimeProbe(userID: accountID())
        )
    }

    private func accountID() -> String {
        settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Watch for the pushed stream going quiet.
    ///
    /// Nothing is polled, so nothing fails loudly when the charger stops
    /// answering: the BLE link can stay connected while the stream is dead,
    /// which would leave the dashboard and the uploader on a frozen snapshot.
    /// This timer is local and sends no BLE traffic unless the stream is
    /// already silent.
    private func startStreamWatchdog() {
        streamWatchdogTask?.cancel()
        lastFrameAt = .now
        streamWatchdogTask = Task { [weak self] in
            var rearmed = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let idle = ContinuousClock.now - lastFrameAt

                if idle < streamIdleTimeout {
                    rearmed = false
                    tickIdleSleep()
                    continue
                }
                if idle >= streamStallTimeout {
                    lastError = "\(slot.displayName)已停止推送，正在重建蓝牙会话"
                    if let peripheral { central?.cancelPeripheralConnection(peripheral) }
                    return
                }
                guard !rearmed else { continue }  // one attempt per quiet period
                rearmed = true
                try? armTelemetry()
            }
        }
    }

    private func resetIdleSleep() {
        idleSleepTask?.cancel()
        idleSleepTask = nil
        isIdleSleeping = false
        probingAfterNap = false
        idleSince = nil
        idleProbeDeadline = nil
        nextNapDuration = slot.idleNapStart
    }

    private func armIdleProbeHoldIfNeeded() {
        guard probingAfterNap else { return }
        probingAfterNap = false
        idleSince = .now
        idleProbeDeadline = .now + slot.idleProbeHold
    }

    /**
     * 充电宝空闲休眠。
     *
     * 连着待机满 `idleBeforeSleep` 就拆 GATT，让设备自己睡、手机也连得上。
     * 过一会儿再连：连不上或连上仍待机，就回去继续睡，间隔倍增直到上限。
     * 一旦有充放电，间隔清回起点，连接保持。
     */
    private func tickIdleSleep() {
        guard slot.supportsIdleSleep, settings.powerBankIdleSleepEnabled else { return }
        guard phase == .connected, let state = powerBankState else { return }
        if state.isBusy {
            idleSince = nil
            idleProbeDeadline = nil
            nextNapDuration = slot.idleNapStart
            return
        }
        if idleSince == nil { idleSince = .now }
        if let deadline = idleProbeDeadline {
            if ContinuousClock.now >= deadline { enterIdleSleep() }
            return
        }
        if let idleSince, ContinuousClock.now - idleSince >= slot.idleBeforeSleep {
            enterIdleSleep()
        }
    }

    private func enterIdleSleep() {
        guard slot.supportsIdleSleep, desiredConnection else { return }
        idleSleepTask?.cancel()
        idleProbeDeadline = nil
        idleSince = nil
        probingAfterNap = false
        isIdleSleeping = true
        lastError = nil
        destroyBluetoothSession()
        phase = .idleSleeping
        scheduleIdleProbe()
    }

    private func scheduleIdleProbe() {
        let delay = nextNapDuration
        nextNapDuration = min(delay * 2, slot.idleNapCap)
        idleSleepTask?.cancel()
        idleSleepTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            beginIdleProbe()
        }
    }

    private func beginIdleProbe() {
        guard desiredConnection else { return }
        if isSystemSleeping {
            isIdleSleeping = true
            phase = .idleSleeping
            return
        }
        isIdleSleeping = false
        probingAfterNap = true
        lastError = nil
        scheduleRetry(after: .seconds(1))
        idleSleepTask?.cancel()
        idleSleepTask = Task { [weak self] in
            try? await Task.sleep(for: self?.slot.idleProbeConnectTimeout ?? .seconds(25))
            guard !Task.isCancelled, let self else { return }
            guard desiredConnection, phase != .connected else { return }
            enterIdleSleep()
        }
    }

    private func send(group: UInt8, command: UInt16, fields: [TLVField]) throws {
        guard let peripheral, let writeCharacteristic, peripheral.state == .connected else {
            throw BLEError.disconnected
        }
        let plaintext = try A2687Protocol.buildTLV(fields)
        let ciphertext = try crypto.encrypt(plaintext)
        let frame = A2687Protocol.buildFrame(group: group, command: command, ciphertext: ciphertext)
        capture("tx", command: command, ["group": Int(group), "raw": frame.hexString])
        peripheral.writeValue(frame, for: writeCharacteristic, type: .withoutResponse)
    }

    private func sendExpect(
        group: UInt8,
        command: UInt16,
        fields: [TLVField],
        timeout: Duration = .seconds(6)
    ) async throws -> Data {
        guard pending == nil else { throw BLEError.requestAlreadyPending }
        let wait = timeout
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self, let pending = self.pending, pending.command == command else { return }
                self.pending = nil
                pending.continuation.resume(throwing: BLEError.responseTimeout(command))
            }
            pending = PendingResponse(command: command, continuation: continuation, timeout: timeout)
            do {
                try send(group: group, command: command, fields: fields)
            } catch {
                timeout.cancel()
                pending = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func handleNotification(_ data: Data) {
        // 抓在切帧之前：如果问题出在切帧本身，切完再抓就什么都看不到了。
        capture("notify", command: 0, ["raw": data.hexString])
        for raw in assembler.feed(data) {
            guard let frame = A2687Protocol.parseFrame(raw) else {
                capture("rx", command: 0, ["ok": false, "reason": "unparsed", "raw": raw.hexString])
                continue
            }
            /**
             * 加密位不是恒真的 —— 两台设备在这里的行为不一样。
             *
             * 充电头的遥测是加密的，所以这段代码原本直接 `guard frame.encrypted`，
             * 把未加密帧全丢掉。**充电宝的 0x0300 是明文发的**：帧头之后直接就是
             * TLV。那个 guard 于是把它每一帧都吃掉了 —— 握手能成（握手帧确实加密），
             * 但一帧遥测都进不来，watchdog 判定停流，表现成「已连接但没数据、还偶尔
             * 断线」。
             *
             * 按帧上的标志位走，不要按设备假设走。
             */
            let payload: Data
            if frame.encrypted {
                do {
                    payload = try crypto.decrypt(frame.body)
                } catch {
                    capture("rx", command: frame.command, ["ok": false, "reason": "decrypt", "raw": raw.hexString])
                    lastError = "解密 0x\(String(format: "%04X", frame.command)) 失败：\(error.localizedDescription)"
                    continue
                }
            } else {
                payload = frame.body
            }
            capture("rx", command: frame.command, [
                "enc": frame.encrypted, "ack": frame.acknowledged, "ok": true,
                "plain": payload.hexString, "raw": raw.hexString,
            ])
            // 任何一帧收到都证明会话还活着，包括握手回复和不带端口数据的空 ack。
            lastFrameAt = .now
            if decoder.handleFrame(command: frame.command, payload: payload) {
                objectWillChange.send()
                onStateChange?()
                tickIdleSleep()
            }
            if let pending, pending.command == frame.command {
                pending.timeout.cancel()
                self.pending = nil
                pending.continuation.resume(returning: payload)
            }
        }
    }
}

extension BluetoothService: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        switch central.state {
        case .poweredOn:
            beginConnect()
            // 蓝牙没就绪时按下的扫描在这里接上
            if isPairingScan { runPairingScan(on: central) }
        case .poweredOff:
            stopPairingScan()
            phase = .bluetoothUnavailable("蓝牙已关闭")
        case .unauthorized:
            stopPairingScan()
            phase = .bluetoothUnavailable("没有蓝牙权限")
        case .unsupported:
            stopPairingScan()
            phase = .bluetoothUnavailable("本机不支持蓝牙")
        case .resetting:
            stopPairingScan()
            phase = .bluetoothUnavailable("蓝牙正在重置")
        case .unknown:
            phase = .bluetoothUnavailable("正在检查蓝牙")
        @unknown default:
            stopPairingScan()
            phase = .bluetoothUnavailable("蓝牙状态未知")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard central === self.central, isPairingScan else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        // 整条 Prime 产品线都播 ff09，所以服务 UUID 只能说明「是台 Anker 设备」。
        // 有名字前缀的认前缀；没有的（充电宝直接播序列号）就反过来把有前缀的排除掉。
        // 两边都列出来会让用户在配对时选错设备。
        let chargerPrefix = A2687Protocol.deviceNamePrefix
        let hasPrimeService = services.contains(CBUUID(string: A2687Protocol.advertisedServiceUUID))
        if let prefix = decoder.namePrefix {
            guard name.hasPrefix(prefix) else { return }
        } else {
            guard hasPrimeService, !name.hasPrefix(chargerPrefix) else { return }
        }
        // 只列出来给用户挑，不自己连。allowDuplicates 关着也可能重复送达，按 UUID 去重。
        let entry = DiscoveredDevice(id: peripheral.identifier, name: name.isEmpty ? peripheral.identifier.uuidString : name, rssi: RSSI.intValue)
        if let index = discovered.firstIndex(where: { $0.id == entry.id }) {
            discovered[index].rssi = entry.rssi
        } else {
            discovered.append(entry)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: A2687Protocol.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central else { return }
        phase = .disconnected
        lastError = error?.localizedDescription ?? "无法连接\(slot.displayName)"
        scheduleRetry(after: reconnectDelay)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error _: Error?) {
        guard central === self.central else { return }
        cancelSessionTasks()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        if isIdleSleeping {
            phase = .idleSleeping
            return
        }
        phase = .disconnected
        if desiredConnection, !isSystemSleeping {
            // 例行掉线（拔掉、休眠、超出范围）两边都一样：定向重连，不写成故障。
            // 握手失败、停流这类已经写进 lastError 的，断开回调不要盖掉。
            scheduleRetry(after: reconnectDelay)
        } else if isSystemSleeping {
            lastError = "Mac 正在睡眠，已释放蓝牙连接"
        } else {
            lastError = "已手动断开"
        }
    }
}

extension BluetoothService: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        if let error { lastError = error.localizedDescription; central?.cancelPeripheralConnection(peripheral); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: A2687Protocol.serviceUUID) }) else {
            lastError = "\(slot.displayName)没有所需 GATT 服务"
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics(
            [CBUUID(string: A2687Protocol.writeCharacteristicUUID), CBUUID(string: A2687Protocol.notifyCharacteristicUUID)],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if let error { lastError = error.localizedDescription; central?.cancelPeripheralConnection(peripheral); return }
        writeCharacteristic = service.characteristics?.first { $0.uuid == CBUUID(string: A2687Protocol.writeCharacteristicUUID) }
        notifyCharacteristic = service.characteristics?.first { $0.uuid == CBUUID(string: A2687Protocol.notifyCharacteristicUUID) }
        guard writeCharacteristic != nil, let notifyCharacteristic else {
            lastError = "\(slot.displayName)缺少写入或通知特征"
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if let error { lastError = error.localizedDescription; central?.cancelPeripheralConnection(peripheral); return }
        if characteristic.uuid == CBUUID(string: A2687Protocol.notifyCharacteristicUUID), characteristic.isNotifying {
            startHandshake()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let value = characteristic.value else { return }
        handleNotification(value)
    }
}

private struct PendingResponse {
    let command: UInt16
    let continuation: CheckedContinuation<Data, Error>
    let timeout: Task<Void, Never>
}

private enum BLEError: LocalizedError {
    case disconnected, requestAlreadyPending, responseTimeout(UInt16), missingDeviceKey, emptyJPEG

    var errorDescription: String? {
        switch self {
        case .disconnected: "蓝牙连接已断开"
        case .requestAlreadyPending: "上一个蓝牙请求尚未完成"
        case let .responseTimeout(command): String(format: "等待命令 0x%04X 响应超时", command)
        case .missingDeviceKey: "设备没有返回有效的 P-256 公钥"
        case .emptyJPEG: "封面 JPEG 是空的，无法传到充电头"
        }
    }
}
