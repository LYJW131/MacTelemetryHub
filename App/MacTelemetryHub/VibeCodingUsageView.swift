import Charts
import SwiftUI

struct VibeCodingUsageView: View {
    let payload: JSONValue?
    let updatedAt: Date?
    let error: String?
    let onRefresh: (() -> Void)?
    let isRefreshing: Bool
    let refreshMessage: String?
    /// 键是 "claude" / "codex"。套餐和限额跟 ccusage 无关 —— ccusage 只数本地
    /// JSONL 里的 token，服务端的额度它一无所知，所以走单独的采集器单独传进来。
    var plans: [String: AgentPlanSnapshot] = [:]

    @State private var selectedAgent: UsageAgentFilter = .all

    init(
        payload: JSONValue?,
        updatedAt: Date?,
        error: String?,
        plans: [String: AgentPlanSnapshot] = [:],
        onRefresh: (() -> Void)? = nil,
        isRefreshing: Bool = false,
        refreshMessage: String? = nil
    ) {
        self.payload = payload
        self.updatedAt = updatedAt
        self.error = error
        self.plans = plans
        self.onRefresh = onRefresh
        self.isRefreshing = isRefreshing
        self.refreshMessage = refreshMessage
    }

    private var report: VibeUsageReport? {
        payload.flatMap(VibeUsageReport.init(payload:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let report {
                let selection = report.selection(for: selectedAgent)
                metrics(selection)
                HStack(alignment: .top, spacing: 14) {
                    dailyChart(selection)
                        .frame(maxWidth: .infinity)
                    breakdown(selection)
                        .frame(width: 300)
                }
                providerRows(report)
            } else {
                ContentUnavailableView {
                    Label("等待 ccusage 数据", systemImage: "chart.xyaxis.line")
                } description: {
                    Text(error ?? "在设置中启用 ccusage，并配置 Node 与 CLI 路径。")
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .padding(18)
        .dashboardPanel(cornerRadius: 8)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.indigo.opacity(0.13))
                Image(systemName: "terminal.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.indigo)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Vibe Coding Usage")
                    .font(.headline)
                Text(updatedAt.map { "ccusage · updated \($0.formatted(date: .omitted, time: .shortened))" }
                    ?? "ccusage · local estimates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Agent", selection: $selectedAgent) {
                ForEach(UsageAgentFilter.allCases) { agent in
                    Text(agent.label).tag(agent)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 230)

            if let onRefresh {
                Button {
                    onRefresh()
                } label: {
                    Group {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)
                .help("立即刷新 Token 用量与限额")
            }

            if let refreshMessage {
                Text(refreshMessage)
                    .font(.caption2)
                    .foregroundStyle(refreshMessage.hasPrefix("刷新失败") ? .red : .secondary)
                    .lineLimit(1)
            }
        }
    }

    private func metrics(_ selection: VibeUsageSelection) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
            spacing: 10
        ) {
            UsageMetricCard(
                title: "Today Tokens",
                value: formatTokens(selection.today.totalTokens),
                detail: selection.today.totalTokens == 0 ? "No activity" : "Local calendar day",
                icon: "sun.max.fill",
                tint: .orange
            )
            UsageMetricCard(
                title: "30d Tokens",
                value: formatTokens(selection.last30Days.totalTokens),
                detail: "\(selection.activeDayCount) active days",
                icon: "calendar",
                tint: .blue
            )
            UsageMetricCard(
                title: "All-time Tokens",
                value: formatTokens(selection.allTime.totalTokens),
                detail: "Input + output + cache",
                icon: "sum",
                tint: .indigo
            )
            UsageMetricCard(
                title: "30d Cost",
                value: formatUSD(selection.last30Days.costUSD),
                detail: "API-rate estimate",
                icon: "dollarsign.circle.fill",
                tint: .green
            )
        }
    }

    private func dailyChart(_ selection: VibeUsageSelection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Daily Tokens · 30d")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                HStack(spacing: 10) {
                    chartLegend("Claude", color: .orange)
                    chartLegend("Codex", color: .blue)
                }
            }

            Chart(selection.dailyPoints) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Tokens", point.totals.totalTokens),
                    series: .value("Agent", point.agent.label)
                )
                .foregroundStyle(point.agent.color)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

                PointMark(
                    x: .value("Date", point.date),
                    y: .value("Tokens", point.totals.totalTokens)
                )
                .foregroundStyle(point.agent.color)
                .symbolSize(18)
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(formatTokens(number))
                        }
                    }
                }
            }
            .frame(height: 210)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.065)))
    }

    private func breakdown(_ selection: VibeUsageSelection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Token Mix · 30d")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Cache share \(formatPercent(selection.last30Days.cacheShare))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Cache read ÷ (cache read + uncached input)")
            }

            TokenMixBar(totals: selection.last30Days)
                .frame(height: 9)

            VStack(spacing: 7) {
                TokenMixRow(label: "Input", value: selection.last30Days.inputTokens, color: .blue)
                TokenMixRow(label: "Output", value: selection.last30Days.outputTokens, color: .mint)
                TokenMixRow(label: "Cache read", value: selection.last30Days.cacheReadTokens, color: .orange)
                TokenMixRow(label: "Cache write", value: selection.last30Days.cacheCreationTokens, color: .purple)
                if selection.last30Days.reasoningTokens > 0 {
                    TokenMixRow(label: "Reasoning (within output)", value: selection.last30Days.reasoningTokens, color: .green)
                }
            }

            Divider()

            Text("Top Models")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if selection.models.isEmpty {
                Text("No model breakdown")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(selection.models.prefix(4)) { model in
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(formatTokens(model.tokens))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(minHeight: 248, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.065)))
    }

    private func providerRows(_ report: VibeUsageReport) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(report.providers) { provider in
                let window = provider.selection
                let plan = plans[provider.agent.rawValue]
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: provider.agent == .claude ? "sparkles" : "chevron.left.forwardslash.chevron.right")
                            .foregroundStyle(provider.agent.color)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(provider.agent.label)
                                    .font(.caption.weight(.semibold))
                                if let plan {
                                    Text("·")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(plan.label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(provider.currentModel ?? "Model unavailable")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(formatTokens(window.today.totalTokens))
                                .font(.callout.monospacedDigit().weight(.semibold))
                            Text("today · \(formatUSD(window.today.costUSD))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let limits = plan?.limits, !limits.isEmpty {
                        Divider().padding(.vertical, 9)
                        // 倒计时只到分钟级，60 秒一跳就够了；整个卡片跟着面板那个
                        // 每秒 TimelineView 重绘的话，下面那张 30 天图会白重画 60 倍。
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            VStack(spacing: 7) {
                                ForEach(limits, id: \.key) { limit in
                                    UsageLimitMeter(limit: limit, tint: provider.agent.color, now: context.date)
                                }
                            }
                        }
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(provider.agent.color.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(provider.agent.color.opacity(0.13)))
            }
        }
    }

    private func chartLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct UsageMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.14)))
    }
}

private struct UsageLimitMeter: View {
    let limit: AgentLimitWindow
    let tint: Color
    let now: Date

    /// 变红的阈值，只在这一处定义
    private static let alertPercent = 90.0

    private var barColor: Color { limit.usedPercent >= Self.alertPercent ? .red : tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(Int(limit.usedPercent.rounded()))%")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(barColor)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(2, proxy.size.width * min(1, max(0, limit.usedPercent / 100))))
                }
            }
            .frame(height: 5)
            if let resetText {
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /**
     * 窗口名。
     *
     * 两个来源给的东西不一样：Codex 给分钟数不给分组，Claude 给分组不给分钟数
     * （它那个端点根本没有时长字段）。所以这里按「有什么用什么」，
     * 不由分组反推分钟数 —— "session 就是 5 小时" 是猜的，官方没给过这个数。
     */
    private var title: String {
        var parts: [String] = []
        if let minutes = limit.windowMinutes {
            parts.append(Self.windowName(minutes))
        } else if let group = limit.group {
            parts.append(Self.groupName(group))
        }
        if let label = limit.label { parts.append(label) }
        return parts.isEmpty ? limit.key : parts.joined(separator: " · ")
    }

    private var resetText: String? {
        guard let resetsAt = limit.resetsAt else { return nil }
        let remaining = Double(resetsAt) - now.timeIntervalSince1970
        guard remaining > 0 else { return "resetting" }
        if remaining < 3_600 { return "resets in \(Int(remaining / 60))m" }
        if remaining < 86_400 { return "resets in \(Int(remaining / 3_600))h" }
        let days = Int(remaining / 86_400)
        let hours = Int(remaining.truncatingRemainder(dividingBy: 86_400) / 3_600)
        return hours == 0 ? "resets in \(days)d" : "resets in \(days)d \(hours)h"
    }

    private static func windowName(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m window" }
        if minutes < 1_440 || minutes % 1_440 != 0 { return "\(minutes / 60)h window" }
        return "\(minutes / 1_440)d window"
    }

    private static func groupName(_ group: String) -> String {
        switch group {
        case "session": "Session"
        case "weekly": "Weekly"
        default: group.capitalized
        }
    }
}

private struct TokenMixBar: View {
    let totals: UsageTokenTotals

    private var parts: [(Double, Color)] {
        [
            (totals.inputTokens, .blue),
            (totals.outputTokens, .mint),
            (totals.cacheReadTokens, .orange),
            (totals.cacheCreationTokens, .purple),
        ].filter { $0.0 > 0 }
    }

    var body: some View {
        GeometryReader { proxy in
            let total = max(1, parts.reduce(0) { $0 + $1.0 })
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(part.1)
                        .frame(width: max(2, proxy.size.width * part.0 / total))
                }
            }
            .clipShape(Capsule())
        }
    }
}

private struct TokenMixRow: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(formatTokens(value))
                .font(.caption.monospacedDigit().weight(.medium))
        }
    }
}

private enum UsageAgentFilter: String, CaseIterable, Identifiable {
    case all
    case claude
    case codex

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

private enum UsageAgent: String, Identifiable {
    case claude
    case codex

    var id: String { rawValue }
    var label: String { self == .claude ? "Claude Code" : "Codex" }
    var color: Color { self == .claude ? .orange : .blue }
}

private struct UsageTokenTotals {
    var inputTokens = 0.0
    var outputTokens = 0.0
    var cacheReadTokens = 0.0
    var cacheCreationTokens = 0.0
    var reasoningTokens = 0.0
    var costUSD = 0.0

    var totalTokens: Double {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    var cacheShare: Double {
        let denominator = cacheReadTokens + inputTokens
        return denominator > 0 ? cacheReadTokens / denominator : 0
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
            costUSD: lhs.costUSD + rhs.costUSD
        )
    }
}

private struct UsageModelTotal: Identifiable {
    let name: String
    let tokens: Double
    var id: String { name }
}

private struct UsageDailyPoint: Identifiable {
    let agent: UsageAgent
    let date: Date
    let totals: UsageTokenTotals
    let models: [String: Double]
    var id: String { "\(agent.rawValue)-\(date.timeIntervalSince1970)" }
}

private struct UsageProviderReport: Identifiable {
    let agent: UsageAgent
    let daily: [UsageDailyPoint]
    let allTime: UsageTokenTotals
    let currentModel: String?
    var id: String { agent.id }

    var selection: VibeUsageSelection {
        VibeUsageSelection(providers: [self])
    }
}

private struct VibeUsageSelection {
    let providers: [UsageProviderReport]
    let dailyPoints: [UsageDailyPoint]
    let today: UsageTokenTotals
    let last30Days: UsageTokenTotals
    let allTime: UsageTokenTotals
    let activeDayCount: Int
    let models: [UsageModelTotal]

    init(providers: [UsageProviderReport]) {
        self.providers = providers
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let windowStart = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
        let points = providers.flatMap(\.daily).filter { $0.date >= windowStart }
        dailyPoints = points.sorted { $0.date < $1.date }
        today = points.filter { calendar.isDate($0.date, inSameDayAs: todayStart) }
            .reduce(into: UsageTokenTotals()) { $0 = $0 + $1.totals }
        last30Days = points.reduce(into: UsageTokenTotals()) { $0 = $0 + $1.totals }
        allTime = providers.reduce(into: UsageTokenTotals()) { $0 = $0 + $1.allTime }
        activeDayCount = Set(points.map { calendar.startOfDay(for: $0.date) }).count
        var modelTotals: [String: Double] = [:]
        for point in points {
            for (name, tokens) in point.models { modelTotals[name, default: 0] += tokens }
        }
        models = modelTotals.map(UsageModelTotal.init).sorted { $0.tokens > $1.tokens }
    }
}

private struct VibeUsageReport {
    let providers: [UsageProviderReport]

    init?(payload: JSONValue) {
        guard let root = payload.objectValue else { return nil }
        providers = [UsageAgent.claude, .codex].compactMap { agent in
            guard let report = root[agent.rawValue]?.objectValue else { return nil }
            let daily = report["daily"]?.arrayValue?.compactMap { row -> UsageDailyPoint? in
                guard let row = row.objectValue,
                      let dateText = row["date"]?.stringValue,
                      let date = Self.dayFormatter.date(from: dateText)
                else { return nil }
                return UsageDailyPoint(
                    agent: agent,
                    date: date,
                    totals: Self.totals(row),
                    models: Self.models(row)
                )
            } ?? []
            let totals = Self.totals(report["totals"]?.objectValue ?? [:])
            let currentModel = report["sessionSummary"]?.objectValue?["currentModel"]?.stringValue
                ?? daily.max(by: { $0.date < $1.date })?.models.max(by: { $0.value < $1.value })?.key
            return UsageProviderReport(agent: agent, daily: daily, allTime: totals, currentModel: currentModel)
        }
        guard !providers.isEmpty else { return nil }
    }

    func selection(for filter: UsageAgentFilter) -> VibeUsageSelection {
        switch filter {
        case .all: VibeUsageSelection(providers: providers)
        case .claude: VibeUsageSelection(providers: providers.filter { $0.agent == .claude })
        case .codex: VibeUsageSelection(providers: providers.filter { $0.agent == .codex })
        }
    }

    private static func totals(_ object: [String: JSONValue]) -> UsageTokenTotals {
        UsageTokenTotals(
            inputTokens: object["inputTokens"]?.numberValue ?? 0,
            outputTokens: object["outputTokens"]?.numberValue ?? 0,
            cacheReadTokens: object["cacheReadTokens"]?.numberValue ?? 0,
            cacheCreationTokens: object["cacheCreationTokens"]?.numberValue ?? 0,
            reasoningTokens: object["reasoningOutputTokens"]?.numberValue ?? 0,
            costUSD: object["totalCost"]?.numberValue ?? object["costUSD"]?.numberValue ?? 0
        )
    }

    private static func models(_ object: [String: JSONValue]) -> [String: Double] {
        var result: [String: Double] = [:]
        if let rows = object["modelBreakdowns"]?.arrayValue {
            for rowValue in rows {
                guard let row = rowValue.objectValue,
                      let name = row["modelName"]?.stringValue else { continue }
                result[name, default: 0] += totals(row).totalTokens
            }
        }
        if let models = object["models"]?.objectValue {
            for (name, value) in models {
                guard let row = value.objectValue else { continue }
                result[name, default: 0] += row["totalTokens"]?.numberValue ?? totals(row).totalTokens
            }
        }
        return result
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }
}

private func formatTokens(_ value: Double) -> String {
    let absolute = abs(value)
    switch absolute {
    case 1_000_000_000...: return String(format: "%.2fB", value / 1_000_000_000)
    case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
    case 1_000...: return String(format: "%.1fK", value / 1_000)
    default: return String(format: "%.0f", value)
    }
}

private func formatUSD(_ value: Double) -> String {
    if value >= 1_000 { return String(format: "$%.2fK", value / 1_000) }
    return String(format: "$%.2f", value)
}

private func formatPercent(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
}
