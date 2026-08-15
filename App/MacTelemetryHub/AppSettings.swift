import Foundation
import Security
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        /// 充电头的配对 UUID。键名是历史遗留 —— 当年只有一台设备，
        /// 改键会让老用户的配对丢失，不值得。
        static let peripheralID = "peripheralID"
        static let powerBankPeripheralID = "powerBankPeripheralID"
        static let powerBankModuleEnabled = "powerBankModuleEnabled"
        static let httpServerEnabled = "httpServerEnabled"
        static let httpPort = "httpPort"
        static let postEnabled = "postEnabled"
        static let postURL = "postURL"
        static let postInterval = "postInterval"
        static let postTimeout = "postTimeout"
        static let deviceID = "telemetryDeviceID"
        static let chargerModuleEnabled = "chargerModuleEnabled"
        static let desktopModuleEnabled = "desktopModuleEnabled"
        static let desktopReportingBlacklist = "desktopReportingBlacklist"
        static let windowTitleApplicationWhitelist = "windowTitleApplicationWhitelist"
        static let appleMusicModuleEnabled = "appleMusicModuleEnabled"
        static let timezoneModuleEnabled = "timezoneModuleEnabled"
        static let codexBarModuleEnabled = "codexBarModuleEnabled"
        static let codexBarCLIPath = "codexBarCLIPath"
        static let ccusageCLIPath = "ccusageCLIPath"
        static let codingSessionRefreshInterval = "codingSessionRefreshInterval"
        static let codexBarCostRefreshInterval = "codexBarCostRefreshInterval"
        static let agentLimitsRefreshInterval = "agentLimitsRefreshInterval"
        static let r2Endpoint = "r2Endpoint"
        static let r2Bucket = "r2Bucket"
        static let r2AccessKeyAccount = "r2-access-key-id"
        static let r2SecretAccessKeyAccount = "r2-secret-access-key"
        static let userIDAccount = "anker-user-id"
        static let telemetrySecretAccount = "telemetry-ingest-secret"
    }

    @Published var userID: String
    @Published var peripheralID: String
    @Published var powerBankPeripheralID: String
    @Published var httpServerEnabled: Bool
    @Published var httpPort: Int
    @Published var postEnabled: Bool
    @Published var postURL: String
    @Published var postInterval: Double
    @Published var postTimeout: Double
    @Published var deviceID: String
    @Published var telemetrySecret: String
    @Published var chargerModuleEnabled: Bool
    @Published var powerBankModuleEnabled: Bool
    @Published var desktopModuleEnabled: Bool
    @Published var desktopReportingBlacklist: String
    @Published var windowTitleApplicationWhitelist: String
    @Published var appleMusicModuleEnabled: Bool
    @Published var timezoneModuleEnabled: Bool
    @Published var codexBarModuleEnabled: Bool
    @Published var codexBarCLIPath: String
    @Published var ccusageCLIPath: String
    @Published var codingSessionRefreshInterval: Double
    @Published var codexBarCostRefreshInterval: Double
    @Published var agentLimitsRefreshInterval: Double
    @Published var r2Endpoint: String
    @Published var r2Bucket: String
    @Published var r2AccessKeyID: String
    @Published var r2SecretAccessKey: String
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
        powerBankPeripheralID = defaults.string(forKey: Key.powerBankPeripheralID)
            ?? environment["ANKER_POWERBANK_ADDRESS"] ?? ""
        httpServerEnabled = defaults.object(forKey: Key.httpServerEnabled) as? Bool ?? false
        let storedPort = defaults.integer(forKey: Key.httpPort)
        httpPort = storedPort == 0 ? Int(environment["A2687_PORT"] ?? "8787") ?? 8787 : storedPort
        let initialPostURL = defaults.string(forKey: Key.postURL) ?? environment["A2687_POST_URL"] ?? ""
        /**
         * 历代入口自动迁移到当前这个，避免升级后还在往已删除的路由发。
         *
         * `/charger` 是只上报充电头的那一版，`/telemetry` 是数据和心跳还分两个
         * 端点的那一版 —— 站点两边都已经删干净，不留兼容路径，所以这里必须换，
         * 而不只是提示用户改设置。
         */
        postURL = Self.migratedPostURL(initialPostURL)
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
        // 默认关：没配对过的机器打开它只会一直停在「未配对」。
        powerBankModuleEnabled = defaults.object(forKey: Key.powerBankModuleEnabled) as? Bool ?? false
        desktopModuleEnabled = defaults.object(forKey: Key.desktopModuleEnabled) as? Bool ?? true
        desktopReportingBlacklist = defaults.string(forKey: Key.desktopReportingBlacklist) ?? ""
        windowTitleApplicationWhitelist = defaults.string(
            forKey: Key.windowTitleApplicationWhitelist
        ) ?? ""
        appleMusicModuleEnabled = defaults.object(forKey: Key.appleMusicModuleEnabled) as? Bool ?? true
        timezoneModuleEnabled = defaults.object(forKey: Key.timezoneModuleEnabled) as? Bool ?? true
        codexBarModuleEnabled = defaults.object(forKey: Key.codexBarModuleEnabled) as? Bool ?? false
        codexBarCLIPath = defaults.string(forKey: Key.codexBarCLIPath)
            ?? environment["CODEXBAR_CLI_PATH"]
            ?? Self.firstExistingPath([
                "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
            ])
            ?? ""
        let storedCcusagePath = defaults.string(forKey: Key.ccusageCLIPath) ?? ""
        ccusageCLIPath = storedCcusagePath.hasPrefix("/") &&
            FileManager.default.isExecutableFile(atPath: storedCcusagePath)
            ? storedCcusagePath
            : environment["CCUSAGE_CLI_PATH"]
                ?? Self.firstExistingPath([
                    "/Users/\(NSUserName())/.hermes/node/bin/ccusage",
                    "/Users/\(NSUserName())/.local/bin/ccusage",
                    "/opt/homebrew/bin/ccusage",
                    "/usr/local/bin/ccusage",
                ])
                ?? ""
        let storedSessionInterval = defaults.double(forKey: Key.codingSessionRefreshInterval)
        codingSessionRefreshInterval = storedSessionInterval == 0 ? 60 : storedSessionInterval
        let storedCostInterval = defaults.double(forKey: Key.codexBarCostRefreshInterval)
        codexBarCostRefreshInterval = storedCostInterval == 0 ? 600 : storedCostInterval
        let storedAgentLimitsInterval = defaults.double(forKey: Key.agentLimitsRefreshInterval)
        agentLimitsRefreshInterval = storedAgentLimitsInterval == 0 ? 600 : storedAgentLimitsInterval
        r2Endpoint = defaults.string(forKey: Key.r2Endpoint)
            ?? environment["R2_ENDPOINT"]
            ?? ""
        r2Bucket = defaults.string(forKey: Key.r2Bucket)
            ?? environment["R2_BUCKET"]
            ?? ""
        r2AccessKeyID = environment["R2_ACCESS_KEY_ID"]
            ?? keychain.read(account: Key.r2AccessKeyAccount)
            ?? ""
        r2SecretAccessKey = environment["R2_SECRET_ACCESS_KEY"]
            ?? keychain.read(account: Key.r2SecretAccessKeyAccount)
            ?? ""
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

        // Explicitly saving Settings is the point where an environment-provided ID
        // becomes persistent.  This keeps startup non-interactive and deterministic.
    }

    /// 站点现在只有这一个上报入口：数据、心跳、优雅下线都发它。
    private static let ingestPath = "/api/ingest/mac"
    /// 已经删除的历代入口，读设置时原地换成上面那个
    private static let retiredIngestPaths = ["/api/ingest/charger", "/api/ingest/telemetry"]

    private static func migratedPostURL(_ stored: String) -> String {
        for retired in retiredIngestPaths where stored.hasSuffix(retired) {
            return String(stored.dropLast(retired.count)) + ingestPath
        }
        return stored
    }

    var normalizedPeripheralID: UUID? {
        Self.normalizedUUID(peripheralID)
    }

    var normalizedPowerBankPeripheralID: UUID? {
        Self.normalizedUUID(powerBankPeripheralID)
    }

    var normalizedDesktopReportingBlacklist: DesktopReportingBlacklist {
        DesktopReportingBlacklist(rawValue: desktopReportingBlacklist)
    }

    var normalizedWindowTitleApplicationWhitelist: BundleIdentifierList {
        BundleIdentifierList(rawValue: windowTitleApplicationWhitelist)
    }

    func isDesktopReportingBlocked(bundleIdentifier: String?) -> Bool {
        normalizedDesktopReportingBlacklist.contains(bundleIdentifier: bundleIdentifier)
    }

    func addToDesktopReportingBlacklist(bundleIdentifier: String) {
        let current = normalizedDesktopReportingBlacklist
        guard !current.contains(bundleIdentifier: bundleIdentifier) else { return }
        desktopReportingBlacklist = (current.bundleIdentifiers + [bundleIdentifier]).joined(separator: "\n")
    }

    func addToWindowTitleApplicationWhitelist(bundleIdentifier: String) {
        let current = normalizedWindowTitleApplicationWhitelist
        guard !current.contains(bundleIdentifier: bundleIdentifier) else { return }
        windowTitleApplicationWhitelist = (current.bundleIdentifiers + [bundleIdentifier])
            .joined(separator: "\n")
    }

    private static func normalizedUUID(_ raw: String) -> UUID? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : UUID(uuidString: value)
    }

    func validate() throws {
        // 两台设备都要账号 ID，但表现不同：充电头没有它一帧都不推；充电宝会推，
        // 然后 26 秒后断链 —— 后者曾经被当成「设备脾气」查了很久。
        if chargerModuleEnabled || powerBankModuleEnabled {
            let trimmedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedUserID.utf8.count == 40, trimmedUserID.unicodeScalars.allSatisfy(\.isASCII) else {
                throw SettingsError.invalidUserID
            }
        }
        if chargerModuleEnabled,
           !peripheralID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           normalizedPeripheralID == nil {
            throw SettingsError.invalidPeripheralID
        }
        if powerBankModuleEnabled,
           !powerBankPeripheralID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           normalizedPowerBankPeripheralID == nil {
            throw SettingsError.invalidPeripheralID
        }
        if httpServerEnabled {
            guard (1...65535).contains(httpPort) else { throw SettingsError.invalidPort }
        }
        guard postInterval > 0, postTimeout > 0 else { throw SettingsError.invalidTiming }
        if postEnabled {
            guard let url = URL(string: postURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw SettingsError.invalidPostURL
            }
        }
        if codexBarModuleEnabled {
            guard FileManager.default.isExecutableFile(atPath: codexBarCLIPath) else {
                throw SettingsError.invalidCodexBarPath
            }
            guard FileManager.default.isExecutableFile(atPath: ccusageCLIPath) else {
                throw SettingsError.invalidCcusagePath
            }
            guard codingSessionRefreshInterval >= 60 else {
                throw SettingsError.invalidCodingSessionInterval
            }
            guard codexBarCostRefreshInterval >= 60 else { throw SettingsError.invalidCodexBarCostInterval }
            guard agentLimitsRefreshInterval >= 60 else { throw SettingsError.invalidAgentLimitsInterval }
        }
        let r2Values = [r2Endpoint, r2Bucket, r2AccessKeyID, r2SecretAccessKey]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if r2Values.contains(where: { !$0.isEmpty }) {
            guard r2Values.allSatisfy({ !$0.isEmpty }),
                  let endpoint = URL(string: r2Values[0]),
                  endpoint.scheme?.lowercased() == "https",
                  endpoint.host != nil else {
                throw SettingsError.invalidR2Configuration
            }
        }
    }

    func save() throws {
        try validate()
        userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        peripheralID = peripheralID.trimmingCharacters(in: .whitespacesAndNewlines)
        powerBankPeripheralID = powerBankPeripheralID.trimmingCharacters(in: .whitespacesAndNewlines)
        postURL = postURL.trimmingCharacters(in: .whitespacesAndNewlines)
        telemetrySecret = telemetrySecret.trimmingCharacters(in: .whitespacesAndNewlines)
        codexBarCLIPath = URL(
            fileURLWithPath: (codexBarCLIPath as NSString).expandingTildeInPath
        ).resolvingSymlinksInPath().path
        ccusageCLIPath = (ccusageCLIPath as NSString).expandingTildeInPath
        r2Endpoint = r2Endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        r2Bucket = r2Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        desktopReportingBlacklist = normalizedDesktopReportingBlacklist.normalizedRawValue
        windowTitleApplicationWhitelist = normalizedWindowTitleApplicationWhitelist.normalizedRawValue
        r2AccessKeyID = r2AccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        r2SecretAccessKey = r2SecretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try keychain.write(userID, account: Key.userIDAccount)
        try keychain.write(telemetrySecret, account: Key.telemetrySecretAccount)
        try keychain.write(r2AccessKeyID, account: Key.r2AccessKeyAccount)
        try keychain.write(r2SecretAccessKey, account: Key.r2SecretAccessKeyAccount)
        defaults.set(peripheralID, forKey: Key.peripheralID)
        defaults.set(powerBankPeripheralID, forKey: Key.powerBankPeripheralID)
        defaults.set(httpServerEnabled, forKey: Key.httpServerEnabled)
        defaults.set(httpPort, forKey: Key.httpPort)
        defaults.set(postEnabled, forKey: Key.postEnabled)
        defaults.set(postURL, forKey: Key.postURL)
        defaults.set(postInterval, forKey: Key.postInterval)
        defaults.set(postTimeout, forKey: Key.postTimeout)
        defaults.set(deviceID, forKey: Key.deviceID)
        defaults.set(chargerModuleEnabled, forKey: Key.chargerModuleEnabled)
        defaults.set(powerBankModuleEnabled, forKey: Key.powerBankModuleEnabled)
        defaults.set(desktopModuleEnabled, forKey: Key.desktopModuleEnabled)
        defaults.set(desktopReportingBlacklist, forKey: Key.desktopReportingBlacklist)
        defaults.set(windowTitleApplicationWhitelist, forKey: Key.windowTitleApplicationWhitelist)
        defaults.set(appleMusicModuleEnabled, forKey: Key.appleMusicModuleEnabled)
        defaults.set(timezoneModuleEnabled, forKey: Key.timezoneModuleEnabled)
        defaults.set(codexBarModuleEnabled, forKey: Key.codexBarModuleEnabled)
        defaults.set(codexBarCLIPath, forKey: Key.codexBarCLIPath)
        defaults.set(ccusageCLIPath, forKey: Key.ccusageCLIPath)
        defaults.set(codingSessionRefreshInterval, forKey: Key.codingSessionRefreshInterval)
        defaults.set(codexBarCostRefreshInterval, forKey: Key.codexBarCostRefreshInterval)
        defaults.set(agentLimitsRefreshInterval, forKey: Key.agentLimitsRefreshInterval)
        defaults.set(r2Endpoint, forKey: Key.r2Endpoint)
        defaults.set(r2Bucket, forKey: Key.r2Bucket)
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
    case invalidCodexBarPath, invalidCcusagePath, invalidCodingSessionInterval
    case invalidCodexBarCostInterval, invalidAgentLimitsInterval
    case invalidR2Configuration

    var errorDescription: String? {
        switch self {
        case .invalidUserID: "Anker 用户 ID 必须是正好 40 个 ASCII 字符。"
        case .invalidPeripheralID: "配对的充电头 ID 必须是有效 UUID，或留空重新配对。"
        case .invalidPort: "HTTP 端口必须在 1 到 65535 之间。"
        case .invalidTiming: "POST 间隔和超时必须大于 0。"
        case .invalidPostURL: "POST 地址必须是完整的 http:// 或 https:// URL。"
        case .invalidCodexBarPath: "启用 Vibe Coding 用量时，CodexBar CLI 路径必须指向可执行文件。"
        case .invalidCcusagePath: "启用 Vibe Coding 状态时，ccusage CLI 路径必须指向可执行文件。"
        case .invalidCodingSessionInterval: "会话状态刷新间隔不能低于 60 秒。"
        case .invalidCodexBarCostInterval: "本地用量刷新间隔不能低于 60 秒。"
        case .invalidAgentLimitsInterval: "限额刷新间隔不能低于 60 秒。"
        case .invalidR2Configuration: "R2 直传配置必须同时填写 HTTPS Endpoint、Bucket、Access Key ID 和 Secret Access Key。"
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
        switch self { case let .status(code): "无法保存配置到钥匙串（\(code)）。" }
    }
}
