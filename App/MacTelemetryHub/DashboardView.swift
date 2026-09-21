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

/// 充电头铭牌上的额定上限，进度条和右边那行文字都按它算。
private let chargerRatedMaxWatts: Double = 250

/**
 * 每秒重算一次的那一小块。
 *
 * 以前整个面板套在一个 1 秒的 TimelineView 里，于是每一秒所有卡片、端口格、封面
 * 列表全部重新求值 —— 而真正跟时间有关的只有钟点、「上次上报多久前」和几处过期
 * 判断。把 TimelineView 收到叶子上，其余部分只在数据真的变了才重绘。
 */
private struct Ticking<Content: View>: View {
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(context.date)
        }
    }
}

struct DashboardView: View {
    @ObservedObject var service: ServiceController
    /// 设置是采集模块的开关，界面到处都在读它。ServiceController 不会把它的
    /// @Published 冒泡上来，得单独订阅，否则改了开关这一页要等别的东西触发才更新。
    @ObservedObject private var settings: AppSettings
    @State private var selection: DashboardSection = .overview

    // 子对象的 @Published 不会冒泡。这里不订阅它们：蓝牙大约 1 Hz 一帧，
    // 挂在窗口根上会把总览、设置无关的卡片一起重算。需要刷新的叶子各自包一层。
    private var chargerLink: BluetoothService { service.chargerLink }
    private var covers: ChargerCoverController { service.covers }
    private var powerBankLink: BluetoothService { service.powerBankLink }
    private var httpServer: LocalHTTPServer { service.httpServer }
    private var desktopActivity: DesktopActivityMonitor { service.desktopActivity }
    private var appleMusic: AppleMusicMonitor { service.appleMusic }
    private var vibeCodingUsageCollector: VibeCodingUsageMonitor { service.vibeCodingUsageCollector }
    private var codingSessions: CodingSessionMonitor { service.codingSessions }
    private var vibeCodingYearCollector: VibeCodingYearMonitor { service.vibeCodingYearCollector }

    init(service: ServiceController) {
        self.service = service
        settings = service.settings
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 880, minHeight: 620)
        .task {
            await covers.refresh(force: false)
        }
        .background {
            // 总览页也要在序列号变化时拉封面，所以这个观察不放进充电头那一页。
            ChargerSerialRefresh(link: chargerLink, covers: covers)
        }
    }

    private var sidebar: some View {
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
                Refreshing(object: chargerLink) { chargingLinkStatusRow(chargerLink) }
                Refreshing(object: powerBankLink) { chargingLinkStatusRow(powerBankLink) }
                Refreshing(object: httpServer) {
                    localHTTPRow
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("遥测中心")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: settings.postEnabled ? "paperplane.fill" : "paperplane")
                        .foregroundStyle(settings.postEnabled ? .blue : .secondary)
                    Text(settings.postEnabled ? "远端上报已启用" : "远端上报未启用")
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

    private var localHTTPRow: some View {
        HStack(spacing: 8) {
                    Circle()
                        .fill(!settings.httpServerEnabled ? Color.secondary : httpServer.listeningURL == nil ? .orange : .green)
                        .frame(width: PanelMetrics.statusDot, height: PanelMetrics.statusDot)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localHTTPStatusText)
                            .font(.callout.weight(.medium))
                        Text(httpServer.listeningDescription
                             ?? (settings.httpServerEnabled ? "在设置中检查地址和端口" : "远端上报继续运行"))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
    }

    /// 三个页面共用一套本地 HTTP 三态文案，侧栏、页脚、设置页说的必须是同一句话。
    private var localHTTPStatusText: String {
        LocalHTTPStatusText.sentence(
            enabled: settings.httpServerEnabled,
            listening: httpServer.listeningURL != nil
        )
    }

    private var detail: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 上报坏了是全局状态，跟当前翻到哪一页无关：三个页面都要看得见。
                    if settings.postEnabled, let error = service.reporterLastError {
                        errorBanner("上报异常：\(error)")
                    }

                    switch selection {
                    case .overview:
                        overviewContent
                    case .charger:
                        Refreshing(object: chargerLink) {
                            Refreshing(object: covers) { chargerContent }
                        }
                    case .powerBank:
                        Refreshing(object: powerBankLink) { powerBankContent }
                    }
                }
                .frame(maxWidth: 980, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(22)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selection.title)
                    .font(.title2.weight(.semibold))
                Ticking { now in
                    Text(selection == .overview
                        ? "Mac Telemetry Hub · \(now.formatted(date: .abbreviated, time: .shortened))"
                        : selection.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 16)

            if settings.postEnabled {
                Ticking { now in
                    Label(lastReportText(now: now), systemImage: "paperplane.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            StatusBadge(
                text: service.reporterLastError == nil ? "遥测运行中" : "上报异常",
                style: service.reporterLastError == nil ? .success : .warning
            )
            // 徽章上只有「上报异常」四个字，原因得能看到，否则只能去翻页脚
            .help(service.reporterLastError ?? "所有已启用模块都在正常上报")

            SettingsLink {
                Image(systemName: "gearshape")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .help("打开设置")
            .accessibilityLabel("打开设置")
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

    /// 一个模块都没开：整页给一个空状态，比八张「已关闭」的卡片有用。
    private var everyModuleDisabled: Bool {
        !settings.desktopModuleEnabled
            && !settings.appleMusicModuleEnabled
            && !settings.timezoneModuleEnabled
            && !settings.vibeCodingModuleEnabled
            && !settings.chargerModuleEnabled
            && !settings.powerBankModuleEnabled
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if everyModuleDisabled {
                EmptyModuleView(
                    title: "还没有启用任何数据源",
                    detail: "所有采集模块都已关闭，这台 Mac 不会产生任何遥测。在设置里打开需要的模块。",
                    icon: "square.stack.3d.up.slash"
                )
            } else {
                sectionHeading("数据源", detail: "每个模块独立运行，状态变化会在这里反映")
                moduleGrid
            }

            Refreshing(object: httpServer) { footer }
        }
    }

    @ViewBuilder
    private var chargerContent: some View {
        if settings.chargerModuleEnabled {
            VStack(alignment: .leading, spacing: 18) {
                chargingLinkSessionHeader(chargerLink)

                if chargerLink.hasTelemetry {
                    overviewCard

                    sectionHeading("端口", detail: "实时电压、电流、功率与识别到的设备")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(["C1", "C2", "C3"], id: \.self) { key in
                            PortCard(key: key, port: chargerLink.chargerStateForDisplay.ports[key] ?? PortState())
                                .frame(minHeight: 248)
                        }
                    }

                    coverSection
                } else {
                    EmptyModuleView(
                        title: chargerLink.phase.label,
                        detail: chargingLinkWaitingDetail(chargerLink),
                        icon: chargerLink.slot.icon
                    )
                }
            }
        } else {
            EmptyModuleView(
                title: "充电头模块未启用",
                detail: "在设置的“充电设备”中启用充电头模块并完成一次配对。",
                icon: chargerLink.slot.icon
            )
        }
    }

    @ViewBuilder
    private var powerBankContent: some View {
        if settings.powerBankModuleEnabled {
            VStack(alignment: .leading, spacing: 18) {
                chargingLinkSessionHeader(powerBankLink)

                if let state = powerBankLink.powerBankState, powerBankLink.hasTelemetry {
                    powerBankOverviewCard(state)
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
                        detail: chargingLinkWaitingDetail(powerBankLink),
                        icon: powerBankLink.slot.icon
                    )
                }
            }
        } else {
            EmptyModuleView(
                title: "充电宝模块未启用",
                detail: "在设置的“充电设备”中启用充电宝模块并完成一次配对。",
                icon: powerBankLink.slot.icon
            )
        }
    }

    /// 和充电头的 overviewCard 同一套版式：左边大数字加进度条，右边设备事实网格。
    /// 两个页面看起来该是同一个产品的两个页签，而不是两个人写的。
    private func powerBankOverviewCard(_ state: PowerBankState) -> some View {
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
        .panelBackground()
    }

    /// 进度条右侧那行。充电宝没有「额定上限」可写，写当前收放电更有信息量。
    private func powerBankFlowText(_ state: PowerBankState) -> String {
        powerBankFlowLabel(state)
    }

    private func powerBankTimeText(_ state: PowerBankState) -> String? {
        guard let hours = state.timeToFullHours, let minutes = state.timeToFullMinutes,
              hours * 60 + minutes > 0 else { return nil }
        return hours > 0 ? "\(hours) 小时 \(minutes) 分" : "\(minutes) 分钟"
    }

    /// 连上了却没有数据，和根本没连上，是两个完全不同的问题。空状态必须能自己
    /// 说清楚卡在哪一步，否则只能靠猜。充电头和充电宝用同一套文案。
    private func chargingLinkWaitingDetail(_ link: BluetoothService) -> String {
        if let error = link.lastError { return error }
        switch link.phase {
        case .connected:
            return "已连接并完成握手，但还没收到遥测帧。正常情况下 1 秒内就该有第一帧。"
        case .handshaking:
            return "正在建立加密会话。"
        case .connecting:
            return "正在连接已配对的\(link.slot.displayName)。"
        case .awaitingPairing:
            return "还没有配对。打开设置，扫描并选择一台\(link.slot.displayName)。"
        case let .bluetoothUnavailable(reason):
            return reason
        case .stopped:
            return "链路已停止。"
        case .disconnected:
            return "定向连接已挂起，\(link.slot.displayName)上电后会自动接入。"
        case .idleSleeping:
            return "长时间没有充放电，已断开蓝牙。隔一段时间会再连上去看一眼。"
        }
    }

    /// 总览卡片正面：有读数就显示读数，没有就显示连接阶段。
    private var chargerOverviewValue: String {
        guard settings.chargerModuleEnabled else { return "已关闭" }
        if chargerLink.hasTelemetry, let watts = chargerLink.chargerStateForDisplay.totalOutputPowerW {
            return String(format: "%.2f W", watts)
        }
        return chargerLink.phase.label
    }

    private var chargerOverviewDetail: String? {
        guard settings.chargerModuleEnabled else { return nil }
        guard chargerLink.hasTelemetry else { return chargerLink.lastError }
        return chargerLink.isConnected ? nil : chargerLink.phase.label
    }

    private var powerBankOverviewValue: String {
        guard settings.powerBankModuleEnabled else { return "已关闭" }
        guard let state = powerBankLink.powerBankState, let percent = state.batteryPercent else {
            return powerBankLink.phase.label
        }
        return String(format: "%.1f%%", percent)
    }

    private var powerBankOverviewDetail: String? {
        guard settings.powerBankModuleEnabled else { return nil }
        guard let state = powerBankLink.powerBankState, powerBankLink.hasTelemetry else {
            return powerBankLink.lastError
        }
        if !powerBankLink.isConnected { return powerBankLink.phase.label }
        if state.isThermallyLimited { return "过热受限，暂不充电" }
        return powerBankFlowLabel(state)
    }

    private var moduleGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            Refreshing(object: desktopActivity) { desktopModuleCard }
            Refreshing(object: appleMusic) { appleMusicModuleCard }
            Refreshing(object: service.timeZone) { timezoneModuleCard }
            // 会话和用量共用一个手动上报模块，卡片却各看各的采集器。
            Refreshing(object: codingSessions) { vibeCodingSessionCard }
            Refreshing(object: vibeCodingUsageCollector) { vibeCodingUsageCard }
            Refreshing(object: vibeCodingYearCollector) { vibeCodingYearCard }
            Refreshing(object: chargerLink) { chargerModuleCard }
            Refreshing(object: powerBankLink) { powerBankModuleCard }
        }
    }

    private var desktopModuleCard: some View {
        ModuleStatusCard(
            title: "前台应用",
            icon: "macwindow",
            enabled: settings.desktopModuleEnabled,
            value: desktopActivity.snapshot?.applicationName ?? "等待活动",
            detail: desktopActivityDetail,
            action: { _ = service.requestImmediateReport(.desktop) },
            actionEnabled: service.canRequestImmediateReport(.desktop),
            isReporting: service.isManualReportInFlight(.desktop),
            feedback: service.manualReportMessage(for: .desktop),
            feedbackIsError: service.manualReportFailed(.desktop)
        )
    }

    private var appleMusicModuleCard: some View {
        ModuleStatusCard(
            title: "Apple Music",
            icon: "music.note",
            enabled: settings.appleMusicModuleEnabled,
            value: appleMusicStateText,
            detail: appleMusicDetailText,
            action: { _ = service.requestImmediateReport(.appleMusic) },
            actionEnabled: service.canRequestImmediateReport(.appleMusic),
            isReporting: service.isManualReportInFlight(.appleMusic),
            feedback: service.manualReportMessage(for: .appleMusic),
            feedbackIsError: service.manualReportFailed(.appleMusic)
        )
    }

    private var timezoneModuleCard: some View {
        ModuleStatusCard(
            title: "Mac 时区",
            icon: "clock",
            enabled: settings.timezoneModuleEnabled,
            value: service.timeZone.snapshot?.identifier ?? "等待时区",
            detail: service.timeZone.snapshot.map { formatUTCOffset($0.secondsFromGMT) },
            action: { _ = service.requestImmediateReport(.timezone) },
            actionEnabled: service.canRequestImmediateReport(.timezone),
            isReporting: service.isManualReportInFlight(.timezone),
            feedback: service.manualReportMessage(for: .timezone),
            feedbackIsError: service.manualReportFailed(.timezone)
        )
    }

    private var vibeCodingSessionCard: some View {
        ModuleStatusCard(
            title: "Vibe · 会话状态",
            icon: "terminal",
            enabled: settings.vibeCodingModuleEnabled,
            value: codingSessions.lastSuccess == nil ? "等待扫描" : "扫描完成",
            detail: codingSessions.lastError
                ?? codingSessions.lastSuccess?.formatted(date: .omitted, time: .standard),
            action: { Task { await service.refreshVibeCodingSessionsNow() } },
            actionIcon: "arrow.clockwise",
            actionHelp: "重新读取本地会话状态并上报",
            actionEnabled: settings.vibeCodingModuleEnabled,
            isReporting: service.isRefreshingVibeCodingSessions
                || service.isManualReportInFlight(.vibeCoding),
            feedback: service.isRefreshingVibeCodingSessions
                ? "正在扫描会话状态…"
                : service.manualReportMessage(for: .vibeCoding),
            feedbackIsError: service.manualReportFailed(.vibeCoding)
        )
    }

    private var vibeCodingUsageCard: some View {
        ModuleStatusCard(
            title: "Vibe · 用量",
            icon: "chart.bar",
            enabled: settings.vibeCodingModuleEnabled,
            value: vibeCodingUsageCollector.lastSuccess == nil ? "等待统计" : "聚合完成",
            detail: vibeCodingUsageCollector.lastError
                ?? vibeCodingUsageCollector.lastSuccess?.formatted(date: .omitted, time: .standard),
            action: { Task { await service.refreshVibeCodingUsageNow() } },
            actionIcon: "arrow.clockwise",
            actionHelp: "重新统计本地与 Cursor 云端完整历史并上报",
            actionEnabled: settings.vibeCodingModuleEnabled,
            isReporting: service.isRefreshingVibeCodingUsage
                || service.isManualReportInFlight(.vibeCoding),
            feedback: service.isRefreshingVibeCodingUsage
                ? "正在重新统计用量…"
                : service.manualReportMessage(for: .vibeCoding),
            feedbackIsError: service.manualReportFailed(.vibeCoding)
        )
    }

    private var vibeCodingYearCard: some View {
        ModuleStatusCard(
            title: "Vibe · 年度用量",
            icon: "calendar",
            enabled: settings.vibeCodingModuleEnabled,
            value: vibeCodingYearCollector.lastSuccess == nil ? "等待日历" : "已采集",
            detail: vibeCodingYearCollector.lastError
                ?? vibeCodingYearCollector.lastSuccess?.formatted(date: .omitted, time: .standard),
            action: { Task { await service.refreshVibeCodingYearNow() } },
            actionIcon: "arrow.clockwise",
            actionHelp: "重新读取过去 53 周的日合计并上报",
            actionEnabled: settings.vibeCodingModuleEnabled,
            isReporting: service.isRefreshingVibeCodingYear
                || service.isManualReportInFlight(.vibeCodingYear),
            feedback: service.isRefreshingVibeCodingYear
                ? "正在读取年度用量…"
                : service.manualReportMessage(for: .vibeCodingYear),
            feedbackIsError: service.manualReportFailed(.vibeCodingYear)
        )
    }

    private var chargerModuleCard: some View {
        ModuleStatusCard(
            title: "充电头",
            icon: "bolt.fill",
            enabled: settings.chargerModuleEnabled,
            value: chargerOverviewValue,
            detail: chargerOverviewDetail,
            action: { _ = service.requestImmediateReport(.charger) },
            actionEnabled: service.canRequestImmediateReport(.charger),
            isReporting: service.isManualReportInFlight(.charger),
            feedback: service.manualReportMessage(for: .charger),
            feedbackIsError: service.manualReportFailed(.charger)
        )
    }

    private var powerBankModuleCard: some View {
        ModuleStatusCard(
            title: "充电宝",
            icon: "minus.plus.batteryblock.fill",
            enabled: settings.powerBankModuleEnabled,
            value: powerBankOverviewValue,
            detail: powerBankOverviewDetail,
            action: { _ = service.requestImmediateReport(.powerBank) },
            actionEnabled: service.canRequestImmediateReport(.powerBank),
            isReporting: service.isManualReportInFlight(.powerBank),
            feedback: service.manualReportMessage(for: .powerBank),
            feedbackIsError: service.manualReportFailed(.powerBank)
        )
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
        if track.isEmpty { return appleMusic.lastError ?? "Music.app 已停止" }
        guard let queue = snapshot.queue, let index = queue.index,
              index + 1 < queue.tracks.count else { return track }
        let next = queue.tracks[index + 1]
        var nextLabel = next.title
        if let artist = next.artist, !artist.isEmpty { nextLabel += " · \(artist)" }
        return "\(track)  ·  下一首 \(nextLabel)"
    }

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeading("自定义封面", detail: "点预览即可切换。头上没有像素的图会先按官方路径传上去（0x0220/0x0221），机内只有 4 个槽，多传会顶掉一张。")
                Spacer()
                Button {
                    Task { await covers.refresh(force: true) }
                } label: {
                    if covers.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(covers.isLoading)
            }

            if let progress = covers.transferProgress, let transferring = covers.transferringID {
                let name = covers.pictures.first(where: { $0.id == transferring }).map {
                    $0.name.isEmpty ? "槽位 \($0.seq)" : $0.name
                } ?? "封面"
                Label("正在把 \(name) 传到充电头（\(progress.0)/\(progress.1)）", systemImage: "arrow.up.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = covers.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !settings.hasAnkerCloudCredentials {
                Label("在设置里填写 Anker 账号密码并登录后，这里会列出封面预览。", systemImage: "person.badge.key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if covers.pictures.isEmpty, covers.isLoading {
                Label("正在从云端拉取封面…", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if covers.pictures.isEmpty {
                Label("云端还没有自定义封面，或充电头尚未连上。", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !covers.pictures.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(covers.pictures) { picture in
                            CoverPreviewTile(
                                picture: picture,
                                image: covers.previews[picture.id],
                                isCurrent: covers.currentPictureID == picture.id,
                                isCloudOnly: covers.cloudOnlyIDs.contains(picture.id),
                                isSelecting: covers.selectingID == picture.id
                                    || covers.transferringID == picture.id,
                                transferLabel: covers.transferringID == picture.id
                                    ? covers.transferProgress.map { "\($0.0)/\($0.1)" }
                                    : nil,
                                enabled: covers.canSelect
                            ) {
                                Task { await covers.select(picture) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.visible, axes: .horizontal)
            }
        }
    }

    private var overviewCard: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Label("实时总输出", systemImage: "bolt.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(number(chargerLink.chargerStateForDisplay.totalOutputPowerW, digits: 2))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("W")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 10) {
                    ProgressView(
                        value: min(
                            max((chargerLink.chargerStateForDisplay.totalOutputPowerW ?? 0) / chargerRatedMaxWatts, 0),
                            1
                        )
                    )
                    .tint(.blue)
                    Text("\(Int(chargerRatedMaxWatts)) W MAX")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().frame(height: 100)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], alignment: .leading, spacing: 14) {
                DeviceFact(title: "序列号", value: chargerLink.chargerStateForDisplay.device.serialNumber, icon: "number")
                DeviceFact(title: "MAC 地址", value: chargerLink.chargerStateForDisplay.device.macAddress, icon: "antenna.radiowaves.left.and.right")
                DeviceFact(title: "固件版本", value: chargerLink.chargerStateForDisplay.device.firmwareVersion, icon: "cpu")
                // 「多久之前」是这张卡里唯一跟时间走的一格，只有它需要每秒重算
                Ticking { now in
                    DeviceFact(title: "数据更新", value: ageText(now: now), icon: "clock.arrow.circlepath")
                }
                DeviceFact(title: "当前封面", value: currentCoverText, icon: "photo")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .panelBackground()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let url = httpServer.listeningURL {
                Circle().fill(.green).frame(width: PanelMetrics.statusDot, height: PanelMetrics.statusDot)
                Text(localHTTPStatusText).font(.caption.weight(.semibold))
                Text(httpServer.listeningDescription ?? url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("打开端点") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
                    .font(.caption)
            } else if !settings.httpServerEnabled {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                Text(localHTTPStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(httpServer.lastError ?? localHTTPStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if settings.postEnabled {
                if let error = service.reporterLastError {
                    Label("上报失败：\(error)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if let date = service.reporterLastSuccess {
                    Label("已于 \(date.formatted(date: .omitted, time: .standard)) 上报", systemImage: "paperplane.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Label("等待首份数据后上报", systemImage: "paperplane")
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("定时上报未启用", systemImage: "paperplane")
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
        .overlay(
            RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius)
                .stroke(.orange.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius))
    }

    /// 过期判断要跟着秒走，所以这一行整个挂在 Ticking 上 —— 它本身很小，重算不心疼。
    private func chargingLinkStatusRow(_ link: BluetoothService) -> some View {
        let enabled = link.slot.isEnabled(settings)
        return Ticking { now in
            HStack(spacing: 8) {
                Circle()
                    .fill(chargingLinkStatusColor(link, now: now))
                    .frame(width: PanelMetrics.statusDot, height: PanelMetrics.statusDot)
                VStack(alignment: .leading, spacing: 2) {
                    Text(enabled ? chargingLinkStatusText(link, now: now) : "已关闭")
                        .font(.callout.weight(.medium))
                    Text(link.slot.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func chargingLinkSessionHeader(_ link: BluetoothService) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = link.lastError, !link.isConnected {
                errorBanner(error)
            }

            HStack(spacing: 8) {
                Button("断开\(link.slot.displayName)", systemImage: "bolt.slash") {
                    link.disconnect()
                }
                .disabled(!link.isConnected)
                .help("断开当前\(link.slot.displayName)")

                Button("重连\(link.slot.displayName)", systemImage: "arrow.clockwise") {
                    link.reconnect()
                }
                .help("重新连接当前\(link.slot.displayName)")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func chargingLinkStatusText(_ link: BluetoothService, now: Date) -> String {
        if link.isConnected, isStale(link, now: now) { return "数据过期" }
        return link.phase.label
    }

    private func chargingLinkStatusColor(_ link: BluetoothService, now: Date) -> Color {
        guard link.slot.isEnabled(settings) else { return .secondary }
        if link.isConnected { return isStale(link, now: now) ? .orange : .green }
        switch link.phase {
        case .connecting, .handshaking: return .blue
        case .awaitingPairing: return .orange
        case .bluetoothUnavailable: return .red
        default: return .secondary
        }
    }

    private func isStale(_ link: BluetoothService, now: Date) -> Bool {
        guard link.isConnected, let updatedAt = link.lastTelemetryAt else { return false }
        return now.timeIntervalSince1970 - updatedAt > PanelMetrics.staleThreshold
    }

    private func ageText(now: Date) -> String? {
        chargerLink.chargerStateForDisplay.updatedAt.map { String(format: "%.1f 秒前", max(0, now.timeIntervalSince1970 - $0)) }
    }

    private var currentCoverText: String? {
        guard let id = chargerLink.chargerStateForDisplay.screensaverId else { return nil }
        if let picture = covers.pictures.first(where: { $0.id == id }) {
            return picture.name.isEmpty ? "槽位 \(picture.seq)" : picture.name
        }
        return "#\(id)"
    }
}

/// 只让这一小块跟着某个 ObservableObject 重绘。窗口根上不订阅它。
private struct Refreshing<Object: ObservableObject, Content: View>: View {
    @ObservedObject var object: Object
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}

/// 充电头序列号变化时拉封面。挂在窗口上，不限于当前打开的是哪一页。
private struct ChargerSerialRefresh: View {
    @ObservedObject var link: BluetoothService
    let covers: ChargerCoverController

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: link.chargerStateForDisplay.device.serialNumber) { _, _ in
                Task { await covers.refresh(force: false) }
            }
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
            // 空状态每一句话都在说「去设置里打开」，那就把设置放在手边
            SettingsLink {
                Label("打开设置", systemImage: "gearshape")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .panelBackground()
    }
}

/// 0.05 W 以下当成待机。总览卡和充电宝大数字共用这一句，避免两处阈值慢慢岔开。
private func powerBankFlowLabel(_ state: PowerBankState) -> String {
    let input = state.inputPowerW ?? 0
    let output = state.outputPowerW ?? 0
    if input > 0.05 { return String(format: "输入 %.1f W", input) }
    if output > 0.05 { return String(format: "输出 %.1f W", output) }
    return "待机"
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
                        // 图标本身只有 14 点，撑到 20 点才好点中
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!actionEnabled || isReporting)
                    .help(actionHelp ?? "立即上报\(title)")
                    .accessibilityLabel(actionHelp ?? "立即上报\(title)")
                }
                Circle()
                    .fill(enabled ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: PanelMetrics.statusDot, height: PanelMetrics.statusDot)
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
        .padding(PanelMetrics.padding)
        .frame(maxWidth: .infinity, minHeight: 101, alignment: .leading)
        .panelBackground()
    }
}

/**
 * 端口卡的骨架：抬头、大瓦数、电压电流条、底下三行说明。
 *
 * 充电头和充电宝的端口卡本来是两份一模一样的版式，只有取值不同 —— 改一边忘另一边
 * 就会错位。骨架收在这里，两边只负责把字算出来。
 */
private struct ChargingPortCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isActive: Bool
    let badgeText: String
    let badgeStyle: StatusBadgeStyle
    let powerText: String
    let voltageText: String
    let currentText: String
    let cableIcon: String
    let cableText: String
    let statusText: String
    let roleText: String
    /// 底下那行是不是识别出了具体东西。没识别出来就压成三级灰。
    let roleIsResolved: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? .blue : .secondary)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                StatusBadge(text: badgeText, style: badgeStyle)
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(powerText)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text("W")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 0) {
                CompactMetric(title: "电压", value: voltageText, unit: "V", icon: "waveform.path", tint: .blue)
                Divider().frame(height: 30)
                CompactMetric(
                    title: "电流",
                    value: currentText,
                    unit: "A",
                    icon: "gauge.with.dots.needle.33percent",
                    tint: .purple
                )
            }
            .padding(.vertical, 8)
            .background(.primary.opacity(0.035))

            VStack(alignment: .leading, spacing: 3) {
                Label(cableText, systemImage: cableIcon)
                Text(statusText)
                    .foregroundStyle(.secondary)
                Text(roleText)
                    .fontWeight(.medium)
                    .foregroundStyle(roleIsResolved ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            }
            .font(.caption)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(PanelMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelBackground()
    }
}

private struct PortCard: View {
    let key: String
    let port: PortState

    private var active: Bool { port.mode == "Output" }
    private var displayModel: String? { port.deviceModel ?? port.vendor }

    var body: some View {
        ChargingPortCard(
            icon: "cable.connector.horizontal",
            title: "USB-C \(key.dropFirst())",
            subtitle: key,
            isActive: active,
            badgeText: active ? "输出" : "关闭",
            badgeStyle: active ? .success : .neutral,
            powerText: number(port.powerW, digits: 2),
            voltageText: number(port.voltageV, digits: 2),
            currentText: number(port.currentA, digits: 2),
            cableIcon: "cable.connector",
            cableText: port.cable ?? "未检测到线缆",
            statusText: port.chargingInfo ?? "未识别充电协议",
            roleText: displayModel ?? "未识别设备",
            roleIsResolved: displayModel != nil
        )
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

    private var isDock: Bool { port.name == "B" }

    var body: some View {
        ChargingPortCard(
            icon: isDock ? "powerplug.fill" : "cable.connector.horizontal",
            title: title,
            subtitle: isDock ? "底座" : port.name,
            isActive: port.isActive,
            badgeText: badge.0,
            badgeStyle: badge.1,
            powerText: port.isActive ? number(port.powerW, digits: 2) : "—",
            voltageText: port.isActive || port.isEnergized ? number(port.voltageV, digits: 2) : "—",
            currentText: port.isActive ? number(port.currentA, digits: 2) : "—",
            cableIcon: isDock ? "powerplug" : "cable.connector",
            cableText: cableText,
            statusText: statusText,
            roleText: isDock ? "仅输入" : (port.name == "A" ? "仅输出" : "支持双向"),
            // 供电方向是这台设备的固有属性，不是「识别出来的东西」，一律压成三级灰
            roleIsResolved: false
        )
    }

    private var cableText: String {
        if isDock { return port.isActive ? "已连接底座" : "未连接底座" }
        return port.attached ? "已插线" : "未检测到线缆"
    }

    private var statusText: String {
        if isDock { return port.isActive ? "正在通过底座取电" : "未放置在充电底座上" }
        if port.isActive { return port.direction == "in" ? "正在取电" : "正在供电" }
        return port.isEnergized ? "已通电，无负载" : "未协商供电"
    }
}

private struct CoverPreviewTile: View {
    let picture: AnkerScreensaverPicture
    let image: NSImage?
    let isCurrent: Bool
    let isCloudOnly: Bool
    let isSelecting: Bool
    let transferLabel: String?
    let enabled: Bool
    let action: () -> Void

    private let imageSize: CGFloat = 132

    private var title: String {
        picture.name.isEmpty ? "槽位 \(picture.seq)" : picture.name
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color.primary.opacity(0.05)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
                    if isSelecting {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: imageSize, height: imageSize)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isCurrent {
                        Text("当前")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.16)))
                    } else if let transferLabel {
                        Text(transferLabel)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.blue)
                    } else if isCloudOnly {
                        Text("需上传")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.16)))
                    }
                }
                .frame(width: imageSize, alignment: .leading)
            }
            .padding(8)
            // 当前那张用蓝色粗边挑出来，其余走统一的灰边
            .panelBackground(stroke: isCurrent ? Color.blue : nil, lineWidth: isCurrent ? 2 : 1)
            .opacity(enabled ? 1 : 0.65)
        }
        .buttonStyle(.plain)
        .disabled((!enabled && !isCurrent) || isSelecting)
        .help(isCurrent ? "当前封面" : "切换到 \(title)")
        .accessibilityLabel(isCurrent ? "当前封面 \(title)" : "切换到 \(title)")
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

private func number(_ value: Double?, digits: Int) -> String {
    guard let value else { return "—" }
    return String(format: "%.*f", digits, value)
}
