import CryptoKit
import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Anker CN/COM/EU passport password wrapping (Solix-compatible).
///
/// ECDH P-256 against the static server point, then AES-256-CBC with the
/// 32-byte shared secret as the key and the first 16 bytes as the IV.
/// The official app also wraps HTTP bodies in `algo_ecdh`; the CN host
/// accepts plaintext JSON if that header is omitted.
public enum AnkerPassportCrypto {
    public static let serverPublicKeyHex =
        "04c5c00c4f8d1197cc7c3167c52bf7acb054d722f0ef08dcd7e0883236e0d72a" +
        "3868d9750cb47fa4619248f3d83f0f662671dadc6e2d31c2f41db0161651c7c076"

    public struct Envelope: Equatable, Sendable {
        public let clientPublicKeyHex: String
        public let encryptedPassword: String

        public init(clientPublicKeyHex: String, encryptedPassword: String) {
            self.clientPublicKeyHex = clientPublicKeyHex
            self.encryptedPassword = encryptedPassword
        }
    }

    public static func passwordEnvelope(_ password: String) throws -> Envelope {
        guard let serverRaw = Data(hex: serverPublicKeyHex), serverRaw.count == 65 else {
            throw PassportCryptoError.invalidServerKey
        }
        let privateKey = P256.KeyAgreement.PrivateKey()
        let server = try P256.KeyAgreement.PublicKey(x963Representation: serverRaw)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: server)
        let shared = secret.withUnsafeBytes { Data($0) }
        guard shared.count == 32 else { throw PassportCryptoError.invalidSharedSecret }
        let ciphertext = try aes256CBCEncrypt(
            key: shared,
            iv: shared.prefix(16),
            plaintext: Data(password.utf8)
        )
        return Envelope(
            clientPublicKeyHex: privateKey.publicKey.x963Representation.map {
                String(format: "%02x", $0)
            }.joined(),
            encryptedPassword: ciphertext.base64EncodedString()
        )
    }

    public static func aes256CBCEncrypt(key: Data, iv: Data, plaintext: Data) throws -> Data {
        guard key.count == 32, iv.count == 16 else { throw PassportCryptoError.invalidSessionMaterial }
        #if canImport(CommonCrypto)
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { plaintextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            plaintextBytes.baseAddress,
                            plaintext.count,
                            outputBytes.baseAddress,
                            outputBytes.count,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw PassportCryptoError.encryptFailed(status) }
        return output.prefix(outputLength)
        #else
        throw PassportCryptoError.commonCryptoUnavailable
        #endif
    }

    public static func parseHashCode(_ raw: String) -> UInt32? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt32(trimmed.dropFirst(2), radix: 16)
        }
        return UInt32(trimmed, radix: 16) ?? UInt32(trimmed)
    }
}

public enum PassportCryptoError: LocalizedError, Equatable {
    case invalidServerKey
    case invalidSharedSecret
    case invalidSessionMaterial
    case encryptFailed(Int32)
    case commonCryptoUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidServerKey: "Anker 登录公钥无效"
        case .invalidSharedSecret: "Anker 登录 ECDH 共享密钥长度不正确"
        case .invalidSessionMaterial: "Anker 登录 AES 密钥或 IV 长度不正确"
        case let .encryptFailed(status): "无法加密 Anker 密码（\(status)）"
        case .commonCryptoUnavailable: "本机构建缺少 CommonCrypto，无法加密 Anker 密码"
        }
    }
}
