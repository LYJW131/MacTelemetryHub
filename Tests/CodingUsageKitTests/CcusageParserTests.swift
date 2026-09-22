import Foundation
import Testing
@testable import CodingUsageKit

struct CcusageParserTests {
    @Test func cursorIsNotALocalSourceEvenWhenDiscovered() {
        #expect(CcusageCollector.sources(requested: ["claude", "cursor"], discovered: ["opencode", "cursor"])
            == ["claude", "opencode"])
    }
    @Test func piCommandReadsBothSessionStores() {
        let home = URL(fileURLWithPath: "/tmp/home")
        let collector = CcusageCollector(executableURL: URL(fileURLWithPath: "/usr/bin/false"), offline: true, home: home)
        let args = collector.commandArguments(source: "pi", section: "daily")
        let path = args[args.firstIndex(of: "--pi-path")! + 1]
        #expect(path == "/tmp/home/.pi/agent/sessions,/tmp/home/.omp/agent/sessions")
        #expect(args.contains("--mode"))
        #expect(!collector.commandArguments(source: "claude", section: "daily").contains("--pi-path"))
        #expect(!collector.commandArguments(source: "codex", section: "daily").contains("--mode"))
        #expect(CcusageCollector.sources(requested: ["claude"], discovered: [], includePi: true) == ["claude", "pi"])
        #expect(!CcusageCollector.includePi(available: ["claude"], home: home))
    }
    @Test func ompSessionsArePresentOnlyWhenALogExists() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!CcusageCollector.ompSessionsPresent(home: home))
        let file = home.appendingPathComponent(".omp/agent/sessions/-x/session.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\n".utf8).write(to: file)
        #expect(CcusageCollector.ompSessionsPresent(home: home))
        #expect(CcusageCollector.includePi(available: ["pi"], home: home))
    }

    private let now = CodingUsageDates.parseInstant("2026-09-05T04:00:00Z")!
    private let noSessions = Data("{\"sessions\":[]}".utf8)
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func rawDay() -> [String: Any] {
        ["date": "2026-09-05", "inputTokens": 10, "outputTokens": 4,
         "cacheReadTokens": 20, "cacheCreationTokens": 3, "totalTokens": 37, "totalCost": 0.5,
         "modelBreakdowns": [["modelName": "model-a", "inputTokens": 10, "outputTokens": 4,
                               "cacheReadTokens": 20, "cacheCreationTokens": 3, "cost": 0.5]]]
    }
    @Test func preservesTokensWhenModelPricingIsMissing() throws {
        var day = rawDay()
        day["totalCost"] = 0
        var model = (day["modelBreakdowns"] as! [[String: Any]])[0]
        model["cost"] = 0
        day["modelBreakdowns"] = [model]
        let report = try CcusageParser.parse(sourceID: "claude", daily: data(["daily": [day]]), sessions: noSessions, collectedAt: now)
        #expect(report.days[0].totalTokens == 37)
        #expect(report.days[0].models["model-a"] == 37)
        #expect(report.costComplete == false)
        #expect(report.completeDates.contains("2026-09-05"))
    }
    @Test func preservesCodexReasoningAsOutputSubsetAndNeverDoubleCountsCache() throws {
        var day = rawDay()
        day["modelBreakdowns"] = nil; day["totalCost"] = nil; day["costUSD"] = 0.5
        day["reasoningOutputTokens"] = 2
        day["models"] = ["gpt-6-test": ["inputTokens": 10, "outputTokens": 4, "cacheReadTokens": 20,
                                           "cacheCreationTokens": 3, "reasoningOutputTokens": 2, "totalTokens": 37]]
        let report = try CcusageParser.parse(sourceID: "codex", daily: data(["daily": [day]]), sessions: noSessions, collectedAt: now)
        #expect(report.days[0].inputTokens == 10)
        #expect(report.days[0].outputTokens == 4)
        #expect(report.days[0].reasoningTokens == 2)
        #expect(report.days[0].totalTokens == 37)
        #expect(report.costComplete == false)
    }
    @Test func antigravityThinkingResidualBelongsToOutputWithoutInventingModelAttribution() throws {
        var day = rawDay(); day["totalTokens"] = 40
        let report = try CcusageParser.parse(sourceID: "antigravity", daily: data(["daily": [day]]), sessions: noSessions, collectedAt: now)
        #expect(report.days[0].outputTokens == 7)
        #expect(report.days[0].reasoningTokens == 3)
        #expect(report.days[0].totalTokens == 40)
        #expect(report.days[0].models["model-a"] == 37)
        #expect(report.precision == .measured)
        #expect(report.costComplete == false)
    }
    @Test func codexHistoricalUnclassifiedResidualKeepsMeasuredTotalAndReportsGap() throws {
        var day = rawDay()
        day["modelBreakdowns"] = nil; day["totalTokens"] = 40
        day["models"] = ["model-a": ["inputTokens": 10, "outputTokens": 4, "cacheReadTokens": 20,
                                      "cacheCreationTokens": 3, "reasoningOutputTokens": 2, "totalTokens": 40]]
        let report = try CcusageParser.parse(sourceID: "codex", daily: data(["daily": [day]]), sessions: noSessions)
        #expect(report.days[0].totalTokens == 40)
        #expect(report.days[0].unclassifiedTokens == 3)
        #expect(report.days[0].inputTokens == 10)
        #expect(report.days[0].outputTokens == 4)
        #expect(report.diagnosticError?.contains("3 token") == true)
    }
    @Test func rejectsInvalidDatesNegativeBooleanFractionalOrInconsistentTokens() throws {
        for value: Any in [-1, true, 1.5, "10"] {
            var day = rawDay(); day["inputTokens"] = value
            #expect(throws: (any Error).self) {
                try CcusageParser.parse(sourceID: "claude", daily: data(["daily": [day]]), sessions: noSessions)
            }
        }
        var badDate = rawDay(); badDate["date"] = "2026-02-30"
        #expect(throws: (any Error).self) { try CcusageParser.parse(sourceID: "claude", daily: data(["daily": [badDate]]), sessions: noSessions) }
        var mismatch = rawDay(); mismatch["totalTokens"] = 36
        #expect(throws: (any Error).self) { try CcusageParser.parse(sourceID: "codex", daily: data(["daily": [mismatch]]), sessions: noSessions) }
        #expect(throws: (any Error).self) { try CcusageParser.parse(sourceID: "claude", daily: data(["daily": "bad"]), sessions: noSessions) }
    }
    @Test func duplicateDaysAreIdempotentButConflictsFail() throws {
        let day = rawDay()
        let report = try CcusageParser.parse(sourceID: "claude", daily: data(["daily": [day, day]]), sessions: noSessions)
        #expect(report.days.count == 1)
        var changed = day; changed["totalCost"] = 2
        #expect(throws: (any Error).self) {
            try CcusageParser.parse(sourceID: "claude", daily: data(["daily": [day, changed]]), sessions: noSessions)
        }
    }
    @Test func hashesAndDeduplicatesSessionsWithoutPersistingPathsOrInventingLatestModel() throws {
        let sessions: [[String: Any]] = [
            ["sessionId": "private-session-id", "projectPath": "/private/project", "lastActivity": "2026-09-05T03:00:00Z", "modelsUsed": ["a"]],
            ["sessionId": "private-session-id", "projectPath": "/backup/private/project", "lastActivity": "2026-09-05T04:00:00Z", "modelsUsed": ["a", "b"]],
        ]
        let report = try CcusageParser.parseSessions(sourceID: "claude", data: data(["sessions": sessions]))
        #expect(report.count == 1)
        #expect(report[0].identityHash.count == 64)
        #expect(report[0].lastActivityAt == now)
        #expect(report[0].currentModel == nil)
        let stored = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!stored.contains("private-session-id"))
        #expect(!stored.contains("/private/project"))
        let otherSource = try CcusageParser.parseSessions(sourceID: "codex", data: data(["sessions": sessions]))
        #expect(otherSource[0].identityHash != report[0].identityHash)
    }

    @Test func pipeDrainingCannotDeadlockOnLargeStderr() async throws {
        let output = try await CodingUsageProcess.run(
            executableURL: URL(fileURLWithPath: testPython),
            arguments: ["-c", "import sys; sys.stderr.write('x' * 2000000); sys.stderr.flush(); print('{\"daily\":[]}')"], timeout: 10)
        #expect(String(decoding: output, as: UTF8.self).contains("daily"))
    }
    @Test func longRunningCollectorTimesOut() async throws {
        let began = Date()
        await #expect(throws: (any Error).self) {
            try await CodingUsageProcess.run(executableURL: URL(fileURLWithPath: testPython),
                                             arguments: ["-c", "import time; time.sleep(10)"], timeout: 0.2)
        }
        #expect(Date().timeIntervalSince(began) < 4)
    }
    @Test func cancellingCollectorTerminatesChildWithoutWaitingForTimeout() async throws {
        let began = Date()
        let task = Task {
            try await CodingUsageProcess.run(executableURL: URL(fileURLWithPath: testPython),
                                             arguments: ["-c", "import time; time.sleep(10)"], timeout: 30)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(began) < 4)
    }
    @Test func discoversAdditionalProvidersAndKeepsUsageWhenSessionsFail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccusage-fake-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("ccusage")
        let sample = String(decoding: try data(rawDay()), as: UTF8.self)
        let script = """
        #!\(testPython)
        import sys,json
        args=sys.argv[1:]
        if args==['--help']:
            print('  claude    Show Claude usage\\n  codex    Show Codex usage\\n  grok    Show Grok usage\\n  opencode    Show OpenCode usage\\n  pi    Show pi usage')
            raise SystemExit
        if args[0]=='daily':
            print(json.dumps({'daily':[{'agents':[{'agent':'opencode'},{'agent':'pi'}]}]}))
            raise SystemExit
        source,section=args[:2]
        if source=='codex':raise SystemExit(3)
        if source=='grok':print(json.dumps({('daily' if section=='daily' else 'sessions'):[]}));raise SystemExit
        if section=='daily':print(json.dumps({'daily':[
        \(sample)
        ]}));raise SystemExit
        if source=='opencode':print('invalid');raise SystemExit
        print(json.dumps({'sessions':[{'sessionId':source+'-private','lastActivity':'2026-09-05T04:00:00Z','modelsUsed':['model-a']}]}))
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let results = await CcusageCollector(executableURL: executable, offline: true).collect(at: now)
        var successes: [String: CodingUsageSourceReport] = [:]
        var failures: [String: Bool] = [:]
        for result in results {
            switch result {
            case let .success(report): successes[report.sourceID] = report
            case let .failure(sourceID, _, unavailable): failures[sourceID] = unavailable
            }
        }
        #expect(successes.keys.sorted() == ["claude", "opencode", "pi"])
        #expect(successes["opencode"]?.days.first?.totalTokens == 37)
        #expect(successes["opencode"]?.diagnosticError != nil)
        #expect(failures["codex"] == false)
        #expect(failures["antigravity"] == true)
        #expect(failures["grok"] == true)
    }
    @Test func ompStoreIsCollectedWhenDiscoveryCannotSeeIt() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("omp-pi-" + UUID().uuidString)
        let sessions = home.appendingPathComponent(".omp/agent/sessions/-proj")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("{}\n".utf8).write(to: sessions.appendingPathComponent("one.jsonl"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccusage-omp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("ccusage")
        let sample = String(decoding: try data(rawDay()), as: UTF8.self)
        let script = """
        #!\(testPython)
        import sys, json
        args=sys.argv[1:]
        if args==['--help']:
            print('  claude    Show Claude usage\\n  pi    Show pi usage')
            raise SystemExit
        if args[0]=='daily':
            print('{"daily":[]}')
            raise SystemExit
        if args[0]=='pi':
            joined=args[args.index('--pi-path')+1]
            if '.pi/agent/sessions' not in joined or '.omp/agent/sessions' not in joined:
                raise SystemExit(2)
            if args[1]=='daily':
                print(json.dumps({'daily':[\(sample)]}))
                raise SystemExit
            print('{"sessions":[]}')
            raise SystemExit
        print('{"daily":[]}' if args[1]=='daily' else '{"sessions":[]}')
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let results = await CcusageCollector(executableURL: executable, sourceIDs: ["claude"], offline: true, home: home)
            .collect(at: now)
        let pi = results.compactMap { if case let .success(report) = $0, report.sourceID == "pi" { report } else { nil } }
        #expect(pi.count == 1)
        #expect(pi.first?.days.first?.totalTokens == 37)
        #expect(pi.first?.days.first?.models["model-a"] == 37)
    }

}
