import Foundation
import Network
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
        static let powerBankIdleSleepEnabled = "powerBankIdleSleepEnabled"
        static let httpServerEnabled = "httpServerEnabled"
        static let httpBindAddress = "httpBindAddress"
        static let httpPort = "httpPort"
        static let postEnabled = "postEnabled"
        static let postURL = "postURL"
        static let postInterval = "postInterval"
        static let postTimeout = "postTimeout"
        static let deviceID = "telemetryDeviceID"
        static let chargerModuleEnabled = "chargerModuleEnabled"
        static let desktopModuleEnabled = "desktopModuleEnabled"
        static let desktopReportingBlacklist = "desktopReportingBlacklist"
        static let windowTitleReportingEnabled = "windowTitleReportingEnabled"
        static let windowTitleBlacklist = "windowTitleBlacklist"
        static let windowTitleTrustedApplications = "windowTitleTrustedApplications"
        static let windowTitleRiskLockMinimum = "windowTitleRiskLockMinimum"
        static let windowTitleRiskClearMaximum = "windowTitleRiskClearMaximum"
        static let windowTitleInformativeMinimum = "windowTitleInformativeMinimum"
        static let typesafeAPIKeyAccount = "typesafe-api-key"
        static let appleMusicModuleEnabled = "appleMusicModuleEnabled"
        static let timezoneModuleEnabled = "timezoneModuleEnabled"
        static let vibeCodingModuleEnabled = "vibeCodingModuleEnabled"
        static let ccusageCLIPath = "codingUsageCLIPath"
        static let codingSessionRefreshInterval = "codingSessionRefreshInterval"
        /// 完整用量采集间隔；账号限额由独立上报器处理。
        static let vibeCodingUsageRefreshInterval = "vibeCodingUsageRefreshInterval"
        static let vibeCodingYearRefreshInterval = "vibeCodingYearRefreshInterval"
        static let r2Endpoint = "r2Endpoint"
        static let r2Bucket = "r2Bucket"
        static let r2AccessKeyAccount = "r2-access-key-id"
        static let r2SecretAccessKeyAccount = "r2-secret-access-key"
        static let userIDAccount = "anker-user-id"
        static let telemetrySecretAccount = "telemetry-ingest-secret"
        /// Cloudflare Access service token 的 Client ID。它不是秘密，放 UserDefaults；
        /// 配对的 Client Secret 沿用上面那个钥匙串条目。
        static let telemetryClientID = "telemetryAccessClientID"
        static let ankerAccount = "ankerAccount"
        static let ankerPasswordAccount = "anker-password"
        static let ankerAuthTokenAccount = "anker-auth-token"
        static let ankerAuthExpiresAt = "ankerAuthExpiresAt"
    }

    // 这些默认值只是占位：真正的取值全在 load() 里，init 和 reload() 共用它。
    // 有了默认值，init 才能把读取逻辑交给一个普通方法，而不用把同一段抄两遍。
    @Published var userID = ""
    @Published var ankerAccount = ""
    @Published var ankerPassword = ""
    @Published var ankerAuthToken = ""
    @Published var ankerAuthExpiresAt: TimeInterval = 0
    @Published var peripheralID = ""
    @Published var powerBankPeripheralID = ""
    @Published var httpServerEnabled = false
    @Published var httpBindAddress = "127.0.0.1"
    @Published var httpPort = 8787
    @Published var postEnabled = false
    @Published var postURL = ""
    @Published var postInterval: Double = 10
    @Published var postTimeout: Double = 10
    @Published var deviceID = ""
    @Published var telemetryClientID = ""
    @Published var telemetrySecret = ""
    @Published var chargerModuleEnabled = true
    @Published var powerBankModuleEnabled = false
    /// 充电宝长时间没有充放电就断开蓝牙，隔一段时间再连上去看一眼。
    @Published var powerBankIdleSleepEnabled = true
    @Published var desktopModuleEnabled = true
    @Published var desktopReportingBlacklist = ""
    /**
     * 窗口标题的总开关。
     *
     * 关掉就整条链不读、不判、不报，判断缓存原样留着。和其它设置不同，它当场
     * 落盘 —— 菜单栏上那一下要立刻生效，所以它不进 `draftToken`，也没有
     * 「未保存」这回事。
     */
    @Published var windowTitleReportingEnabled = true
    /// 标题黑名单：这些应用的窗口标题永不读取、永不判断、永不上报。
    @Published var windowTitleBlacklist = ""
    /// 免判放行：这些应用的标题直接上报，不问 Jev。
    @Published var windowTitleTrustedApplications = ""
    /// 锁定线：五道风险题任何一道到了这个概率就直接锁定。
    @Published var windowTitleRiskLockMinimum = WindowTitleJudgmentThresholds.standard.riskLockMinimum
    /// 放行线：五道风险题全都低到这个数才自动公开。
    @Published var windowTitleRiskClearMaximum = WindowTitleJudgmentThresholds.standard.riskClearMaximum
    /// 值得展示线：信息量低于它就当这条标题没什么可公开的。
    @Published var windowTitleInformativeMinimum = WindowTitleJudgmentThresholds.standard.informativeMinimum
    /// 判断窗口标题用的 TypeSafe API key。落钥匙串，不进 UserDefaults。
    @Published var typesafeAPIKey = ""
    @Published var appleMusicModuleEnabled = true
    @Published var timezoneModuleEnabled = true
    @Published var vibeCodingModuleEnabled = false
    /// ccusage 可执行文件，读取本地完整历史与会话摘要。
    @Published var ccusageCLIPath = ""
    /// 短间隔那份：此刻在不在用
    @Published var codingSessionRefreshInterval: Double = 60
    /// 长间隔那份：全历史 token 与费用，限额由 NAS 独立采集。
    @Published var vibeCodingUsageRefreshInterval: Double = 600
    /// 年度热力图：过去 53 周日合计。格子按天变，默认一小时。
    @Published var vibeCodingYearRefreshInterval: Double = 3_600
    @Published var r2Endpoint = ""
    @Published var r2Bucket = ""
    @Published var r2AccessKeyID = ""
    @Published var r2SecretAccessKey = ""
    @Published var launchAtLoginEnabled = false

    private let defaults: UserDefaults
    private let environment: [String: String]
    private let keychain = KeychainStore(service: "com.liangyangjunwei.MacTelemetryHub")

    init(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        self.environment = environment
        load()
    }

    /**
     * 把所有字段重新读回落盘的值，丢掉界面上没保存的改动。
     *
     * 设置页的控件直接绑在这个对象上，输入的一刻就已经改了内存里的值 —— 点「取消」
     * 只关窗口的话，改动会留在采集模块脚下继续生效。回滚必须真的重读一遍。
     */
    func reload() {
        load()
    }

    private func load() {
        let environmentUserID = environment["A2687_USER_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A freshly rebuilt/ad-hoc-signed app can trigger a synchronous Keychain ACL
        // prompt.  Prefer an explicitly supplied launch value and avoid touching the
        // Keychain at startup in that case, so the UI and HTTP listener cannot stall.
        let storedUserID = environmentUserID.isEmpty ? (keychain.read(account: Key.userIDAccount) ?? "") : ""
        userID = environmentUserID.isEmpty ? storedUserID : environmentUserID
        ankerAccount = defaults.string(forKey: Key.ankerAccount)
            ?? environment["ANKER_ACCOUNT"]
            ?? environment["A2687_ACCOUNT"]
            ?? ""
        ankerPassword = environment["ANKER_PASSWORD"]
            ?? environment["A2687_PASSWORD"]
            ?? (environmentUserID.isEmpty ? (keychain.read(account: Key.ankerPasswordAccount) ?? "") : "")
        ankerAuthToken = environmentUserID.isEmpty
            ? (keychain.read(account: Key.ankerAuthTokenAccount) ?? "")
            : ""
        ankerAuthExpiresAt = defaults.double(forKey: Key.ankerAuthExpiresAt)
        peripheralID = defaults.string(forKey: Key.peripheralID) ?? environment["A2687_ADDRESS"] ?? ""
        powerBankPeripheralID = defaults.string(forKey: Key.powerBankPeripheralID)
            ?? environment["ANKER_POWERBANK_ADDRESS"] ?? ""
        httpServerEnabled = defaults.object(forKey: Key.httpServerEnabled) as? Bool ?? false
        let storedBind = defaults.string(forKey: Key.httpBindAddress)
            ?? environment["TELEMETRY_HTTP_BIND"]
            ?? environment["A2687_BIND"]
            ?? ""
        httpBindAddress = storedBind.isEmpty ? "127.0.0.1" : storedBind
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
        // 设备 ID 只在保存时落盘。还没保存过就重读（点了取消）时不能顺手换一个新的 ——
        // 站点会把它当成另一台 Mac，历史就断在这里。
        let storedDeviceID = defaults.string(forKey: Key.deviceID) ?? ""
        deviceID = storedDeviceID.isEmpty
            ? (deviceID.isEmpty ? UUID().uuidString.lowercased() : deviceID)
            : storedDeviceID
        // Cloudflare Access service token：Client ID 进 UserDefaults，Client Secret 进钥匙串。
        telemetryClientID = environment["ACCESS_CLIENT_ID"]
            ?? defaults.string(forKey: Key.telemetryClientID)
            ?? ""
        telemetrySecret = environment["ACCESS_CLIENT_SECRET"]
            ?? keychain.read(account: Key.telemetrySecretAccount)
            ?? ""
        chargerModuleEnabled = defaults.object(forKey: Key.chargerModuleEnabled) as? Bool ?? true
        // 默认关：没配对过的机器打开它只会一直停在「未配对」。
        powerBankModuleEnabled = defaults.object(forKey: Key.powerBankModuleEnabled) as? Bool ?? false
        powerBankIdleSleepEnabled = defaults.object(forKey: Key.powerBankIdleSleepEnabled) as? Bool ?? true
        desktopModuleEnabled = defaults.object(forKey: Key.desktopModuleEnabled) as? Bool ?? true
        desktopReportingBlacklist = defaults.string(forKey: Key.desktopReportingBlacklist) ?? ""
        windowTitleReportingEnabled = defaults.object(
            forKey: Key.windowTitleReportingEnabled
        ) as? Bool ?? true
        windowTitleBlacklist = defaults.string(forKey: Key.windowTitleBlacklist) ?? ""
        windowTitleTrustedApplications = defaults.string(
            forKey: Key.windowTitleTrustedApplications
        ) ?? ""
        // 三条线用 object(forKey:) 而不是 double(forKey:)：值得展示线取 0 是
        // 合法的「一律当有信息」，而 double 会把没设置过和 0 说成同一件事。
        let standardThresholds = WindowTitleJudgmentThresholds.standard
        windowTitleRiskLockMinimum = defaults.object(forKey: Key.windowTitleRiskLockMinimum)
            as? Double ?? standardThresholds.riskLockMinimum
        windowTitleRiskClearMaximum = defaults.object(forKey: Key.windowTitleRiskClearMaximum)
            as? Double ?? standardThresholds.riskClearMaximum
        windowTitleInformativeMinimum = defaults.object(forKey: Key.windowTitleInformativeMinimum)
            as? Double ?? standardThresholds.informativeMinimum
        // 和 telemetrySecret 同一套：环境变量优先，其次钥匙串。
        typesafeAPIKey = environment["TYPESAFE_API_KEY"]
            ?? keychain.read(account: Key.typesafeAPIKeyAccount)
            ?? ""
        appleMusicModuleEnabled = defaults.object(forKey: Key.appleMusicModuleEnabled) as? Bool ?? true
        timezoneModuleEnabled = defaults.object(forKey: Key.timezoneModuleEnabled) as? Bool ?? true
        vibeCodingModuleEnabled = defaults.object(forKey: Key.vibeCodingModuleEnabled) as? Bool ?? false
        let storedCcusagePath = defaults.string(forKey: Key.ccusageCLIPath) ?? ""
        let bundledCcusage = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ccusage").path
        ccusageCLIPath = environment["CCUSAGE_CLI_PATH"] ?? (storedCcusagePath.hasPrefix("/") &&
            FileManager.default.isExecutableFile(atPath: storedCcusagePath)
            ? storedCcusagePath
            : bundledCcusage.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
                ?? Self.firstExistingPath([
                    "/Users/\(NSUserName())/.hermes/node/bin/ccusage",
                    "/Users/\(NSUserName())/.local/bin/ccusage",
                    "/opt/homebrew/bin/ccusage",
                    "/usr/local/bin/ccusage",
                ])
                ?? "")
        let storedSessionInterval = defaults.double(forKey: Key.codingSessionRefreshInterval)
        codingSessionRefreshInterval = storedSessionInterval == 0 ? 60 : storedSessionInterval
        let storedUsageInterval = defaults.double(forKey: Key.vibeCodingUsageRefreshInterval)
        vibeCodingUsageRefreshInterval = storedUsageInterval == 0 ? 600 : storedUsageInterval
        let storedYearInterval = defaults.double(forKey: Key.vibeCodingYearRefreshInterval)
        vibeCodingYearRefreshInterval = storedYearInterval == 0
            ? VibeCodingYearMonitor.defaultRefreshInterval
            : storedYearInterval
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

    var normalizedHTTPBindAddress: String? {
        Self.normalizedBindAddress(httpBindAddress)
    }

    /**
     * 绑定地址只接受 IP，不接受主机名。
     *
     * `127.0.0.1` / `::1` 仅本机；`0.0.0.0` / `::` 所有网卡；也可以填某一块
     * 网卡的地址。方括号可有可无（`[::1]` 和 `::1` 一样）。
     */
    static func normalizedBindAddress(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["), value.hasSuffix("]"), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty else { return nil }
        if IPv4Address(value) != nil { return value }
        if IPv6Address(value) != nil { return value }
        return nil
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

    var normalizedWindowTitleBlacklist: BundleIdentifierList {
        BundleIdentifierList(rawValue: windowTitleBlacklist)
    }

    var normalizedWindowTitleTrustedApplications: BundleIdentifierList {
        BundleIdentifierList(rawValue: windowTitleTrustedApplications)
    }

    /// 三条线打成一份给判断用。校验在 `validate()`，这里只搬数。
    var windowTitleJudgmentThresholds: WindowTitleJudgmentThresholds {
        WindowTitleJudgmentThresholds(
            riskLockMinimum: windowTitleRiskLockMinimum,
            riskClearMaximum: windowTitleRiskClearMaximum,
            informativeMinimum: windowTitleInformativeMinimum
        )
    }

    /// 三条线回到实测那一组。只改内存里的草稿，落盘仍然走「保存」。
    func resetWindowTitleThresholds() {
        let standard = WindowTitleJudgmentThresholds.standard
        windowTitleRiskLockMinimum = standard.riskLockMinimum
        windowTitleRiskClearMaximum = standard.riskClearMaximum
        windowTitleInformativeMinimum = standard.informativeMinimum
    }

    var hasAnkerCloudCredentials: Bool {
        !ankerAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !ankerPassword.isEmpty
    }

    var hasValidAnkerToken: Bool {
        let token = ankerAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        if ankerAuthExpiresAt <= 0 { return true }
        return ankerAuthExpiresAt > Date().timeIntervalSince1970 + 60
    }

    func isDesktopReportingBlocked(bundleIdentifier: String?) -> Bool {
        normalizedDesktopReportingBlacklist.contains(bundleIdentifier: bundleIdentifier)
    }

    func addToDesktopReportingBlacklist(bundleIdentifier: String) {
        let current = normalizedDesktopReportingBlacklist
        guard !current.contains(bundleIdentifier: bundleIdentifier) else { return }
        desktopReportingBlacklist = (current.bundleIdentifiers + [bundleIdentifier]).joined(separator: "\n")
    }

    func addToWindowTitleBlacklist(bundleIdentifier: String) {
        let current = normalizedWindowTitleBlacklist
        guard !current.contains(bundleIdentifier: bundleIdentifier) else { return }
        windowTitleBlacklist = (current.bundleIdentifiers + [bundleIdentifier])
            .joined(separator: "\n")
    }

    func addToWindowTitleTrustedApplications(bundleIdentifier: String) {
        let current = normalizedWindowTitleTrustedApplications
        guard !current.contains(bundleIdentifier: bundleIdentifier) else { return }
        windowTitleTrustedApplications = (current.bundleIdentifiers + [bundleIdentifier])
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
            guard Self.normalizedBindAddress(httpBindAddress) != nil else {
                throw SettingsError.invalidBindAddress
            }
        }
        // 缺一样，Access 会把每一封都拒在边缘，站点日志里连痕迹都没有
        if postEnabled,
           telemetryClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || telemetrySecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SettingsError.missingAccessClientSecret
        }
        guard postInterval > 0, postTimeout > 0 else { throw SettingsError.invalidTiming }
        // 放行线严格低于锁定线：两条线相等的话中间那档没了，「问一句」这条路
        // 就此消失，一条模型也拿不准的标题会被直接归进公开或锁定。
        guard windowTitleRiskClearMaximum > 0,
              windowTitleRiskClearMaximum < windowTitleRiskLockMinimum,
              windowTitleRiskLockMinimum <= 1 else {
            throw SettingsError.invalidWindowTitleRiskThresholds
        }
        guard (0...1).contains(windowTitleInformativeMinimum) else {
            throw SettingsError.invalidWindowTitleInformativeMinimum
        }
        if postEnabled {
            guard let url = URL(string: postURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw SettingsError.invalidPostURL
            }
        }
        if vibeCodingModuleEnabled {
            guard FileManager.default.isExecutableFile(atPath: ccusageCLIPath) else {
                throw SettingsError.invalidCcusagePath
            }
            guard codingSessionRefreshInterval >= 60 else {
                throw SettingsError.invalidCodingSessionInterval
            }
            guard vibeCodingUsageRefreshInterval >= 60 else {
                throw SettingsError.invalidVibeCodingUsageInterval
            }
            guard vibeCodingYearRefreshInterval >= 60 else {
                throw SettingsError.invalidVibeCodingYearInterval
            }
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
        ankerAccount = ankerAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        peripheralID = peripheralID.trimmingCharacters(in: .whitespacesAndNewlines)
        powerBankPeripheralID = powerBankPeripheralID.trimmingCharacters(in: .whitespacesAndNewlines)
        postURL = postURL.trimmingCharacters(in: .whitespacesAndNewlines)
        telemetryClientID = telemetryClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        telemetrySecret = telemetrySecret.trimmingCharacters(in: .whitespacesAndNewlines)
        ccusageCLIPath = (ccusageCLIPath as NSString).expandingTildeInPath
        r2Endpoint = r2Endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        r2Bucket = r2Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        desktopReportingBlacklist = normalizedDesktopReportingBlacklist.normalizedRawValue
        windowTitleBlacklist = normalizedWindowTitleBlacklist.normalizedRawValue
        windowTitleTrustedApplications = normalizedWindowTitleTrustedApplications.normalizedRawValue
        typesafeAPIKey = typesafeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        r2AccessKeyID = r2AccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        r2SecretAccessKey = r2SecretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try persistAnkerAccount()
        try keychain.write(telemetrySecret, account: Key.telemetrySecretAccount)
        try keychain.write(typesafeAPIKey, account: Key.typesafeAPIKeyAccount)
        try keychain.write(r2AccessKeyID, account: Key.r2AccessKeyAccount)
        try keychain.write(r2SecretAccessKey, account: Key.r2SecretAccessKeyAccount)
        defaults.set(peripheralID, forKey: Key.peripheralID)
        defaults.set(powerBankPeripheralID, forKey: Key.powerBankPeripheralID)
        httpBindAddress = Self.normalizedBindAddress(httpBindAddress) ?? httpBindAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(httpServerEnabled, forKey: Key.httpServerEnabled)
        defaults.set(httpBindAddress, forKey: Key.httpBindAddress)
        defaults.set(httpPort, forKey: Key.httpPort)
        defaults.set(postEnabled, forKey: Key.postEnabled)
        defaults.set(postURL, forKey: Key.postURL)
        defaults.set(telemetryClientID, forKey: Key.telemetryClientID)
        defaults.set(postInterval, forKey: Key.postInterval)
        defaults.set(postTimeout, forKey: Key.postTimeout)
        defaults.set(deviceID, forKey: Key.deviceID)
        defaults.set(chargerModuleEnabled, forKey: Key.chargerModuleEnabled)
        defaults.set(powerBankModuleEnabled, forKey: Key.powerBankModuleEnabled)
        defaults.set(powerBankIdleSleepEnabled, forKey: Key.powerBankIdleSleepEnabled)
        defaults.set(desktopModuleEnabled, forKey: Key.desktopModuleEnabled)
        defaults.set(desktopReportingBlacklist, forKey: Key.desktopReportingBlacklist)
        defaults.set(windowTitleReportingEnabled, forKey: Key.windowTitleReportingEnabled)
        defaults.set(windowTitleBlacklist, forKey: Key.windowTitleBlacklist)
        defaults.set(windowTitleTrustedApplications, forKey: Key.windowTitleTrustedApplications)
        defaults.set(windowTitleRiskLockMinimum, forKey: Key.windowTitleRiskLockMinimum)
        defaults.set(windowTitleRiskClearMaximum, forKey: Key.windowTitleRiskClearMaximum)
        defaults.set(windowTitleInformativeMinimum, forKey: Key.windowTitleInformativeMinimum)
        defaults.set(appleMusicModuleEnabled, forKey: Key.appleMusicModuleEnabled)
        defaults.set(timezoneModuleEnabled, forKey: Key.timezoneModuleEnabled)
        defaults.set(vibeCodingModuleEnabled, forKey: Key.vibeCodingModuleEnabled)
        defaults.set(ccusageCLIPath, forKey: Key.ccusageCLIPath)
        defaults.set(codingSessionRefreshInterval, forKey: Key.codingSessionRefreshInterval)
        defaults.set(vibeCodingUsageRefreshInterval, forKey: Key.vibeCodingUsageRefreshInterval)
        defaults.set(vibeCodingYearRefreshInterval, forKey: Key.vibeCodingYearRefreshInterval)
        defaults.set(r2Endpoint, forKey: Key.r2Endpoint)
        defaults.set(r2Bucket, forKey: Key.r2Bucket)
    }

    /// Writes account, password, token and user ID without re-validating the rest of Settings.
    func persistAnkerAccount() throws {
        userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        ankerAccount = ankerAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        try keychain.write(userID, account: Key.userIDAccount)
        try keychain.write(ankerPassword, account: Key.ankerPasswordAccount)
        try keychain.write(ankerAuthToken, account: Key.ankerAuthTokenAccount)
        defaults.set(ankerAccount, forKey: Key.ankerAccount)
        defaults.set(ankerAuthExpiresAt, forKey: Key.ankerAuthExpiresAt)
    }

    /**
     * 只把某一台设备的配对 UUID 写进去，不碰别的字段、不做整页校验。
     *
     * 在配对列表里点一台设备，UUID 当场就进了内存。如果这时走整页保存，一个跟配对
     * 毫无关系的字段（比如上报端点还没填完）会让保存失败 —— 界面报一个看不懂的错，
     * 配对却已经改掉了，两边对不上。配对是一个独立动作，落盘也该是独立的。
     */
    /**
     * 只落窗口标题总开关这一个键。
     *
     * 和配对 UUID 同一个理由：菜单栏上拨一下是个独立动作，走整页 `save()` 的话
     * 一个跟它无关的字段没填好就会把这一步顶回来，而开关早就改进内存里了。
     * `save()` 里照样写它一次，幂等。
     */
    /**
     * 只落配对登录换来的那三样：Client ID、Client Secret、上报端点，外加上报开关。
     *
     * 和配对 UUID 同一个理由不走整页 `save()`：服务端在兑换那一刻已经把旧 secret
     * 作废了，这时候一个无关字段没填好把保存顶回来，本机就只剩一把死钥匙。整页保存
     * 也会把用户别处没打算保存的草稿一起写下去。上报开关一并打开落盘：登录按钮只在
     * 开关打开时出现，拿到凭据就是要上报；不落的话上报会话按内存里的「开」重启，
     * 点「取消」回滚成「关」时会话却还在跑。
     */
    func persistPairingCredentials(clientID: String, secret: String, ingestURL: String) throws {
        try keychain.write(secret, account: Key.telemetrySecretAccount)
        telemetryClientID = clientID
        telemetrySecret = secret
        postURL = ingestURL
        postEnabled = true
        defaults.set(true, forKey: Key.postEnabled)
        defaults.set(clientID, forKey: Key.telemetryClientID)
        defaults.set(ingestURL, forKey: Key.postURL)
    }

    /// 启动时会盖过设置页那两栏的环境变量。配对结果照样落盘，但下次启动又会被它们顶掉。
    var accessCredentialEnvironmentOverrides: [String] {
        ["ACCESS_CLIENT_ID", "ACCESS_CLIENT_SECRET"]
            .filter { environment[$0] != nil }
    }

    func persistWindowTitleReporting(_ enabled: Bool) {
        windowTitleReportingEnabled = enabled
        defaults.set(enabled, forKey: Key.windowTitleReportingEnabled)
    }

    func persistPeripheralIdentifier(for slot: ChargingDeviceSlot) {
        switch slot {
        case .charger:
            peripheralID = peripheralID.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(peripheralID, forKey: Key.peripheralID)
        case .powerBank:
            powerBankPeripheralID = powerBankPeripheralID.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(powerBankPeripheralID, forKey: Key.powerBankPeripheralID)
        }
    }

    /// 关设置窗口时用来判断有没有没保存的改动。登录自启和配对 UUID 当场落盘，不在这里。
    var draftToken: SettingsDraftToken {
        SettingsDraftToken(
            userID: userID,
            ankerAccount: ankerAccount,
            ankerPassword: ankerPassword,
            ankerAuthToken: ankerAuthToken,
            ankerAuthExpiresAt: ankerAuthExpiresAt,
            httpServerEnabled: httpServerEnabled,
            httpBindAddress: httpBindAddress,
            httpPort: httpPort,
            postEnabled: postEnabled,
            postURL: postURL,
            telemetryClientID: telemetryClientID,
            telemetrySecret: telemetrySecret,
            postInterval: postInterval,
            postTimeout: postTimeout,
            deviceID: deviceID,
            chargerModuleEnabled: chargerModuleEnabled,
            powerBankModuleEnabled: powerBankModuleEnabled,
            powerBankIdleSleepEnabled: powerBankIdleSleepEnabled,
            desktopModuleEnabled: desktopModuleEnabled,
            desktopReportingBlacklist: desktopReportingBlacklist,
            windowTitleBlacklist: windowTitleBlacklist,
            windowTitleTrustedApplications: windowTitleTrustedApplications,
            windowTitleRiskLockMinimum: windowTitleRiskLockMinimum,
            windowTitleRiskClearMaximum: windowTitleRiskClearMaximum,
            windowTitleInformativeMinimum: windowTitleInformativeMinimum,
            typesafeAPIKey: typesafeAPIKey,
            appleMusicModuleEnabled: appleMusicModuleEnabled,
            timezoneModuleEnabled: timezoneModuleEnabled,
            vibeCodingModuleEnabled: vibeCodingModuleEnabled,
            ccusageCLIPath: ccusageCLIPath,
            codingSessionRefreshInterval: codingSessionRefreshInterval,
            vibeCodingUsageRefreshInterval: vibeCodingUsageRefreshInterval,
            vibeCodingYearRefreshInterval: vibeCodingYearRefreshInterval,
            r2Endpoint: r2Endpoint,
            r2Bucket: r2Bucket,
            r2AccessKeyID: r2AccessKeyID,
            r2SecretAccessKey: r2SecretAccessKey
        )
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

struct SettingsDraftToken: Equatable {
    var userID: String
    var ankerAccount: String
    var ankerPassword: String
    var ankerAuthToken: String
    var ankerAuthExpiresAt: TimeInterval
    var httpServerEnabled: Bool
    var httpBindAddress: String
    var httpPort: Int
    var postEnabled: Bool
    var postURL: String
    var telemetryClientID: String
    var telemetrySecret: String
    var postInterval: Double
    var postTimeout: Double
    var deviceID: String
    var chargerModuleEnabled: Bool
    var powerBankModuleEnabled: Bool
    var powerBankIdleSleepEnabled: Bool
    var desktopModuleEnabled: Bool
    var desktopReportingBlacklist: String
    var windowTitleBlacklist: String
    var windowTitleTrustedApplications: String
    var windowTitleRiskLockMinimum: Double
    var windowTitleRiskClearMaximum: Double
    var windowTitleInformativeMinimum: Double
    var typesafeAPIKey: String
    var appleMusicModuleEnabled: Bool
    var timezoneModuleEnabled: Bool
    var vibeCodingModuleEnabled: Bool
    var ccusageCLIPath: String
    var codingSessionRefreshInterval: Double
    var vibeCodingUsageRefreshInterval: Double
    var vibeCodingYearRefreshInterval: Double
    var r2Endpoint: String
    var r2Bucket: String
    var r2AccessKeyID: String
    var r2SecretAccessKey: String
}

enum SettingsError: LocalizedError {
    case invalidUserID, invalidPeripheralID, invalidPort, invalidBindAddress, invalidTiming, invalidPostURL
    case invalidCcusagePath, invalidCodingSessionInterval
    case invalidVibeCodingUsageInterval
    case invalidVibeCodingYearInterval
    case invalidR2Configuration
    case invalidWindowTitleRiskThresholds
    case invalidWindowTitleInformativeMinimum
    case missingAccessClientSecret

    var errorDescription: String? {
        switch self {
        case .invalidUserID: "Anker 用户 ID 必须是正好 40 个 ASCII 字符。"
        case .invalidPeripheralID: "配对的设备 ID 必须是有效 UUID，或留空重新配对。"
        case .invalidPort: "HTTP 端口必须在 1 到 65535 之间。"
        case .invalidBindAddress: "绑定地址必须是 IP，例如 127.0.0.1、0.0.0.0 或 ::1。"
        // 错误里出现的名字必须和设置页上那一栏的标题一模一样，否则用户不知道该改哪里。
        case .invalidTiming: "上报间隔和请求超时必须大于 0。"
        case .invalidPostURL: "上报端点必须是完整的 http:// 或 https:// URL。"
        case .invalidCcusagePath: "启用 Vibe Coding 用量时，ccusage CLI 路径必须指向可执行文件。"
        case .invalidCodingSessionInterval: "会话状态刷新间隔不能低于 60 秒。"
        case .invalidVibeCodingUsageInterval: "用量刷新间隔不能低于 60 秒。"
        case .invalidVibeCodingYearInterval: "年度热力图刷新间隔不能低于 60 秒。"
        case .invalidR2Configuration: "R2 直传配置必须同时填写 HTTPS Endpoint、Bucket、Access Key ID 和 Secret Access Key。"
        case .invalidWindowTitleRiskThresholds: "放行线必须大于 0 且小于锁定线，锁定线不能超过 1。"
        case .invalidWindowTitleInformativeMinimum: "值得展示线必须在 0 到 1 之间。"
        case .missingAccessClientSecret: "开着远端上报时，Access Client ID 和 Client Secret 都要填（或者点「登录 Cloudflare 获取上报凭据」）。"
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
