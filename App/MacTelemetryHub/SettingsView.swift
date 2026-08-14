import SwiftUI

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
        case .local: "本机 HTTP API 与调试端点"
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

struct SettingsView: View {
    @ObservedObject var service: ServiceController
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var bluetooth: BluetoothService
    @ObservedObject private var powerBankLink: BluetoothService
    @ObservedObject private var appleMusicAuthorization: AppleMusicAuthorizationManager
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SettingsCategory = .general
    @State private var revealUserID = false
    @State private var message: String?
    @State private var isError = false

    init(service: ServiceController) {
        self.service = service
        settings = service.settings
        bluetooth = service.chargerLink
        powerBankLink = service.powerBankLink
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
        .onDisappear { bluetooth.stopPairingScan() }
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

            StatusBadge(
                text: bluetooth.isConnected ? "设备已连接" : bluetooth.phase.label,
                style: bluetooth.isConnected ? .success : .neutral
            )
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
            settingSection("前台应用", detail: "仅采集应用名、Bundle ID 和图标，不读取窗口标题或窗口内容。", icon: "macwindow") {
                Toggle("启用前台应用采集", isOn: $settings.desktopModuleEnabled)
                    .toggleStyle(.switch)
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

            settingSection("Vibe Coding 用量", detail: "CodexBar 聚合 Token、费用和限额；ccusage 只读取最近会话时间与模型，用来判断是否正在使用。不会上传 session ID、项目路径、提示词或回复。", icon: "terminal") {
                Toggle("启用 CodexBar", isOn: $settings.codexBarModuleEnabled)
                    .toggleStyle(.switch)

                if settings.codexBarModuleEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        pathField(
                            title: "CodexBar CLI",
                            detail: "必须使用 App 内置真实路径；保存时会自动解析 Homebrew 符号链接",
                            text: $settings.codexBarCLIPath,
                            placeholder: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"
                        )
                        pathField(
                            title: "ccusage CLI",
                            detail: "仅扫描 Claude/Codex session 的最近活动，不参与 Token、费用或限额",
                            text: $settings.ccusageCLIPath,
                            placeholder: "~/.hermes/node/bin/ccusage"
                        )
                        NumericField(title: "会话状态刷新", unit: "秒（最少 60）", placeholder: "60", value: $settings.codingSessionRefreshInterval)
                        NumericField(title: "Token / 费用刷新", unit: "秒（最少 60）", placeholder: "600", value: $settings.codexBarCostRefreshInterval)
                        NumericField(title: "限额刷新", unit: "秒（最少 60）", placeholder: "600", value: $settings.agentLimitsRefreshInterval)
                    }
                    .padding(.top, 5)
                }
            }

            if let message {
                feedbackMessage(message)
            }
        }
    }

    private var chargerSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingSection("充电头遥测", detail: "启用后连接 Anker Prime，并接收端口级实时数据。", icon: "bolt.horizontal") {
                Toggle("启用充电头模块", isOn: $settings.chargerModuleEnabled)
                    .toggleStyle(.switch)

                if settings.chargerModuleEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        fieldTitle("Anker 用户 ID", detail: "40 个 ASCII 字符")
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
                                Image(systemName: revealUserID ? "eye.slash" : "eye")
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.bordered)
                            .help(revealUserID ? "隐藏用户 ID" : "显示用户 ID")
                        }
                        Text("该 ID 同时决定屏保个性化状态；使用其他账户的值会导致锁屏图片消失。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)

                    Divider().padding(.vertical, 3)

                    fieldTitle("配对的充电头", detail: settings.normalizedPeripheralID == nil ? "未配对" : "已配对")
                    if settings.normalizedPeripheralID == nil {
                        pairingPicker(bluetooth)
                    } else {
                        pairedRow(bluetooth)
                    }
                }
            }

            settingSection(
                "充电宝遥测",
                detail: "启用后连接 Anker Prime 充电宝，接收电量、温度、每口功率与热控状态。和充电头共用上面那个 Anker 用户 ID。",
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
                    Text("充电宝空闲时会自己休眠并停止广播；手机 App 连着它的时候本机也连不上。扫不到就先按一下机身按钮。")
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
            settingSection("本地 HTTP API", detail: "监听所有本机网络接口，供调试与局域网客户端读取。", icon: "network") {
                Toggle("启用本地 HTTP API", isOn: $settings.httpServerEnabled)
                    .toggleStyle(.switch)

                if settings.httpServerEnabled {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("监听端口")
                                .font(.callout.weight(.medium))
                            Text("端点会在保存后重新监听。")
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
                        Text("/status  ·  /activity  ·  /telemetry  ·  /health")
                        Text("/apple-music/authorization  ·  /ports  ·  /metrics")
                        Text("/disconnect  ·  /reconnect")
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
                    Text(!settings.httpServerEnabled ? "HTTP 服务已关闭" : service.httpServer.listeningURL == nil ? "HTTP 服务未启动" : "HTTP 服务正在监听")
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

    private func pathField(title: String, detail: String, text: Binding<String>, placeholder: String) -> some View {
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

            ForEach(link.discovered) { charger in
                Button {
                    link.slot.storePeripheralID(charger.id.uuidString, in: settings)
                    link.stopPairingScan()
                    save()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(charger.name).font(.callout.weight(.medium))
                            Text(charger.id.uuidString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(charger.rssi) dBm")
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
                    ? "正在找附近的 A2687，让充电头保持通电。"
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
                Text(link.slot == .charger ? settings.peripheralID : settings.powerBankPeripheralID)
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
            Button("保存并重连", systemImage: "checkmark") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private func save() {
        do {
            try service.applySettings()
            message = "设置已保存，正在建立新会话。"
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
