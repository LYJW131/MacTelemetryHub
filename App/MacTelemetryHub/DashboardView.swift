import AppKit
import SwiftUI

private enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case charger
    case powerBank

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "总览"
        case .charger: "充电头"
        case .powerBank: "充电宝"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "查看所有已启用的数据源"
        case .charger: "端口、电流与设备状态"
        case .powerBank: "电量、温度与每口收放电"
        }
    }

    var icon: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .charger: "bolt.horizontal"
        case .powerBank: "minus.plus.batteryblock"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var service: ServiceController
    @ObservedObject private var bluetooth: BluetoothService
    @ObservedObject private var powerBankLink: BluetoothService
    @ObservedObject private var httpServer: LocalHTTPServer
    @ObservedObject private var desktopActivity: DesktopActivityMonitor
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
        bluetooth = service.chargerLink
        powerBankLink = service.powerBankLink
        httpServer = service.httpServer
        desktopActivity = service.desktopActivity
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
                        Text(service.settings.chargerModuleEnabled ? "充电头" : "充电头模块已关闭")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)

                HStack(spacing: 8) {
                    Circle()
                        .fill(!service.settings.powerBankModuleEnabled ? Color.secondary
                              : powerBankLink.isConnected ? .green : .orange)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.settings.powerBankModuleEnabled
                             ? powerBankLink.phase.label : "充电宝模块已关闭")
                            .font(.callout.weight(.medium))
                        Text("充电宝")
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
                    case .powerBank:
                        powerBankContent(now: now)
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

            if service.settings.postEnabled {
                Label(lastReportText(now: now), systemImage: "paperplane.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

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

    /**
     * 顶栏那句「上次上报多久之前」。
     *
     * 取的是 reporterLastSuccess，所以心跳也算 —— 它就是「最后一次成功发出去」。
     * 用相对时刻而不是钟点：想知道的是「还活着吗」，那是个时长问题。整个视图
     * 本来就挂在 1 秒一转的 TimelineView 上，这行跟着一起走，不用另开计时器。
     */
    private func lastReportText(now: Date) -> String {
        guard let last = service.reporterLastSuccess else { return "尚未上报" }
        let seconds = Int(max(0, now.timeIntervalSince(last)))
        return switch seconds {
        case ..<5: "刚刚上报"
        case ..<60: "上次上报 \(seconds) 秒前"
        case ..<3_600: "上次上报 \(seconds / 60) 分钟前"
        case ..<86_400: "上次上报 \(seconds / 3_600) 小时前"
        default: "上次上报 \(seconds / 86_400) 天前"
        }
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let error = bluetooth.lastError, !bluetooth.isConnected {
                errorBanner(error)
            }

            sectionHeading("数据源", detail: "每个模块独立运行，状态变化会在这里反映")
            moduleGrid

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
                        PortCard(key: key, port: bluetooth.chargerStateForDisplay.ports[key] ?? PortState())
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

    @ViewBuilder
    private func powerBankContent(now: Date) -> some View {
        if service.settings.powerBankModuleEnabled {
            VStack(alignment: .leading, spacing: 18) {
                if let error = powerBankLink.lastError, !powerBankLink.isConnected {
                    errorBanner(error)
                }

                HStack(spacing: 8) {
                    Button("断开充电宝", systemImage: "bolt.slash") { powerBankLink.disconnect() }
                        .disabled(!powerBankLink.isConnected)
                    Button("重连充电宝", systemImage: "arrow.clockwise") { powerBankLink.reconnect() }
                        .disabled(powerBankLink.phase == .handshaking)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let state = powerBankLink.powerBankState, powerBankLink.hasTelemetry {
                    powerBankOverviewCard(state, now: now)
                    sectionHeading("端口", detail: "C1 与 C2 双向，A 口只出，B 为底座输入。空闲端口不显示功率 —— 那个读数是过期的")
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                        spacing: 12
                    ) {
                        ForEach(state.ports, id: \.name) { port in
                            PowerBankPortCard(port: port).frame(minHeight: 248)
                        }
                    }
                } else {
                    EmptyModuleView(
                        title: powerBankLink.phase.label,
                        detail: powerBankWaitingDetail,
                        icon: "minus.plus.batteryblock"
                    )
                }
            }
        } else {
            EmptyModuleView(
                title: "充电宝模块未启用",
                detail: "在设置的“充电设备”中启用充电宝模块并完成一次配对。",
                icon: "minus.plus.batteryblock"
            )
        }
    }

    /// 和充电头的 overviewCard 同一套版式：左边大数字加进度条，右边设备事实网格。
    /// 两个页面看起来该是同一个产品的两个页签，而不是两个人写的。
    private func powerBankOverviewCard(_ state: PowerBankState, now: Date) -> some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("电量", systemImage: "minus.plus.batteryblock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if state.isThermallyLimited {
                        StatusBadge(text: "过热受限", style: .warning)
                    } else if state.charging == true {
                        StatusBadge(text: "充电中", style: .success)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(number(state.batteryPercent, digits: 2))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 10) {
                    ProgressView(value: min(max((state.batteryPercent ?? 0) / 100, 0), 1))
                        .tint(state.isThermallyLimited ? .orange : .blue)
                    Text(powerBankFlowText(state))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().frame(height: 100)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], alignment: .leading, spacing: 14) {
                DeviceFact(title: "序列号", value: state.serialNumber, icon: "number")
                DeviceFact(title: "MAC 地址", value: state.macAddress, icon: "antenna.radiowaves.left.and.right")
                DeviceFact(title: "固件版本", value: state.firmwareVersion, icon: "cpu")
                // 只在连上时读一次，之后整个会话都是同一个值
                DeviceFact(
                    title: "电池健康",
                    value: state.batteryHealthPercent.map { "\($0)%" },
                    icon: "heart.text.square"
                )
                DeviceFact(
                    title: "温度",
                    value: state.temperatures.isEmpty
                        ? nil : state.temperatures.map { "\($0)°C" }.joined(separator: " / "),
                    icon: "thermometer.medium"
                )
                DeviceFact(title: "充满还需", value: powerBankTimeText(state), icon: "clock.arrow.circlepath")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 进度条右侧那行。充电宝没有「额定上限」可写，写当前收放电更有信息量。
    private func powerBankFlowText(_ state: PowerBankState) -> String {
        let input = state.inputPowerW ?? 0
        let output = state.outputPowerW ?? 0
        if input > 0.05 { return String(format: "输入 %.1f W", input) }
        if output > 0.05 { return String(format: "输出 %.1f W", output) }
        return "待机"
    }

    private func powerBankTimeText(_ state: PowerBankState) -> String? {
        guard let hours = state.timeToFullHours, let minutes = state.timeToFullMinutes,
              hours * 60 + minutes > 0 else { return nil }
        return hours > 0 ? "\(hours) 小时 \(minutes) 分" : "\(minutes) 分钟"
    }

    /// 连上了却没有数据，和根本没连上，是两个完全不同的问题。空状态必须能自己
    /// 说清楚卡在哪一步，否则只能靠猜。
    private var powerBankWaitingDetail: String {
        if let error = powerBankLink.lastError { return error }
        if powerBankLink.isConnected {
            return "已连接并完成握手，但还没收到遥测帧。正常情况下 1 秒内就该有第一帧。"
        }
        if powerBankLink.phase == .handshaking {
            return "正在建立加密会话。"
        }
        return "充电宝空闲时会休眠并停止广播，手机 App 连着它时本机也连不上。按一下机身按钮再等片刻。"
    }

    /// 总览卡片正面：有电量就显示电量，没有就显示连接阶段 —— 那才是这时候
    /// 用户真正想知道的（在连？在认证？还是根本没配对）。
    private var powerBankOverviewValue: String {
        guard service.settings.powerBankModuleEnabled else { return "已关闭" }
        guard let state = powerBankLink.powerBankState, let percent = state.batteryPercent else {
            return powerBankLink.phase.label
        }
        return String(format: "%.1f%%", percent)
    }

    private var powerBankOverviewDetail: String? {
        guard service.settings.powerBankModuleEnabled else { return nil }
        guard let state = powerBankLink.powerBankState, powerBankLink.hasTelemetry else {
            return powerBankLink.lastError
        }
        if state.isThermallyLimited { return "过热受限，暂不充电" }
        if let input = state.inputPowerW, input > 0.05 {
            return String(format: "输入 %.1f W", input)
        }
        if let output = state.outputPowerW, output > 0.05 {
            return String(format: "输出 %.1f W", output)
        }
        return "待机"
    }

    private var moduleGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ModuleStatusCard(
                title: "前台应用",
                icon: "macwindow",
                enabled: service.settings.desktopModuleEnabled,
                value: desktopActivity.snapshot?.applicationName ?? "等待活动",
                detail: desktopActivityDetail,
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
                title: "充电头",
                icon: "bolt.fill",
                enabled: service.settings.chargerModuleEnabled,
                value: service.settings.chargerModuleEnabled ? bluetooth.phase.label : "已关闭",
                detail: bluetooth.chargerStateForDisplay.totalOutputPowerW.map { String(format: "%.2f W", $0) },
                action: { _ = service.requestImmediateReport(.charger) },
                actionEnabled: service.canRequestImmediateReport(.charger),
                isReporting: service.isManualReportInFlight(.charger),
                feedback: service.manualReportMessage(for: .charger),
                feedbackIsError: service.manualReportFailed(.charger)
            )
            ModuleStatusCard(
                title: "充电宝",
                icon: "minus.plus.batteryblock.fill",
                enabled: service.settings.powerBankModuleEnabled,
                value: powerBankOverviewValue,
                detail: powerBankOverviewDetail,
                action: { _ = service.requestImmediateReport(.powerBank) },
                actionEnabled: service.canRequestImmediateReport(.powerBank),
                isReporting: service.isManualReportInFlight(.powerBank),
                feedback: service.manualReportMessage(for: .powerBank),
                feedbackIsError: service.manualReportFailed(.powerBank)
            )
        }
    }

    private var desktopActivityDetail: String? {
        var parts: [String] = []
        if let title = desktopActivity.windowTitle, !title.isEmpty { parts.append(title) }
        if let bundleIdentifier = desktopActivity.snapshot?.bundleIdentifier,
           !bundleIdentifier.isEmpty {
            parts.append(bundleIdentifier)
        }
        if service.currentDesktopReportingIsBlocked {
            parts.append("远端已隐藏")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
                    Text(number(bluetooth.chargerStateForDisplay.totalOutputPowerW, digits: 2))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("W")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 10) {
                    ProgressView(value: min(max((bluetooth.chargerStateForDisplay.totalOutputPowerW ?? 0) / 250, 0), 1))
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
                DeviceFact(title: "序列号", value: bluetooth.chargerStateForDisplay.device.serialNumber, icon: "number")
                DeviceFact(title: "MAC 地址", value: bluetooth.chargerStateForDisplay.device.macAddress, icon: "antenna.radiowaves.left.and.right")
                DeviceFact(title: "固件版本", value: bluetooth.chargerStateForDisplay.device.firmwareVersion, icon: "cpu")
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
        guard let updatedAt = bluetooth.chargerStateForDisplay.updatedAt else { return bluetooth.isConnected }
        return now.timeIntervalSince1970 - updatedAt > 15
    }

    private func ageText(now: Date) -> String? {
        bluetooth.chargerStateForDisplay.updatedAt.map { String(format: "%.1f 秒前", max(0, now.timeIntervalSince1970 - $0)) }
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
            // 这一行永远占位，没反馈时留一个空行。写成 if-let 的话，按一下上报
            // 卡片就会长高一行、整格网格跟着跳一下，上报完又缩回去。
            Text(feedback ?? " ")
                .font(.caption2)
                .foregroundStyle(feedbackIsError ? .red : .secondary)
                .lineLimit(1)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 101, alignment: .leading)
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

/**
 * 充电宝的端口卡，版式和充电头的 PortCard 一致。
 *
 * 差别只在内容：充电宝的口是双向的，所以徽章要区分输入/输出；空闲口一律不显示
 * 功率电压电流 —— 固件那个槽位是粘滞的，端口断开后仍留着上一次的读数，照原样画
 * 出来就是在报几分钟前的数。
 */
private struct PowerBankPortCard: View {
    let port: PowerBankPort

    private var title: String {
        switch port.name {
        case "A": "USB-A"
        case "B": "Dock"
        default: "USB-C \(port.name.dropFirst())"
        }
    }

    private var badge: (String, StatusBadgeStyle) {
        switch port.direction {
        case "in":
            return ("输入", .info)
        case "out":
            return ("输出", .success)
        default:
            if port.name == "B" {
                return ("空闲", .neutral)
            }
            if port.isEnergized {
                return ("待机", .neutral)
            }
            if port.attached {
                return ("已插线", .neutral)
            }
            return ("空闲", .neutral)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: port.name == "B" ? "powerplug.fill" : "cable.connector.horizontal")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(port.isActive ? .blue : .secondary)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(port.name == "B" ? "底座" : port.name)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                StatusBadge(text: badge.0, style: badge.1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(port.isActive ? number(port.powerW, digits: 2) : "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text("W")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 0) {
                CompactMetric(
                    title: "电压",
                    value: port.isActive || port.isEnergized ? number(port.voltageV, digits: 2) : "—",
                    unit: "V", icon: "waveform.path", tint: .blue
                )
                Divider().frame(height: 30)
                CompactMetric(
                    title: "电流",
                    value: port.isActive ? number(port.currentA, digits: 2) : "—",
                    unit: "A", icon: "gauge.with.dots.needle.33percent", tint: .purple
                )
            }
            .padding(.vertical, 8)
            .background(.primary.opacity(0.035))

            VStack(alignment: .leading, spacing: 3) {
                if port.name == "B" {
                    Label(port.isActive ? "已连接底座" : "未连接底座", systemImage: "powerplug")
                    Text(port.isActive ? "正在通过底座取电" : "未放置在充电底座上")
                        .foregroundStyle(.secondary)
                    Text("仅输入")
                        .fontWeight(.medium)
                        .foregroundStyle(.tertiary)
                } else {
                    Label(port.attached ? "已插线" : "未检测到线缆", systemImage: "cable.connector")
                    Text(port.isActive ? (port.direction == "in" ? "正在取电" : "正在供电")
                         : port.isEnergized ? "已通电，无负载" : "未协商供电")
                        .foregroundStyle(.secondary)
                    Text(port.name == "A" ? "仅输出" : "支持双向")
                        .fontWeight(.medium)
                        .foregroundStyle(.tertiary)
                }
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
