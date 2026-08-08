import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var service: ServiceController
    @ObservedObject private var bluetooth: BluetoothService
    @ObservedObject private var httpServer: LocalHTTPServer
    @ObservedObject private var appleMusic: AppleMusicMonitor
    @ObservedObject private var ccusage: CcusageMonitor
    @ObservedObject private var agentLimits: AgentLimitsMonitor
    @State private var showingSettings = false

    init(service: ServiceController) {
        self.service = service
        bluetooth = service.bluetooth
        httpServer = service.httpServer
        appleMusic = service.appleMusic
        ccusage = service.ccusage
        agentLimits = service.agentLimits
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color.blue.opacity(0.045),
                        Color(nsColor: .windowBackgroundColor),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            header(now: context.date)
                            if let error = bluetooth.lastError, !bluetooth.isConnected {
                                errorBanner(error)
                            }
                            moduleStrip
                            if service.settings.ccusageModuleEnabled {
                                VibeCodingUsageView(
                                    payload: ccusage.payload,
                                    updatedAt: ccusage.lastSuccess,
                                    error: ccusage.lastError,
                                    plans: agentLimits.plans
                                )
                            }
                            if service.settings.chargerModuleEnabled {
                                overviewCard(now: context.date)
                                HStack(alignment: .top, spacing: 12) {
                                    ForEach(["C1", "C2", "C3"], id: \.self) { key in
                                        PortCard(key: key, port: bluetooth.state.ports[key] ?? PortState())
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                                .frame(height: 244)
                            }
                            Spacer(minLength: 12)
                            footer(now: context.date)
                        }
                        .frame(minHeight: max(0, proxy.size.height - 40), alignment: .top)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 20)
                    }
                }
            }
        }
        .frame(minWidth: 880, minHeight: 620)
        .sheet(isPresented: $showingSettings) {
            SettingsView(service: service)
        }
    }

    @ViewBuilder
    private func header(now: Date) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "wave.3.right")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
            .shadow(color: .blue.opacity(0.22), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Mac Telemetry Hub")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text("本机活动、媒体、Vibe Coding 与充电头遥测")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 18)
            StatusBadge(
                text: service.reporterLastError == nil ? "遥测运行中" : "上报异常",
                style: service.reporterLastError == nil ? .success : .warning
            )

            HStack(spacing: 8) {
                if service.settings.chargerModuleEnabled {
                    Button("断开", systemImage: "bolt.slash") { bluetooth.disconnect() }
                        .disabled(!bluetooth.isConnected)
                    Button("重连", systemImage: "arrow.clockwise") { bluetooth.reconnect() }
                        .disabled(bluetooth.phase == .handshaking)
                }
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 16, height: 16)
                }
                .help("设置")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var moduleStrip: some View {
        HStack(spacing: 12) {
            ModuleStatusCard(
                title: "前台应用",
                icon: "macwindow",
                enabled: service.settings.desktopModuleEnabled,
                value: service.desktopActivity.snapshot?.applicationName ?? "等待活动",
                detail: service.desktopActivity.snapshot?.bundleIdentifier
            )
            ModuleStatusCard(
                title: "Apple Music",
                icon: "music.note",
                enabled: service.settings.appleMusicModuleEnabled,
                value: appleMusicStateText,
                detail: appleMusicDetailText
            )
            ModuleStatusCard(
                title: "ccusage",
                icon: "terminal",
                enabled: service.settings.ccusageModuleEnabled,
                value: service.ccusage.lastSuccess == nil ? "等待统计" : "聚合完成",
                detail: service.ccusage.lastError
                    ?? service.ccusage.lastSuccess?.formatted(date: .omitted, time: .standard)
            )
            ModuleStatusCard(
                title: "充电头",
                icon: "bolt.fill",
                enabled: service.settings.chargerModuleEnabled,
                value: service.settings.chargerModuleEnabled ? bluetooth.phase.label : "已关闭",
                detail: bluetooth.state.totalOutputPowerW.map { String(format: "%.2f W", $0) }
            )
        }
    }

    private var appleMusicStateText: String {
        switch appleMusic.snapshot?.state {
        case "playing":
            return "正在播放"
        case "paused":
            return "已暂停"
        default:
            return "当前未播放"
        }
    }

    private var appleMusicDetailText: String? {
        guard let snapshot = appleMusic.snapshot else {
            return appleMusic.lastError
        }

        let track = [snapshot.title, snapshot.artist]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        if !track.isEmpty {
            return track
        }
        return appleMusic.lastError ?? "Music.app 已停止"
    }

    private func overviewCard(now: Date) -> some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Label("实时总输出", systemImage: "bolt.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(number(bluetooth.state.totalOutputPowerW, digits: 2))
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
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

            Divider()
                .frame(height: 104)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 22), GridItem(.flexible(), spacing: 22)],
                alignment: .leading,
                spacing: 16
            ) {
                DeviceFact(title: "序列号", value: bluetooth.state.device.serialNumber, icon: "number")
                DeviceFact(title: "MAC 地址", value: bluetooth.state.device.macAddress, icon: "antenna.radiowaves.left.and.right")
                DeviceFact(title: "固件版本", value: bluetooth.state.device.firmwareVersion, icon: "cpu")
                DeviceFact(title: "数据更新", value: ageText(now: now), icon: "clock.arrow.circlepath")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .dashboardPanel(cornerRadius: 20)
    }

    private func footer(now: Date) -> some View {
        HStack(spacing: 10) {
            if let url = httpServer.listeningURL {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("API 在线")
                    .font(.caption.weight(.semibold))
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Button("打开") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
                    .font(.caption)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(httpServer.lastError ?? "HTTP 服务未启动")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

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
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Capsule().fill(.primary.opacity(0.045)))
        .overlay(Capsule().stroke(.primary.opacity(0.06), lineWidth: 1))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.orange.opacity(0.11)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.orange.opacity(0.18)))
    }

    private func statusText(now: Date) -> String {
        if bluetooth.isConnected, isStale(now: now) { return "数据过期" }
        return bluetooth.phase.label
    }

    private func statusStyle(now: Date) -> StatusBadgeStyle {
        if bluetooth.isConnected { return isStale(now: now) ? .warning : .success }
        switch bluetooth.phase {
        case .connecting, .handshaking: return .info
        case .awaitingPairing: return .warning
        case .bluetoothUnavailable: return .error
        default: return .neutral
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

private struct ModuleStatusCard: View {
    let title: String
    let icon: String
    let enabled: Bool
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(enabled ? .primary : .secondary)
                Spacer()
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
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardPanel(cornerRadius: 14)
    }
}

private struct PortCard: View {
    let key: String
    let port: PortState

    private var active: Bool { port.mode == "Output" }
    private var displayModel: String? { port.deviceModel ?? port.vendor }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(active ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.09))
                    Image(systemName: "cable.connector.horizontal")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(active ? .blue : .secondary)
                }
                .frame(width: 34, height: 34)

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
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text("W")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack(spacing: 0) {
                CompactMetric(title: "电压", value: number(port.voltageV, digits: 2), unit: "V", icon: "waveform.path", tint: .blue)
                Divider().frame(height: 34)
                CompactMetric(title: "电流", value: number(port.currentA, digits: 2), unit: "A", icon: "gauge.with.dots.needle.33percent", tint: .purple)
            }
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 11).fill(.primary.opacity(0.035)))

            VStack(alignment: .leading, spacing: 3) {
                Label(port.cable == "N/A" ? "未检测到线缆" : port.cable, systemImage: "cable.connector")
                    .foregroundStyle(.primary)
                Text(port.chargingInfo == "N/A" ? "未识别充电协议" : port.chargingInfo)
                    .foregroundStyle(.secondary)
                Text(displayModel ?? "未识别设备")
                    .fontWeight(.medium)
                    .foregroundStyle(displayModel == nil ? .tertiary : .primary)
            }
            .font(.caption)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardPanel(cornerRadius: 18)
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
        .padding(.horizontal, 10)
    }
}

private struct DeviceFact: View {
    let title: String
    let value: String?
    let icon: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 18)
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
    func dashboardPanel(cornerRadius: CGFloat) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.primary.opacity(0.075), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.055), radius: 10, y: 4)
    }
}

private func number(_ value: Double?, digits: Int) -> String {
    guard let value else { return "—" }
    return String(format: "%.*f", digits, value)
}
