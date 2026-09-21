import Foundation

/// 一帧已经切好、并按帧头标志决定过要不要解密的通知。
public struct IngestedNotification: Equatable, Sendable {
    public let command: UInt16
    public let encrypted: Bool
    public let acknowledged: Bool
    public let payload: Data
    public let raw: Data

    public init(command: UInt16, encrypted: Bool, acknowledged: Bool, payload: Data, raw: Data) {
        self.command = command
        self.encrypted = encrypted
        self.acknowledged = acknowledged
        self.payload = payload
        self.raw = raw
    }
}

public struct NotificationIngestFailure: Equatable, Sendable {
    public let command: UInt16
    /// `unparsed` 或 `decrypt`。调用方负责写日志，这里不带本地化文案。
    public let reason: String

    public init(command: UInt16, reason: String) {
        self.command = command
        self.reason = reason
    }
}

/**
 * 通知字节到明文载荷。
 *
 * 切帧、解析、以及「只在帧头说加密时才解密」都在这里。充电宝的 `0x0300`
 * 是明文，充电头的遥测是密文；按设备假设丢弃未加密帧会把充电宝整路吃掉。
 * CoreBluetooth 的回调、会话时钟和界面刷新留在 App。
 */
public struct A2687NotificationPipeline: Sendable {
    public var assembler = FrameAssembler()
    public var crypto = A2687CryptoContext()

    public init() {}

    public mutating func resetSession() {
        assembler.reset()
        crypto = A2687CryptoContext()
    }

    public mutating func ingest(_ chunk: Data) -> (frames: [IngestedNotification], failures: [NotificationIngestFailure]) {
        var frames: [IngestedNotification] = []
        var failures: [NotificationIngestFailure] = []
        for raw in assembler.feed(chunk) {
            guard let frame = A2687Protocol.parseFrame(raw) else {
                failures.append(NotificationIngestFailure(command: 0, reason: "unparsed"))
                continue
            }
            let payload: Data
            if frame.encrypted {
                do {
                    payload = try crypto.decrypt(frame.body)
                } catch {
                    failures.append(NotificationIngestFailure(command: frame.command, reason: "decrypt"))
                    continue
                }
            } else {
                payload = frame.body
            }
            frames.append(IngestedNotification(
                command: frame.command,
                encrypted: frame.encrypted,
                acknowledged: frame.acknowledged,
                payload: payload,
                raw: raw
            ))
        }
        return (frames, failures)
    }
}
