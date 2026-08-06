import CryptoKit
import Foundation

public struct A2687CryptoContext: Sendable {
    public enum State: String, Sendable { case initial, session }

    private static let initialKey = Data(hex: "b8ff7422955d4eb6d554a2c470280559")!
    private static let initialNonce = Data(hex: "6ba3e3f2f3a60f2971ce5d1f")!
    private static let aad = Data(hex: "3322110077665544bbaa9988ffeeddcc")!

    private var key = SymmetricKey(data: initialKey)
    private var nonce = initialNonce
    public private(set) var state: State = .initial

    public init() {}

    public mutating func setSession(key: Data, nonce: Data) throws {
        guard key.count == 16, nonce.count == 12 else { throw CryptoError.invalidSessionMaterial }
        self.key = SymmetricKey(data: key)
        self.nonce = nonce
        state = .session
    }

    public func encrypt(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: try AES.GCM.Nonce(data: nonce),
            authenticating: Self.aad
        )
        return sealed.ciphertext + sealed.tag
    }

    public func decrypt(_ ciphertextAndTag: Data) throws -> Data {
        guard ciphertextAndTag.count >= 16 else { throw CryptoError.ciphertextTooShort }
        let ciphertext = ciphertextAndTag.dropLast(16)
        let tag = ciphertextAndTag.suffix(16)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext,
            tag: tag
        )
        return try AES.GCM.open(box, using: key, authenticating: Self.aad)
    }
}

public struct A2687ECDHSession: Sendable {
    private let privateKey: P256.KeyAgreement.PrivateKey

    public init() { privateKey = P256.KeyAgreement.PrivateKey() }

    public var publicCoordinates: Data {
        Data(privateKey.publicKey.x963Representation.dropFirst())
    }

    public func derive(deviceCoordinates: Data) throws -> (key: Data, nonce: Data) {
        guard deviceCoordinates.count == 64 else { throw CryptoError.invalidDevicePublicKey }
        var representation = Data([0x04])
        representation.append(deviceCoordinates)
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: representation)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let bytes = secret.withUnsafeBytes { Data($0) }
        guard bytes.count == 32 else { throw CryptoError.invalidSharedSecret }
        return (Data(bytes.prefix(16)), Data(bytes.dropFirst(16).prefix(12)))
    }
}

public enum CryptoError: LocalizedError {
    case invalidSessionMaterial
    case ciphertextTooShort
    case invalidDevicePublicKey
    case invalidSharedSecret

    public var errorDescription: String? {
        switch self {
        case .invalidSessionMaterial: "会话密钥或 nonce 长度不正确"
        case .ciphertextTooShort: "AES-GCM 密文过短"
        case .invalidDevicePublicKey: "充电器 P-256 公钥必须是 64 字节"
        case .invalidSharedSecret: "ECDH 共享密钥长度不正确"
        }
    }
}

extension Data {
    public init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var output = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            output.append(byte)
            index = next
        }
        self = output
    }

    public var uppercaseHex: String { map { String(format: "%02X", $0) }.joined() }
}
