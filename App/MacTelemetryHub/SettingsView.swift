import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case sources
    case charger
    case local
    case reporting

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .sources: "数据源"
        case .charger: "充电设备"
        case .local: "本地服务"
        case .reporting: "远端上报"
        }
    }

    var detail: String {
        switch self {
        case .general: "后台运行与应用标识"
        case .sources: "前台应用、音乐与用量统计"
        case .charger: "Anker Prime 配对与端口遥测"
        case .local: "本机健康检查与充电设备 SSE"
        case .reporting: "版本化遥测入口与发送策略"
        }
    }

    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .sources: "square.stack.3d.up"
        case .charger: "bolt.horizontal"
        case .local: "network"
        case .reporting: "paperplane"
        }
    }
}

private struct RunningApplicationChoice: Identifiable {
    let name: String
    let bundleIdentifier: String

    var id: String { bundleIdentifier.lowercased() }
}

struct SettingsView: View {
    @ObservedObject var service: ServiceController
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var covers: ChargerCoverController
    @ObservedObject private var chargerLink: BluetoothService
    @ObservedObject private var powerBankLink: BluetoothService
    @ObservedObject private var desktopActivity: DesktopActivityMonitor
    @ObservedObject private var appleMusicAuthorization: AppleMusicAuthorizationManager
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SettingsCategory = .general
    @State private var revealUserID = false
    @State private var revealAnkerPassword = false
    @State private var message: String?
    @State private var isError = false

    init(service: ServiceController) {
        self.service = service
        settings = service.settings
        covers = service.covers
        chargerLink = service.chargerLink
        powerBankLink = service.powerBankLink
        desktopActivity = service.desktopActivity
        appleMusicAuthorization = service.appleMusicAuthorization
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("设置") {
                    ForEach(SettingsCategory.allCases) { category in
                        Label(category.title, systemImage: category.icon)
                            .tag(category)
                    }
                }

                Section("应用") {
                    LabeledContent("版本", value: appVersion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(settings.deviceID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .help("遥测设备标识")
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("设置")
        } detail: {
            VStack(spacing: 0) {
                detailHeader
                Divider()

                ScrollView {
                    settingsContent
                        .frame(maxWidth: 700, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(24)
                }
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()
                footer
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 500)
        .onDisappear {
            chargerLink.stopPairingScan()
            powerBankLink.stopPairingScan()
        }
    }

    private func chargingLinkBadge(_ link: BluetoothService) -> some View {
        let enabled = link.slot.isEnabled(settings)
        return StatusBadge(
            text: enabled ? "\(link.slot.displayName) · \(link.phase.label)" : "\(link.slot.displayName)已关闭",
            style: enabled && link.isConnected ? .success : .neutral
        )
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: selection.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(selection.title)
                    .font(.title2.weight(.semibold))
                Text(selection.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if selection == .charger {
                HStack(spacing: 8) {
                    chargingLinkBadge(chargerLink)
                    chargingLinkBadge(powerBankLink)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selection {
        case .general:
            generalSettings
        case .sources:
            sourceSettings
        case .charger:
            chargerSettings
        case .local:
            localSettings
        case .reporting:
            reportingSettings
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingSection("后台运行", detail: "关闭控制面板后，菜单栏服务仍会继续运行。", icon: "menubar.rectangle") {
                Toggle("登录后自动启动", isOn: $settings.launchAtLoginEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: settings.launchAtLoginEnabled) { _, enabled in
                        updateLaunchAtLogin(enabled)
                    }
                Text("需要完成签名并将应用放入“应用程序”文件夹。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            settingSection("遥测设备", detail: "此标识用于区分同一账户下的不同 Mac。", icon: "desktopcomputer") {
                LabeledContent("设备 ID") {
                    Text(settings.deviceID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            }

            if let message {
                feedbackMessage(message)
            }
        }
    }

    private var sourceSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingSection("前台应用", detail: "应用身份默认参与上报；可按 Bundle ID 排除。", icon: "macwindow") {
                Toggle("启用前台应用采集", isOn: $settings.desktopModuleEnabled)
                    .toggleStyle(.switch)

                Divider().padding(.vertical, 3)

                fieldTitle("远端上报黑名单", detail: "每行一个 Bundle ID；也接受逗号或分号，匹配时忽略大小写")
                TextEditor(text: $settings.desktopReportingBlacklist)
                    .font(.body.monospaced())
                    .frame(minHeight: 72, maxHeight: 110)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }

                HStack(spacing: 10) {
                    Menu("添加运行中的应用") {
                        if runningApplicationsForReportingBlacklist.isEmpty {
                            Text("没有可添加的应用")
                        } else {
                            ForEach(runningApplicationsForReportingBlacklist) { application in
                                Button("\(application.name) — \(application.bundleIdentifier)") {
                                    settings.addToDesktopReportingBlacklist(
                                        bundleIdentifier: application.bundleIdentifier
                                    )
                                }
                            }
                        }
                    }

                    Button("从应用程序中选择…") {
                        chooseApplicationsForDesktopReportingBlacklist()
                    }
                }

                Text("命中时本机界面和本地 API 仍会显示当前应用；远端会收到一次空状态来清除上一个应用，应用身份和图标不会上传。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 3)

                fieldTitle("窗口标题白名单", detail: "只有列表中的 Bundle ID 才会读取标题；默认不检测任何应用")
                TextEditor(text: $settings.windowTitleApplicationWhitelist)
                    .font(.body.monospaced())
                    .frame(minHeight: 72, maxHeight: 110)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }

                HStack(spacing: 10) {
                    Menu("添加运行中的应用") {
                        if runningApplicationsForWindowTitleWhitelist.isEmpty {
                            Text("没有可添加的应用")
                        } else {
                            ForEach(runningApplicationsForWindowTitleWhitelist) { application in
                                Button("\(application.name) — \(application.bundleIdentifier)") {
                                    settings.addToWindowTitleApplicationWhitelist(
                                        bundleIdentifier: application.bundleIdentifier
                                    )
                                }
                            }
                        }
                    }

                    Button("从应用程序中选择…") {
                        chooseApplicationsForWindowTitleWhitelist()
                    }
                }

                LabeledContent("辅助功能权限") {
                    Text(windowTitleStatusText)
                        .foregroundStyle(windowTitleStatusColor)
                }

                Text("未命中白名单时不会读取窗口元素或标题，并会立即停止旧观察。标题始终不会写入本地 API、调试快照或远端遥测。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !settings.normalizedWindowTitleApplicationWhitelist.bundleIdentifiers.isEmpty,
                   !desktopActivity.windowTitleAccessGranted {
                    HStack(spacing: 10) {
                        Button("请求辅助功能权限") {
                            desktopActivity.requestWindowTitleAccess()
                        }
                        Button("打开系统设置") {
                            desktopActivity.openWindowTitlePrivacySettings()
                        }
                    }
                }
            }

            settingSection("Apple Music", detail: "直接读取本机 Music.app 的播放状态、曲目与进度。", icon: "music.note") {
                Toggle("启用本机 Apple Music", isOn: $settings.appleMusicModuleEnabled)
                    .toggleStyle(.switch)

                Divider().padding(.vertical, 3)

                fieldTitle("Apple Music 资料库权限", detail: appleMusicAuthorization.statusDescription)
                HStack(spacing: 10) {
                    Button {
                        Task { await service.authorizeAppleMusic() }
                    } label: {
                        Label(
                            service.isUploadingAppleMusicCredentials ? "正在授权…" : "授权 Apple Music",
                            systemImage: service.isUploadingAppleMusicCredentials ? "hourglass" : "person.crop.circle.badge.checkmark"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(service.isUploadingAppleMusicCredentials)

                    if appleMusicAuthorization.hasUserToken {
                        Label("token 已上报，到期前自动续", systemImage: "checkmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("只需授权一次：macOS 会请求资料库权限，之后 token 由本机 MusicKit 现签、到期前自动续期上报。私钥不会离开这台电脑。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let uploadError = service.appleMusicCredentialsUploadError {
                    Label(uploadError, systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let uploadedAt = service.appleMusicCredentialsUploadAt {
                    Label("凭据已于 \(uploadedAt.formatted(date: .omitted, time: .shortened)) 上报", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            settingSection("Mac 时区", detail: "上传 IANA 时区、当前 UTC 偏移和时区缩写，不读取地址。", icon: "clock") {
                Toggle("启用 Mac 时区采集", isOn: $settings.timezoneModuleEnabled)
                    .toggleStyle(.switch)
            }

            settingSection("Vibe Coding 用量", detail: "ccusage 读取本地完整用量与会话；Cursor 直接同步账号云端历史。Mac 保存历史并统一上报摘要，限额由 NAS 独立上报。不会上传 session ID、项目路径、提示词或回复。", icon: "terminal") {
                Toggle("启用用量采集", isOn: $settings.vibeCodingModuleEnabled)
                    .toggleStyle(.switch)

                if settings.vibeCodingModuleEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        monoField(
                            title: "ccusage CLI",
                            detail: "默认使用随应用附带的版本；自定义 CLI 需支持 Antigravity",
                            text: $settings.ccusageCLIPath,
                            placeholder: "应用内置 ccusage 的绝对路径"
                        )
                        NumericField(title: "会话状态刷新", unit: "秒（最少 60）", placeholder: "60", value: $settings.codingSessionRefreshInterval)
                        NumericField(title: "用量刷新", unit: "秒（最少 60）", placeholder: "600", value: $settings.vibeCodingUsageRefreshInterval)
                        NumericField(title: "年度热力图刷新", unit: "秒（最少 60）", placeholder: "3600", value: $settings.vibeCodingYearRefreshInterval)
                    }
                    .padding(.top, 5)
                }
            }

            if let message {
                feedbackMessage(message)
            }
        }
    }

    private var runningApplicationsForReportingBlacklist: [RunningApplicationChoice] {
        runningApplicationChoices(excluding: settings.normalizedDesktopReportingBlacklist)
    }

    private var runningApplicationsForWindowTitleWhitelist: [RunningApplicationChoice] {
        runningApplicationChoices(excluding: settings.normalizedWindowTitleApplicationWhitelist)
    }

    private func runningApplicationChoices(
        excluding configuredList: BundleIdentifierList
    ) -> [RunningApplicationChoice] {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier?.lowercased()
        var seen: Set<String> = []
        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular,
                  let bundleIdentifier = application.bundleIdentifier,
                  bundleIdentifier.lowercased() != ownBundleIdentifier,
                  !configuredList.contains(bundleIdentifier: bundleIdentifier),
                  seen.insert(bundleIdentifier.lowercased()).inserted else {
                return nil
            }
            return RunningApplicationChoice(
                name: application.localizedName ?? bundleIdentifier,
                bundleIdentifier: bundleIdentifier
            )
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func chooseApplicationsForDesktopReportingBlacklist() {
        chooseApplications(
            title: "选择不参与远端上报的应用",
            prompt: "加入黑名单",
            add: settings.addToDesktopReportingBlacklist(bundleIdentifier:)
        )
    }

    private func chooseApplicationsForWindowTitleWhitelist() {
        chooseApplications(
            title: "选择允许读取窗口标题的应用",
            prompt: "加入白名单",
            add: settings.addToWindowTitleApplicationWhitelist(bundleIdentifier:)
        )
    }

    private func chooseApplications(
        title: String,
        prompt: String,
        add: (String) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK else { return }
        let ownBundleIdentifier = Bundle.main.bundleIdentifier?.lowercased()
        for url in panel.urls {
            guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier,
                  bundleIdentifier.lowercased() != ownBundleIdentifier else {
                continue
            }
            add(bundleIdentifier)
        }
    }

    private var windowTitleStatusText: String {
        if settings.normalizedWindowTitleApplicationWhitelist.bundleIdentifiers.isEmpty {
            return "白名单为空，不检测"
        }
        return desktopActivity.windowTitleAccessGranted
            ? "已授权，仅对白名单应用检测"
            : "需要辅助功能权限"
    }

    private var windowTitleStatusColor: Color {
        settings.normalizedWindowTitleApplicationWhitelist.bundleIdentifiers.isEmpty ||
            desktopActivity.windowTitleAccessGranted ? .secondary : .orange
    }

    private var chargerSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 账号 ID 是两台设备共用的，所以它自己一段，排在两个模块前面。
            // 塞在「充电头遥测」里会让人以为只有充电头要 —— 充电宝没有它也能连上，
            // 但会话 26 秒后就断，那种失败很难往这里想。
            settingSection(
                "Anker 账号",
                detail: "充电头和充电宝共用。登录后会写入 40 位用户 ID，并用来拉封面预览。",
                icon: "person.badge.key"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    fieldTitle("账号", detail: "手机号或邮箱")
                    TextField("例如 13800000000", text: $settings.ankerAccount)
                        .textFieldStyle(.roundedBorder)

                    fieldTitle("密码", detail: "保存在钥匙串")
                    HStack(spacing: 8) {
                        Group {
                            if revealAnkerPassword {
                                TextField("Anker 密码", text: $settings.ankerPassword)
                            } else {
                                SecureField("Anker 密码", text: $settings.ankerPassword)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            revealAnkerPassword.toggle()
                        } label: {
                            Image(systemName: revealAnkerPassword ? "eye" : "eye.slash")
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.bordered)
                        .help(revealAnkerPassword ? "隐藏密码" : "显示密码")
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await loginAnkerAccount() }
                        } label: {
                            Label(
                                covers.isLoggingIn ? "正在登录…" : "登录并写入用户 ID",
                                systemImage: covers.isLoggingIn ? "hourglass" : "person.badge.key.fill"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(covers.isLoggingIn || !settings.hasAnkerCloudCredentials)

                        Text(settings.hasValidAnkerToken ? "云端会话有效" : "尚未登录云端")
                            .font(.caption)
                            .foregroundStyle(settings.hasValidAnkerToken ? Color.secondary : Color.orange)
                    }

                    fieldTitle("Anker 用户 ID", detail: "登录后自动填写，也可手改")
                    HStack(spacing: 8) {
                        Group {
                            if revealUserID {
                                TextField("40 位 Anker 用户 ID", text: $settings.userID)
                            } else {
                                SecureField("40 位 Anker 用户 ID", text: $settings.userID)
                            }
                        }
                        .font(.body.monospaced())
                        .textFieldStyle(.roundedBorder)

                        Button {
                            revealUserID.toggle()
                        } label: {
                            Image(systemName: revealUserID ? "eye" : "eye.slash")
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.bordered)
                        .help(revealUserID ? "隐藏用户 ID" : "显示用户 ID")
                    }
                    Text("BLE 会话仍然用这个 ID。只有点「登录并写入用户 ID」才会向 Anker 发登录请求；保存设置、刷新封面都不会自动登录。新登录有可能把手机 App 顶下线。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let loginMessage = covers.loginMessage {
                        Label(loginMessage, systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let coverError = covers.lastError, selection == .charger {
                        Label(coverError, systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            settingSection("充电头遥测", detail: "启用后连接 Anker Prime，并接收端口级实时数据。", icon: "bolt.horizontal") {
                Toggle("启用充电头模块", isOn: $settings.chargerModuleEnabled)
                    .toggleStyle(.switch)

                if settings.chargerModuleEnabled {
                    fieldTitle("配对的充电头", detail: settings.normalizedPeripheralID == nil ? "未配对" : "已配对")
                    if settings.normalizedPeripheralID == nil {
                        pairingPicker(chargerLink)
                    } else {
                        pairedRow(chargerLink)
                    }
                }
            }

            settingSection(
                "充电宝遥测",
                detail: "启用后连接 Anker Prime 充电宝，接收电量、温度、每口功率与热控状态。",
                icon: "minus.plus.batteryblock"
            ) {
                Toggle("启用充电宝模块", isOn: $settings.powerBankModuleEnabled)
                    .toggleStyle(.switch)

                if settings.powerBankModuleEnabled {
                    fieldTitle(
                        "配对的充电宝",
                        detail: settings.normalizedPowerBankPeripheralID == nil ? "未配对" : "已配对"
                    )
                    if settings.normalizedPowerBankPeripheralID == nil {
                        pairingPicker(powerBankLink)
                    } else {
                        pairedRow(powerBankLink)
                    }
                    Toggle("空闲时智能休眠", isOn: $settings.powerBankIdleSleepEnabled)
                        .toggleStyle(.switch)
                        .padding(.top, 8)
                    Text("待机约五分钟后断开蓝牙，之后隔一段时间再连上去看有没有充放电。仍空闲就继续睡，间隔逐渐加长。充电头不受影响。手机 App 连充电宝时也需要本机先放开。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }

            if let message {
                feedbackMessage(message)
            }
        }
    }

    private var localSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingSection("本地 HTTP", detail: "健康检查，以及两条跟随蓝牙推流的充电设备 SSE。", icon: "network") {
                Toggle("启用本地 HTTP", isOn: $settings.httpServerEnabled)
                    .toggleStyle(.switch)

                if settings.httpServerEnabled {
                    fieldTitle("绑定地址", detail: "只填 IP。127.0.0.1 仅本机，0.0.0.0 所有 IPv4 网卡，也可以填某一块网卡的地址。")
                    TextField("127.0.0.1", text: $settings.httpBindAddress)
                        .font(.body.monospaced())
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("监听端口")
                                .font(.callout.weight(.medium))
                            Text("改地址或端口会断开现有 SSE 并重新监听。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        TextField("8787", value: $settings.httpPort, format: .number.grouping(.never))
                            .font(.body.monospacedDigit())
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Label("可用端点", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.callout.weight(.medium))
                        Text("GET  /health")
                        Text("GET  /sse/charger")
                        Text("GET  /sse/powerbank")
                        Text("SSE 没有本地定时器，充电设备推一帧才发一帧。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                } else {
                    Label("关闭后不监听任何本地或局域网端口；远端上报不受影响。", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            settingSection("后台状态", detail: "服务在菜单栏保持可见，关闭主窗口不会停止采集。", icon: "menubar.rectangle") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(!settings.httpServerEnabled ? Color.secondary : service.httpServer.listeningURL == nil ? .orange : .green)
                        .frame(width: 7, height: 7)
                    Text(!settings.httpServerEnabled ? "本地 HTTP 已关闭" : service.httpServer.listeningURL == nil ? "本地 HTTP 未启动" : "本地 HTTP 正在监听")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if let url = service.httpServer.listeningURL {
                        Button("打开端点") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.link)
                    }
                }
            }

            if let message {
                feedbackMessage(message)
            }
        }
    }

    private var reportingSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingSection("统一上报", detail: "所有已启用模块使用同一个版本化遥测入口。", icon: "paperplane") {
                Toggle("启用远端上报", isOn: $settings.postEnabled)
                    .toggleStyle(.switch)

                if settings.postEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        fieldTitle("上报端点", detail: "HTTP / HTTPS")
                        TextField("https://example.com/api/ingest/mac", text: $settings.postURL)
                            .textFieldStyle(.roundedBorder)

                        fieldTitle("Bearer 密钥", detail: "保存在钥匙串")
                        SecureField("与网站 TELEMETRY_INGEST_SECRET 一致", text: $settings.telemetrySecret)
                            .font(.body.monospaced())
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 14) {
                            NumericField(title: "发送间隔", unit: "秒", placeholder: "60", value: $settings.postInterval)
                            NumericField(title: "请求超时", unit: "秒", placeholder: "10", value: $settings.postTimeout)
                        }

                        fieldTitle("前台应用图标直传 R2", detail: "可选；密钥保存在钥匙串")
                        TextField("https://<account-id>.r2.cloudflarestorage.com", text: $settings.r2Endpoint)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 14) {
                            TextField("R2 Bucket", text: $settings.r2Bucket)
                                .textFieldStyle(.roundedBorder)
                            TextField("Access Key ID", text: $settings.r2AccessKeyID)
                                .textFieldStyle(.roundedBorder)
                        }
                        SecureField("R2 Secret Access Key", text: $settings.r2SecretAccessKey)
                            .font(.body.monospaced())
                            .textFieldStyle(.roundedBorder)

                        Label("模块按字段部分更新；上报失败不会中断本地采集。", systemImage: "shield.checkered")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label("配置完整后，图标由本机直接 PUT 到 R2；网站只接收图标哈希。", systemImage: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 5)
                } else {
                    Label("开启后可配置上报地址、发送间隔和请求超时。", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let message {
                feedbackMessage(message)
            }
        }
    }

    @ViewBuilder
    private func settingSection<Content: View>(_ title: String, detail: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) { Divider() }
        .padding(.bottom, 20)
    }

    private func fieldTitle(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(.callout.weight(.medium))
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func monoField(title: String, detail: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldTitle(title, detail: detail)
            TextField(placeholder, text: text)
                .font(.caption.monospaced())
                .textFieldStyle(.roundedBorder)
        }
    }

    private func pairingPicker(_ link: BluetoothService) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Button {
                    link.startPairingScan()
                } label: {
                    Label(link.isPairingScan ? "正在扫描…" : "扫描\(link.slot.displayName)", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.bordered)
                .disabled(link.isPairingScan)

                if link.isPairingScan {
                    ProgressView().controlSize(.small)
                    Button("停止", systemImage: "stop.fill") { link.stopPairingScan() }
                        .buttonStyle(.borderless)
                }
            }

            ForEach(link.discovered) { device in
                Button {
                    link.slot.storePeripheralID(device.id.uuidString, in: settings)
                    link.stopPairingScan()
                    save()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: link.slot.icon).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.callout.weight(.medium))
                            Text(device.id.uuidString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(device.rssi) dBm")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.07), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if link.discovered.isEmpty {
                Text(link.isPairingScan
                    ? "正在扫描附近的\(link.slot.displayName)。"
                    : "扫描一次并选择设备后，应用会记住它，以后只连接这一台。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pairedRow(_ link: BluetoothService) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(link.slot.peripheralIDString(settings))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("重新配对", systemImage: "arrow.triangle.2.circlepath") {
                    link.slot.storePeripheralID("", in: settings)
                    save()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text("只会尝试连接这一台设备；请求会保持等待，\(link.slot.displayName)上电后自动接入。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func feedbackMessage(_ text: String) -> some View {
        Label(text, systemImage: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(isError ? .red : .green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .lineLimit(2)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let message {
                Label(message, systemImage: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .green)
                    .lineLimit(1)
            } else {
                Text("更改会在保存后应用到采集模块。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存", systemImage: "checkmark") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private func save() {
        Task { await saveSettings() }
    }

    private func loginAnkerAccount() async {
        do {
            try await service.covers.loginAndStoreUserID()
            message = service.covers.loginMessage ?? "Anker 账号已登录。"
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }

    private func saveSettings() async {
        do {
            try service.applySettings()
            message = "设置已保存。"
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            try settings.setLaunchAtLogin(enabled)
            message = enabled ? "已启用登录自启。" : "已关闭登录自启。"
            isError = false
        } catch {
            message = "无法修改登录自启：\(error.localizedDescription)"
            isError = true
        }
    }
}

private struct NumericField: View {
    let title: String
    let unit: String
    let placeholder: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            HStack(spacing: 6) {
                TextField(placeholder, value: $value, format: .number)
                    .font(.body.monospacedDigit())
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
    }
}
