import CodingUsageKit
import Foundation

/// Reproducible read-only collection. Writing an output file never posts it to a site.
@main
struct CodingUsageDiagnostic {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, ["collect", "snapshot", "sessions", "pulse"].contains(command) else {
            print("coding-usage collect|snapshot|sessions|pulse --ledger <path> --ccusage <path> [--output <path>] [--offline] [--local-only]")
            return
        }
        args.removeFirst()
        var values: [String: String] = [:]
        var flags = Set<String>()
        while !args.isEmpty {
            let key = args.removeFirst()
            if ["--offline", "--local-only"].contains(key) { flags.insert(key); continue }
            guard ["--ledger", "--ccusage", "--output"].contains(key), !args.isEmpty else {
                throw CodingUsageError.invalid("无效诊断参数：\(key)")
            }
            values[key] = args.removeFirst()
        }
        if command == "pulse" {
            var scanner = CodingTokenScanner()
            let value = try scanner.scan(home: FileManager.default.homeDirectoryForCurrentUser)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            if let output = values["--output"] {
                try encoder.encode(value).write(to: URL(fileURLWithPath: output), options: .atomic)
            }
            print("Collected \(value.windows.count) five-minute token windows; " + value.sources.map { "\($0.id): \($0.state)" }.joined(separator: ", "))
            return
        }
        guard let ledgerPath = values["--ledger"] else {
            throw CodingUsageError.invalid("请用 --ledger 指定独立诊断账本")
        }
        let engine = CodingUsageEngine(ledgerURL: URL(fileURLWithPath: ledgerPath))
        let snapshot: CodingUsageSnapshot
        if command == "snapshot" { snapshot = try await engine.snapshot() }
        else {
            guard let cliPath = values["--ccusage"] else { throw CodingUsageError.invalid("请指定 --ccusage") }
            if command == "sessions" {
                snapshot = try await engine.refreshSessions(executableURL: URL(fileURLWithPath: cliPath)).snapshot
            } else {
                snapshot = try await engine.refresh(executableURL: URL(fileURLWithPath: cliPath),
                                                    offline: flags.contains("--offline"),
                                                    includeCursor: !flags.contains("--local-only"))
            }
        }
        if let output = values["--output"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(snapshot).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        let summary: [String: Any] = [
            "totalTokens": snapshot.usage.totals.totalTokens,
            "activeDays": snapshot.usage.totals.activeDays,
            "sessionCount": snapshot.usage.totals.sessionCount,
            "yearDays": snapshot.year.days.count,
            "sources": snapshot.usage.agents.map { agent -> [String: Any] in
                ["id": agent.id, "state": agent.usageStatus.state.rawValue,
                 "from": agent.usageStatus.coverageStart ?? "", "to": agent.usageStatus.coverageEnd ?? "",
                 "costComplete": agent.usageStatus.costComplete, "error": agent.usageStatus.error ?? ""]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
