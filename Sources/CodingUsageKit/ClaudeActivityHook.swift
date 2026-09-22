import Foundation

/// Claude Code hook → “正在使用”. The helper writes one small file; the app does not scan logs.
public enum ClaudeActivityHook {
    public static let helperExecutableName = "claude-activity-hook"
    /// Events that mean a Claude Code session is in progress or just changed model.
    /// Tool batches keep a long turn inside the five-minute activity window.
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PostToolBatch", "Stop", "StopFailure",
        "PostModelSwitch", "SessionEnd",
    ]
    /// While a turn is in progress, republish at this interval so the site's window stays open.
    public static let publishInterval: TimeInterval = 60
    public static let activeWindow: TimeInterval = 300

    public struct Notice: Equatable, Sendable {
        public var event: String
        public var model: String?
        public var at: Date
    }

    public static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/MacTelemetryHub/claude-activity")
    }

    public static func latestURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        directory(home: home).appendingPathComponent("latest.json")
    }

    public static func settingsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    /// Reads a hook stdin payload and keeps only the event name, model, and time.
    /// Prompt text, transcripts, and tool input are dropped before anything is written.
    public static func notice(from data: Data, at receivedAt: Date = Date()) -> Notice? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let notice = notice(from: object, at: receivedAt) {
            return notice
        }
        return noticeScanningPrefix(data, at: receivedAt)
    }

    public static func record(
        _ stdin: Data, at date: Date = Date(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard let notice = notice(from: stdin, at: date) else { return }
        var payload: [String: Any] = [
            "hookEventName": notice.event,
            "at": date.timeIntervalSince1970,
        ]
        if let model = notice.model { payload["model"] = model }
        let url = latestURL(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    public static func alreadyInstalled(existing: Data?, command: String) -> Bool {
        guard let existing, !existing.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for event in events {
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            let handlers = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            guard handlers.contains(where: { isOurs($0) && ($0["command"] as? String) == command && ($0["async"] as? Bool) == true }) else {
                return false
            }
        }
        return true
    }

    public static func settingsInstalling(existing: Data?, command: String) throws -> Data {
        let root = try mutableRoot(existing)
        let hooks = NSMutableDictionary(dictionary: root["hooks"] as? [String: Any] ?? [:])
        let handler = ownedHandler(command: command)
        for event in events {
            var groups = (hooks[event] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                var copy = group
                let list = (copy["hooks"] as? [[String: Any]] ?? []).filter { !isOurs($0) }
                guard !list.isEmpty else { return nil }
                copy["hooks"] = list
                return copy
            }
            groups.append(["hooks": [handler]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    public static func settingsRemoving(existing: Data) throws -> Data {
        let root = try mutableRoot(existing)
        guard let current = root["hooks"] as? [String: Any] else {
            return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        }
        let hooks = NSMutableDictionary(dictionary: current)
        for event in events {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                var copy = group
                let list = (copy["hooks"] as? [[String: Any]] ?? []).filter { !isOurs($0) }
                guard !list.isEmpty else { return nil }
                copy["hooks"] = list
                return copy
            }
            if kept.isEmpty { hooks.removeObject(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.count == 0 { root.removeObject(forKey: "hooks") } else { root["hooks"] = hooks }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    public static func install(
        command: String, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let url = settingsURL(home: home)
        let existing = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        if alreadyInstalled(existing: existing, command: command) { return }
        let updated = try settingsInstalling(existing: existing, command: command)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.appendingPathExtension("mac-telemetry-tmp")
        try updated.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    public static func remove(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let url = settingsURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let existing = try Data(contentsOf: url)
        let updated = try settingsRemoving(existing: existing)
        let temporary = url.appendingPathExtension("mac-telemetry-tmp")
        try updated.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    private static func notice(from object: [String: Any], at receivedAt: Date) -> Notice? {
        let event = (object["hook_event_name"] as? String) ?? (object["hookEventName"] as? String) ?? ""
        guard events.contains(event) else { return nil }
        let model = bounded(object["to_model"]) ?? bounded(object["model"])
        let at = (object["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? receivedAt
        return Notice(event: event, model: model, at: at)
    }

    /// A truncated stdin still counts as activity when the event name is in the prefix.
    /// The scan window stays small so a long prompt is never retained.
    private static func noticeScanningPrefix(_ data: Data, at receivedAt: Date) -> Notice? {
        let prefix = data.prefix(8_192)
        guard let text = String(data: prefix, encoding: .utf8) else { return nil }
        guard let event = firstMatch(text, key: "hook_event_name"), events.contains(event) else { return nil }
        let model = firstMatch(text, key: "to_model") ?? firstMatch(text, key: "model")
        return Notice(event: event, model: model, at: receivedAt)
    }

    private static func firstMatch(_ text: String, key: String) -> String? {
        guard let range = text.range(of: "\"\(key)\"") else { return nil }
        let tail = text[range.upperBound...]
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        var rest = tail[tail.index(after: colon)...].drop(while: { $0 == " " || $0 == "\n" || $0 == "\t" })
        guard rest.first == "\"" else { return nil }
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return bounded(String(rest[..<end]))
    }

    private static func bounded(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(80))
    }

    private static func isOurs(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.contains(helperExecutableName)
    }

    private static func ownedHandler(command: String) -> [String: Any] {
        ["type": "command", "command": command, "async": true, "timeout": 5]
    }

    private static func mutableRoot(_ existing: Data?) throws -> NSMutableDictionary {
        guard let existing, !existing.isEmpty else { return NSMutableDictionary() }
        guard let object = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            throw CodingUsageError.invalid("Claude Code 设置不是 JSON 对象")
        }
        return NSMutableDictionary(dictionary: object)
    }
}
