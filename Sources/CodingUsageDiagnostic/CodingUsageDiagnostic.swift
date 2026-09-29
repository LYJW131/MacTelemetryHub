import CodingUsageKit
import Foundation

/**
 * Reproducible read-only collection. Writing an output file never posts it to a site.
 *
 * `--output` 写的是信封里 `modules` 的那几格（`codingUsage` / `codingActivity` / `codingTokenBuckets`），
 * 和 App 上报的是同一份，可以原样拼进一封 v4 信封。
 */
@main
struct CodingUsageDiagnostic {
    /// 信封 `modules` 里的 coding 三格；没有的那格整个省略
    private struct Modules: Encodable {
        var codingUsage: CodingUsageReport?
        var codingActivity: CodingActivityReport?
        var codingTokenBuckets: CodingTokenBucketReport?
    }

    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, ["collect", "report", "sessions", "pulse"].contains(command) else {
            print("coding-usage collect|report|sessions|pulse [--ledger <path>] [--ccusage <path>] [--output <path>] [--offline]")
            return
        }
        args.removeFirst()
        var values: [String: String] = [:]
        var flags = Set<String>()
        while !args.isEmpty {
            let key = args.removeFirst()
            if key == "--offline" { flags.insert(key); continue }
            guard ["--ledger", "--ccusage", "--output"].contains(key), !args.isEmpty else {
                throw CodingUsageError.invalid("无效诊断参数：\(key)")
            }
            values[key] = args.removeFirst()
        }
        if command == "pulse" {
            var scanner = CodingTokenScanner()
            let buckets = try scanner.scan(home: FileManager.default.homeDirectoryForCurrentUser)
            try write(Modules(codingTokenBuckets: buckets), to: values["--output"])
            try printSummary(["buckets": bucketSummary(buckets)])
            return
        }
        guard let ledgerPath = values["--ledger"] else {
            throw CodingUsageError.invalid("请用 --ledger 指定独立诊断账本")
        }
        let engine = CodingUsageEngine(ledgerURL: URL(fileURLWithPath: ledgerPath))
        if command == "report" {
            let usage = try await engine.usage()
            try write(Modules(codingUsage: usage.report.agents.isEmpty ? nil : usage.report), to: values["--output"])
            try printSummary(usageSummary(usage))
            return
        }
        guard let cliPath = values["--ccusage"] else { throw CodingUsageError.invalid("请指定 --ccusage") }
        let executable = URL(fileURLWithPath: cliPath)
        if command == "sessions" {
            let sessions = try await engine.refreshSessions(executableURL: executable, forceCcusage: true)
            try write(Modules(codingActivity: sessions.activity, codingTokenBuckets: sessions.buckets), to: values["--output"])
            try printSummary([
                "activity": sessions.activity.agents.map { agent -> [String: Any] in
                    ["id": agent.id, "lastActivityAt": json(agent.lastActivityAt), "model": json(agent.model)]
                },
                "buckets": bucketSummary(sessions.buckets),
                "problems": sessions.problems,
            ])
            return
        }
        let usage = try await engine.refresh(executableURL: executable, offline: flags.contains("--offline"))
        try write(Modules(codingUsage: usage.report.agents.isEmpty ? nil : usage.report), to: values["--output"])
        try printSummary(usageSummary(usage))
    }

    private static func write(_ modules: Modules, to path: String?) throws {
        guard let path else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(modules).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// 标准输出只给数量和来源健康，不打印日行本身
    private static func usageSummary(_ usage: CodingUsageRefresh) -> [String: Any] {
        [
            "agents": usage.report.agents.map { agent -> [String: Any] in
                let days = agent.days ?? []
                return [
                    "id": agent.id, "state": agent.state.rawValue,
                    "collectedAt": json(agent.collectedAt), "sessionCount": json(agent.sessionCount),
                    "days": days.count, "from": json(days.first?.date), "to": json(days.last?.date),
                    "error": json(agent.error), "warning": json(agent.warning),
                ]
            },
            "problems": usage.problems,
        ]
    }

    private static func bucketSummary(_ buckets: CodingTokenBucketReport) -> [String: Any] {
        [
            "windows": buckets.windows.count,
            "agents": buckets.agents.map { "\($0.id): \($0.state.rawValue)" },
        ]
    }

    /// JSONSerialization 认 NSNull 不认 nil
    private static func json(_ value: Any?) -> Any { value ?? NSNull() }

    private static func printSummary(_ summary: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
