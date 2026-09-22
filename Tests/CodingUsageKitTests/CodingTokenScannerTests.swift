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
