import Foundation
import XCTest
@testable import CodingUsageKit

final class EngineTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_788_580_800)

    private func event(
        at date: Date, input: Int64 = 100, output: Int64 = 50,
        cacheRead: Int64 = 200, cacheWrite: Int64 = 300,
        model: String = "claude-4.5-sonnet-thinking", measured: Bool = true
    ) -> CursorUsageRecord {
        CursorUsageRecord(
            timestampMs: Int64(date.timeIntervalSince1970 * 1_000), model: model,
            inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheWrite, tokenCountsAvailable: measured,
            reportedTokenCostUSD: 999, chargedUSD: 9_999
        )
    }

    private func report(
        _ records: [CursorUsageRecord], at collectedAt: Date? = nil,
        account: String = "fixture-account-hash", complete: Bool = true
    ) -> CursorUsageReport {
        CursorUsageReport(
            accountHash: account, records: records, fetchedAt: collectedAt ?? now,
            requestedStart: Date(timeIntervalSince1970: 0), requestedEnd: now,
            rawRecordCount: records.count, reportedRecordCount: records.count,
            pageCount: 1, isComplete: complete
        )
    }

    private func withLedger(_ body: (inout CodingUsageLedger) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var ledger = try CodingUsageLedger(url: folder.appendingPathComponent("history.json"))
        try body(&ledger)
    }

    func testCursorCacheWritesAreIndependentAndPlanChargesAreNotValuation() throws {
        // A sanitized real API event shape, including two intentionally unrelated billing amounts.
        let json = """
        {"totalUsageEventsCount":1,"usageEventsDisplay":[{
          "timestamp":"1788580800000","model":"claude-4.5-sonnet-thinking",
          "tokenUsage":{"inputTokens":100,"outputTokens":50,"cacheReadTokens":200,"cacheWriteTokens":300,"totalCents":99900},
          "chargedCents":999900,"isTokenBasedCall":true,"kind":"USAGE_EVENT_KIND_INCLUDED",
          "conversationId":"private-fixture-id","owningUser":"private-fixture-owner"
        }]}
        """
        let decoded = try CursorUsageParsing.page(Data(json.utf8), lower: 0, upper: 1_788_580_800_000)
        let source = try CodingUsageEngine.sourceReport(report(decoded.events.map(\.record)))
        let row = try XCTUnwrap(source.days.first { $0.totalTokens > 0 })
        XCTAssertEqual(row.inputTokens, 100)
        XCTAssertEqual(row.cacheCreationTokens, 300)
        XCTAssertEqual(row.cacheReadTokens, 200)
        XCTAssertEqual(row.outputTokens, 50)
        XCTAssertEqual(row.totalTokens, 650)
        XCTAssertEqual(try XCTUnwrap(row.apiEquivalentCostUSD), 0.002235, accuracy: 0.000000001)
        XCTAssertTrue(source.costComplete)
        try withLedger { ledger in
            try ledger.apply(source)
            let data = try JSONEncoder().encode(ledger.snapshot(at: now))
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("private-fixture"))
            XCTAssertFalse(text.contains("chargedUSD"))
            XCTAssertFalse(text.contains("reportedTokenCostUSD"))
        }
    }

    func testUnmeasuredHistoricalRequestsReportDiagnosticsAndKeepMeasuredTotals() throws {
        let oldDate = now.addingTimeInterval(-86_400)
        let unknown = event(at: oldDate, input: 0, output: 0, cacheRead: 0, cacheWrite: 0, measured: false)
        let cloud = report(Array(repeating: unknown, count: 1_891) + [event(at: now)])
        let source = try CodingUsageEngine.sourceReport(cloud)
        XCTAssertFalse(source.costComplete)
        XCTAssertTrue(source.diagnosticError?.contains("1891") == true)
        XCTAssertEqual(source.days.reduce(Int64(0)) { $0 + $1.totalTokens }, 650)
        try withLedger { ledger in
            try ledger.apply(source)
            let snapshot = try ledger.snapshot(at: now)
            let cursor = try XCTUnwrap(snapshot.usage.agents.first { $0.id == "cursor" })
            XCTAssertEqual(snapshot.usage.totals.totalTokens, 650)
            // 采到了但有缺口：状态仍是 ok，缺口进 warning（error 只留给真失败）
            XCTAssertEqual(cursor.usageStatus.state, .ok)
            XCTAssertNil(cursor.usageStatus.error)
            XCTAssertTrue(cursor.usageStatus.warning?.contains("1891") == true)
            XCTAssertFalse(cursor.usageStatus.costComplete)
        }
    }

    func testHistoricalCorrectionCanDecreaseAnActuallyReturnedDay() throws {
        let oldDate = now.addingTimeInterval(-86_400)
        try withLedger { ledger in
            try ledger.apply(CodingUsageEngine.sourceReport(report([event(at: oldDate, input: 1_000)])))
            try ledger.apply(CodingUsageEngine.sourceReport(report(
                [event(at: oldDate, input: 100)], at: now.addingTimeInterval(1)
            )))
            let snapshot = try ledger.snapshot(at: now)
            XCTAssertEqual(snapshot.usage.totals.totalTokens, 650)
            XCTAssertEqual(snapshot.usage.totals.activeDays, 1)
        }
    }

    func testAbsentHistoricalDayAndSourceFailurePreserveTheLedger() throws {
        let oldDate = now.addingTimeInterval(-86_400)
        try withLedger { ledger in
            try ledger.apply(CodingUsageEngine.sourceReport(report([event(at: oldDate), event(at: now)])))
            try ledger.apply(CodingUsageEngine.sourceReport(report([event(at: now)], at: now.addingTimeInterval(1))))
            var snapshot = try ledger.snapshot(at: now)
            XCTAssertEqual(snapshot.usage.totals.totalTokens, 1_300)
            XCTAssertEqual(snapshot.usage.totals.activeDays, 2)
            let status = snapshot.usage.agents.first { $0.id == "cursor" }?.usageStatus
            XCTAssertEqual(status?.state, .ok)
            XCTAssertNotNil(status?.warning)
            try ledger.recordFailure(sourceID: "cursor", error: "fixture timeout")
            snapshot = try ledger.snapshot(at: now)
            XCTAssertEqual(snapshot.usage.totals.totalTokens, 1_300)
            XCTAssertEqual(snapshot.usage.totals.activeDays, 2)
        }
    }

    func testAccountSwitchDoesNotAddTwoAccountHistories() throws {
        try withLedger { ledger in
            try ledger.apply(CodingUsageEngine.sourceReport(report([event(at: now, input: 1_000)])))
            try ledger.apply(CodingUsageEngine.sourceReport(report(
                [event(at: now, input: 100)], at: now.addingTimeInterval(1), account: "other-fixture-hash"
            )))
            XCTAssertEqual(try ledger.snapshot(at: now).usage.totals.totalTokens, 650)
        }
    }

    func testUnknownPricePreservesTokensAndMarksCostIncomplete() throws {
        let source = try CodingUsageEngine.sourceReport(report([event(at: now, model: "fixture-unpriced")]))
        XCTAssertFalse(source.costComplete)
        XCTAssertEqual(source.days.reduce(Int64(0)) { $0 + $1.totalTokens }, 650)
        XCTAssertEqual(source.days.reduce(0) { $0 + ($1.apiEquivalentCostUSD ?? 0) }, 0)
    }

    func testEventDayUsesContractTimezoneAtMidnight() throws {
        let boundary = Date(timeIntervalSince1970: 1_788_537_600) // 2026-09-05 00:00 in +08:00.
        let source = try CodingUsageEngine.sourceReport(report([
            event(at: boundary.addingTimeInterval(-0.001)), event(at: boundary),
        ]))
        XCTAssertEqual(source.days.first { $0.date == "2026-09-04" }?.totalTokens, 650)
        XCTAssertEqual(source.days.first { $0.date == "2026-09-05" }?.totalTokens, 650)
    }

    func testIncompleteCloudReportCannotReachAuthoritativeLedgerMapping() throws {
        XCTAssertThrowsError(try CodingUsageEngine.sourceReport(report([event(at: now)], complete: false))) {
            XCTAssertEqual($0 as? CursorUsageError, .incompletePagination)
        }
    }

    func testCancelledEngineRefreshNeverWritesFailureStatusesOrReplacesHistory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("fixture-cli")
        let marker = folder.appendingPathComponent("started")
        let ledgerURL = folder.appendingPathComponent("history.json")
        let script = #"""
        #!/bin/sh
        if [ "$1" = "--help" ]; then
          printf '  claude Show usage\n'
          exit 0
        fi
        printf started > "$ENGINE_TEST_MARKER"
        exec /bin/sleep 30
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let engine = CodingUsageEngine(ledgerURL: ledgerURL, home: folder)
        let task = Task {
            try await engine.refresh(
                executableURL: executable, environment: ["ENGINE_TEST_MARKER": marker.path], includeCursor: false
            )
        }
        // 上限放宽到 10 秒：只是等 fixture 进程真正跑起来，通常几十毫秒就到；
        // 机器同时在跑 xcodebuild 时 spawn 会拖到 1 秒以上，之前 1 秒的上限就偶发红。
        // 标记一出现就跳出，正常情况下不会多等。
        for _ in 0..<1_000 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "fixture CLI 10 秒内没有启动")
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))
    }
}
