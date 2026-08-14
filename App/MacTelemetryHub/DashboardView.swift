import AppKit
import SwiftUI

private enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case charger

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "总览"
        case .charger: "充电设备"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "查看所有已启用的数据源"
        case .charger: "端口、电流与设备状态"
        }
    }

    var icon: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .charger: "bolt.horizontal"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var service: ServiceController
    @ObservedObject private var bluetooth: BluetoothService
    @ObservedObject private var httpServer: LocalHTTPServer
    @ObservedObject private var appleMusic: AppleMusicMonitor
    @ObservedObject private var codexBarCost: CodexBarCostMonitor
    // 三张卡各看一个采集器，三个都得单独订阅：ServiceController 是 ObservableObject，
    // 但它内部这几个 monitor 的 @Published 不会冒泡上来。从前会话状态那行的错误
    // 就是这么挂在 service 下面读的，只有别的东西触发重绘时才会跟着变。
    @ObservedObject private var agentLimits: AgentLimitsMonitor
    @ObservedObject private var codingSessions: CodingSessionMonitor
    @State private var selection: DashboardSection = .overview

    init(service: ServiceController) {
        self.service = service
        bluetooth = service.bluetooth
        httpServer = service.httpServer
        appleMusic = service.appleMusic
        codexBarCost = service.codexBarCost
        agentLimits = service.agentLimits
        codingSessions = service.codingSessions
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            NavigationSplitView {
                sidebar(now: context.date)
            } detail: {
                detail(now: context.date)
            }
            .navigationSplitViewStyle(.balanced)
        }
        .frame(minWidth: 880, minHeight: 620)
    }

    private func sidebar(now: Date) -> some View {
        List(selection: $selection) {
            Section("监测") {
                ForEach(DashboardSection.allCases) { section in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                            Text(section.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: section.icon)
                            .frame(width: 18)
                    }
                    .tag(section)
                }
            }

            Section("连接") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(serviceStatusColor(now: now))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusText(now: now))
                            .font(.callout.weight(.medium))
                        Text(service.settings.chargerModuleEnabled ? "充电设备" : "充电模块已关闭")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)

                HStack(spacing: 8) {
                    Circle()
                        .fill(!service.settings.httpServerEnabled ? Color.secondary : httpServer.listeningURL == nil ? .orange : .green)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(!service.settings.httpServerEnabled ? "本地 API 已关闭" : httpServer.listeningURL == nil ? "本地 API 未监听" : "本地 API 在线")
                            .font(.callout.weight(.medium))
                        Text(httpServer.listeningURL?.absoluteString ?? (service.settings.httpServerEnabled ? "在设置中检查端口" : "远端上报继续运行"))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("遥测中心")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: service.settings.postEnabled ? "paperplane.fill" : "paperplane")
                        .foregroundStyle(service.settings.postEnabled ? .blue : .secondary)
                    Text(service.settings.postEnabled ? "远端上报已启用" : "远端上报未启用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .background(.bar)
        }
    }

    private func detail(now: Date) -> some View {
        VStack(spacing: 0) {
            detailHeader(now: now)
            Divider()

            ScrollView {
                Group {
                    switch selection {
                    case .overview:
                        overviewContent
                    case .charger:
                        chargerContent(now: now)
                    }
                }
                .frame(maxWidth: 980, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(22)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func detailHeader(now: Date) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selection.title)
                    .font(.title2.weight(.semibold))
                Text(selection == .overview ? "Mac Telemetry Hub · \(now.formatted(date: .abbreviated, time: .shortened))" : selection.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            StatusBadge(
                text: service.reporterLastError == nil ? "遥测运行中" : "上报异常",
                style: service.reporterLastError == nil ? .success : .warning
            )

            SettingsLink {
                Image(systemName: "gearshape")
                    .frame(width: 16, height: 16)
            }
            .help("打开设置")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let error = bluetooth.lastError, !bluetooth.isConnected {
                errorBanner(error)
            }

            sectionHeading("数据源", detail: "每个模块独立运行，状态变化会在这里反映")
            moduleGrid

            if service.settings.chargerModuleEnabled {
                sectionHeading("充电摘要", detail: "当前连接设备的实时输出")
                overviewCard(now: Date())
            }

            footer(now: Date())
        }
    }

    private func chargerContent(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if service.settings.chargerModuleEnabled {
                if let error = bluetooth.lastError, !bluetooth.isConnected {
                    errorBanner(error)
                }

                HStack(spacing: 8) {
                    Button("断开充电头", systemImage: "bolt.slash") {
                        bluetooth.disconnect()
                    }
                    .disabled(!bluetooth.isConnected)
                    .help("断开当前充电设备")

                    Button("重连充电头", systemImage: "arrow.clockwise") {
                        bluetooth.reconnect()
                    }
                    .disabled(bluetooth.phase == .handshaking)
                    .help("重新连接当前充电设备")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                overviewCard(now: now)

                sectionHeading("端口", detail: "实时电压、电流、功率与识别到的设备")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(["C1", "C2", "C3"], id: \.self) { key in
                        PortCard(key: key, port: bluetooth.state.ports[key] ?? PortState())
                            .frame(minHeight: 248)
                    }
                }
            } else {
                EmptyModuleView(
                    title: "充电模块未启用",
                    detail: "在设置的“充电设备”中启用模块并完成一次配对。",
                    icon: "bolt.horizontal"
                )
            }
        }
    }

    private var moduleGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ModuleStatusCard(
                title: "前台应用",
                icon: "macwindow",
                enabled: service.settings.desktopModuleEnabled,
                value: service.desktopActivity.snapshot?.applicationName ?? "等待活动",
                detail: service.desktopActivity.snapshot?.bundleIdentifier,
                action: { _ = service.requestImmediateReport(.desktop) },
                actionEnabled: service.canRequestImmediateReport(.desktop),
                isReporting: service.isManualReportInFlight(.desktop),
                feedback: service.manualReportMessage(for: .desktop),
                feedbackIsError: service.manualReportFailed(.desktop)
            )
            ModuleStatusCard(
                title: "Apple Music",
                icon: "music.note",
                enabled: service.settings.appleMusicModuleEnabled,
                value: appleMusicStateText,
                detail: appleMusicDetailText,
                action: { _ = service.requestImmediateReport(.appleMusic) },
                actionEnabled: service.canRequestImmediateReport(.appleMusic),
                isReporting: service.isManualReportInFlight(.appleMusic),
                feedback: service.manualReportMessage(for: .appleMusic),
                feedbackIsError: service.manualReportFailed(.appleMusic)
            )
            ModuleStatusCard(
                title: "Mac 时区",
                icon: "clock",
                enabled: service.settings.timezoneModuleEnabled,
                value: service.timeZone.snapshot?.identifier ?? "等待时区",
                detail: service.timeZone.snapshot.map { formatUTCOffset($0.secondsFromGMT) },
                action: { _ = service.requestImmediateReport(.timezone) },
                actionEnabled: service.canRequestImmediateReport(.timezone),
                isReporting: service.isManualReportInFlight(.timezone),
                feedback: service.manualReportMessage(for: .timezone),
                feedbackIsError: service.manualReportFailed(.timezone)
            )
            // Vibe coding 一行拆三行，一个采集器一行：三条命令的失败原因互不相干，
            // 合成一行时限额取不到这件事在本机根本看不见（从前那条链里就没有它）。
            ModuleStatusCard(
                title: "会话状态",
                icon: "terminal",
                enabled: service.settings.codexBarModuleEnabled,
                value: codingSessions.lastSuccess == nil ? "等待扫描" : "扫描完成",
                detail: codingSessions.lastError
                    ?? codingSessions.lastSuccess?.formatted(date: .omitted, time: .standard),
                action: { Task { await service.refreshVibeCodingSessionsNow() } },
                actionIcon: "arrow.clockwise",
                actionHelp: "重新扫描 ccusage 会话状态并上报",
                actionEnabled: service.settings.codexBarModuleEnabled,
                isReporting: service.isRefreshingVibeCodingSessions
                    || service.isManualReportInFlight(.vibeCoding),
                feedback: service.isRefreshingVibeCodingSessions
                    ? "正在扫描会话状态…"
                    : service.manualReportMessage(for: .vibeCoding),
                feedbackIsError: service.manualReportFailed(.vibeCoding)
            )
            ModuleStatusCard(
                title: "Token / 费用",
                icon: "chart.bar",
                enabled: service.settings.codexBarModuleEnabled,
                value: codexBarCost.lastSuccess == nil ? "等待统计" : "聚合完成",
                detail: codexBarCost.lastError
                    ?? codexBarCost.lastSuccess?.formatted(date: .omitted, time: .standard),
                action: { Task { await service.refreshVibeCodingUsageNow() } },
                actionIcon: "arrow.clockwise",
                actionHelp: "重新统计 CodexBar 用量与费用并上报",
                actionEnabled: service.settings.codexBarModuleEnabled,
                isReporting: service.isRefreshingVibeCodingUsage
                    || service.isManualReportInFlight(.vibeCoding),
                feedback: service.isRefreshingVibeCodingUsage
                    ? "正在重新统计用量…"
                    : service.manualReportMessage(for: .vibeCoding),
                feedbackIsError: service.manualReportFailed(.vibeCoding)
            )
            ModuleStatusCard(
                title: "限额",
                icon: "gauge.with.dots.needle.33percent",
                enabled: service.settings.codexBarModuleEnabled,
                value: agentLimits.lastSuccess == nil ? "等待限额" : "限额已取",
                detail: agentLimits.lastError
                    ?? agentLimits.lastSuccess?.formatted(date: .omitted, time: .standard),
                action: { Task { await service.refreshVibeCodingLimitsNow() } },
                actionIcon: "arrow.clockwise",
                actionHelp: "重新读取 CodexBar 限额并上报",
                actionEnabled: service.settings.codexBarModuleEnabled,
                isReporting: service.isRefreshingVibeCodingLimits
                    || service.isManualReportInFlight(.vibeCoding),
                feedback: service.isRefreshingVibeCodingLimits
                    ? "正在读取限额…"
                    : service.manualReportMessage(for: .vibeCoding),
                feedbackIsError: service.manualReportFailed(.vibeCoding)
            )
            ModuleStatusCard(
                title: "充电设备",
                icon: "bolt.fill",
                enabled: service.settings.chargerModuleEnabled,
                value: service.settings.chargerModuleEnabled ? bluetooth.phase.label : "已关闭",
                detail: bluetooth.state.totalOutputPowerW.map { String(format: "%.2f W", $0) },
                action: { _ = service.requestImmediateReport(.charger) },
                actionEnabled: service.canRequestImmediateReport(.charger),
                isReporting: service.isManualReportInFlight(.charger),
                feedback: service.manualReportMessage(for: .charger),
                feedbackIsError: service.manualReportFailed(.charger)
            )
        }
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appleMusicStateText: String {
        switch appleMusic.snapshot?.state {
        case "playing": "正在播放"
        case "paused": "已暂停"
        default: "当前未播放"
        }
    }

    private var appleMusicDetailText: String? {
        guard let snapshot = appleMusic.snapshot else { return appleMusic.lastError }
        let track = [snapshot.title, snapshot.artist]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return track.isEmpty ? (appleMusic.lastError ?? "Music.app 已停止") : track
    }

    private func overviewCard(now: Date) -> some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Label("实时总输出", systemImage: "bolt.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(number(bluetooth.state.totalOutputPowerW, digits: 2))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("W")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 10) {
                    ProgressView(value: min(max((bluetooth.state.totalOutputPowerW ?? 0) / 250, 0), 1))
                        .tint(.blue)
                    Text("250 W MAX")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().frame(height: 100)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], alignment: .leading, spacing: 14) {
                DeviceFact(title: "序列号", value: bluetooth.state.device.serialNumber, icon: "number")
                DeviceFact(title: "MAC 地址", value: bluetooth.state.device.macAddress, icon: "antenna.radiowaves.left.and.right")
                DeviceFact(title: "固件版本", value: bluetooth.state.device.firmwareVersion, icon: "cpu")
                DeviceFact(title: "数据更新", value: ageText(now: now), icon: "clock.arrow.circlepath")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func footer(now: Date) -> some View {
        HStack(spacing: 10) {
            if let url = httpServer.listeningURL {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("API 在线").font(.caption.weight(.semibold))
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("打开") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
                    .font(.caption)
            } else if !service.settings.httpServerEnabled {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                Text("本地 HTTP API 已关闭")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(httpServer.lastError ?? "HTTP 服务未启动")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if service.settings.postEnabled {
                if let error = service.reporterLastError {
                    Label("POST 失败：\(error)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if let date = service.reporterLastSuccess {
                    Label("已于 \(date.formatted(date: .omitted, time: .standard)) POST", systemImage: "paperplane.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Label("等待首份数据后 POST", systemImage: "paperplane")
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("定时 POST 未启用", systemImage: "paperplane")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.vertical, 8)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).lineLimit(2)
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.09))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.18), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusText(now: Date) -> String {
        if bluetooth.isConnected, isStale(now: now) { return "数据过期" }
        return bluetooth.phase.label
    }

    private func serviceStatusColor(now: Date) -> Color {
        if bluetooth.isConnected { return isStale(now: now) ? .orange : .green }
        switch bluetooth.phase {
        case .connecting, .handshaking: return .blue
        case .awaitingPairing: return .orange
        case .bluetoothUnavailable: return .red
        default: return .secondary
        }
    }

    private func isStale(now: Date) -> Bool {
        guard let updatedAt = bluetooth.state.updatedAt else { return bluetooth.isConnected }
        return now.timeIntervalSince1970 - updatedAt > 15
    }

    private func ageText(now: Date) -> String? {
        bluetooth.state.updatedAt.map { String(format: "%.1f 秒前", max(0, now.timeIntervalSince1970 - $0)) }
    }
}

private struct EmptyModuleView: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private func formatUTCOffset(_ seconds: Int) -> String {
    let sign = seconds < 0 ? "−" : "+"
    let absolute = abs(seconds)
    return String(format: "UTC%@%02d:%02d", sign, absolute / 3_600, (absolute % 3_600) / 60)
}

private struct ModuleStatusCard: View {
    let title: String
    let icon: String
    let enabled: Bool
    let value: String
    let detail: String?
    let action: (() -> Void)?
    var actionIcon = "paperplane"
    var actionHelp: String?
    let actionEnabled: Bool
    let isReporting: Bool
    let feedback: String?
    let feedbackIsError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(enabled ? .primary : .secondary)
                Spacer()
                if let action {
                    Button {
                        action()
                    } label: {
                        Group {
                            if isReporting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: actionIcon)
                            }
                        }
                        .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!actionEnabled || isReporting)
                    .help(actionHelp ?? "立即上报\(title)")
                }
                Circle()
                    .fill(enabled ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
            Text(enabled ? value : "已关闭")
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(enabled ? (detail ?? "运行中") : "可在设置中开启")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let feedback {
                Text(feedback)
                    .font(.caption2)
                    .foregroundStyle(feedbackIsError ? .red : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct PortCard: View {
    let key: String
    let port: PortState

    private var active: Bool { port.mode == "Output" }
    private var displayModel: String? { port.deviceModel ?? port.vendor }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "cable.connector.horizontal")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(active ? .blue : .secondary)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("USB-C \(key.dropFirst())")
                        .font(.headline)
                    Text(key)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                StatusBadge(text: active ? "输出" : "关闭", style: active ? .success : .neutral)
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(number(port.powerW, digits: 2))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text("W")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 0) {
                CompactMetric(title: "电压", value: number(port.voltageV, digits: 2), unit: "V", icon: "waveform.path", tint: .blue)
                Divider().frame(height: 30)
                CompactMetric(title: "电流", value: number(port.currentA, digits: 2), unit: "A", icon: "gauge.with.dots.needle.33percent", tint: .purple)
            }
            .padding(.vertical, 8)
            .background(.primary.opacity(0.035))

            VStack(alignment: .leading, spacing: 3) {
                Label(port.cable ?? "未检测到线缆", systemImage: "cable.connector")
                Text(port.chargingInfo ?? "未识别充电协议")
                    .foregroundStyle(.secondary)
                Text(displayModel ?? "未识别设备")
                    .fontWeight(.medium)
                    .foregroundStyle(displayModel == nil ? .tertiary : .primary)
            }
            .font(.caption)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CompactMetric: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
                .fixedSize(horizontal: true, vertical: false)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }
}

private struct DeviceFact: View {
    let title: String
    let value: String?
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(value ?? "—")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

extension View {
    func dashboardPanel(cornerRadius: CGFloat = 8) -> some View {
        background(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: min(cornerRadius, 8), style: .continuous)
                    .stroke(.primary.opacity(0.075), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: min(cornerRadius, 8), style: .continuous))
    }
}

private func number(_ value: Double?, digits: Int) -> String {
    guard let value else { return "—" }
    return String(format: "%.*f", digits, value)
}
