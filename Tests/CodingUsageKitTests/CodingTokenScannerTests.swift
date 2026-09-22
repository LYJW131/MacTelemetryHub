import Foundation
import Testing
@testable import CodingUsageKit

struct CodingTokenScannerTests {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)
        return url
    }
    @Test func codexDeduplicatesAndKeepsTokenComponentsAcrossWindows() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(); let ms = Int64(now.timeIntervalSince1970*1000); let boundary = ms/300000*300000
        func event(_ at: Int64, _ total: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["timestamp":ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:Double(at)/1000)),
                "type":"event_msg","payload":["type":"token_count","info":["total_token_usage":["total_tokens":total],"last_token_usage":["input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":10]]]]) + Data([10])
        }
        let file=root.appendingPathComponent(".codex/sessions/test.jsonl")
        let first=try event(boundary-1000,120), second=try event(boundary+1000,240)
        try (first+first+second).write(to:file)
        var scanner=CodingTokenScanner()
        let result=try scanner.scan(home:root,at:Date(timeIntervalSince1970:Double(boundary+2000)/1000))
        #expect(result.windows.count==2)
        #expect(result.windows[0].agents[0].inputTokens==20)
        #expect(result.windows[0].agents[0].cacheReadTokens==80)
        #expect(result.windows[0].agents[0].reasoningTokens==10)
        #expect(result.windows[0].agents[0].eventCount==1)
        #expect(try scanner.scan(home:root,at:Date(timeIntervalSince1970:Double(boundary+2000)/1000))==result)
        #expect(scanner.latestActivity["codex"]?.at==Date(timeIntervalSince1970:Double(boundary+1000)/1000))
        #expect(scanner.latestActivity["claude"]==nil)
    }
    @Test func claudeStreamingUsageReplacesRatherThanAddsAndPartialLineWaits() throws {
        let root=try home();defer{try? FileManager.default.removeItem(at:root)}
        let now=Date();let stamp=ISO8601DateFormatter().string(from:now.addingTimeInterval(-30))
        func event(_ output:Int)throws->Data {try JSONSerialization.data(withJSONObject:["type":"assistant","timestamp":stamp,"message":["id":"response-one","model":"claude-test","usage":["input_tokens":10,"output_tokens":output,"cache_read_input_tokens":30,"cache_creation_input_tokens":5]]])}
        let file=root.appendingPathComponent(".claude/projects/test.jsonl")
        try (event(2)+Data([10])+event(20)).write(to:file)
        var scanner=CodingTokenScanner();let first=try scanner.scan(home:root,at:now)
        #expect(first.windows[0].agents[0].outputTokens==2)
        let handle=try FileHandle(forWritingTo:file);try handle.seekToEnd();try handle.write(contentsOf:Data([10]));try handle.close()
        let next=try scanner.scan(home:root,at:now)
        #expect(next.windows[0].agents[0].outputTokens==20)
        #expect(next.windows[0].agents[0].eventCount==1)
        #expect(scanner.latestActivity["claude"]?.model=="claude-test")
        #expect(abs(scanner.latestActivity["claude"]!.at.timeIntervalSince(now.addingTimeInterval(-30)))<1)
        try (event(20)+Data([10])).write(to:root.appendingPathComponent(".claude/projects/copy.jsonl"))
        #expect(try scanner.scan(home:root,at:now).windows[0].agents[0].eventCount==1)
        let text=String(data:try JSONEncoder().encode(next),encoding:.utf8)!
        #expect(!text.contains("response-one"));#expect(!text.contains(root.path))
    }
    @Test func absentSourcesAreNotMeasuredZero() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var scanner=CodingTokenScanner();let value=try scanner.scan(home:root)
        #expect(value.sources.allSatisfy{$0.state=="unavailable"});#expect(value.windows.isEmpty)
    }
}

struct SessionActivityOverlayTests {
    private let now = CodingUsageDates.parseInstant("2026-09-23T04:00:00Z")!
    private func agent(_ id: String, at: Date?, model: String? = "old-model") -> CodingUsageNowAgentPayload {
        CodingUsageNowAgentPayload(id: id, currentModel: model, lastActivityAt: at.map(CodingUsageDates.instant),
                                   active: false)
    }

    @Test func newerScannedEventLightsTheAgentAndCarriesItsModel() {
        let payload = CodingUsageNowPayload(agents: [agent("codex", at: now.addingTimeInterval(-3_600)), agent("grok", at: nil)])
        let seen = now.addingTimeInterval(-60)
        let result = CodingUsageEngine.overlay(payload, activity: [
            "codex": CodingTokenActivity(at: seen, model: "gpt-5.5-codex"),
        ], at: now)
        let codex = result.agents.first { $0.id == "codex" }!
        #expect(codex.active)
        #expect(codex.lastActivityAt == CodingUsageDates.instant(seen))
        #expect(codex.currentModel == CodingUsageModelIdentity.canonical("gpt-5.5-codex"))
        #expect(result.agents.first { $0.id == "grok" } == payload.agents[1])
    }

    @Test func olderOrExpiredScanDoesNotOverrideTheLedger() {
        let recorded = now.addingTimeInterval(-30)
        let payload = CodingUsageNowPayload(agents: [agent("claude", at: recorded)])
        let older = CodingUsageEngine.overlay(payload, activity: [
            "claude": CodingTokenActivity(at: now.addingTimeInterval(-120), model: "claude-opus-5"),
        ], at: now)
        #expect(older == payload)
        let expired = CodingUsageEngine.overlay(CodingUsageNowPayload(agents: [agent("claude", at: nil)]), activity: [
            "claude": CodingTokenActivity(at: now.addingTimeInterval(-301), model: nil),
        ], at: now)
        #expect(expired.agents[0].active == false)
        #expect(expired.agents[0].currentModel == "old-model")
    }
}
