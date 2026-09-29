import Foundation
import XCTest
@testable import CodingUsageKit

final class EngineTests: XCTestCase, @unchecked Sendable {
    private let now = CodingUsageDates.parseInstant("2026-09-23T04:00:00Z")!
    private func ms(_ date: Date) -> Int64 { CodingUsageDates.milliseconds(date) }

    // MARK: - codingActivity

    func testNewerScannedEventWinsAndCarriesItsModel() throws {
        let seen = now.addingTimeInterval(-60)
        let report = CodingUsageEngine.activity(
            sources: ["codex", "grok"],
            recorded: ["codex": CodingActivitySample(at: now.addingTimeInterval(-3_600), model: "old-model")],
            scanned: ["codex": CodingActivitySample(at: seen, model: "gpt-5.5-codex")],
            at: now
        )
        XCTAssertEqual(report.collectedAt, ms(now))
        XCTAssertEqual(report.agents, [
            CodingActivityAgent(id: "codex", lastActivityAt: ms(seen), model: "gpt-5.5-codex"),
            // 本机有这个来源、但从没见过它的用量事件
            CodingActivityAgent(id: "grok", lastActivityAt: nil, model: nil),
        ])
        // 在不在跑由站点按时刻现算，这里没有电平
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let rows = try XCTUnwrap(json["agents"] as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), ["id", "lastActivityAt", "model"])
        XCTAssertEqual(Set(rows[1].keys), ["id"])
    }

    func testOlderScanOrTieKeepsTheLedgerSession() {
        let recorded = now.addingTimeInterval(-30)
        let older = CodingUsageEngine.activity(
            sources: ["claude"],
            recorded: ["claude": CodingActivitySample(at: recorded, model: "claude-opus-5")],
            scanned: ["claude": CodingActivitySample(at: now.addingTimeInterval(-120), model: "claude-fable-5")],
            at: now
        )
        XCTAssertEqual(older.agents, [CodingActivityAgent(id: "claude", lastActivityAt: ms(recorded), model: "claude-opus-5")])
        let tie = CodingUsageEngine.activity(
            sources: ["claude"],
            recorded: ["claude": CodingActivitySample(at: recorded, model: "claude-opus-5")],
            scanned: ["claude": CodingActivitySample(at: recorded, model: "claude-fable-5")],
            at: now
        )
        XCTAssertEqual(tie.agents.first?.model, "claude-opus-5")
    }

    func testChosenEventWithoutAModelBorrowsTheOthers() {
        let report = CodingUsageEngine.activity(
            sources: ["codex"],
            recorded: ["codex": CodingActivitySample(at: now.addingTimeInterval(-600), model: "gpt-5.5-codex")],
            scanned: ["codex": CodingActivitySample(at: now.addingTimeInterval(-60), model: nil)],
            at: now
        )
        XCTAssertEqual(report.agents.first?.lastActivityAt, ms(now.addingTimeInterval(-60)))
        XCTAssertEqual(report.agents.first?.model, "gpt-5.5-codex")
    }

    func testRetiredSourcesAndFutureStampsAreLeftOut() {
        let report = CodingUsageEngine.activity(
            sources: ["cursor", "claude", "Bad Source"],
            recorded: [
                "claude": CodingActivitySample(at: now.addingTimeInterval(3_600), model: "claude-opus-5"),
                "cursor": CodingActivitySample(at: now, model: "composer-2"),
            ],
            scanned: [:],
            at: now
        )
        XCTAssertEqual(report.agents, [CodingActivityAgent(id: "claude", lastActivityAt: nil, model: nil)])
    }

    func testPlaceholderModelNamesArePublished() {
        let report = CodingUsageEngine.activity(
            sources: ["antigravity"],
            recorded: ["antigravity": CodingActivitySample(at: now, model: "MODEL_PLACEHOLDER_M318")],
            scanned: [:],
            at: now
        )
        XCTAssertEqual(report.agents.first?.model, "gemini-3.8-flash-high")
    }

    /// 一次会话扫描：Claude 的活动和桶来自日志扫描，Grok 的活动来自 `ccusage session` 记进账本的会话
    func testSessionRefreshReportsActivityAndBuckets() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("engine-sessions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projects = folder.appendingPathComponent(".claude/projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let current = Date()
        // 日志里的时刻只到秒
        let seen = Date(timeIntervalSince1970: (current.timeIntervalSince1970 - 90).rounded(.down))
        let stamp = ISO8601DateFormatter().string(from: seen)
        let line = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "timestamp": stamp,
            "message": ["id": "response", "model": "claude-test", "usage": ["input_tokens": 3, "output_tokens": 2]],
        ])
        try (line + Data([10])).write(to: projects.appendingPathComponent("session.jsonl"))
        let executable = folder.appendingPathComponent("ccusage")
        let script = """
        #!\(testPython)
        import sys,json
        args=sys.argv[1:]
        if args==['--help']:
            print('  claude    Show Claude usage\\n  codex    Show Codex usage\\n  grok    Show Grok usage\\n  antigravity    Show Antigravity usage')
            raise SystemExit
        if args[0]=='daily':
            print(json.dumps({'daily':[{'agents':[{'agent':'grok'}]}]}))
            raise SystemExit
        if args[0]=='grok':
            print(json.dumps({'sessions':[{'sessionId':'private-grok','lastActivity':'2026-09-23T03:00:00Z','modelsUsed':['grok-5']}]}))
        else:
            print(json.dumps({'sessions':[]}))
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let engine = CodingUsageEngine(ledgerURL: folder.appendingPathComponent("history.json"), home: folder)
        let result = try await engine.refreshSessions(executableURL: executable, at: current)
        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(result.activity.collectedAt, ms(current))
        XCTAssertEqual(result.activity.agents, [
            // 默认要问的来源：问过了、没有会话
            CodingActivityAgent(id: "antigravity", lastActivityAt: nil, model: nil),
            CodingActivityAgent(id: "claude", lastActivityAt: ms(seen), model: "claude-test"),
            CodingActivityAgent(id: "grok", lastActivityAt: ms(CodingUsageDates.parseInstant("2026-09-23T03:00:00Z")!),
                                model: "grok-5"),
        ])
        XCTAssertEqual(result.buckets.agents.map(\.id), ["codex", "claude"])
        XCTAssertEqual(result.buckets.windows.flatMap(\.agents).map(\.outputTokens), [2])
        XCTAssertEqual(result.buckets.collectedAt, ms(current))
        // 会话 ID 只以摘要进账本，上报里一个字都没有
        let text = String(decoding: try JSONEncoder().encode(result.activity), as: UTF8.self)
        XCTAssertFalse(text.contains("private-grok"))
    }

    // MARK: - codingUsage

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
            try await engine.refresh(executableURL: executable, environment: ["ENGINE_TEST_MARKER": marker.path])
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
