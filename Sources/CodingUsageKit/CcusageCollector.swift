import Foundation
import CryptoKit
import CoreFoundation
import Darwin

public enum CodingUsageSessionsResult: Sendable {
    case success(sourceID: String, sessions: [CodingUsageSessionRecord])
    case failure(sourceID: String, message: String, unavailable: Bool)
}

/// ccusage is the sole local usage parser. Each provider fails independently.
public struct CcusageCollector: Sendable {
    public var executableURL: URL
    public var environment: [String: String]
    public var sourceIDs: [String]
    public var timeout: TimeInterval
    public var offline: Bool

    public init(executableURL: URL, environment: [String: String] = [:],
                sourceIDs: [String] = ["claude", "codex", "grok", "antigravity"],
                timeout: TimeInterval = 90, offline: Bool = false) {
        self.executableURL = executableURL; self.environment = environment
        self.sourceIDs = sourceIDs; self.timeout = timeout; self.offline = offline
    }

    public func collect(at now: Date = Date()) async -> [CodingUsageSourceResult] {
        let available = await availableSources()
        let (discovered, discoveryError) = await discoveredSources(useCache: false)
        let requested = Set(sourceIDs).union(discovered)
        return await withTaskGroup(of: CodingUsageSourceResult.self, returning: [CodingUsageSourceResult].self) { group in
            for source in requested.sorted() {
                group.addTask {
                    if let available, !available.contains(source) {
                        return .failure(sourceID: source, message: "当前 ccusage 版本不支持此来源", unavailable: true)
                    }
                    do {
                        // In particular, Antigravity's SQLite reader cannot safely open the same
                        // WAL databases twice concurrently. Providers still run in parallel.
                        let dayData = try await run(source: source, section: "daily")
                        let (data, sessionError) = await sessionData(source: source)
                        var report: CodingUsageSourceReport
                        do {
                            report = try CcusageParser.parse(sourceID: source, daily: dayData, sessions: data, collectedAt: now)
                        } catch {
                            // A damaged session index must not discard successfully parsed token history.
                            report = try CcusageParser.parse(sourceID: source, daily: dayData,
                                                            sessions: Data("{\"sessions\":[]}".utf8), collectedAt: now)
                            report.diagnosticError = "会话元数据解析失败，已保留既有会话"
                        }
                        if let sessionError { report.diagnosticError = sessionError }
                        if let discoveryError {
                            report.diagnosticError = [report.diagnosticError, discoveryError].compactMap { $0 }.joined(separator: "；")
                        }
                        if report.days.isEmpty && report.sessions.isEmpty {
                            return .failure(sourceID: source, message: "ccusage 未发现本地用量或会话记录", unavailable: true)
                        }
                        return .success(report)
                    } catch {
                        return .failure(sourceID: source, message: "ccusage \(source)：\(error.localizedDescription)", unavailable: false)
                    }
                }
            }
            var results: [CodingUsageSourceResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    public func collectSessions() async -> [CodingUsageSessionsResult] {
        let available = await availableSources()
        let (discovered, _) = await discoveredSources(useCache: true)
        return await withTaskGroup(of: CodingUsageSessionsResult.self, returning: [CodingUsageSessionsResult].self) { group in
            for source in Set(sourceIDs).union(discovered).sorted() {
                group.addTask {
                    if let available, !available.contains(source) {
                        return .failure(sourceID: source, message: "当前 ccusage 版本不支持 \(source)", unavailable: true)
                    }
                    do {
                        let data = try await run(source: source, section: "session")
                        let sessions = try CcusageParser.parseSessions(sourceID: source, data: data)
                        return .success(sourceID: source, sessions: sessions)
                    } catch {
                        return .failure(sourceID: source, message: "ccusage \(source) 会话：\(error.localizedDescription)", unavailable: false)
                    }
                }
            }
            var results: [CodingUsageSessionsResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    private func run(source: String, section: String) async throws -> Data {
        var arguments = [source, section, "--json", "--no-color", "--timezone", "Asia/Shanghai"]
        // These are ALL historical records, deliberately without --since / --until.
        if source != "codex" { arguments += ["--mode", "calculate"] }
        if offline { arguments.append("--offline") }
        if source == "antigravity" {
            let commandArguments = arguments
            return try await CcusageSQLiteAccess.run {
                try await CodingUsageProcess.run(executableURL: executableURL, arguments: commandArguments,
                                                 environment: environment, timeout: timeout)
            }
        }
        return try await CodingUsageProcess.run(executableURL: executableURL, arguments: arguments,
                                                environment: environment, timeout: timeout)
    }

    private func sessionData(source: String) async -> (Data, String?) {
        do { return (try await run(source: source, section: "session"), nil) }
        catch { return (Data("{\"sessions\":[]}".utf8), "会话采集失败，已保留既有会话：\(error.localizedDescription)") }
    }
    private func availableSources() async -> Set<String>? {
        guard let data = try? await CodingUsageProcess.run(executableURL: executableURL, arguments: ["--help"],
                                                          environment: environment, timeout: min(timeout, 10)),
              let help = String(data: data, encoding: .utf8) else { return nil }
        return Set(help.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("  "), line.contains("Show ") else { return nil }
            return line.split(whereSeparator: \.isWhitespace).first.map(String.init)
        })
    }

    private func discoveredSources(useCache: Bool) async -> (Set<String>, String?) {
        let fingerprint = executableURL.path + environment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "\u{0}")
        let key = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        do {
            let ids = try await CcusageSourceDiscovery.shared.resolve(key, useCache: useCache) {
                let data = try await CcusageSQLiteAccess.run {
                    try await CodingUsageProcess.run(
                        executableURL: executableURL,
                        arguments: ["daily", "--by-agent", "--json", "--no-color", "--offline", "--timezone", "Asia/Shanghai"],
                        environment: environment, timeout: timeout)
                }
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let days = root["daily"] as? [[String: Any]] else {
                    throw CodingUsageError.invalid("全来源发现响应无效")
                }
                var ids = Set<String>()
                for day in days {
                    for row in day["agents"] as? [[String: Any]] ?? [] {
                        if let id = row["agent"] as? String, !id.isEmpty, id != "all" { ids.insert(id) }
                    }
                }
                return ids
            }
            return (ids, nil)
        } catch {
            let previous = await CcusageSourceDiscovery.shared.get(key, allowExpired: true) ?? []
            return (previous, "全来源发现失败，仅刷新已知来源")
        }
    }
}

public enum CcusageParser {
    public static func parse(sourceID: String, daily: Data, sessions: Data,
                             collectedAt: Date = Date()) throws -> CodingUsageSourceReport {
        let root = try object(daily)
        guard let rows = root["daily"] as? [[String: Any]] else {
            throw CodingUsageError.invalid("daily 响应缺少日桶数组")
        }
        var costComplete = true
        var days: [CodingUsageDayRecord] = []
        var unclassifiedTotal: Int64 = 0
        var unique: [String: CodingUsageDayRecord] = [:]
        for raw in rows {
            guard let date = raw["date"] as? String, CodingUsageDates.parseDay(date) != nil else {
                throw CodingUsageError.invalid("daily 响应包含无效日期")
            }
            let components = try tokens(raw, antigravityDay: sourceID == "antigravity",
                                        allowUnclassified: sourceID != "antigravity")
            let cost = try amount(raw["totalCost"] ?? raw["costUSD"], field: "费用")
            var models: [String: Int64] = [:]
            if let breakdowns = raw["modelBreakdowns"] as? [[String: Any]] {
                for model in breakdowns {
                    guard let name = model["modelName"] as? String, !name.isEmpty else {
                        throw CodingUsageError.invalid("模型拆分缺少名称")
                    }
                    let values = try tokens(model, allowUnclassified: true)
                    models[name] = try CodingUsageLedger.add(models[name, default: 0], values.total)
                    let modelCost = try amount(model["cost"], field: "模型费用")
                    if values.total > 0 && (modelCost == nil || modelCost == 0) { costComplete = false }
                }
            } else if let breakdowns = raw["models"] as? [String: [String: Any]] {
                // Focused Codex reports retain reasoning and an authoritative model breakdown.
                // v20 has only daily costUSD, no proof every model was priced. Keep known cost,
                // but never label that partial amount complete.
                for (name, model) in breakdowns {
                    let values = try tokens(model, allowUnclassified: true)
                    models[name] = values.total
                    let modelCost = try amount(model["costUSD"] ?? model["cost"], field: "模型费用")
                    if values.total > 0 && modelCost == nil {
                        costComplete = false
                    }
                }
            } else if components.total > 0 {
                throw CodingUsageError.invalid("有用量的日桶缺少模型拆分")
            }
            if components.total > 0 && (cost == nil || cost == 0) { costComplete = false }
            if sourceID == "antigravity", components.reasoning > 0 { costComplete = false }
            let day = CodingUsageDayRecord(
                date: date, inputTokens: components.input, outputTokens: components.output,
                cacheReadTokens: components.cacheRead, cacheCreationTokens: components.cacheCreation,
                reasoningTokens: components.reasoning, totalTokens: components.total,
                apiEquivalentCostUSD: cost, models: models,
                unclassifiedTokens: components.unclassified > 0 ? components.unclassified : nil
            )
            try CodingUsageLedger.validate(day)
            if let previous = unique[date] {
                guard previous == day else { throw CodingUsageError.invalid("daily 返回冲突的重复日期") }
            } else {
                unique[date] = day; days.append(day)
                unclassifiedTotal = try CodingUsageLedger.add(unclassifiedTotal, components.unclassified)
            }
        }
        days.sort { $0.date < $1.date }
        let sessionRows = try parseSessions(sourceID: sourceID, data: sessions)
        let today = CodingUsageDates.day(collectedAt)
        // Sparse reports do not explicitly correct omitted dates to zero. A successful coverage
        // boundary can render an empty today, but must not erase a previously observed active day.
        return CodingUsageSourceReport(
            sourceID: sourceID, days: days, sessions: sessionRows, collectedAt: collectedAt,
            coverageStart: days.first?.date, coverageEnd: today,
            precision: .measured,
            costComplete: costComplete, completeDates: Set(days.map(\.date)), authoritative: true,
            diagnosticError: unclassifiedTotal > 0 ? "历史记录有 \(unclassifiedTotal) token 未提供分列，已保留实测总量" : nil
        )
    }

    public static func parseSessions(sourceID: String, data: Data) throws -> [CodingUsageSessionRecord] {
        let root = try object(data)
        guard let rows = root["sessions"] as? [[String: Any]] else {
            throw CodingUsageError.invalid("session 响应缺少会话数组")
        }
        var unique: [String: CodingUsageSessionRecord] = [:]
        for raw in rows {
            guard let identity = raw["sessionId"] as? String, !identity.isEmpty else {
                throw CodingUsageError.invalid("会话记录缺少稳定标识")
            }
            let identityHash = SHA256.hash(data: Data((sourceID + "\u{0}" + identity).utf8))
                .map { String(format: "%02x", $0) }.joined()
            var activity: Date?
            if let value = raw["lastActivity"] {
                guard let text = value as? String, let date = CodingUsageDates.parseInstant(text) else {
                    throw CodingUsageError.invalid("会话活动时间不是精确时间戳")
                }
                activity = date
            }
            let names = (raw["modelsUsed"] as? [String]) ?? (raw["models"] as? [String]) ?? []
            let explicit = raw["currentModel"] as? String
            // A model set has no chronological ordering. Do not present its last element as now.
            let model = explicit ?? (names.count == 1 ? names.first : nil)
            let row = CodingUsageSessionRecord(identityHash: identityHash, lastActivityAt: activity, currentModel: model)
            if unique[identityHash] == nil || (activity ?? .distantPast) >= (unique[identityHash]?.lastActivityAt ?? .distantPast) {
                unique[identityHash] = row
            }
        }
        return unique.values.sorted { $0.identityHash < $1.identityHash }
    }

    private struct Tokens {
        let input, output, cacheRead, cacheCreation, reasoning, total, unclassified: Int64
    }
    private static func tokens(_ raw: [String: Any], antigravityDay: Bool = false, allowUnclassified: Bool = false) throws -> Tokens {
        let input = try integer(raw["inputTokens"], field: "inputTokens")
        var output = try integer(raw["outputTokens"], field: "outputTokens")
        let read = try integer(raw["cacheReadTokens"], field: "cacheReadTokens")
        let creation = try integer(raw["cacheCreationTokens"], field: "cacheCreationTokens")
        var reasoning = try integer(raw["reasoningOutputTokens"] ?? raw["reasoningTokens"], field: "reasoningTokens", optional: true)
        let sum = try [input, output, read, creation].reduce(Int64(0), CodingUsageLedger.add)
        let total = raw["totalTokens"] == nil ? sum : try integer(raw["totalTokens"], field: "totalTokens")
        // Antigravity's provider reports thinking separately in totalTokens, while ccusage's
        // day JSON omits that column. Its documented residual belongs to output, not input.
        if antigravityDay && total > sum {
            let thinking = total - sum
            output = try CodingUsageLedger.add(output, thinking)
            reasoning = max(reasoning, thinking)
        }
        let unclassified = allowUnclassified && total > sum ? total - sum : 0
        guard (total == sum || ((antigravityDay || allowUnclassified) && total > sum)), reasoning <= output else {
            throw CodingUsageError.invalid("Token 总量或缓存/推理口径不一致")
        }
        return Tokens(input: input, output: output, cacheRead: read, cacheCreation: creation, reasoning: reasoning, total: total, unclassified: unclassified)
    }
    private static func integer(_ raw: Any?, field: String, optional: Bool = false) throws -> Int64 {
        if raw == nil && optional { return 0 }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue <= 9_007_199_254_740_991,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else {
            throw CodingUsageError.invalid("\(field) 必须是非负安全整数")
        }
        return number.int64Value
    }
    private static func amount(_ raw: Any?, field: String) throws -> Double? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else {
            throw CodingUsageError.invalid("\(field) 必须是非负有限数字")
        }
        return number.doubleValue
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodingUsageError.invalid("ccusage 输出不是 JSON 对象")
        }
        return value
    }
}

/// Pipes are drained concurrently, including stderr, with bounded memory and a wall-clock timeout.
public enum CodingUsageProcess {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var exited = false
        private var processID: Int32?
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func attach(_ pid: Int32) {
            lock.lock()
            guard !exited else { lock.unlock(); return }
            processID = pid; let stop = cancelled; lock.unlock()
            if stop { terminate(pid) }
        }
        func didExit() { lock.lock(); exited = true; processID = nil; lock.unlock() }
        func cancel() {
            lock.lock(); cancelled = true; let pid = processID; lock.unlock()
            if let pid { terminate(pid) }
        }
        private func terminate(_ pid: Int32) {
            kill(pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock(); let stillRunning = processID == pid; lock.unlock()
                if stillRunning { kill(pid, SIGKILL) }
            }
        }
    }
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var overflow = false
        func drain(_ handle: FileHandle, limit: Int) {
            while true {
                let part: Data
                do { part = try handle.read(upToCount: 65_536) ?? Data() } catch { break }
                if part.isEmpty { break }
                lock.lock()
                if data.count + part.count <= limit { data.append(part) } else { overflow = true }
                lock.unlock()
            }
        }
        func result() -> (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (data, overflow) }
    }

    public static func run(executableURL: URL, arguments: [String], environment: [String: String] = [:],
                           timeout: TimeInterval = 90) async throws -> Data {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached {
                try runSynchronously(executableURL: executableURL, arguments: arguments,
                                     environment: environment, timeout: timeout, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    private static func runSynchronously(executableURL: URL, arguments: [String], environment: [String: String],
                                         timeout: TimeInterval, cancellation: Cancellation) throws -> Data {
            if cancellation.isCancelled { throw CancellationError() }
            guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                throw CodingUsageError.command("CLI 路径不可执行")
            }
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            var vars = ProcessInfo.processInfo.environment
            vars.merge(environment) { _, replacement in replacement }
            let bin = executableURL.deletingLastPathComponent().path
            vars["PATH"] = bin + ":/opt/homebrew/bin:/usr/local/bin:" + (vars["PATH"] ?? "/usr/bin:/bin")
            process.environment = vars
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output; process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in cancellation.didExit(); exited.signal() }
            try process.run()
            cancellation.attach(process.processIdentifier)
            let capturedOutput = Capture(), capturedErrors = Capture()
            let drain = DispatchGroup()
            drain.enter()
            DispatchQueue.global(qos: .utility).async {
                capturedOutput.drain(output.fileHandleForReading, limit: 128 * 1024 * 1024)
                drain.leave()
            }
            drain.enter()
            DispatchQueue.global(qos: .utility).async {
                capturedErrors.drain(errors.fileHandleForReading, limit: 1024 * 1024)
                drain.leave()
            }
            let timedOut = exited.wait(timeout: .now() + max(0.1, timeout)) == .timedOut
            if timedOut {
                process.terminate()
                if exited.wait(timeout: .now() + 1) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 1)
                }
            }
            // A wrapper may leave inherited pipe descriptors in a child. Never wait indefinitely.
            if drain.wait(timeout: .now() + 2) == .timedOut {
                try? output.fileHandleForReading.close()
                try? errors.fileHandleForReading.close()
            }
            if timedOut { throw CodingUsageError.command("采集超时") }
            if cancellation.isCancelled { throw CancellationError() }
            guard process.terminationStatus == 0 else {
                // stderr may contain local paths; only the exit status crosses the CLI boundary.
                throw CodingUsageError.command("退出码 \(process.terminationStatus)")
            }
            let (data, overflow) = capturedOutput.result()
            guard !overflow else { throw CodingUsageError.command("JSON 输出超过允许大小") }
            return data
    }
}
