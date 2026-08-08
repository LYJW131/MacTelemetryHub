import SwiftUI

struct SettingsView: View {
    @ObservedObject var service: ServiceController
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var bluetooth: BluetoothService
    @Environment(\.dismiss) private var dismiss
    @State private var revealUserID = false
    @State private var message: String?
    @State private var isError = false

    init(service: ServiceController) {
        self.service = service
        settings = service.settings
        bluetooth = service.bluetooth
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    connectionSection

                    HStack(alignment: .top, spacing: 12) {
                        apiSection
                        backgroundSection
                    }

                    modulesSection
                    postSection

                    if let message {
                        Label(message, systemImage: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(isError ? .red : .green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill((isError ? Color.red : Color.green).opacity(0.09))
                            )
                    }
                }
                .padding(16)
            }
            .background(
                LinearGradient(
                    colors: [Color(nsColor: .windowBackgroundColor), Color.blue.opacity(0.035)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            Divider()
            footer
        }
        .frame(width: 640, height: 680)
        // 关掉面板就别让电台白扫完剩下的窗口
        .onDisappear { bluetooth.stopPairingScan() }
    }

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("遥测中心设置")
                    .font(.title2.bold())
                Text("模块、API 与统一上报")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(text: service.bluetooth.phase.label, style: service.bluetooth.isConnected ? .success : .neutral)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var connectionSection: some View {
        SettingsCard(title: "充电头模块", subtitle: "启用后连接 Anker Prime 并采集端口遥测", icon: "bolt.fill", tint: .blue) {
            Toggle("启用充电头遥测", isOn: $settings.chargerModuleEnabled)
                .toggleStyle(.switch)

            if settings.chargerModuleEnabled {
            VStack(alignment: .leading, spacing: 8) {
                FieldTitle(title: "Anker 用户 ID", detail: "40 位")
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

                    Button { revealUserID.toggle() } label: {
                        Image(systemName: revealUserID ? "eye.slash" : "eye")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .help(revealUserID ? "隐藏用户 ID" : "显示用户 ID")
                }
                Text("这个 uid 同时决定屏保个性化状态；使用其他账户的值会导致锁屏图片消失。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                FieldTitle(title: "配对的充电头", detail: settings.normalizedPeripheralID == nil ? "未配对" : "已配对")
                if settings.normalizedPeripheralID == nil {
                    pairingPicker
                } else {
                    pairedRow
                }
            }
            }
        }
    }

    /// 没配对过：按一下扫 15 秒，挑一台就把 UUID 存下来，之后再也不扫。
    private var pairingPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    bluetooth.startPairingScan()
                } label: {
                    Label(bluetooth.isPairingScan ? "正在扫描…" : "扫描充电头", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.bordered)
                .disabled(bluetooth.isPairingScan)

                if bluetooth.isPairingScan {
                    ProgressView().controlSize(.small)
                    Button("停止") { bluetooth.stopPairingScan() }
                        .buttonStyle(.borderless)
                }
            }

            ForEach(bluetooth.discovered) { charger in
                Button {
                    settings.peripheralID = charger.id.uuidString
                    bluetooth.stopPairingScan()
                    save()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
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
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.045)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if bluetooth.discovered.isEmpty {
                Text(bluetooth.isPairingScan
                     ? "正在找附近的 A2687，让充电头保持通电。"
                     : "还没配对充电头。扫描一次选中之后就会记住，以后只连这一台，不再扫描。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 已配对：只显示存下的 UUID，和一个「重新配对」的出口。
    private var pairedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(settings.peripheralID)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("重新配对") {
                    settings.peripheralID = ""
                    save()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text("只会尝试连这一台，连接请求一直挂着，充电头上电就自动接上，全程不扫描。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var apiSection: some View {
        SettingsCard(title: "本地 API", subtitle: "监听所有本机网络接口", icon: "network", tint: .purple) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("监听端口")
                        .font(.callout.weight(.medium))
                    Text("本机调试端点共用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("8787", value: $settings.httpPort, format: .number.grouping(.never))
                    .font(.body.monospacedDigit())
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 92)
            }
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("/status  ·  /activity  ·  /telemetry")
                    Text("/disconnect  ·  /reconnect")
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var modulesSection: some View {
        SettingsCard(title: "采集模块", subtitle: "每个模块独立开关，失败不会影响其他模块", icon: "square.grid.2x2.fill", tint: .indigo) {
            Toggle("前台应用", isOn: $settings.desktopModuleEnabled)
                .toggleStyle(.switch)
            if settings.desktopModuleEnabled {
                Text("只上报应用名、Bundle ID 和图标，不读取窗口标题或任何窗口内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("本机 Apple Music", isOn: $settings.appleMusicModuleEnabled)
                .toggleStyle(.switch)
            Text("直接读取 Music.app 的播放状态、歌曲和进度，与网站现有 Apple Music API 独立。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("ccusage", isOn: $settings.ccusageModuleEnabled)
                .toggleStyle(.switch)
            if settings.ccusageModuleEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    FieldTitle(title: "Node 可执行文件", detail: "本机路径")
                    TextField("/opt/homebrew/bin/node", text: $settings.nodePath)
                        .font(.caption.monospaced())
                        .textFieldStyle(.roundedBorder)
                    FieldTitle(title: "ccusage CLI", detail: "node_modules/ccusage/src/cli.js")
                    TextField("/path/to/node_modules/ccusage/src/cli.js", text: $settings.ccusageCLIPath)
                        .font(.caption.monospaced())
                        .textFieldStyle(.roundedBorder)
                    NumericField(title: "统计刷新", unit: "秒", placeholder: "60", value: $settings.ccusageRefreshInterval)
                    FieldTitle(title: "Codex 可执行文件", detail: "留空则不采集 Codex 限额")
                    TextField("/opt/homebrew/bin/codex", text: $settings.codexCLIPath)
                        .font(.caption.monospaced())
                        .textFieldStyle(.roundedBorder)
                    NumericField(title: "限额刷新", unit: "秒", placeholder: "300", value: $settings.agentLimitsRefreshInterval)
                    Text("限额刷新最小 60 秒。Claude 套餐等级直接读本地配置，不受这里的路径影响。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("只上传聚合统计；sessionId、项目路径、提示词和回复不会离开电脑。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var backgroundSection: some View {
        SettingsCard(title: "后台运行", subtitle: "关闭窗口后菜单栏仍保持服务", icon: "menubar.rectangle", tint: .orange) {
            Toggle("登录后自动启动", isOn: $settings.launchAtLoginEnabled)
                .toggleStyle(.switch)
                .onChange(of: settings.launchAtLoginEnabled) { _, enabled in
                    updateLaunchAtLogin(enabled)
                }
            Text("签名完成并放入“应用程序”文件夹后启用。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var postSection: some View {
        SettingsCard(title: "统一上报", subtitle: "所有已启用模块写入同一个版本化入口", icon: "paperplane.fill", tint: .green) {
            Toggle("启用远端上报", isOn: $settings.postEnabled)
                .toggleStyle(.switch)

            if settings.postEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    FieldTitle(title: "上报端点", detail: "HTTP / HTTPS")
                    TextField("https://example.com/api/ingest/telemetry", text: $settings.postURL)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    FieldTitle(title: "Bearer 密钥", detail: "保存在钥匙串")
                    SecureField("与网站 TELEMETRY_INGEST_SECRET 一致", text: $settings.telemetrySecret)
                        .font(.body.monospaced())
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 14) {
                    NumericField(title: "发送间隔", unit: "秒", placeholder: "60", value: $settings.postInterval)
                    NumericField(title: "请求超时", unit: "秒", placeholder: "10", value: $settings.postTimeout)
                }

                Label("模块按字段部分更新；上报失败不会中断本地采集。", systemImage: "shield.checkered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("开启后可配置上报地址、发送间隔和请求超时。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("保存后会重载模块，并在需要时请求系统权限")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存并重连") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
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

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.11))
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            content()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.primary.opacity(0.075), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.045), radius: 8, y: 3)
    }
}

private struct FieldTitle: View {
    let title: String
    let detail: String

    var body: some View {
        HStack {
            Text(title).font(.callout.weight(.medium))
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.tertiary)
        }
    }
}

private struct NumericField: View {
    let title: String
    let unit: String
    let placeholder: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout.weight(.medium))
            HStack(spacing: 6) {
                TextField(placeholder, value: $value, format: .number)
                    .font(.body.monospacedDigit())
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
