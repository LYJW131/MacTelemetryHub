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
    private func day(_ date: String, _ tokens: Int64, cost: Double? = 1) -> CodingUsageDayRecord {
        CodingUsageDayRecord(date: date, inputTokens: tokens, totalTokens: tokens, apiEquivalentCostUSD: cost, models: ["model-a": tokens])
    }
    private func report(_ source: String, _ days: [CodingUsageDayRecord], account: String? = nil,
                        sessions: [CodingUsageSessionRecord] = [], completeDates: Set<String> = []) -> CodingUsageSourceReport {
        CodingUsageSourceReport(sourceID: source, accountID: account, days: days, sessions: sessions,
                                collectedAt: now, coverageStart: days.map(\.date).min(), coverageEnd: "2026-09-05",
                                costComplete: true, completeDates: completeDates)
    }

    @Test func persistsUnionOfSourcesAndDeduplicatesRepeatedReports() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        let session = CodingUsageSessionRecord(identityHash: String(repeating: "a", count: 64), lastActivityAt: now, currentModel: "model-a")
        let local = report("claude", [day("2026-09-03", 5), day("2026-09-05", 20)], sessions: [session, session])
        try ledger.apply(local); try ledger.apply(local)
        try ledger.apply(report("cursor", [day("2026-09-02", 7), day("2026-09-05", 3)], account: "account-hash"))
        let restored = try CodingUsageLedger(url: url)
        let snapshot = try restored.snapshot(at: now)
        #expect(snapshot.usage.totals.totalTokens == 35)
        let withoutCursor = try restored.snapshot(at: now, omitting: ["cursor"])
        #expect(withoutCursor.usage.omittedSources == ["cursor"])
        #expect(withoutCursor.usage.agents.contains { $0.id == "cursor" } == false)
        #expect(withoutCursor.usage.totals.totalTokens == 25)
        #expect(withoutCursor.year.days.reduce(0, +) == 25)
        #expect(snapshot.usage.totals.activeDays == 3)
        #expect(snapshot.usage.totals.sessionCount == 1)
        #expect(snapshot.year.days.reduce(0, +) == 35)
        #expect(snapshot.now.agents.first { $0.id == "claude" }?.active == true)
        #expect(try restored.snapshot(at: now.addingTimeInterval(301)).now.agents.first { $0.id == "claude" }?.active == false)
    }

    @Test func failuresAndMissingHistoryRetainFactsAndExposeCoverageError() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("cursor", [day("2026-08-01", 30), day("2026-09-05", 10)]))
        try ledger.recordFailure(sourceID: "cursor", error: "分页不完整")
        #expect(try ledger.snapshot(at: now).usage.totals.totalTokens == 40)
        try ledger.apply(report("cursor", [day("2026-09-05", 12)]))
        let cursor = try ledger.snapshot(at: now).usage.agents.first { $0.id == "cursor" }!
        #expect(cursor.usageStatus.state == .error)
        #expect(cursor.usageStatus.error?.contains("缩短") == true)
        #expect(try ledger.snapshot(at: now).usage.totals.totalTokens == 42)
        #expect(try ledger.snapshot(at: now).usage.totals.activeDays == 2)
    }

    @Test func authoritativeExplicitCorrectionsMayDecreaseAndZeroDates() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("claude", [day("2026-09-03", 30), day("2026-09-05", 10)]))
        var corrected = report("claude", [day("2026-09-05", 8)], completeDates: ["2026-09-03", "2026-09-05"])
        corrected.coverageStart = "2026-09-03"
        try ledger.apply(corrected)
        let snapshot = try ledger.snapshot(at: now)
        #expect(snapshot.usage.totals.totalTokens == 8)
        #expect(snapshot.usage.totals.activeDays == 1)
        #expect(snapshot.usage.agents.first { $0.id == "claude" }?.usageStatus.state == .ok)
    }

    @Test func accountSwitchIsolatesHistoryAndCanRestorePreviousAccount() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("cursor", [day("2026-09-05", 80)], account: "a"))
        try ledger.apply(report("cursor", [day("2026-09-05", 2)], account: "b"))
        #expect(try ledger.snapshot(at: now).usage.totals.totalTokens == 2)
        try ledger.apply(report("cursor", [day("2026-09-05", 81)], account: "a"))
        #expect(try ledger.snapshot(at: now).usage.totals.totalTokens == 81)
    }

    @Test func antigravityPlaceholdersPublishPublicNamesAndMerge() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        let row = CodingUsageDayRecord(
            date: "2026-09-05",
            inputTokens: 100,
            totalTokens: 100,
            apiEquivalentCostUSD: 1,
            models: ["model_placeholder_m318": 80, "gemini-3.8-flash-high": 20]
        )
        let session = CodingUsageSessionRecord(
            identityHash: String(repeating: "b", count: 64),
            lastActivityAt: now,
            currentModel: "MODEL_PLACEHOLDER_M318"
        )
        try ledger.apply(report("antigravity", [row], sessions: [session]))
        let snapshot = try ledger.snapshot(at: now)
        let agent = snapshot.usage.agents.first { $0.id == "antigravity" }!
        #expect(agent.models == ["gemini-3.8-flash-high"])
        #expect(agent.currentModel == "gemini-3.8-flash-high")
        #expect(agent.topModel == "gemini-3.8-flash-high")
        #expect(snapshot.usage.topModels.map(\.model) == ["gemini-3.8-flash-high"])
        #expect(snapshot.usage.topModels.first?.tokens == 100)
        #expect(snapshot.year.models == ["gemini-3.8-flash-high"])
    }

    @Test func sessionRefreshDoesNotMarkUsageFreshAndSurvivesIndependentWriters() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var usageWriter = try CodingUsageLedger(url: url)
        var sessionWriter = try CodingUsageLedger(url: url)
        try usageWriter.apply(report("codex", [day("2026-09-05", 9)]))
        try sessionWriter.applySessions(sourceID: "codex", sessions: [.init(identityHash: "session-hash", lastActivityAt: now)])
        let snapshot = try CodingUsageLedger(url: url).snapshot(at: now)
        #expect(snapshot.usage.totals.totalTokens == 9)
        #expect(snapshot.usage.totals.sessionCount == 1)
        #expect(snapshot.usage.agents.first { $0.id == "codex" }?.usageStatus.collectedAt == CodingUsageDates.instant(now))
    }

    @Test func unknownTodayAndStatusFieldsEncodeAsNull() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let snapshot = try CodingUsageLedger(url: url).snapshot(at: now)
        let root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.usage)) as! [String: Any]
        let agent = (root["agents"] as! [[String: Any]])[0]
        #expect(agent["today"] is NSNull)
        let status = agent["usageStatus"] as! [String: Any]
        for field in ["collectedAt", "error", "coverageStart", "coverageEnd"] { #expect(status[field] is NSNull) }
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

    @Test func shanghaiMidnightAndYearModelMixUseSameSnapshot() throws {
        #expect(CodingUsageDates.day(CodingUsageDates.parseInstant("2026-09-04T16:00:00Z")!) == "2026-09-05")
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("claude", [day("2026-09-05", 5)]))
        let snapshot = try ledger.snapshot(at: now)
        #expect(snapshot.year.days.count == 371)
        for row in snapshot.year.mix {
            var total: Int64 = 0
            for i in stride(from: 2, to: row.count, by: 2) { total += row[i] }
            #expect(total <= snapshot.year.days[Int(row[0])])
        }
    }
    @Test func restoredSnapshotsHaveStableCostSumsAndSessionTieBreaking() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        let sessions: [CodingUsageSessionRecord] = [
            .init(identityHash: "bbbb", lastActivityAt: now, currentModel: "model-b"),
            .init(identityHash: "aaaa", lastActivityAt: now, currentModel: "model-a"),
        ]
        try ledger.apply(report("opencode", [day("2026-09-05", 1, cost: 0.1), day("2026-09-03", 1, cost: 10000.2),
                                             day("2026-09-04", 1, cost: 0.3)], sessions: sessions))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let snapshot = try ledger.snapshot(at: now)
        #expect(snapshot.now.agents.first { $0.id == "opencode" }?.currentModel == "model-a")
        let original = try encoder.encode(snapshot)
        for _ in 0..<5 {
            let restored = try CodingUsageLedger(url: url).snapshot(at: now)
            #expect(try encoder.encode(restored) == original)
        }
    }
    @Test func sparseTodayDoesNotErasePreviouslyMeasuredUsage() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("claude", [day("2026-09-04", 10), day("2026-09-05", 20)]))
        try ledger.apply(report("claude", [day("2026-09-04", 10)]))
        let snapshot = try ledger.snapshot(at: now)
        #expect(snapshot.usage.totals.totalTokens == 30)
        #expect(snapshot.usage.agents.first { $0.id == "claude" }?.today?.totalTokens == 20)
        #expect(snapshot.usage.agents.first { $0.id == "claude" }?.usageStatus.state == .error)
    }
    @Test func successfulSparseScanRecordsOnlyNewEmptyToday() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("claude", [day("2026-09-04", 10)]))
        let snapshot = try ledger.snapshot(at: now)
        #expect(snapshot.usage.agents.first { $0.id == "claude" }?.today?.totalTokens == 0)
        #expect(snapshot.usage.totals.activeDays == 1)
        #expect(snapshot.usage.agents.first { $0.id == "claude" }?.usageStatus.coverageEnd == "2026-09-05")
        let disk = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let accounts = disk["accounts"] as! [String: [String: [String: Any]]]
        let days = accounts["claude"]!["local"]!["days"] as! [String: [String: Any]]
        #expect((days["2026-09-05"]?["totalTokens"] as? NSNumber)?.int64Value == 0)
    }

    @Test func todayPatchReplacesClaudeTodayWithoutFlaggingMissingHistory() throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = try CodingUsageLedger(url: url)
        try ledger.apply(report("claude", [day("2026-09-04", 10), day("2026-09-05", 20)]))
        var patch = report("claude", [day("2026-09-05", 15)])
        patch.preservesHistory = true
        patch.coverageStart = "2026-09-05"
        try ledger.apply(patch)
        let agent = try ledger.snapshot(at: now).usage.agents.first { $0.id == "claude" }
        #expect(agent?.today?.totalTokens == 15)
        #expect(agent?.usageStatus.state == .ok)
        #expect(agent?.usageStatus.error == nil)
        #expect(agent?.usageStatus.coverageStart == "2026-09-04")
        let later = CodingUsageDates.parseInstant("2026-09-05T05:00:00Z")!
        var empty = CodingUsageSourceReport(
            sourceID: "claude", days: [], collectedAt: later, coverageEnd: "2026-09-05",
            costComplete: true, preservesHistory: true
        )
        empty.preservesHistory = true
        try ledger.apply(empty)
        let after = try ledger.snapshot(at: later).usage.agents.first { $0.id == "claude" }
        #expect(after?.today?.totalTokens == 15)
        #expect(try ledger.snapshot(at: now).usage.totals.totalTokens == 25)
    }
}
