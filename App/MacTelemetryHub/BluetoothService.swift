@preconcurrency import CoreBluetooth
import AppKit
import Foundation
import IOKit.ps

@MainActor
final class BluetoothService: NSObject, ObservableObject {
    enum Phase: Equatable {
        case stopped
        case bluetoothUnavailable(String)
        case scanning
        case connecting(String)
        case handshaking
        case connected
        case disconnected

        var label: String {
            switch self {
            case .stopped: "已停止"
            case let .bluetoothUnavailable(reason): reason
            case .scanning: "正在扫描"
            case .connecting: "正在连接"
            case .handshaking: "正在认证"
            case .connected: "已连接"
            case .disconnected: "未连接"
            }
        }
    }

    @Published private(set) var state = ChargerState()
    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var lastError: String?
    @Published private(set) var desiredConnection = true

    var isConnected: Bool { phase == .connected }

    private let settings: AppSettings
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var crypto = A2687CryptoContext()
    private var assembler = FrameAssembler()
    private var handshakeTask: Task<Void, Never>?
    private var pollingTasks: [Task<Void, Never>] = []
    private var retryTask: Task<Void, Never>?
    private var attemptTimeoutTask: Task<Void, Never>?
    private var pending: PendingResponse?
    private var observesWorkspacePower = false
    private var isSystemSleeping = false
    private var retryAttempt = 0

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    func start() {
        guard central == nil else { return }
        desiredConnection = true
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
        destroyBluetoothSession()
    }

    func reconnect() {
        desiredConnection = true
        lastError = nil
        retryAttempt = 0
        destroyBluetoothSession()
        scheduleRetry(after: .seconds(1))
    }

    func shutdown() {
        desiredConnection = false
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
        retryAttempt = 0
        lastError = "Mac 已唤醒，正在重新建立蓝牙会话"
        scheduleRetry(after: .seconds(1))
    }

    private func startCentralIfNeeded() {
        guard desiredConnection, !isSystemSleeping, central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func destroyBluetoothSession() {
        cancelSessionTasks()
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
        phase = .disconnected
    }

    private func beginDiscovery() {
        guard desiredConnection,
              !isSystemSleeping,
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
        if let identifier = settings.normalizedPeripheralID,
           let known = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            connect(to: known)
            return
        }
        phase = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scheduleAttemptTimeout()
    }

    private func connect(to candidate: CBPeripheral) {
        guard desiredConnection, !isSystemSleeping, let central else { return }
        central.stopScan()
        peripheral = candidate
        candidate.delegate = self
        phase = .connecting(candidate.name ?? candidate.identifier.uuidString)
        central.connect(candidate, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        scheduleAttemptTimeout()
    }

    private func scheduleAttemptTimeout(after delay: Duration = .seconds(15)) {
        attemptTimeoutTask?.cancel()
        attemptTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            switch phase {
            case .scanning, .connecting:
                lastError = "未发现充电器，已暂停蓝牙以节省电量"
                destroyBluetoothSession()
                scheduleBackoffRetry()
            default:
                break
            }
        }
    }

    private func scheduleBackoffRetry() {
        let delay: Int64
        if isUsingBatteryPower {
            let delays: [Int64] = [60, 120, 240, 300]
            delay = delays[min(retryAttempt, delays.count - 1)]
            retryAttempt += 1
        } else {
            delay = 15
        }
        scheduleRetry(after: .seconds(delay))
    }

    private var isUsingBatteryPower: Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(snapshot).takeUnretainedValue() as String
        return source == kIOPSBatteryPowerValue
    }

    private func scheduleRetry(after delay: Duration = .seconds(5)) {
        guard desiredConnection, !isSystemSleeping else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if central == nil {
                startCentralIfNeeded()
            } else {
                beginDiscovery()
            }
        }
    }

    private func cancelSessionTasks() {
        handshakeTask?.cancel()
        handshakeTask = nil
        pollingTasks.forEach { $0.cancel() }
        pollingTasks.removeAll()
        retryTask?.cancel()
        retryTask = nil
        attemptTimeoutTask?.cancel()
        attemptTimeoutTask = nil
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
                retryAttempt = 0
                phase = .connected
                lastError = nil
                startPolling()
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
        let userID = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try A2687Protocol.realtimeProbe(userID: userID)

        for step in A2687Protocol.handshakeSteps() {
            if step.expectsResponse {
                let payload = try await sendExpect(group: A2687Protocol.groupSession, command: step.command, fields: step.fields)
                if step.command == 0x0029 {
                    A2687Protocol.parseHandshakeInfo(payload, device: &state.device)
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
        try send(group: A2687Protocol.groupTelemetry, command: A2687Protocol.commandStatus, fields: A2687Protocol.statusProbe())
        try send(
            group: A2687Protocol.groupTelemetry,
            command: A2687Protocol.commandRealtime,
            fields: A2687Protocol.realtimeProbe(userID: userID)
        )
    }

    private func startPolling() {
        pollingTasks.forEach { $0.cancel() }
        pollingTasks = [
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(12))
                    guard let self, !Task.isCancelled else { return }
                    try? send(group: A2687Protocol.groupTelemetry, command: A2687Protocol.commandStatus, fields: A2687Protocol.statusProbe())
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(6))
                    guard let self, !Task.isCancelled else { return }
                    let fields = try? A2687Protocol.realtimeProbe(userID: settings.userID)
                    if let fields {
                        try? send(group: A2687Protocol.groupTelemetry, command: A2687Protocol.commandRealtime, fields: fields)
                    }
                }
            },
        ]
    }

    private func send(group: UInt8, command: UInt16, fields: [TLVField]) throws {
        guard let peripheral, let writeCharacteristic, peripheral.state == .connected else {
            throw BLEError.disconnected
        }
        let plaintext = try A2687Protocol.buildTLV(fields)
        let ciphertext = try crypto.encrypt(plaintext)
        let frame = A2687Protocol.buildFrame(group: group, command: command, ciphertext: ciphertext)
        peripheral.writeValue(frame, for: writeCharacteristic, type: .withoutResponse)
    }

    private func sendExpect(group: UInt8, command: UInt16, fields: [TLVField]) async throws -> Data {
        guard pending == nil else { throw BLEError.requestAlreadyPending }
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
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
        for raw in assembler.feed(data) {
            guard let frame = A2687Protocol.parseFrame(raw), frame.encrypted else { continue }
            do {
                let payload = try crypto.decrypt(frame.body)
                if frame.command == 0x0200 || frame.command == 0x0A00 {
                    A2687Protocol.parseStatusSnapshot(payload, state: &state)
                    _ = A2687Protocol.parseRealtime(payload, command: frame.command, state: &state)
                    objectWillChange.send()
                } else if [0x020A, 0x0207, 0x0206, 0x4300, 0x0300, 0x0303, 0x0410].contains(frame.command) {
                    if A2687Protocol.parseRealtime(payload, command: frame.command, state: &state) {
                        objectWillChange.send()
                    }
                }
                if let pending, pending.command == frame.command {
                    pending.timeout.cancel()
                    self.pending = nil
                    pending.continuation.resume(returning: payload)
                }
            } catch {
                lastError = "解密 0x\(String(format: "%04X", frame.command)) 失败：\(error.localizedDescription)"
            }
        }
    }
}

extension BluetoothService: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        switch central.state {
        case .poweredOn:
            beginDiscovery()
        case .poweredOff:
            phase = .bluetoothUnavailable("蓝牙已关闭")
        case .unauthorized:
            phase = .bluetoothUnavailable("没有蓝牙权限")
        case .unsupported:
            phase = .bluetoothUnavailable("本机不支持蓝牙")
        case .resetting:
            phase = .bluetoothUnavailable("蓝牙正在重置")
        case .unknown:
            phase = .bluetoothUnavailable("正在检查蓝牙")
        @unknown default:
            phase = .bluetoothUnavailable("蓝牙状态未知")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard central === self.central else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard name.hasPrefix(A2687Protocol.deviceNamePrefix) || services.contains(CBUUID(string: A2687Protocol.advertisedServiceUUID)) else { return }
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central else { return }
        attemptTimeoutTask?.cancel()
        attemptTimeoutTask = nil
        self.peripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: A2687Protocol.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central else { return }
        phase = .disconnected
        lastError = error?.localizedDescription ?? "无法连接充电器"
        scheduleBackoffRetry()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central else { return }
        cancelSessionTasks()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        phase = .disconnected
        if desiredConnection, !isSystemSleeping {
            lastError = error?.localizedDescription ?? "连接已断开"
            scheduleBackoffRetry()
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
            lastError = "充电器没有所需 GATT 服务"
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
            lastError = "充电器缺少写入或通知特征"
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
    case disconnected, requestAlreadyPending, responseTimeout(UInt16), missingDeviceKey

    var errorDescription: String? {
        switch self {
        case .disconnected: "蓝牙连接已断开"
        case .requestAlreadyPending: "上一个蓝牙请求尚未完成"
        case let .responseTimeout(command): String(format: "等待命令 0x%04X 响应超时", command)
        case .missingDeviceKey: "充电器没有返回有效的 P-256 公钥"
        }
    }
}
