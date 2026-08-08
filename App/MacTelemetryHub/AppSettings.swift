import Foundation
import Security
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let peripheralID = "peripheralID"
        static let httpPort = "httpPort"
        static let postEnabled = "postEnabled"
        static let postURL = "postURL"
        static let postInterval = "postInterval"
        static let postTimeout = "postTimeout"
        static let deviceID = "telemetryDeviceID"
        static let chargerModuleEnabled = "chargerModuleEnabled"
        static let desktopModuleEnabled = "desktopModuleEnabled"
        static let appleMusicModuleEnabled = "appleMusicModuleEnabled"
        static let ccusageModuleEnabled = "ccusageModuleEnabled"
        static let nodePath = "ccusageNodePath"
        static let ccusageCLIPath = "ccusageCLIPath"
        static let ccusageRefreshInterval = "ccusageRefreshInterval"
        static let codexCLIPath = "codexCLIPath"
        static let agentLimitsRefreshInterval = "agentLimitsRefreshInterval"
        static let userIDAccount = "anker-user-id"
        static let telemetrySecretAccount = "telemetry-ingest-secret"
    }

    @Published var userID: String
    @Published var peripheralID: String
    @Published var httpPort: Int
    @Published var postEnabled: Bool
    @Published var postURL: String
    @Published var postInterval: Double
    @Published var postTimeout: Double
    @Published var deviceID: String
    @Published var telemetrySecret: String
    @Published var chargerModuleEnabled: Bool
    @Published var desktopModuleEnabled: Bool
    @Published var appleMusicModuleEnabled: Bool
    @Published var ccusageModuleEnabled: Bool
    @Published var nodePath: String
    @Published var ccusageCLIPath: String
    @Published var ccusageRefreshInterval: Double
    @Published var codexCLIPath: String
    @Published var agentLimitsRefreshInterval: Double
    @Published var launchAtLoginEnabled = false

    private let defaults: UserDefaults
    private let keychain = KeychainStore(service: "com.liangyangjunwei.MacTelemetryHub")

    init(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        let environmentUserID = environment["A2687_USER_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A freshly rebuilt/ad-hoc-signed app can trigger a synchronous Keychain ACL
        // prompt.  Prefer an explicitly supplied launch value and avoid touching the
        // Keychain at startup in that case, so the UI and HTTP listener cannot stall.
        let storedUserID = environmentUserID.isEmpty ? (keychain.read(account: Key.userIDAccount) ?? "") : ""
        userID = environmentUserID.isEmpty ? storedUserID : environmentUserID
        peripheralID = defaults.string(forKey: Key.peripheralID) ?? environment["A2687_ADDRESS"] ?? ""
        let storedPort = defaults.integer(forKey: Key.httpPort)
        httpPort = storedPort == 0 ? Int(environment["A2687_PORT"] ?? "8787") ?? 8787 : storedPort
        let initialPostURL = defaults.string(forKey: Key.postURL) ?? environment["A2687_POST_URL"] ?? ""
        // 旧版只上报充电头；升级后自动迁移到统一遥测入口，避免发送 envelope 到旧路由。
        postURL = initialPostURL.hasSuffix("/api/ingest/charger")
            ? String(initialPostURL.dropLast("/api/ingest/charger".count)) + "/api/ingest/telemetry"
            : initialPostURL
        postEnabled = defaults.object(forKey: Key.postEnabled) as? Bool ?? !initialPostURL.isEmpty
        let storedInterval = defaults.double(forKey: Key.postInterval)
        postInterval = storedInterval == 0 ? Double(environment["TELEMETRY_POST_INTERVAL"] ?? environment["A2687_POST_INTERVAL"] ?? "10") ?? 10 : storedInterval
        let storedTimeout = defaults.double(forKey: Key.postTimeout)
        postTimeout = storedTimeout == 0 ? Double(environment["A2687_POST_TIMEOUT"] ?? "10") ?? 10 : storedTimeout
        deviceID = defaults.string(forKey: Key.deviceID) ?? UUID().uuidString.lowercased()
        telemetrySecret = environment["TELEMETRY_INGEST_SECRET"]
            ?? keychain.read(account: Key.telemetrySecretAccount)
            ?? ""
        chargerModuleEnabled = defaults.object(forKey: Key.chargerModuleEnabled) as? Bool ?? true
        desktopModuleEnabled = defaults.object(forKey: Key.desktopModuleEnabled) as? Bool ?? true
        appleMusicModuleEnabled = defaults.object(forKey: Key.appleMusicModuleEnabled) as? Bool ?? true
        ccusageModuleEnabled = defaults.object(forKey: Key.ccusageModuleEnabled) as? Bool ?? false
        nodePath = defaults.string(forKey: Key.nodePath)
            ?? environment["CCUSAGE_NODE_PATH"]
            ?? Self.firstExistingPath(["/Users/\(NSUserName())/.local/bin/node", "/opt/homebrew/bin/node", "/usr/local/bin/node"])
            ?? ""
        ccusageCLIPath = defaults.string(forKey: Key.ccusageCLIPath)
            ?? environment["CCUSAGE_CLI_PATH"]
            ?? ""
        let storedCcusageInterval = defaults.double(forKey: Key.ccusageRefreshInterval)
        ccusageRefreshInterval = storedCcusageInterval == 0 ? 60 : storedCcusageInterval
        codexCLIPath = defaults.string(forKey: Key.codexCLIPath)
            ?? environment["CODEX_CLI_PATH"]
            ?? Self.firstExistingPath(["/Users/\(NSUserName())/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"])
            ?? ""
        let storedAgentLimitsInterval = defaults.double(forKey: Key.agentLimitsRefreshInterval)
        agentLimitsRefreshInterval = storedAgentLimitsInterval == 0 ? 300 : storedAgentLimitsInterval
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

        // Explicitly saving Settings is the point where an environment-provided ID
        // becomes persistent.  This keeps startup non-interactive and deterministic.
    }

    var normalizedPeripheralID: UUID? {
        let value = peripheralID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : UUID(uuidString: value)
    }

    func validate() throws {
        if chargerModuleEnabled {
            let trimmedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedUserID.utf8.count == 40, trimmedUserID.unicodeScalars.allSatisfy(\.isASCII) else {
                throw SettingsError.invalidUserID
            }
            if !peripheralID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               normalizedPeripheralID == nil {
                throw SettingsError.invalidPeripheralID
            }
        }
        guard (1...65535).contains(httpPort) else { throw SettingsError.invalidPort }
        guard postInterval > 0, postTimeout > 0 else { throw SettingsError.invalidTiming }
        if postEnabled {
            guard let url = URL(string: postURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw SettingsError.invalidPostURL
            }
        }
        if ccusageModuleEnabled {
            guard FileManager.default.isExecutableFile(atPath: nodePath) else {
                throw SettingsError.invalidNodePath
            }
            guard FileManager.default.fileExists(atPath: ccusageCLIPath) else {
                throw SettingsError.invalidCcusagePath
            }
            guard ccusageRefreshInterval >= 60 else { throw SettingsError.invalidCcusageInterval }
            // 没装 Codex 的机器留空即可，此时只出 Claude 套餐等级，不该因此拦住保存
            if !codexCLIPath.isEmpty {
                guard FileManager.default.isExecutableFile(atPath: codexCLIPath) else {
                    throw SettingsError.invalidCodexPath
                }
            }
            guard agentLimitsRefreshInterval >= 60 else { throw SettingsError.invalidAgentLimitsInterval }
        }
    }

    func save() throws {
        try validate()
        userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        peripheralID = peripheralID.trimmingCharacters(in: .whitespacesAndNewlines)
        postURL = postURL.trimmingCharacters(in: .whitespacesAndNewlines)
        telemetrySecret = telemetrySecret.trimmingCharacters(in: .whitespacesAndNewlines)
        nodePath = (nodePath as NSString).expandingTildeInPath
        ccusageCLIPath = (ccusageCLIPath as NSString).expandingTildeInPath
        codexCLIPath = (codexCLIPath as NSString).expandingTildeInPath
        try keychain.write(userID, account: Key.userIDAccount)
        try keychain.write(telemetrySecret, account: Key.telemetrySecretAccount)
        defaults.set(peripheralID, forKey: Key.peripheralID)
        defaults.set(httpPort, forKey: Key.httpPort)
        defaults.set(postEnabled, forKey: Key.postEnabled)
        defaults.set(postURL, forKey: Key.postURL)
        defaults.set(postInterval, forKey: Key.postInterval)
        defaults.set(postTimeout, forKey: Key.postTimeout)
        defaults.set(deviceID, forKey: Key.deviceID)
        defaults.set(chargerModuleEnabled, forKey: Key.chargerModuleEnabled)
        defaults.set(desktopModuleEnabled, forKey: Key.desktopModuleEnabled)
        defaults.set(appleMusicModuleEnabled, forKey: Key.appleMusicModuleEnabled)
        defaults.set(ccusageModuleEnabled, forKey: Key.ccusageModuleEnabled)
        defaults.set(nodePath, forKey: Key.nodePath)
        defaults.set(ccusageCLIPath, forKey: Key.ccusageCLIPath)
        defaults.set(ccusageRefreshInterval, forKey: Key.ccusageRefreshInterval)
        defaults.set(codexCLIPath, forKey: Key.codexCLIPath)
        defaults.set(agentLimitsRefreshInterval, forKey: Key.agentLimitsRefreshInterval)
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    private static func firstExistingPath(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum SettingsError: LocalizedError {
    case invalidUserID, invalidPeripheralID, invalidPort, invalidTiming, invalidPostURL
    case invalidNodePath, invalidCcusagePath, invalidCcusageInterval
    case invalidCodexPath, invalidAgentLimitsInterval

    var errorDescription: String? {
        switch self {
        case .invalidUserID: "Anker 用户 ID 必须是正好 40 个 ASCII 字符。"
        case .invalidPeripheralID: "配对的充电头 ID 必须是有效 UUID，或留空重新配对。"
        case .invalidPort: "HTTP 端口必须在 1 到 65535 之间。"
        case .invalidTiming: "POST 间隔和超时必须大于 0。"
        case .invalidPostURL: "POST 地址必须是完整的 http:// 或 https:// URL。"
        case .invalidNodePath: "启用 ccusage 时，Node 路径必须指向可执行文件。"
        case .invalidCcusagePath: "启用 ccusage 时，CLI 路径必须指向 ccusage/src/cli.js。"
        case .invalidCcusageInterval: "ccusage 刷新间隔不能低于 60 秒。"
        case .invalidCodexPath: "Codex 路径填写后必须指向可执行文件；留空则不采集 Codex 限额。"
        case .invalidAgentLimitsInterval: "限额刷新间隔不能低于 60 秒。"
        }
    }
}

private struct KeychainStore {
    let service: String

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = Data(value.utf8)
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }
}

private enum KeychainError: LocalizedError {
    case status(OSStatus)
    var errorDescription: String? {
        switch self { case let .status(code): "无法保存用户 ID 到钥匙串（\(code)）。" }
    }
}
