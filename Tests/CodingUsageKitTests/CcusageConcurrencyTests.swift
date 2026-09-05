import Foundation
import Testing
@testable import CodingUsageKit

struct CcusageConcurrencyTests {
    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    @Test func cancelledSQLiteWaiterNeverRunsAndDoesNotBlockFollowingWork() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let counter = Counter()
        let first = Task {
            try await CcusageSQLiteAccess.run {
                entered.continuation.yield(())
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        for await _ in entered.stream { break }
        let cancelled = Task {
            try await CcusageSQLiteAccess.run { await counter.increment() }
        }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await first.value
        try await CcusageSQLiteAccess.run { await counter.increment() }
        #expect(await counter.value == 1)
    }

    @Test func discoveryIsSingleFlightAndOneSubscriberMayCancelIndependently() async throws {
        let discovery = CcusageSourceDiscovery()
        let counter = Counter()
        let entered = AsyncStream<Void>.makeStream()
        let first = Task {
            try await discovery.resolve("source-key", useCache: false) {
                await counter.increment()
                entered.continuation.yield(())
                try await Task.sleep(for: .milliseconds(150))
                return ["claude", "opencode"]
            }
        }
        for await _ in entered.stream { break }
        let second = Task {
            try await discovery.resolve("source-key", useCache: false) {
                await counter.increment()
                return ["wrong"]
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value == ["claude", "opencode"])
        #expect(await counter.value == 1)
        #expect(await discovery.get("source-key") == ["claude", "opencode"])
    }

    @Test func usageAndSessionCollectorsShareDiscoveryAndSQLiteExclusion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccusage-concurrency-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("ccusage")
        let script = """
        #!/usr/bin/python3
        import sys,json,time,fcntl,pathlib
        folder=pathlib.Path(__file__).parent
        args=sys.argv[1:]
        if args==['--help']:
            print('  antigravity    Show Antigravity usage')
            raise SystemExit
        with open(folder/'sqlite.lock','a') as guard:
            try:fcntl.flock(guard,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:raise SystemExit(77)
            with open(folder/'operations.log','a') as log:log.write(args[0]+':'+args[1]+'\\n')
            time.sleep(0.12)
            if args[0]=='daily':
                print(json.dumps({'daily':[{'agents':[{'agent':'antigravity'}]}]}))
            elif args[1]=='daily':
                print(json.dumps({'daily':[{'date':'2026-09-05','inputTokens':3,'outputTokens':1,'cacheReadTokens':0,'cacheCreationTokens':0,'totalTokens':4,'totalCost':1,'modelBreakdowns':[{'modelName':'test','inputTokens':3,'outputTokens':1,'cacheReadTokens':0,'cacheCreationTokens':0,'cost':1}]}]}))
            else:
                print(json.dumps({'sessions':[{'sessionId':'private','lastActivity':'2026-09-05T04:00:00Z','modelsUsed':['test']}]}))
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let usageCollector = CcusageCollector(executableURL: executable, sourceIDs: ["antigravity"], offline: true)
        let sessionCollector = CcusageCollector(executableURL: executable, sourceIDs: ["antigravity"], offline: true)
        async let usage = usageCollector.collect(at: CodingUsageDates.parseInstant("2026-09-05T04:00:00Z")!)
        async let sessions = sessionCollector.collectSessions()
        let (usageResults, sessionResults) = await (usage, sessions)
        #expect(usageResults.count == 1)
        #expect(sessionResults.count == 1)
        guard case let .success(report) = usageResults[0], case .success = sessionResults[0] else {
            Issue.record("Concurrent collectors failed or overlapped SQLite readers")
            return
        }
        #expect(report.diagnosticError == nil)
        let operations = try String(contentsOf: directory.appendingPathComponent("operations.log"), encoding: .utf8)
            .split(separator: "\n")
        #expect(operations.filter { $0.hasPrefix("daily:") }.count == 1)
        #expect(operations.count == 4)
    }
}
