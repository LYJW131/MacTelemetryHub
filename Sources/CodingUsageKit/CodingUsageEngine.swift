import Foundation

/// 一轮用量采集的结果：上报的那一份，外加给界面看的问题（采集失败的来源、没法上报的来源）
public struct CodingUsageRefresh: Sendable {
    public var report: CodingUsageReport
    public var problems: [String]
}

/// 一轮会话扫描的结果：此刻的活动、五分钟桶，外加 `ccusage session` 的失败
public struct CodingSessionsRefresh: Sendable {
    public var activity: CodingActivityReport
    public var buckets: CodingTokenBucketReport
    public var problems: [String]
}

/// One collector owns every usage source. The app and the diagnostic CLI use this same path.
public actor CodingUsageEngine {
    public let ledgerURL: URL
    public let home: URL
    private var tokenScanner = CodingTokenScanner()
    /// `ccusage session` for sources the token scanner does not read. Once per this interval,
    /// its errors are kept between runs so the status does not flicker.
    public static let ccusageSessionInterval: TimeInterval = 300
    /// 活动时刻最多比采集时刻晚这么多（站点按收到时刻 + 60 秒卡）；更晚的是日志里写错的时间，不报
    static let activityFutureSlack: TimeInterval = 60
    private var lastCcusageSessions: Date?
    private var ccusageSessionErrors: [String] = []
    /// `only` 为 nil 是完整刷新；完整那一轮也覆盖只刷几家的请求，反过来不行
    private var inFlight: (id: UUID, only: Set<String>?, task: Task<CodingUsageRefresh, Error>)?

    public init(ledgerURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.ledgerURL = ledgerURL
        self.home = home
    }

    public static var defaultLedgerURL: URL {
        if let path = ProcessInfo.processInfo.environment["CODING_USAGE_LEDGER_PATH"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacTelemetryHub/CodingUsage/history.json")
    }

    /**
     * 刷新用量账本并出 `codingUsage`。`only` 限定这一轮只采哪几家，报告也只带它们；其余来源在
     * 账本里原样留着（日桶、状态、采集时刻都不动）。nil 是全部来源的完整刷新。
     */
    public func refresh(
        executableURL: URL, environment: [String: String] = [:], offline: Bool = false,
        only: Set<String>? = nil, at now: Date = Date()
    ) async throws -> CodingUsageRefresh {
        if let inFlight, !inFlight.task.isCancelled {
            if inFlight.only == nil || inFlight.only == only { return try await Self.value(of: inFlight.task) }
            // 正在跑的只刷了几家，这次要的更多：等它跑完再开自己那一轮
            _ = try? await Self.value(of: inFlight.task)
        }
        let ledgerURL = self.ledgerURL
        let task = Task {
            let collector = CcusageCollector(executableURL: executableURL, environment: environment,
                                            sourceIDs: try Self.knownSources(CodingUsageLedger(url: ledgerURL)),
                                            offline: offline)
            let results = await collector.collect(at: now, only: only)
            try Task.checkCancellation()
            var ledger = try CodingUsageLedger(url: ledgerURL)
            for result in results {
                try Task.checkCancellation()
                switch result {
                case let .success(report): try ledger.apply(report)
                case let .failure(sourceID, message, unavailable):
                    try ledger.recordFailure(sourceID: sourceID, error: message, unavailable: unavailable)
                }
            }
            return try Self.usage(ledger, only: only)
        }
        let id = UUID()
        inFlight = (id, only, task)
        defer { if inFlight?.id == id { inFlight = nil } }
        return try await Self.value(of: task)
    }

    /**
     * The one-minute “正在使用” refresh.
     *
     * Codex and Claude come from the incremental log scanner, which only reads bytes appended
     * since the last scan and also yields the five-minute token buckets. Every other local
     * source still needs a `ccusage session` run, which rereads its whole history, so that runs
     * at most every `ccusageSessionInterval` unless `forceCcusage` is set.
     */
    public func refreshSessions(
        executableURL: URL, environment: [String: String] = [:], forceCcusage: Bool = false,
        at now: Date = Date()
    ) async throws -> CodingSessionsRefresh {
        let buckets = try tokenScanner.scan(home: home, at: now)
        var ledger = try CodingUsageLedger(url: ledgerURL)
        let due = forceCcusage || lastCcusageSessions.map { now.timeIntervalSince($0) >= Self.ccusageSessionInterval } ?? true
        if due {
            // Session reports need no price refresh.
            let results = await CcusageCollector(executableURL: executableURL, environment: environment,
                                                sourceIDs: Self.knownSources(ledger), offline: true)
                .collectSessions(excluding: Set(CodingTokenScanner.sourceIDs))
            try Task.checkCancellation()
            ledger = try CodingUsageLedger(url: ledgerURL)
            var errors: [String] = []
            for result in results {
                try Task.checkCancellation()
                switch result {
                case let .success(sourceID, sessions): try ledger.applySessions(sourceID: sourceID, sessions: sessions)
                case let .failure(_, message, _): errors.append(message)
                }
            }
            lastCcusageSessions = now
            ccusageSessionErrors = errors
        }
        let activity = Self.activity(sources: ledger.sourceIDs, recorded: ledger.latestSessionActivity(),
                                     scanned: tokenScanner.latestActivity, at: now)
        return CodingSessionsRefresh(activity: activity, buckets: buckets, problems: ccusageSessionErrors)
    }

    /// 只读账本，不采集
    public func usage() throws -> CodingUsageRefresh {
        try Self.usage(CodingUsageLedger(url: ledgerURL), only: nil)
    }

    /**
     * `codingActivity`：每个本机来源最近一条用量事件的时刻和模型。
     *
     * Codex、Claude 以扫描器读到的为准，比账本里 `ccusage session` 记下的新才换（同一时刻以账本为准）；
     * 其余来源只有账本那一份。模型跟着被选中的那条事件走，它没带模型才用另一条的。
     * 在不在跑、要不要亮灯由站点按时刻现算，这里不判。
     */
    static func activity(
        sources: [String], recorded: [String: CodingActivitySample],
        scanned: [String: CodingActivitySample], at now: Date
    ) -> CodingActivityReport {
        let latestAllowed = now.addingTimeInterval(activityFutureSlack)
        let ids = Set(sources).union(scanned.keys).filter(CodingUsageLedger.isReported).sorted()
        let agents = ids.map { id -> CodingActivityAgent in
            let candidates = [recorded[id], scanned[id]].compactMap { $0 }.filter { $0.at <= latestAllowed }
            guard let first = candidates.first else {
                return CodingActivityAgent(id: id, lastActivityAt: nil, model: nil)
            }
            let chosen = candidates.dropFirst().first { $0.at > first.at } ?? first
            let model = chosen.model ?? candidates.first { $0 != chosen }?.model
            return CodingActivityAgent(
                id: id, lastActivityAt: CodingUsageDates.milliseconds(chosen.at),
                model: model.map(CodingUsageModelIdentity.reported)
            )
        }
        return CodingActivityReport(collectedAt: CodingUsageDates.milliseconds(now), agents: agents)
    }

    /// 发现之外要问的来源：默认那几家，加上账本里已经有的本机来源
    private static func knownSources(_ ledger: CodingUsageLedger) -> [String] {
        Set(CcusageCollector.defaultSourceIDs).union(ledger.sourceIDs).sorted()
    }

    private static func usage(_ ledger: CodingUsageLedger, only: Set<String>?) throws -> CodingUsageRefresh {
        let report = try ledger.report(agents: only)
        var problems = report.agents.compactMap { agent in
            agent.state == .error ? "\(agent.id)：\(agent.error ?? "这一轮没有采到用量")" : nil
        }
        problems += ledger.unreportedSourceIDs
            .filter { only?.contains($0) ?? true }
            .map { "\($0)：来源名不合上报契约，没有上报" }
        return CodingUsageRefresh(report: report, problems: problems)
    }

    private static func value(of task: Task<CodingUsageRefresh, Error>) async throws -> CodingUsageRefresh {
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
