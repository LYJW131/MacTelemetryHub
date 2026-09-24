import Foundation

/// One collector owns every usage source. The app and the diagnostic CLI use this same path.
public actor CodingUsageEngine {
    public let ledgerURL: URL
    public let home: URL
    private var tokenScanner = CodingTokenScanner()
    /// `ccusage session` for sources the token scanner does not read. Once per this interval,
    /// its errors are kept between runs so the status does not flicker.
    public static let ccusageSessionInterval: TimeInterval = 300
    private var lastCcusageSessions: Date?
    private var ccusageSessionErrors: [String] = []
    /// `only` 为 nil 是完整刷新；完整那一轮也覆盖只刷几家的请求，反过来不行
    private var inFlight: (id: UUID, only: Set<String>?, task: Task<CodingUsageSnapshot, Error>)?

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
     * 刷新用量账本并出快照。`only` 限定这一轮只采哪几家，其余来源在账本里原样留着
     * （日桶、状态、采集时刻都不动）；nil 是全部来源的完整刷新。
     */
    public func refresh(
        executableURL: URL, environment: [String: String] = [:], offline: Bool = false,
        includeCursor: Bool = true, omitting: Set<String> = [], only: Set<String>? = nil, at now: Date = Date()
    ) async throws -> CodingUsageSnapshot {
        if let inFlight, !inFlight.task.isCancelled {
            if inFlight.only == nil || inFlight.only == only { return try await Self.value(of: inFlight.task) }
            // 正在跑的只刷了几家，这次要的更多：等它跑完再开自己那一轮
            _ = try? await Self.value(of: inFlight.task)
        }
        let ledgerURL = self.ledgerURL
        let home = self.home
        let task = Task {
            let knownSources = try CodingUsageLedger(url: ledgerURL).snapshot().usage.agents.map(\.id)
                .filter { $0 != "cursor" }
            let collector = CcusageCollector(executableURL: executableURL, environment: environment,
                                            sourceIDs: knownSources, offline: offline)
            async let local = collector.collect(at: now, only: only)
            let results: [CodingUsageSourceResult]
            if includeCursor, only?.contains("cursor") ?? true {
                async let cloud = Self.collectCursor(home: home, enabled: true, at: now)
                results = await local + [cloud]
            } else {
                results = await local
            }
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
            return try ledger.snapshot(at: now, omitting: omitting)
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
     * since the last scan and also yields the five-minute token windows. Every other local
     * source still needs a `ccusage session` run, which rereads its whole history, so that runs
     * at most every `ccusageSessionInterval` unless `forceCcusage` is set.
     */
    public func refreshSessions(
        executableURL: URL, environment: [String: String] = [:], forceCcusage: Bool = false,
        at now: Date = Date()
    ) async throws -> (snapshot: CodingUsageSnapshot, errors: [String]) {
        let tokenUsage = try tokenScanner.scan(home: home, at: now)
        var ledger = try CodingUsageLedger(url: ledgerURL)
        let due = forceCcusage || lastCcusageSessions.map { now.timeIntervalSince($0) >= Self.ccusageSessionInterval } ?? true
        if due {
            // Session reports need no price refresh. They never trigger Cursor cloud requests.
            let knownSources = try ledger.snapshot().usage.agents.map(\.id).filter { $0 != "cursor" }
            let results = await CcusageCollector(executableURL: executableURL, environment: environment,
                                                sourceIDs: knownSources, offline: true)
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
        let saved = try ledger.snapshot(at: now)
        var current = Self.overlay(saved.now, activity: tokenScanner.latestActivity, at: now)
        current.tokenUsage = tokenUsage
        return (CodingUsageSnapshot(usage: saved.usage, now: current, year: saved.year), ccusageSessionErrors)
    }

    /// Scanned activity wins when it is newer than what the ledger's session list says.
    /// The ledger still carries these sources' sessions from the ten-minute usage refresh.
    static func overlay(
        _ payload: CodingUsageNowPayload, activity: [String: CodingTokenActivity], at now: Date
    ) -> CodingUsageNowPayload {
        let agents = payload.agents.map { agent -> CodingUsageNowAgentPayload in
            guard let seen = activity[agent.id] else { return agent }
            let recorded = agent.lastActivityAt.flatMap(CodingUsageDates.parseInstant)
            if let recorded, recorded >= seen.at { return agent }
            let model = seen.model.map(CodingUsageModelIdentity.canonical)
                .flatMap { CodingUsageLedger.visibleModel($0) ? $0 : nil }
            let age = now.timeIntervalSince(seen.at)
            return CodingUsageNowAgentPayload(
                id: agent.id, currentModel: model ?? agent.currentModel,
                lastActivityAt: CodingUsageDates.instant(seen.at),
                active: age >= 0 && age <= 300
            )
        }
        return CodingUsageNowPayload(agents: agents, tokenUsage: payload.tokenUsage)
    }

    public func snapshot(omitting: Set<String> = [], at now: Date = Date()) throws -> CodingUsageSnapshot {
        try CodingUsageLedger(url: ledgerURL).snapshot(at: now, omitting: omitting)
    }

    private static func value(of task: Task<CodingUsageSnapshot, Error>) async throws -> CodingUsageSnapshot {
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private static func collectCursor(home: URL, enabled: Bool, at now: Date) async -> CodingUsageSourceResult {
        guard enabled else {
            return .failure(sourceID: "cursor", message: "本次诊断未启用 Cursor 云端采集", unavailable: true)
        }
        do {
            return .success(try sourceReport(await CursorUsageClient().fetchLocalHistory(home: home, until: now)))
        } catch {
            return .failure(sourceID: "cursor", message: error.localizedDescription,
                            unavailable: (error as? CursorUsageError) == .notLoggedIn)
        }
    }

    /// A complete cloud query replaces only the days it actually returned. It cannot prove retention
    /// outside those days, so absent historical dates remain in the ledger and surface a coverage error.
    public static func sourceReport(_ report: CursorUsageReport) throws -> CodingUsageSourceReport {
        guard report.isComplete else { throw CursorUsageError.incompletePagination }
        var days: [String: CodingUsageDayRecord] = [:]
        var costComplete = report.tokenCountsComplete
        for event in report.records {
            let day = CodingUsageDates.day(event.date)
            var row = days[day] ?? CodingUsageDayRecord(date: day, apiEquivalentCostUSD: 0)
            row.inputTokens = try add(row.inputTokens, event.inputTokens)
            row.outputTokens = try add(row.outputTokens, event.outputTokens)
            row.cacheReadTokens = try add(row.cacheReadTokens, event.cacheReadTokens)
            row.cacheCreationTokens = try add(row.cacheCreationTokens, event.cacheCreationTokens)
            row.totalTokens = try add(row.totalTokens, event.totalTokens)
            row.models[event.model] = try add(row.models[event.model, default: 0], event.totalTokens)
            if let cost = CodingUsagePricing.estimate(
                model: event.model, inputTokens: event.inputTokens, outputTokens: event.outputTokens,
                cacheReadTokens: event.cacheReadTokens, cacheCreationTokens: event.cacheCreationTokens, at: event.date
            ) {
                row.apiEquivalentCostUSD = (row.apiEquivalentCostUSD ?? 0) + cost
            } else { costComplete = false }
            days[day] = row
        }
        let today = CodingUsageDates.day(report.requestedEnd)
        return CodingUsageSourceReport(
            sourceID: "cursor", accountID: report.accountHash, days: days.values.sorted { $0.date < $1.date },
            collectedAt: report.fetchedAt, coverageStart: report.earliestRecordAt.map(CodingUsageDates.day),
            coverageEnd: today, precision: .measured, costComplete: costComplete,
            completeDates: Set(days.keys), authoritative: true,
            diagnosticError: report.tokenCountsComplete ? nil : "\(report.records.filter { !$0.tokenCountsAvailable }.count) 条历史请求未提供 token，显示已计量用量"
        )
    }

    private static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard lhs >= 0, rhs >= 0, !overflow else { throw CodingUsageError.invalid("Cursor token 合计溢出") }
        return value
    }
}
