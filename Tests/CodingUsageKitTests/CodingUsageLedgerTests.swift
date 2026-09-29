import Foundation
import Testing
@testable import CodingUsageKit

struct CodingUsageLedgerTests {
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coding-usage-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ledger.json")
    }
    private let now = CodingUsageDates.parseInstant("2026-09-05T04:00:00Z")!
    private var nowMs: Int64 { CodingUsageDates.milliseconds(now) }
    private func day(_ date: String, _ tokens: Int64, cost: Double? = 1, complete: Bool? = true,
                     models: [String: Int64]? = nil) -> CodingUsageDayRecord {
        CodingUsageDayRecord(date: date, inputTokens: tokens, totalTokens: tokens, apiEquivalentCostUSD: cost,
                             models: models ?? ["model-a": tokens], costComplete: complete)
    }
    private func report(_ source: String, _ days: [CodingUsageDayRecord], account: String? = nil,
                        sessions: [CodingUsageSessionRecord] = [], completeDates: Set<String> = [],
                        at collectedAt: Date? = nil) -> CodingUsageSourceReport {
        CodingUsageSourceReport(sourceID: source, accountID: account, days: days, sessions: sessions,
                                collectedAt: collectedAt ?? now, coverageStart: days.map(\.date).min(),
                                coverageEnd: "2026-09-05", completeDates: completeDates)
    }
    private func agent(_ ledger: CodingUsageLedger, _ id: String) throws -> CodingUsageAgent? {
        try ledger.report().agents.first { $0.id == id }
    }

    @Test func reportCarriesEveryLocalDayWithSessionsAndStatus() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        let session = CodingUsageSessionRecord(identityHash: String(repeating: "a", count: 64), lastActivityAt: now, currentModel: "model-a")
        let local = report("claude", [day("2026-09-05", 20), day("2026-09-03", 5)], sessions: [session, session])
        try ledger.apply(local); try ledger.apply(local)
        try ledger.apply(report("codex", [day("2026-09-04", 7)]))
        let restored = try CodingUsageLedger(url: url)
        let agents = try restored.report().agents
        #expect(agents.map(\.id) == ["claude", "codex"])
        let claude = agents[0]
        #expect(claude.state == .ok)
        #expect(claude.collectedAt == nowMs)
        #expect(claude.sessionCount == 1)
        #expect(claude.error == nil && claude.warning == nil)
        #expect(claude.days?.map(\.date) == ["2026-09-03", "2026-09-05"])
        #expect(claude.days?.last == CodingUsageDay(
            date: "2026-09-05", inputTokens: 20, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
            reasoningTokens: 0, totalTokens: 20, apiEquivalentCostUSD: 1, costComplete: true,
            models: [CodingUsageModelTokens(model: "model-a", tokens: 20)]
        ))
        // 扫描当天没有用量的来源补一行全 0：站点才知道「今天确认没用」而不是「不知道」
        let codex = try #require(agents.first { $0.id == "codex" })
        #expect(codex.days?.map(\.date) == ["2026-09-04", "2026-09-05"])
        #expect(codex.days?.last?.totalTokens == 0)
        #expect(codex.days?.last?.models.isEmpty == true)
        #expect(codex.days?.last?.costComplete == true)
    }

    @Test func wireShapeUsesEpochMillisecondsAndOmitsNil() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("claude", [day("2026-09-05", 20)]))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger.report())) as? [String: Any])
        let row = try #require((json["agents"] as? [[String: Any]])?.first)
        #expect(Set(row.keys) == ["id", "state", "collectedAt", "sessionCount", "days"])
        #expect((row["collectedAt"] as? NSNumber)?.int64Value == nowMs)
        let dayJSON = try #require((row["days"] as? [[String: Any]])?.first)
        #expect(Set(dayJSON.keys) == [
            "date", "inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens", "reasoningTokens",
            "totalTokens", "apiEquivalentCostUSD", "costComplete", "models",
        ])
    }

    @Test func cursorLeftInOldLedgersIsNeverReported() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("cursor", [day("2026-09-02", 7)], account: "account-hash"))
        try ledger.apply(report("claude", [day("2026-09-05", 3)]))
        #expect(ledger.sourceIDs == ["claude"])
        #expect(try ledger.report().agents.map(\.id) == ["claude"])
        #expect(try ledger.report(agents: ["cursor"]).agents.isEmpty)
    }

    @Test func onlyLimitsTheReportToTheRequestedSources() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("claude", [day("2026-09-05", 3)]))
        try ledger.apply(report("grok", [day("2026-09-05", 4)]))
        #expect(try ledger.report(agents: ["claude"]).agents.map(\.id) == ["claude"])
        #expect(try ledger.report().agents.map(\.id) == ["claude", "grok"])
    }

    @Test func failedRoundReportsErrorWithoutDaysAndNeverSeenSourcesStayOut() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("claude", [day("2026-09-04", 10), day("2026-09-05", 20)]))
        try ledger.apply(report("claude", [day("2026-09-04", 10)], at: now.addingTimeInterval(60)))
        try ledger.recordFailure(sourceID: "claude", error: "ccusage claude：采集超时")
        try ledger.recordFailure(sourceID: "grok", error: "ccusage 未发现本地用量或会话记录", unavailable: true)
        let agents = try ledger.report().agents
        // 从没采到过的 grok 不报；失败的 claude 只换状态，不带日子，采集时刻停在上次成功
        #expect(agents.map(\.id) == ["claude"])
        let claude = agents[0]
        #expect(claude.state == .error)
        #expect(claude.error == "ccusage claude：采集超时")
        #expect(claude.warning == nil)
        #expect(claude.days == nil)
        #expect(claude.collectedAt == nowMs + 60_000)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(claude)) as? [String: Any])
        #expect(json["days"] == nil)
    }

    @Test func costCompleteIsJudgedPerDay() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("codex", [
            day("2026-09-03", 5, complete: true),
            day("2026-09-04", 6, complete: false),
            day("2026-09-05", 7, cost: nil, complete: nil),
        ]))
        let days = try #require(try agent(ledger, "codex")?.days)
        #expect(days.map(\.costComplete) == [true, false, false])
        // 没估到的费用按 0 报，不编造
        #expect(days[2].apiEquivalentCostUSD == 0)
    }

    @Test func placeholderModelsMergeAndZeroModelsAreDropped() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("antigravity", [day("2026-09-05", 100, models: [
            "model_placeholder_m318": 80, "gemini-3.8-flash-high": 15, "unknown": 5, "idle-model": 0,
        ])]))
        let models = try #require(try agent(ledger, "antigravity")?.days?.last?.models)
        // 隐藏哪些名字归站点：unknown 照样报，零用量的不报
        #expect(models == [
            CodingUsageModelTokens(model: "gemini-3.8-flash-high", tokens: 95),
            CodingUsageModelTokens(model: "unknown", tokens: 5),
        ])
    }

    @Test func modelsPerDayStayWithinTheSiteLimit() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        let names = Dictionary(uniqueKeysWithValues: (1...70).map { ("model-\($0)", Int64($0)) })
        let total = names.values.reduce(0, +)
        try ledger.apply(report("opencode", [day("2026-09-05", total, models: names)]))
        let row = try #require(try agent(ledger, "opencode")?.days?.last)
        #expect(row.models.count == CodingUsageLedger.reportedModelsPerDay)
        #expect(row.models.first == CodingUsageModelTokens(model: "model-70", tokens: 70))
        #expect(row.models.last == CodingUsageModelTokens(model: "model-7", tokens: 7))
        #expect(row.models.map(\.tokens).reduce(0, +) <= row.totalTokens)
        let long = String(repeating: "长", count: 250)
        try ledger.apply(report("pi", [day("2026-09-05", 3, models: [long: 3])]))
        let name = try #require(try agent(ledger, "pi")?.days?.last?.models.first?.model)
        #expect(name.utf16.count <= 200)
        #expect(long.hasPrefix(name))
    }

    @Test func unclassifiedTokensStayInTheTotal() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        let row = CodingUsageDayRecord(date: "2026-09-05", inputTokens: 10, outputTokens: 4, reasoningTokens: 2,
                                       totalTokens: 17, apiEquivalentCostUSD: 0.5, models: ["gpt": 17],
                                       unclassifiedTokens: 3, costComplete: false)
        try ledger.apply(report("codex", [row]))
        let reported = try #require(try agent(ledger, "codex")?.days?.last)
        #expect(reported.totalTokens == 17)
        #expect(reported.inputTokens + reported.outputTokens + reported.cacheReadTokens + reported.cacheCreationTokens == 14)
        #expect(reported.reasoningTokens == 2)
        #expect(!reported.costComplete)
    }

    @Test func sparseScanKeepsOldDaysAndReportsTheGapAsAWarning() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("claude", [day("2026-09-04", 10), day("2026-09-05", 20)]))
        try ledger.apply(report("claude", [day("2026-09-04", 10)], at: now.addingTimeInterval(1)))
        let claude = try #require(try agent(ledger, "claude"))
        #expect(claude.state == .ok)
        #expect(claude.error == nil)
        #expect(claude.warning == "1 个既有活动日未返回，已保留")
        #expect(claude.days?.map(\.totalTokens) == [10, 20])
    }

    @Test func authoritativeExplicitCorrectionsMayDecreaseAndZeroDates() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("claude", [day("2026-09-03", 30), day("2026-09-05", 10)]))
        var corrected = report("claude", [day("2026-09-05", 8)], completeDates: ["2026-09-03", "2026-09-05"],
                               at: now.addingTimeInterval(1))
        corrected.coverageStart = "2026-09-03"
        try ledger.apply(corrected)
        let claude = try #require(try agent(ledger, "claude"))
        #expect(claude.days?.map(\.totalTokens) == [0, 8])
        #expect(claude.days?.first?.costComplete == true)
        #expect(claude.warning == nil)
    }

    @Test func accountSwitchIsolatesHistoryAndCanRestorePreviousAccount() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("codex", [day("2026-09-05", 80)], account: "a"))
        try ledger.apply(report("codex", [day("2026-09-05", 2)], account: "b"))
        #expect(try agent(ledger, "codex")?.days?.last?.totalTokens == 2)
        try ledger.apply(report("codex", [day("2026-09-05", 81)], account: "a"))
        #expect(try agent(ledger, "codex")?.days?.last?.totalTokens == 81)
    }

    @Test func sessionRefreshDoesNotMarkUsageFreshAndSurvivesIndependentWriters() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var usageWriter = try CodingUsageLedger(url: url)
        var sessionWriter = try CodingUsageLedger(url: url)
        try usageWriter.apply(report("codex", [day("2026-09-05", 9)]))
        try sessionWriter.applySessions(sourceID: "codex", sessions: [.init(identityHash: "session-hash", lastActivityAt: now)])
        let codex = try #require(try agent(CodingUsageLedger(url: url), "codex"))
        #expect(codex.days?.last?.totalTokens == 9)
        #expect(codex.sessionCount == 1)
        #expect(codex.collectedAt == nowMs)
    }

    @Test func latestSessionActivityIsTheNewestSessionWithAStableTieBreak() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("opencode", [day("2026-09-05", 1)], sessions: [
            .init(identityHash: "bbbb", lastActivityAt: now, currentModel: "model-b"),
            .init(identityHash: "aaaa", lastActivityAt: now, currentModel: "model-a"),
            .init(identityHash: "cccc", lastActivityAt: now.addingTimeInterval(-60), currentModel: "model-c"),
            .init(identityHash: "dddd", lastActivityAt: nil, currentModel: "model-d"),
        ]))
        try ledger.applySessions(sourceID: "grok", sessions: [.init(identityHash: "eeee")])
        for _ in 0..<5 {
            let latest = try CodingUsageLedger(url: url).latestSessionActivity()
            #expect(latest == ["opencode": CodingActivitySample(at: now, model: "model-a")])
        }
    }

    @Test func idsTheSiteWouldRejectAreLeftOut() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("Bad Source", [day("2026-09-05", 1)]))
        try ledger.apply(report("kilo_code.v2", [day("2026-09-05", 1)]))
        #expect(ledger.unreportedSourceIDs == ["Bad Source"])
        #expect(try ledger.report().agents.map(\.id) == ["kilo_code.v2"])
    }

    @Test func invalidCorrectionAndCorruptDiskNeverOverwriteHistory() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("claude", [day("2026-09-05", 5)]))
        let original = try Data(contentsOf: url)
        var invalid = day("2026-09-05", 4); invalid.totalTokens = 99
        #expect(throws: (any Error).self) { try ledger.apply(report("claude", [invalid])) }
        #expect(try Data(contentsOf: url) == original)
        try Data("invalid".utf8).write(to: url)
        #expect(throws: (any Error).self) { try ledger.recordFailure(sourceID: "claude", error: "error") }
        #expect(try Data(contentsOf: url) == Data("invalid".utf8))
    }

    /**
     * 现在装着的账本是旧版写的：状态里有 precision / costComplete，日行没有 costComplete，还有一份
     * Cursor 的账号历史。新版要读得进来、照常出报告；写回去的状态也得保留那两格，旧版还能读。
     */
    @Test func ledgersWrittenByTheOldAppStillLoadAndReport() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacy = #"""
        {"accounts":{
          "codex":{"local":{"completeDates":["2026-09-04"],
            "days":{"2026-09-04":{"cacheCreationTokens":0,"cacheReadTokens":20,"date":"2026-09-04","inputTokens":10,
              "models":{"gpt-5.5-codex":40},"outputTokens":4,"reasoningTokens":2,"totalTokens":40,
              "unclassifiedTokens":6,"apiEquivalentCostUSD":0.25}},
            "sessions":{"h1":{"identityHash":"h1","lastActivityAt":778000000,"currentModel":"gpt-5.5-codex"}},
            "status":{"collectedAt":"2026-09-04T05:55:26.252Z","costComplete":false,"coverageEnd":"2026-09-04",
              "coverageStart":"2026-09-04","error":null,"precision":"measured","state":"ok",
              "warning":"历史记录有 6 token 未提供分列，已保留实测总量"}}},
          "cursor":{"fixture-account":{"completeDates":[],
            "days":{"2026-09-01":{"cacheCreationTokens":0,"cacheReadTokens":0,"date":"2026-09-01","inputTokens":0,
              "models":{"composer-1":0},"outputTokens":0,"reasoningTokens":0,"totalTokens":0}},
            "sessions":{},
            "status":{"collectedAt":"2026-09-02T00:00:00Z","costComplete":false,"coverageEnd":null,"coverageStart":null,
              "error":"分页不完整","precision":"measured","state":"error","warning":null}}}},
         "selectedAccounts":{"codex":"local","cursor":"fixture-account"},
         "timezone":"Asia/Shanghai","version":1}
        """#
        try Data(legacy.utf8).write(to: url)
        var ledger = try CodingUsageLedger(url: url)
        let codex = try #require(try ledger.report().agents.onlyElement)
        #expect(codex.id == "codex")
        #expect(codex.collectedAt == CodingUsageDates.milliseconds(CodingUsageDates.parseInstant("2026-09-04T05:55:26.252Z")!))
        #expect(codex.warning == "历史记录有 6 token 未提供分列，已保留实测总量")
        #expect(codex.days == [CodingUsageDay(
            date: "2026-09-04", inputTokens: 10, outputTokens: 4, cacheReadTokens: 20, cacheCreationTokens: 0,
            reasoningTokens: 2, totalTokens: 40, apiEquivalentCostUSD: 0.25, costComplete: false,
            models: [CodingUsageModelTokens(model: "gpt-5.5-codex", tokens: 40)]
        )])
        try ledger.apply(report("claude", [day("2026-09-05", 3)]))
        let disk = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let accounts = try #require(disk["accounts"] as? [String: [String: [String: Any]]])
        let status = try #require(accounts["claude"]?["local"]?["status"] as? [String: Any])
        #expect(status["precision"] as? String == "measured")
        #expect(status["costComplete"] as? Bool == true)
        #expect(accounts["cursor"] != nil)
    }

    @Test func reportsAreStableAcrossReloads() throws {
        #expect(CodingUsageDates.day(CodingUsageDates.parseInstant("2026-09-04T16:00:00Z")!) == "2026-09-05")
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("opencode", [day("2026-09-05", 3, cost: 0.1, models: ["b": 1, "a": 1, "c": 1]),
                                             day("2026-09-03", 1, cost: 10000.2), day("2026-09-04", 1, cost: 0.3)]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(ledger.report())
        for _ in 0..<5 {
            #expect(try encoder.encode(CodingUsageLedger(url: url).report()) == original)
        }
        #expect(try agent(ledger, "opencode")?.days?.last?.models.map(\.model) == ["a", "b", "c"])
    }
}

private extension Array {
    var onlyElement: Element? { count == 1 ? first : nil }
}
