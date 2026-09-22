import Foundation
import Testing
@testable import CodingUsageKit

struct ClaudeActivityHookTests {
    @Test func recordDropsPromptAndKeepsModel() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hook-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let secret = "do-not-persist-this-prompt"
        let stdin = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit",
            "prompt": secret,
            "transcript_path": "/tmp/private.jsonl",
            "session_id": "abc",
            "model": "claude-opus-5",
        ])
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        try ClaudeActivityHook.record(stdin, at: at, home: home)
        let written = try Data(contentsOf: ClaudeActivityHook.latestURL(home: home))
        let text = String(decoding: written, as: UTF8.self)
        #expect(!text.contains(secret))
        #expect(!text.contains("private.jsonl"))
        #expect(!text.contains("abc"))
        let notice = ClaudeActivityHook.notice(from: written, at: Date())
        #expect(notice?.event == "UserPromptSubmit")
        #expect(notice?.model == "claude-opus-5")
        #expect(notice?.at == at)
    }

    @Test func postModelSwitchPrefersToModel() {
        let notice = ClaudeActivityHook.notice(from: Data(#"{"hook_event_name":"PostModelSwitch","from_model":"claude-sonnet-5","to_model":"claude-opus-5","requested_model":"opus"}"#.utf8))
        #expect(notice?.model == "claude-opus-5")
    }

    @Test func settingsInstallPreservesOtherHooksAndReplacesOurCommand() throws {
        let existing = Data(#"""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/say done"}]}]},"theme":"dark"}
        """#.utf8)
        let command = "/Applications/Mac Telemetry Hub.app/Contents/MacOS/claude-activity-hook"
        let installed = try ClaudeActivityHook.settingsInstalling(existing: existing, command: command)
        let again = try ClaudeActivityHook.settingsInstalling(existing: installed, command: "/tmp/new/claude-activity-hook")
        let root = try JSONSerialization.jsonObject(with: again) as! [String: Any]
        #expect(root["theme"] as? String == "dark")
        let hooks = root["hooks"] as! [String: [[String: Any]]]
        let stop = hooks["Stop"]!
        let commands = stop.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.compactMap { $0["command"] as? String }
        #expect(commands.contains("/usr/bin/say done"))
        #expect(commands.filter { $0.contains("claude-activity-hook") } == ["/tmp/new/claude-activity-hook"])
        #expect(ClaudeActivityHook.events.allSatisfy { hooks[$0] != nil })
        let removed = try ClaudeActivityHook.settingsRemoving(existing: again)
        let after = try JSONSerialization.jsonObject(with: removed) as! [String: Any]
        let remaining = ((after["hooks"] as? [String: [[String: Any]]])?["Stop"] ?? [])
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(remaining == ["/usr/bin/say done"])
        #expect(after["theme"] as? String == "dark")
    }

    @Test func todayCommandAsksOnlyForThatShanghaiDay() {
        let collector = CcusageCollector(executableURL: URL(fileURLWithPath: "/usr/bin/true"), sourceIDs: ["claude"], offline: true)
        let arguments = collector.commandArguments(source: "claude", section: "daily", since: "20260923", until: "20260923")
        #expect(arguments.contains("--since"))
        #expect(arguments.contains("20260923"))
        #expect(!arguments.contains("codex"))
    }
}
