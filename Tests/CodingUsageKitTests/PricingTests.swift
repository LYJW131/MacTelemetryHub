import Foundation
import XCTest
@testable import CodingUsageKit

final class CodingUsagePricingTests: XCTestCase {
    private func date(_ text: String = "2026-09-05T12:00:00Z") -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func estimate(_ model: String, input: Int64 = 1_000, output: Int64 = 2_000,
                          read: Int64 = 0, write: Int64 = 0, at: Date? = nil) -> Double? {
        CodingUsagePricing.estimate(model: model, inputTokens: input, outputTokens: output,
                                   cacheReadTokens: read, cacheCreationTokens: write, at: at ?? date())
    }

    func testExclusiveBucketsAreEachCountedOnceAtPerMillionRates() throws {
        let cost = try XCTUnwrap(estimate("claude-sonnet-4-5", input: 1_000_000, output: 1_000_000,
                                         read: 1_000_000, write: 1_000_000))
        XCTAssertEqual(cost, 3 + 15 + 0.3 + 3.75, accuracy: 0.000_000_001)
    }

    func testObservedCursorAliasesMapOnlyToTheirNamedModel() throws {
        let aliases = [
            "claude-4.5-sonnet-thinking": "claude-sonnet-4-5",
            "claude-4.6-opus-max-thinking": "claude-opus-4-6",
            "claude-opus-4-8-thinking-high": "claude-opus-4-8",
            "claude-fable-5-1-thinking-high": "claude-fable-5-1",
            "gpt-5.5-extra-high-fast": "gpt-5.5",
            "gpt-5.6-sol-medium": "gpt-5.6-sol",
            "cursor-grok-4.6-xhigh-fast": "grok-4.6",
            "Premium (Codex 5.3)": "gpt-5.3-codex",
            "glm-5.2-high": "glm-5.2",
        ]
        for (alias, canonical) in aliases {
            XCTAssertEqual(try XCTUnwrap(estimate(alias)), try XCTUnwrap(estimate(canonical)), alias)
        }
        XCTAssertEqual(estimate("  ANTHROPIC/claude-4.5-sonnet-thinking\n"), estimate("claude-sonnet-4-5"))
        XCTAssertEqual(estimate("model_placeholder_m318"), estimate("gemini-3.8-flash"))
        XCTAssertEqual(estimate("gemini-3.8-flash-high"), estimate("gemini-3.8-flash"))
    }

    func testUnknownRoutingAndUnseenVariantsHaveNoPrice() {
        for model in ["auto", "composer-1", "premium", "grok-bot-default", "github_bugbot", "agent_review",
                      "gpt-5.5-unreleased", "claude-sonnet-4-9", "provider-x/claude-sonnet-4-5"] {
            XCTAssertNil(estimate(model), model)
        }
        XCTAssertNil(estimate("auto", input: 0, output: 0))
    }

    func testExactDatedModelsDoNotCollapseToCurrentModelPrice() throws {
        XCTAssertEqual(try XCTUnwrap(estimate("gpt-4o-2024-05-13", input: 100_000, output: 0)), 0.5)
        XCTAssertEqual(try XCTUnwrap(estimate("gpt-4o-2024-08-06", input: 100_000, output: 0)), 0.25)
        XCTAssertEqual(estimate("claude-sonnet-4-20250514"), estimate("claude-sonnet-4"))
        XCTAssertNil(estimate("claude-sonnet-4-20991231"))
    }

    func testMissingCachePriceOnlyInvalidatesNonzeroBucket() throws {
        // GPT-5.5 has no separately published cache-creation rate in the snapshot.
        XCTAssertEqual(try XCTUnwrap(estimate("gpt-5.5")), 0.065, accuracy: 0.000_000_001)
        XCTAssertNil(estimate("gpt-5.5", write: 1))
        // No cache-read rate is published for o3-pro; a request without cache is still priceable.
        XCTAssertNotNil(estimate("o3-pro"))
        XCTAssertNil(estimate("o3-pro", read: 1))
        // An explicitly published zero rate is different from an absent rate.
        XCTAssertEqual(estimate("glm-5.2", input: 0, output: 0, write: 1_000_000), 0)
        XCTAssertEqual(estimate("gpt-5.5", input: 0, output: 0), 0)
    }

    func testLongContextBoundaryIncludesAllPromptBucketsButNotOutput() throws {
        let atBoundary = try XCTUnwrap(estimate("gpt-5.5", input: 20_000, output: 1_000, read: 252_000))
        XCTAssertEqual(atBoundary, 0.1 + 0.03 + 0.126, accuracy: 0.000_000_001)
        let above = try XCTUnwrap(estimate("gpt-5.5", input: 20_000, output: 1_000, read: 252_001))
        XCTAssertEqual(above, 0.2 + 0.045 + 0.252001, accuracy: 0.000_000_001)
        let outputOnly = try XCTUnwrap(estimate("gpt-5.5", input: 0, output: 300_000))
        XCTAssertEqual(outputOnly, 9)
        let gemini = try XCTUnwrap(estimate("gemini-3-pro-preview", input: 200_001, output: 1_000))
        XCTAssertEqual(gemini, 0.800004 + 0.018, accuracy: 0.000_000_001)
    }

    func testDeepSeekScheduleUsesEventUTCWithExclusiveEndBoundaries() throws {
        let old = try XCTUnwrap(estimate("deepseek-v4-flash", input: 1_000_000, output: 0,
                                        at: date("2026-08-16T01:00:00Z")))
        XCTAssertEqual(old, 0.14)
        let peak = try XCTUnwrap(estimate("deepseek-v4-flash", input: 1_000_000, output: 0,
                                         at: date("2026-09-04T01:00:00Z")))
        let end = try XCTUnwrap(estimate("deepseek-v4-flash", input: 1_000_000, output: 0,
                                        at: date("2026-09-04T04:00:00Z")))
        let weekend = try XCTUnwrap(estimate("deepseek-v4-flash", input: 1_000_000, output: 0,
                                            at: date("2026-09-05T01:00:00Z")))
        XCTAssertEqual(peak, 0.44)
        XCTAssertEqual(end, 0.22)
        XCTAssertEqual(weekend, 0.22)
        XCTAssertEqual(estimate("deepseek-v4-pro", at: date("2026-09-04T09:00:00+08:00")),
                       estimate("deepseek-v4-pro", at: date("2026-09-04T01:00:00Z")))
    }

    func testInvalidCountsDatesAndPromptOverflowFailClosed() {
        XCTAssertNil(estimate("gpt-5.5", input: -1))
        XCTAssertNil(estimate("gpt-5.5", input: .max, read: 1))
        XCTAssertNil(estimate("gpt-5.5", read: .max, write: 1))
        XCTAssertNil(estimate("gpt-5.5", at: Date(timeIntervalSince1970: .nan)))
        XCTAssertNil(estimate("gpt-5.5", at: Date(timeIntervalSince1970: -1)))
    }
}
