import Foundation
import Darwin

/// Persistent source/account/day snapshots. A failed scan never replaces a successful history.
/// Cross-process locking protects concurrent usage and session refreshes from lost updates.
///
/// 上报只出本机观测到的原始事实（`report`）：每个来源的完整日行、会话数、采集状态。
/// 合计、排名、「今天」、年度格子、模型隐藏名单都归站点。
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

    /**
     * 账本里还留着、但不再是本机来源的 id。Cursor 的历史由 agents-reporter 以账号来源上报，
     * 本机不再采集；旧账本里留下的 Cursor 日子原样留在盘上，不进上报也不进活动。
     */
    static let retiredSourceIDs: Set<String> = ["cursor"]

    /// 站点收的 agent id（lyjwpage shared/coding-usage.ts 的 AGENT_ID）
    static func acceptsID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9._-]{0,39}$"#, options: .regularExpression) != nil
    }

    /// 能上报的本机来源：不是退役的，id 也合站点的规矩
    static func isReported(_ id: String) -> Bool {
        !retiredSourceIDs.contains(id) && acceptsID(id)
    }

    /// 同一天最多报这么多个模型（站点的上限）；超出的是用量最小的那些，丢掉后合计仍 ≤ totalTokens
    static let reportedModelsPerDay = 64

    public init(url: URL) throws {
        self.url = url
        self.disk = try Self.read(url)
    }

    /// 账本里的本机来源（不含退役的），按 id 排序
    public var sourceIDs: [String] {
        disk.selectedAccounts.keys.filter { !Self.retiredSourceIDs.contains($0) }.sorted()
    }

    /// 本机来源里 id 不合站点规矩、因此不上报的那几个。一个坏 id 会让站点拒掉整个模块，所以宁可不报它
    public var unreportedSourceIDs: [String] {
        sourceIDs.filter { !Self.acceptsID($0) }
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
                // 确认过没用的日子：一个 token 都没有，自然没有估不到价的请求
                for date in report.completeDates where freshRows[date] == nil {
                    source.days[date] = CodingUsageDayRecord(date: date, apiEquivalentCostUSD: 0, costComplete: true)
                }
                source.completeDates.formUnion(report.completeDates)
                source.completeDates.formUnion(freshRows.keys)
                let scannedToday = CodingUsageDates.day(report.collectedAt)
                if report.coverageEnd == scannedToday, source.days[scannedToday] == nil {
                    source.days[scannedToday] = CodingUsageDayRecord(date: scannedToday, apiEquivalentCostUSD: 0, costComplete: true)
                    source.completeDates.insert(scannedToday)
                }
            }
            Self.mergeSessions(report.sessions, into: &source)
            // 走到这里就是采到了：缺口只是提醒，不算失败
            source.status = CodingUsageStatus(
                state: .ok,
                collectedAt: CodingUsageDates.instant(report.collectedAt),
                warning: problems.isEmpty ? nil : Array(Set(problems)).sorted().joined(separator: "；"),
                coverageStart: source.days.keys.min(),
                coverageEnd: [source.days.keys.max(), report.coverageEnd].compactMap { $0 }.max(),
                precision: .measured,
                costComplete: problems.isEmpty && freshRows.values.allSatisfy(Self.costComplete)
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
            // 上一轮的缺口提醒说的是那份数据，这一轮什么都没拿到，不再挂着
            source.status.warning = nil
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

    /**
     * `modules.codingUsage`：`only` 限定报哪几个来源（只刷了 Claude 的那一轮只报 Claude），nil 是全部。
     *
     * 采到过的来源（`ok`）带完整日行；这一轮失败但从前采到过的报 `error`，不带日行，站点留着
     * 已有的日子。从没采到过用量的来源不报 —— 那是这台 Mac 上压根没有它，报一行 error 只是噪音。
     */
    public func report(agents only: Set<String>? = nil) throws -> CodingUsageReport {
        var agents: [CodingUsageAgent] = []
        for id in sourceIDs where Self.acceptsID(id) && (only?.contains(id) ?? true) {
            if let agent = try Self.agent(id: id, source: state(for: id)) { agents.append(agent) }
        }
        return CodingUsageReport(agents: agents)
    }

    /// 各本机来源会话记录里最近的一次活动（`ccusage session` 给的），没有带时刻的会话就不在里面
    public func latestSessionActivity() -> [String: CodingActivitySample] {
        var latest: [String: CodingActivitySample] = [:]
        for id in sourceIDs {
            var newest: (at: Date, session: CodingUsageSessionRecord)?
            for session in state(for: id).sessions.values {
                guard let at = session.lastActivityAt else { continue }
                // 同一时刻按 identityHash 取，结果和字典顺序无关
                if let current = newest, at < current.at || (at == current.at && session.identityHash > current.session.identityHash) {
                    continue
                }
                newest = (at, session)
            }
            if let newest { latest[id] = CodingActivitySample(at: newest.at, model: newest.session.currentModel) }
        }
        return latest
    }

    private func state(for sourceID: String) -> SourceState {
        disk.accounts[sourceID]?[disk.selectedAccounts[sourceID] ?? "local"] ?? SourceState()
    }

    private static func agent(id: String, source: SourceState) throws -> CodingUsageAgent? {
        let collectedAt = source.status.collectedAt
            .flatMap(CodingUsageDates.parseInstant)
            .map(CodingUsageDates.milliseconds)
        if source.status.state == .ok, let collectedAt {
            return CodingUsageAgent(
                id: id, state: .ok, collectedAt: collectedAt, error: nil, warning: source.status.warning,
                sessionCount: source.sessions.count,
                days: try source.days.keys.sorted().map { try day(source.days[$0]!) }
            )
        }
        guard collectedAt != nil || !source.days.isEmpty else { return nil }
        return CodingUsageAgent(
            id: id, state: .error, collectedAt: collectedAt, error: source.status.error, warning: nil,
            sessionCount: source.sessions.count, days: nil
        )
    }

    /// 日行换成上报的形状：模型名过 `CodingUsageModelIdentity.reported`（占位符映射后同名的合并），
    /// 零用量的模型不报；`totalTokens` 原样，含来源没分列的那部分
    static func day(_ record: CodingUsageDayRecord) throws -> CodingUsageDay {
        var merged: [String: Int64] = [:]
        for (raw, tokens) in record.models where tokens > 0 {
            let name = CodingUsageModelIdentity.reported(raw)
            merged[name] = try add(merged[name, default: 0], tokens)
        }
        let models = merged
            .map { CodingUsageModelTokens(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens == $1.tokens ? $0.model < $1.model : $0.tokens > $1.tokens }
        return CodingUsageDay(
            date: record.date,
            inputTokens: record.inputTokens,
            outputTokens: record.outputTokens,
            cacheReadTokens: record.cacheReadTokens,
            cacheCreationTokens: record.cacheCreationTokens,
            reasoningTokens: record.reasoningTokens,
            totalTokens: record.totalTokens,
            apiEquivalentCostUSD: record.apiEquivalentCostUSD ?? 0,
            costComplete: costComplete(record),
            models: Array(models.prefix(reportedModelsPerDay))
        )
    }

    /// 旧账本的日行没记这一格：没有 token 的那天谈不上漏估，有 token 的按没估全算
    static func costComplete(_ record: CodingUsageDayRecord) -> Bool {
        record.costComplete ?? (record.totalTokens == 0)
    }

    private static func mergeSessions(_ sessions: [CodingUsageSessionRecord], into source: inout SourceState) {
        for session in sessions where !session.identityHash.isEmpty {
            let previous = source.sessions[session.identityHash]
            if previous == nil || (session.lastActivityAt ?? .distantPast) >= (previous?.lastActivityAt ?? .distantPast) {
                source.sessions[session.identityHash] = session
            }
        }
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
            // 写盘前先按上报的口径出一遍：出不了报告的账本（比如模型合并后溢出）不落盘
            _ = try report()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(fresh).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            disk = previous
            throw error
        }
    }
}
