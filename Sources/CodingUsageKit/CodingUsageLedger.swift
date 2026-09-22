import Foundation
import Darwin

/// Persistent source/account/day snapshots. A failed scan never replaces a successful history.
/// Cross-process locking protects concurrent usage and session refreshes from lost updates.
public struct CodingUsageLedger: Sendable {
    private struct SourceState: Codable, Sendable {
        var days: [String: CodingUsageDayRecord] = [:]
        var sessions: [String: CodingUsageSessionRecord] = [:]
        var completeDates: Set<String> = []
        var status = CodingUsageStatus(state: .unavailable)
    }
    private struct DiskState: Codable, Sendable {
        var version = 1
        var timezone = "Asia/Shanghai"
        var accounts: [String: [String: SourceState]] = [:]
        var selectedAccounts: [String: String] = [:]
    }
    public let url: URL
    private var disk: DiskState

    public init(url: URL) throws {
        self.url = url
        self.disk = try Self.read(url)
    }

    public mutating func apply(_ report: CodingUsageSourceReport) throws {
        guard !report.sourceID.isEmpty else { throw CodingUsageError.invalid("来源标识为空") }
        if let start = report.coverageStart, CodingUsageDates.parseDay(start) == nil {
            throw CodingUsageError.invalid("来源历史起始日期无效")
        }
        if let end = report.coverageEnd, CodingUsageDates.parseDay(end) == nil {
            throw CodingUsageError.invalid("来源历史结束日期无效")
        }
        if let start = report.coverageStart, let end = report.coverageEnd, start > end {
            throw CodingUsageError.invalid("来源历史日期倒置")
        }
        var rows: [String: CodingUsageDayRecord] = [:]
        for day in report.days {
            try Self.validate(day)
            if let previous = rows[day.date], previous != day {
                throw CodingUsageError.invalid("同一来源有重复且冲突的日桶")
            }
            rows[day.date] = day
        }
        guard report.completeDates.allSatisfy({ CodingUsageDates.parseDay($0) != nil }) else {
            throw CodingUsageError.invalid("完整日桶包含无效日期")
        }
        let freshRows = rows
        try mutate { disk in
            let account = report.accountID ?? "local"
            var source = disk.accounts[report.sourceID]?[account] ?? SourceState()
            if let previousTime = source.status.collectedAt.flatMap(CodingUsageDates.parseInstant),
               report.collectedAt < previousTime { return }
            var problems: [String] = report.diagnosticError.map { [$0] } ?? []
            let previousNonzero = source.days.values.filter { $0.totalTokens > 0 }
            if let oldStart = previousNonzero.map(\.date).min(),
               report.coverageStart == nil || report.coverageStart! > oldStart {
                problems.append("历史起始范围缩短，已保留旧日桶")
            }
            if let oldEnd = previousNonzero.map(\.date).max(),
               report.coverageEnd == nil || report.coverageEnd! < oldEnd {
                problems.append("历史结束范围缩短，已保留旧日桶")
            }
            let missing = previousNonzero.filter {
                freshRows[$0.date] == nil && !(report.authoritative && report.completeDates.contains($0.date))
            }
            if !missing.isEmpty { problems.append("\(missing.count) 个既有活动日未返回，已保留") }
            for (date, row) in freshRows {
                if let previous = source.days[date], !report.authoritative,
                   row.totalTokens < previous.totalTokens {
                    problems.append("非完整日桶出现下调，已保留旧值")
                    continue
                }
                source.days[date] = row
            }
            if report.authoritative {
                for date in report.completeDates where freshRows[date] == nil {
                    source.days[date] = CodingUsageDayRecord(date: date, apiEquivalentCostUSD: 0)
                }
                source.completeDates.formUnion(report.completeDates)
                source.completeDates.formUnion(freshRows.keys)
                let scannedToday = CodingUsageDates.day(report.collectedAt)
                if report.coverageEnd == scannedToday, source.days[scannedToday] == nil {
                    source.days[scannedToday] = CodingUsageDayRecord(date: scannedToday, apiEquivalentCostUSD: 0)
                    source.completeDates.insert(scannedToday)
                }
            }
            Self.mergeSessions(report.sessions, into: &source)
            source.status = CodingUsageStatus(
                state: problems.isEmpty ? .ok : .error,
                collectedAt: CodingUsageDates.instant(report.collectedAt),
                error: problems.isEmpty ? nil : Array(Set(problems)).sorted().joined(separator: "；"),
                coverageStart: source.days.keys.min(),
                coverageEnd: [source.days.keys.max(), report.coverageEnd].compactMap { $0 }.max(),
                precision: report.precision,
                costComplete: report.costComplete && problems.isEmpty
            )
            disk.accounts[report.sourceID, default: [:]][account] = source
            disk.selectedAccounts[report.sourceID] = account
        }
    }

    public mutating func recordFailure(sourceID: String, error: String, unavailable: Bool = false) throws {
        try mutate { disk in
            let account = disk.selectedAccounts[sourceID] ?? "local"
            var source = disk.accounts[sourceID]?[account] ?? SourceState()
            source.status.state = unavailable ? .unavailable : .error
            source.status.error = error
            disk.accounts[sourceID, default: [:]][account] = source
            disk.selectedAccounts[sourceID] = account
        }
    }

    /// A quick session scan has no authority to change historical usage or its health status.
    public mutating func applySessions(sourceID: String, sessions: [CodingUsageSessionRecord], accountID: String? = nil) throws {
        try mutate { disk in
            let account = accountID ?? disk.selectedAccounts[sourceID] ?? "local"
            var source = disk.accounts[sourceID]?[account] ?? SourceState()
            Self.mergeSessions(sessions, into: &source)
            disk.accounts[sourceID, default: [:]][account] = source
            disk.selectedAccounts[sourceID] = account
        }
    }

    public func snapshot(
        at now: Date = Date(),
        agents specs: [CodingUsageAgentSpec] = CodingUsageAgentSpec.defaults,
        omitting omittedSourceIDs: Set<String> = []
    ) throws -> CodingUsageSnapshot {
        var allSpecs = specs
        for id in disk.selectedAccounts.keys.sorted() where !allSpecs.contains(where: { $0.id == id }) && !omittedSourceIDs.contains(id) {
            allSpecs.append(CodingUsageAgentSpec(id: id, label: id, icon: id))
        }
        let today = CodingUsageDates.day(now)
        var totals = CodingUsageTotalsPayload()
        var activeDates = Set<String>()
        var combinedDays: [String: Int64] = [:]
        var dayModels: [String: [String: Int64]] = [:]
        var allModels: [String: Int64] = [:]
        var agentPayloads: [CodingUsageAgentPayload] = []
        var nowPayloads: [CodingUsageNowAgentPayload] = []
        var lastCollection: String?
        for spec in allSpecs where !omittedSourceIDs.contains(spec.id) {
            let source = state(for: spec.id)
            var models: [String: Int64] = [:]
            // A reproducible order matters for floating-point cost sums and change detection.
            for date in source.days.keys.sorted() {
                let row = source.days[date]!
                totals.inputTokens = try Self.add(totals.inputTokens, row.inputTokens)
                totals.outputTokens = try Self.add(totals.outputTokens, row.outputTokens)
                totals.cacheReadTokens = try Self.add(totals.cacheReadTokens, row.cacheReadTokens)
                totals.cacheCreationTokens = try Self.add(totals.cacheCreationTokens, row.cacheCreationTokens)
                totals.reasoningTokens = try Self.add(totals.reasoningTokens, row.reasoningTokens)
                totals.totalTokens = try Self.add(totals.totalTokens, row.totalTokens)
                totals.apiEquivalentCostUSD += row.apiEquivalentCostUSD ?? 0
                guard totals.apiEquivalentCostUSD.isFinite else { throw CodingUsageError.invalid("费用总和溢出") }
                if row.totalTokens > 0 { activeDates.insert(row.date) }
                combinedDays[row.date] = try Self.add(combinedDays[row.date, default: 0], row.totalTokens)
                for (model, value) in row.models {
                    let name = CodingUsageModelIdentity.canonical(model)
                    models[name] = try Self.add(models[name, default: 0], value)
                    if Self.visibleModel(name) {
                        allModels[name] = try Self.add(allModels[name, default: 0], value)
                        dayModels[row.date, default: [:]][name] = try Self.add(dayModels[row.date]?[name] ?? 0, value)
                    }
                }
            }
            totals.sessionCount += source.sessions.count
            // Unavailable configured sources and missing prices cannot be called complete.
            totals.costComplete = totals.costComplete && source.status.costComplete && source.status.state == .ok
            let ordered = source.sessions.values.sorted {
                let left = $0.lastActivityAt ?? .distantPast, right = $1.lastActivityAt ?? .distantPast
                return left == right ? $0.identityHash < $1.identityHash : left > right
            }
            let lastActivity = ordered.first?.lastActivityAt
            let currentModel = ordered.first?.currentModel
                .map(CodingUsageModelIdentity.canonical)
                .flatMap { Self.visibleModel($0) ? $0 : nil }
            let fallbackModel = source.days.keys.sorted().reversed().lazy.compactMap {
                Self.ranked(source.days[$0]?.models ?? [:]).first?.model
            }.first
            let todayRow: CodingUsageDayPayload?
            if let row = source.days[today] { todayRow = CodingUsageDayPayload(row) }
            else if source.completeDates.contains(today) {
                todayRow = CodingUsageDayPayload(.init(date: today, apiEquivalentCostUSD: 0))
            }
            else { todayRow = nil }
            agentPayloads.append(CodingUsageAgentPayload(
                id: spec.id, label: spec.label, icon: spec.icon,
                models: models.keys.filter { $0 != "unknown" }.sorted(),
                currentModel: currentModel ?? fallbackModel, topModel: Self.ranked(models).first?.model,
                today: todayRow, usageStatus: source.status
            ))
            if let collectedAt = source.status.collectedAt, collectedAt > (lastCollection ?? "") {
                lastCollection = collectedAt
            }
            let age = lastActivity.map { now.timeIntervalSince($0) }
            nowPayloads.append(CodingUsageNowAgentPayload(
                id: spec.id, currentModel: currentModel,
                lastActivityAt: lastActivity.map(CodingUsageDates.instant),
                active: age.map { $0 >= 0 && $0 <= 300 } ?? false
            ))
        }
        totals.activeDays = activeDates.count
        let calendar = CodingUsageDates.calendar
        let start = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: start)
        let origin = calendar.date(byAdding: .day, value: -(52 * 7 + weekday - 1), to: start)!
        var yearDays: [Int64] = []
        var yearParts: [(Int, [CodingUsageModelPayload])] = []
        var yearModelNames = Set<String>()
        for offset in 0..<371 {
            let date = CodingUsageDates.day(calendar.date(byAdding: .day, value: offset, to: origin)!)
            let value = date <= today ? combinedDays[date, default: 0] : 0
            yearDays.append(value)
            let parts = Array(Self.ranked(dayModels[date] ?? [:]).prefix(5))
            if value > 0 && !parts.isEmpty {
                yearParts.append((offset, parts))
                yearModelNames.formUnion(parts.map(\.model))
            }
        }
        let yearModels = yearModelNames.sorted()
        let indexes = Dictionary(uniqueKeysWithValues: yearModels.enumerated().map { ($0.element, Int64($0.offset)) })
        let mix = yearParts.map { offset, parts in
            [Int64(offset)] + parts.flatMap { [indexes[$0.model]!, $0.tokens] }
        }
        return CodingUsageSnapshot(
            usage: CodingUsagePayload(agents: agentPayloads, totals: totals, topModels: Array(Self.ranked(allModels).prefix(3)),
                                      collectedAt: lastCollection ?? CodingUsageDates.instant(now),
                                      omittedSources: omittedSourceIDs.sorted()),
            now: CodingUsageNowPayload(agents: nowPayloads),
            year: CodingUsageYearPayload(origin: CodingUsageDates.day(origin), days: yearDays, models: yearModels, mix: mix)
        )
    }

    private func state(for sourceID: String) -> SourceState {
        disk.accounts[sourceID]?[disk.selectedAccounts[sourceID] ?? "local"] ?? SourceState()
    }
    private static func mergeSessions(_ sessions: [CodingUsageSessionRecord], into source: inout SourceState) {
        for session in sessions where !session.identityHash.isEmpty {
            let previous = source.sessions[session.identityHash]
            if previous == nil || (session.lastActivityAt ?? .distantPast) >= (previous?.lastActivityAt ?? .distantPast) {
                source.sessions[session.identityHash] = session
            }
        }
    }
    static func visibleModel(_ value: String) -> Bool {
        !value.isEmpty && value != "unknown" && value != "codex-auto-review"
    }
    private static func ranked(_ values: [String: Int64]) -> [CodingUsageModelPayload] {
        var merged: [String: Int64] = [:]
        for (model, value) in values where value > 0 {
            let name = CodingUsageModelIdentity.canonical(model)
            guard visibleModel(name), let next = try? add(merged[name, default: 0], value) else { continue }
            merged[name] = next
        }
        return merged
            .map { CodingUsageModelPayload(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens == $1.tokens ? $0.model < $1.model : $0.tokens > $1.tokens }
    }
    static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, value <= 9_007_199_254_740_991 else { throw CodingUsageError.invalid("Token 数量超出 JSON 安全整数范围") }
        return value
    }
    static func validate(_ row: CodingUsageDayRecord) throws {
        guard CodingUsageDates.parseDay(row.date) != nil else { throw CodingUsageError.invalid("日桶日期无效") }
        let values = [row.inputTokens, row.outputTokens, row.cacheReadTokens, row.cacheCreationTokens, row.reasoningTokens, row.totalTokens, row.unclassifiedTokens ?? 0]
        guard values.allSatisfy({ $0 >= 0 && $0 <= 9_007_199_254_740_991 }), row.reasoningTokens <= row.outputTokens else {
            throw CodingUsageError.invalid("Token 分列无效或推理 token 超过输出")
        }
        let sum = try [row.inputTokens, row.outputTokens, row.cacheReadTokens, row.cacheCreationTokens, row.unclassifiedTokens ?? 0].reduce(Int64(0), add)
        guard sum == row.totalTokens else { throw CodingUsageError.invalid("Token 总量与分列不一致") }
        if let cost = row.apiEquivalentCostUSD, !cost.isFinite || cost < 0 { throw CodingUsageError.invalid("费用无效") }
        guard row.models.values.allSatisfy({ $0 >= 0 }), try row.models.values.reduce(Int64(0), add) <= row.totalTokens else {
            throw CodingUsageError.invalid("模型拆分超过日总量")
        }
    }
    private static func read(_ url: URL) throws -> DiskState {
        guard FileManager.default.fileExists(atPath: url.path) else { return DiskState() }
        do {
            let decoded = try JSONDecoder().decode(DiskState.self, from: Data(contentsOf: url))
            guard decoded.version == 1, decoded.timezone == "Asia/Shanghai" else {
                throw CodingUsageError.persistence("用量账本版本或时区不匹配")
            }
            for accounts in decoded.accounts.values {
                for source in accounts.values { for row in source.days.values { try validate(row) } }
            }
            return decoded
        } catch { throw CodingUsageError.persistence("用量账本读取失败，保留原文件：\(error.localizedDescription)") }
    }
    private mutating func mutate(_ body: (inout DiskState) throws -> Void) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path + ".lock", O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw CodingUsageError.persistence("无法打开用量账本锁") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CodingUsageError.persistence("无法锁定用量账本") }
        defer { _ = flock(descriptor, LOCK_UN) }
        var fresh = try Self.read(url)
        try body(&fresh)
        let previous = disk
        disk = fresh
        do {
            _ = try snapshot()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(fresh).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            disk = previous
            throw error
        }
    }
}
