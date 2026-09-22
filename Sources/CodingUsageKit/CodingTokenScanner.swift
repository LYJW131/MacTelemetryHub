import Foundation
import CoreFoundation

public struct CodingTokenCounts: Codable, Equatable, Sendable {
    public var id: String
    public var model: String?
    public var inputTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var cacheReadTokens: Int64 = 0
    public var cacheCreationTokens: Int64 = 0
    public var reasoningTokens: Int64 = 0
    public var eventCount: Int64 = 0
}
public struct CodingTokenWindow: Codable, Equatable, Sendable {
    public var from: Int64
    public var to: Int64
    public var agents: [CodingTokenCounts]
}
public struct CodingTokenSource: Codable, Equatable, Sendable {
    public var id: String
    public var state: String
}
public struct CodingTokenUsage: Codable, Equatable, Sendable {
    public var from: Int64
    public var to: Int64
    public var collectedAt: Int64
    public var sources: [CodingTokenSource]
    public var windows: [CodingTokenWindow]
}

/// Reads only Claude Code usage metadata. Codex logs are not walked: the live “正在使用”
/// signal comes from a hook, and this scan is the manual `coding-usage pulse` diagnostic.
/// Prompt, response text, paths and session IDs never leave the scanner.
/// Per-file offsets avoid re-reading unchanged history; restart safely replays and deduplicates it.
public struct CodingTokenScanner: Sendable {
    private struct Event: Sendable { var at: Int64; var counts: CodingTokenCounts }
    private struct FileState: Sendable {
        var offset: UInt64 = 0
        var tail = Data()
        var session: String = ""
        var incomplete = false
        var model: String?
        var lastTotal: Int64?
        var events: [String: Event] = [:]
    }
    private var files: [String: FileState] = [:]
    public init() {}
    public mutating func scan(home: URL, at now: Date = Date()) throws -> CodingTokenUsage {
        let end = Int64(now.timeIntervalSince1970 * 1000)
        let start = end - 86_400_000
        let roots = [("claude", home.appendingPathComponent(".claude/projects"))]
        var states = ["claude": "unavailable"]
        var found = Set<String>()
        for (source, root) in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            if states[source] != "partial" { states[source] = "ok" }
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
                states[source] = "partial"; continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                try Task.checkCancellation()
                do {
                    let info = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    guard let modified = info.contentModificationDate, modified.timeIntervalSince1970 * 1000 >= Double(start) else { continue }
                    found.insert(url.path)
                    var file = files[url.path] ?? FileState()
                    if UInt64(info.fileSize ?? 0) < file.offset { file = FileState() }
                    if file.session.isEmpty { file.session = url.lastPathComponent }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: file.offset)
                    while let data = try handle.read(upToCount: 262_144), !data.isEmpty {
                        try Task.checkCancellation()
                        file.offset += UInt64(data.count)
                        file.tail.append(data)
                        while let newline = file.tail.firstIndex(of: 10) {
                            let line = Data(file.tail[..<newline])
                            file.tail.removeSubrange(...newline)
                            if !line.isEmpty {
                                do { try Self.consume(line, source: source, start: start, end: end, file: &file) }
                                catch { file.incomplete = true }
                            }
                        }
                        if file.tail.count > 16_777_216 { throw CodingUsageError.invalid("Usage log line exceeds limit") }
                    }
                    file.events = file.events.filter { $0.value.at >= start }
                    files[url.path] = file
                    if file.incomplete { states[source] = "partial" }
                } catch is CancellationError { throw CancellationError() }
                catch { states[source] = "partial" }
            }
        }
        files = files.filter { found.contains($0.key) }
        var buckets: [Int64: [String: CodingTokenCounts]] = [:]
        var unique: [String: Event] = [:]
        for file in files.values {
            for (id, event) in file.events where event.at >= start && event.at < end {
                let key = event.counts.id + ":" + id
                if let old = unique[key], old.counts.outputTokens >= event.counts.outputTokens { continue }
                unique[key] = event
            }
        }
        for event in unique.values {
                let bucket = event.at / 300_000 * 300_000
                let key = event.counts.id + ":" + (event.counts.model ?? "")
                var total = buckets[bucket]?[key] ?? CodingTokenCounts(id: event.counts.id, model: event.counts.model)
                let c = event.counts
                total.inputTokens += c.inputTokens; total.outputTokens += c.outputTokens
                total.cacheReadTokens += c.cacheReadTokens; total.cacheCreationTokens += c.cacheCreationTokens
                total.reasoningTokens += c.reasoningTokens; total.eventCount += c.eventCount
                buckets[bucket, default: [:]][key] = total
        }
        return CodingTokenUsage(from: start, to: end, collectedAt: end,
            sources: ["claude"].map { CodingTokenSource(id: $0, state: states[$0]!) },
            windows: buckets.keys.sorted().map { from in CodingTokenWindow(from: from, to: from + 300_000,
                agents: buckets[from]!.values.sorted { ($0.id + ($0.model ?? "")) < ($1.id + ($1.model ?? "")) }) })
    }
    private static func consume(_ data: Data, source: String, start: Int64, end: Int64, file: inout FileState) throws {
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let payload = row["payload"] as? [String: Any] ?? [:]
        if source == "codex", row["type"] as? String == "session_meta", let id = payload["id"] as? String {
            file.session = id; return
        }
        if source == "codex", row["type"] as? String == "turn_context" {
            file.model = (payload["model"] as? String).map { String($0.prefix(80)) }; return
        }
        guard let stamp = row["timestamp"] as? String else { return }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
        guard let date else { return }
        let at = Int64(date.timeIntervalSince1970 * 1000)
        func number(_ object: [String: Any], _ key: String) throws -> Int64 {
            guard let value = object[key] else { return 0 }
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                  n.doubleValue >= 0, n.doubleValue <= 1_000_000_000_000, n.doubleValue.rounded() == n.doubleValue else {
                throw CodingUsageError.invalid("Invalid usage count")
            }
            return n.int64Value
        }
        var counts = CodingTokenCounts(id: source, model: file.model)
        let identity: String
        if source == "codex" {
            guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
                  let usage = info["last_token_usage"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any] else { return }
            let totalTokens = try number(total, "total_tokens")
            guard totalTokens != file.lastTotal else { return }
            file.lastTotal = totalTokens
            identity = "\(file.session):\(stamp):\(totalTokens)"
            let input = try number(usage, "input_tokens")
            counts.cacheReadTokens = try number(usage, "cached_input_tokens")
            guard input >= counts.cacheReadTokens else { throw CodingUsageError.invalid("Cache exceeds input") }
            counts.inputTokens = input - counts.cacheReadTokens
            counts.outputTokens = try number(usage, "output_tokens")
            counts.reasoningTokens = try number(usage, "reasoning_output_tokens")
        } else {
            guard row["type"] as? String == "assistant", let message = row["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any], let id = message["id"] as? String else { return }
            identity = id // streaming records replace previous usage for the same response
            counts.model = (message["model"] as? String).map { String($0.prefix(80)) }
            counts.inputTokens = try number(usage, "input_tokens")
            counts.outputTokens = try number(usage, "output_tokens")
            counts.cacheReadTokens = try number(usage, "cache_read_input_tokens")
            counts.cacheCreationTokens = try number(usage, "cache_creation_input_tokens")
        }
        guard counts.reasoningTokens <= counts.outputTokens else { throw CodingUsageError.invalid("Reasoning exceeds output") }
        counts.eventCount = 1
        if source == "claude", let previous = file.events[identity]?.counts {
            counts.inputTokens = max(counts.inputTokens, previous.inputTokens)
            counts.outputTokens = max(counts.outputTokens, previous.outputTokens)
            counts.cacheReadTokens = max(counts.cacheReadTokens, previous.cacheReadTokens)
            counts.cacheCreationTokens = max(counts.cacheCreationTokens, previous.cacheCreationTokens)
        }
        if at >= start { file.events[identity] = Event(at: file.events[identity]?.at ?? at, counts: counts) }
    }
}
