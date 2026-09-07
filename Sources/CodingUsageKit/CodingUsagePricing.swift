import Foundation

/*
Offline pricing data adapted from ccusage 20.0.20's models.dev snapshot.
https://github.com/ryoppippi/ccusage
Source: rust/crates/ccusage-core/src/models-dev-pricing.json
models.dev revision: 6e5efcd056370b0853db07ce9b4e02391c8a2d55
Snapshot SHA-256: 5abd2b6d523d021137bec8c4b8a36be19eca0150ff1dcfa0806f5a0c6ce84317
Retrieved 2026-09-05. Only supported text model identities are embedded.
https://github.com/anomalyco/models.dev/blob/dev/LICENSE

MIT License

Copyright (c) 2025 ryoppippi
Copyright (c) 2025 models.dev

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

/// Standard public API-equivalent valuation of ONE request's four exclusive token buckets.
/// Rates are USD per million tokens. This is not Cursor's charged or token-cost amount.
/// Published snapshot rates value historical usage; this is not a reconstruction of old bills.
/// Anthropic cache creation uses the public 5-minute write rate because Cursor does not expose TTL.
/// Explicit Cursor effort/fast aliases identify the base model and use standard API rates:
/// Cursor's fast label does not establish that a provider billed its priority/fast service tier.
/// Unknown routing labels (auto, composer, premium, bugbot, etc.) deliberately have no price.
/// Update this compiled snapshot to adopt price changes; collection never fetches a price list.
public enum CodingUsagePricing {
    public static let catalogVersion = "models.dev-6e5efcd056370b0853db07ce9b4e02391c8a2d55"

    public static func estimate(
        model: String,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheCreationTokens: Int64,
        at: Date
    ) -> Double? {
        guard at.timeIntervalSince1970.isFinite, at.timeIntervalSince1970 >= 0,
              [inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens].allSatisfy({ $0 >= 0 })
        else { return nil }
        let (cachedPrompt, overflow1) = cacheReadTokens.addingReportingOverflow(cacheCreationTokens)
        let (prompt, overflow2) = inputTokens.addingReportingOverflow(cachedPrompt)
        guard !overflow1, !overflow2 else { return nil }
        let modelKey = canonicalKey(model)
        guard let price = scheduledPrice(modelKey, at: at) ?? catalog[modelKey] else { return nil }
        let rates: Rates
        if let threshold = price.threshold, prompt > threshold {
            guard let tier = price.longContext else { return nil }
            rates = tier
        } else { rates = price.base }
        let buckets = [
            (inputTokens, rates.input), (outputTokens, rates.output),
            (cacheReadTokens, rates.cacheRead), (cacheCreationTokens, rates.cacheCreation),
        ]
        var total: Double = 0
        for (count, rate) in buckets where count > 0 {
            // A missing rate matters only when that bucket was actually used.
            guard let rate, rate.isFinite, rate >= 0 else { return nil }
            total += Double(count) * rate / 1_000_000
        }
        return total.isFinite ? total : nil
    }

    private struct Rates: Sendable {
        let input: Double?
        let output: Double?
        let cacheRead: Double?
        let cacheCreation: Double?
    }
    private struct Price: Sendable {
        let base: Rates
        var threshold: Int64? = nil
        var longContext: Rates? = nil
    }

    private static func canonicalKey(_ value: String) -> String {
        var key = CodingUsageModelIdentity.canonical(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        for prefix in ["anthropic/", "openai/", "google/", "x-ai/", "xai/", "deepseek/"] where key.hasPrefix(prefix) {
            key.removeFirst(prefix.count)
            break
        }
        key = key.replacingOccurrences(of: ".", with: "-")
        return aliases[key] ?? key
    }

    // DeepSeek's public v4 schedules are event-time dependent. The historical cutoff and
    // pre-change rates follow ccusage pricing.rs; current UTC windows were checked against
    // https://api-docs.deepseek.com/quick_start/pricing/ on 2026-09-05.
    private static func scheduledPrice(_ model: String, at: Date) -> Price? {
        guard model == "deepseek-v4-flash" || model == "deepseek-v4-pro" else { return nil }
        let flash = model == "deepseek-v4-flash"
        if at.timeIntervalSince1970 < 1_786_896_000 {
            return Price(base: flash
                ? Rates(input: 0.14, output: 0.28, cacheRead: 0.0028, cacheCreation: 0.14)
                : Rates(input: 0.435, output: 0.87, cacheRead: 0.003625, cacheCreation: 0.435))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.weekday, .hour], from: at)
        let weekday = parts.weekday ?? 1
        let hour = parts.hour ?? 0
        let peak = (2...6).contains(weekday) && ((1..<4).contains(hour) || (6..<10).contains(hour))
        let factor: Double = peak ? 2 : 1
        return Price(base: flash
            ? Rates(input: 0.22 * factor, output: 0.66 * factor, cacheRead: 0.007 * factor, cacheCreation: 0.22 * factor)
            : Rates(input: 0.66 * factor, output: 1.98 * factor, cacheRead: 0.022 * factor, cacheCreation: 0.66 * factor))
    }

    private static let aliases: [String: String] = [
        "claude-3-5-sonnet": "claude-3-5-sonnet-v2",
        "claude-3-5-sonnet-20240620": "claude-3-5-sonnet-v2",
        "claude-3-5-sonnet-20241022": "claude-3-5-sonnet-v2",
        "claude-3-7-sonnet-thinking": "claude-3-7-sonnet",
        "claude-4-1-opus": "claude-opus-4-1",
        "claude-4-5-haiku": "claude-haiku-4-5",
        "claude-4-5-haiku-thinking": "claude-haiku-4-5",
        "claude-4-5-opus": "claude-opus-4-5",
        "claude-4-5-opus-high-thinking": "claude-opus-4-5",
        "claude-4-5-sonnet": "claude-sonnet-4-5",
        "claude-4-5-sonnet-thinking": "claude-sonnet-4-5",
        "claude-4-6-opus": "claude-opus-4-6",
        "claude-4-6-opus-high": "claude-opus-4-6",
        "claude-4-6-opus-high-thinking": "claude-opus-4-6",
        "claude-4-6-opus-max": "claude-opus-4-6",
        "claude-4-6-opus-max-thinking": "claude-opus-4-6",
        "claude-4-6-sonnet": "claude-sonnet-4-6",
        "claude-4-6-sonnet-high-thinking": "claude-sonnet-4-6",
        "claude-4-6-sonnet-medium-thinking": "claude-sonnet-4-6",
        "claude-4-opus": "claude-opus-4",
        "claude-4-sonnet": "claude-sonnet-4",
        "claude-4-sonnet-thinking": "claude-sonnet-4",
        "claude-fable-5-1-thinking-high": "claude-fable-5-1",
        "claude-fable-5-thinking-high": "claude-fable-5",
        "claude-fable-5-thinking-xhigh": "claude-fable-5",
        "claude-opus-4-1-20250805": "claude-opus-4-1",
        "claude-opus-4-20250514": "claude-opus-4",
        "claude-opus-4-7-thinking-high": "claude-opus-4-7",
        "claude-opus-4-7-thinking-xhigh": "claude-opus-4-7",
        "claude-opus-4-8-thinking-high": "claude-opus-4-8",
        "claude-opus-5-low": "claude-opus-5",
        "claude-opus-5-thinking-high": "claude-opus-5",
        "claude-sonnet-4-20250514": "claude-sonnet-4",
        "claude-sonnet-5-thinking-high": "claude-sonnet-5",
        "cursor-grok-4-5-high": "grok-4-5",
        "cursor-grok-4-5-high-fast": "grok-4-5",
        "cursor-grok-4-6-high": "grok-4-6",
        "cursor-grok-4-6-high-fast": "grok-4-6",
        "cursor-grok-4-6-medium-fast": "grok-4-6",
        "cursor-grok-4-6-xhigh-fast": "grok-4-6",
        "glm-5-2-high": "glm-5-2",
        "gpt-5-1-codex-high": "gpt-5-1-codex",
        "gpt-5-2-xhigh": "gpt-5-2",
        "gpt-5-3-spark": "gpt-5-3-codex-spark",
        "gpt-5-5-extra-high": "gpt-5-5",
        "gpt-5-5-extra-high-fast": "gpt-5-5",
        "gpt-5-5-high": "gpt-5-5",
        "gpt-5-5-high-fast": "gpt-5-5",
        "gpt-5-5-medium": "gpt-5-5",
        "gpt-5-6": "gpt-5-6-sol",
        "gpt-5-6-sol-medium": "gpt-5-6-sol",
        "gpt-5-fast": "gpt-5",
        "grok-4-0709": "grok-4",
        "grok-4-5-fast-xhigh": "grok-4-5",
        "grok-4-5-high": "grok-4-5",
        "grok-4-5-xhigh": "grok-4-5",
        "premium (codex 5-3)": "gpt-5-3-codex",
        "gemini-3-6-flash-high": "gemini-3-6-flash",
        "gemini-3-6-flash-medium": "gemini-3-6-flash",
        "gemini-3-6-flash-low": "gemini-3-6-flash",
        "gemini-3-7-flash-high": "gemini-3-7-flash",
        "gemini-3-7-flash-medium": "gemini-3-7-flash",
        "gemini-3-7-flash-low": "gemini-3-7-flash",
        "gemini-3-8-flash-high": "gemini-3-8-flash",
        "gemini-3-8-flash-medium": "gemini-3-8-flash",
        "gemini-3-8-flash-low": "gemini-3-8-flash",
    ]

    private static let catalog: [String: Price] = [
        "claude-3-5-haiku-20241022": Price(base: Rates(input: 0.8, output: 4, cacheRead: 0.08, cacheCreation: 1)),
        "claude-3-7-sonnet-20250219": Price(base: Rates(input: 3, output: 15, cacheRead: 0.3, cacheCreation: 3.75)),
        "claude-3-haiku-20240307": Price(base: Rates(input: 0.25, output: 1.25, cacheRead: 0.03, cacheCreation: 0.3)),
        "claude-3-5-haiku": Price(base: Rates(input: 0.8, output: 4, cacheRead: 0.08, cacheCreation: 1)),
        "claude-3-5-sonnet-v2": Price(base: Rates(input: 3, output: 15, cacheRead: 0.3, cacheCreation: 3.75)),
        "claude-3-7-sonnet": Price(base: Rates(input: 3, output: 15, cacheRead: 0.3, cacheCreation: 3.75)),
        "claude-fable-5": Price(base: Rates(input: 10, output: 50, cacheRead: 1, cacheCreation: 12.5)),
        "claude-fable-5-1": Price(base: Rates(input: 10, output: 50, cacheRead: 0.25, cacheCreation: 12.5)),
        "claude-haiku-4-5": Price(base: Rates(input: 1, output: 5, cacheRead: 0.1, cacheCreation: 1.25)),
        "claude-haiku-4-5-20251001": Price(base: Rates(input: 1, output: 5, cacheRead: 0.1, cacheCreation: 1.25)),
        "claude-mythos-5": Price(base: Rates(input: 10, output: 50, cacheRead: 1, cacheCreation: 12.5)),
        "claude-opus-4": Price(base: Rates(input: 15, output: 75, cacheRead: 1.5, cacheCreation: 18.75)),
        "claude-opus-4-1": Price(base: Rates(input: 15, output: 75, cacheRead: 1.5, cacheCreation: 18.75)),
        "claude-opus-4-5": Price(base: Rates(input: 5, output: 25, cacheRead: 0.5, cacheCreation: 6.25)),
        "claude-opus-4-5-20251101": Price(base: Rates(input: 5, output: 25, cacheRead: 0.5, cacheCreation: 6.25)),
        "claude-opus-4-6": Price(base: Rates(input: 5, output: 25, cacheRead: 0.5, cacheCreation: 6.25)),
        "claude-opus-4-7": Price(base: Rates(input: 5, output: 25, cacheRead: 0.5, cacheCreation: 6.25)),
        "claude-opus-4-8": Price(base: Rates(input: 5, output: 25, cacheRead: 0.5, cacheCreation: 6.25)),
        "claude-opus-5": Price(base: Rates(input: 5, output: 25, cacheRead: 0.5, cacheCreation: 6.25)),
        "claude-sonnet-4": Price(base: Rates(input: 3, output: 15, cacheRead: 0.3, cacheCreation: 3.75), threshold: 200000, longContext: Rates(input: 6, output: 22.5, cacheRead: 0.6, cacheCreation: 7.5)),
        "claude-sonnet-4-5": Price(base: Rates(input: 3, output: 15, cacheRead: 0.3, cacheCreation: 3.75)),
        "claude-sonnet-4-5-20250929": Price(base: Rates(input: 3, output: 15, cacheRead: 0.3, cacheCreation: 3.75)),
        "claude-sonnet-4-6": Price(base: Rates(input: 3, output: 15, cacheRead: 0.3, cacheCreation: 3.75)),
        "claude-sonnet-5": Price(base: Rates(input: 2, output: 10, cacheRead: 0.2, cacheCreation: 2.5)),
        "gemini-2-0-flash-lite": Price(base: Rates(input: 0.075, output: 0.3, cacheRead: nil, cacheCreation: nil)),
        "gemini-2-5-flash": Price(base: Rates(input: 0.3, output: 2.5, cacheRead: 0.03, cacheCreation: nil)),
        "gemini-2-5-flash-lite": Price(base: Rates(input: 0.1, output: 0.4, cacheRead: 0.01, cacheCreation: nil)),
        "gemini-2-5-pro": Price(base: Rates(input: 1.25, output: 10, cacheRead: 0.125, cacheCreation: nil), threshold: 200000, longContext: Rates(input: 2.5, output: 15, cacheRead: 0.25, cacheCreation: nil)),
        "gemini-3-flash-preview": Price(base: Rates(input: 0.5, output: 3, cacheRead: 0.05, cacheCreation: nil)),
        "gemini-3-pro": Price(base: Rates(input: 2, output: 12, cacheRead: 0.2, cacheCreation: nil), threshold: 200000, longContext: Rates(input: 4, output: 18, cacheRead: 0.4, cacheCreation: nil)),
        "gemini-3-pro-preview": Price(base: Rates(input: 2, output: 12, cacheRead: 0.2, cacheCreation: nil), threshold: 200000, longContext: Rates(input: 4, output: 18, cacheRead: 0.4, cacheCreation: nil)),
        "gemini-3-1-flash-lite": Price(base: Rates(input: 0.25, output: 1.5, cacheRead: 0.025, cacheCreation: nil)),
        "gemini-3-1-flash-lite-preview": Price(base: Rates(input: 0.25, output: 1.5, cacheRead: 0.025, cacheCreation: nil)),
        "gemini-3-1-pro-preview": Price(base: Rates(input: 2, output: 12, cacheRead: 0.2, cacheCreation: nil), threshold: 200000, longContext: Rates(input: 4, output: 18, cacheRead: 0.4, cacheCreation: nil)),
        "gemini-3-1-pro-preview-customtools": Price(base: Rates(input: 2, output: 12, cacheRead: 0.2, cacheCreation: nil), threshold: 200000, longContext: Rates(input: 4, output: 18, cacheRead: 0.4, cacheCreation: nil)),
        "gemini-3-5-flash": Price(base: Rates(input: 1.5, output: 9, cacheRead: 0.15, cacheCreation: nil)),
        "gemini-3-5-flash-lite": Price(base: Rates(input: 0.3, output: 2.5, cacheRead: 0.03, cacheCreation: nil)),
        "gemini-3-6-flash": Price(base: Rates(input: 0.75, output: 3.75, cacheRead: 0.075, cacheCreation: nil)),
        "gemini-3-7-flash": Price(base: Rates(input: 0.75, output: 3.75, cacheRead: 0.075, cacheCreation: nil)),
        "gemini-3-8-flash": Price(base: Rates(input: 0.75, output: 3.75, cacheRead: 0.075, cacheCreation: nil)),
        "gemini-flash-latest": Price(base: Rates(input: 0.75, output: 3.75, cacheRead: 0.075, cacheCreation: nil)),
        "gemini-flash-lite-latest": Price(base: Rates(input: 0.3, output: 2.5, cacheRead: 0.03, cacheCreation: nil)),
        "glm-5-2": Price(base: Rates(input: 1.4, output: 4.4, cacheRead: 0.28, cacheCreation: 0)),
        "gpt-3-5-turbo": Price(base: Rates(input: 0.5, output: 1.5, cacheRead: 0, cacheCreation: nil)),
        "gpt-4": Price(base: Rates(input: 30, output: 60, cacheRead: nil, cacheCreation: nil)),
        "gpt-4-turbo": Price(base: Rates(input: 10, output: 30, cacheRead: nil, cacheCreation: nil)),
        "gpt-4-1": Price(base: Rates(input: 2, output: 8, cacheRead: 0.5, cacheCreation: nil)),
        "gpt-4-1-mini": Price(base: Rates(input: 0.4, output: 1.6, cacheRead: 0.1, cacheCreation: nil)),
        "gpt-4-1-nano": Price(base: Rates(input: 0.1, output: 0.4, cacheRead: 0.025, cacheCreation: nil)),
        "gpt-4o": Price(base: Rates(input: 2.5, output: 10, cacheRead: 1.25, cacheCreation: nil)),
        "gpt-4o-2024-05-13": Price(base: Rates(input: 5, output: 15, cacheRead: nil, cacheCreation: nil)),
        "gpt-4o-2024-08-06": Price(base: Rates(input: 2.5, output: 10, cacheRead: 1.25, cacheCreation: nil)),
        "gpt-4o-2024-11-20": Price(base: Rates(input: 2.5, output: 10, cacheRead: 1.25, cacheCreation: nil)),
        "gpt-4o-mini": Price(base: Rates(input: 0.15, output: 0.6, cacheRead: 0.075, cacheCreation: nil)),
        "gpt-5": Price(base: Rates(input: 1.25, output: 10, cacheRead: 0.125, cacheCreation: nil)),
        "gpt-5-chat-latest": Price(base: Rates(input: 1.25, output: 10, cacheRead: 0.125, cacheCreation: nil)),
        "gpt-5-codex": Price(base: Rates(input: 1.25, output: 10, cacheRead: 0.13, cacheCreation: nil)),
        "gpt-5-mini": Price(base: Rates(input: 0.25, output: 2, cacheRead: 0.025, cacheCreation: nil)),
        "gpt-5-nano": Price(base: Rates(input: 0.05, output: 0.4, cacheRead: 0.005, cacheCreation: nil)),
        "gpt-5-pro": Price(base: Rates(input: 15, output: 120, cacheRead: nil, cacheCreation: nil)),
        "gpt-5-1": Price(base: Rates(input: 1.25, output: 10, cacheRead: 0.125, cacheCreation: nil)),
        "gpt-5-1-chat-latest": Price(base: Rates(input: 1.25, output: 10, cacheRead: 0.125, cacheCreation: nil)),
        "gpt-5-1-codex": Price(base: Rates(input: 1.25, output: 10, cacheRead: 0.125, cacheCreation: nil)),
        "gpt-5-1-codex-max": Price(base: Rates(input: 1.25, output: 10, cacheRead: 0.125, cacheCreation: nil)),
        "gpt-5-1-codex-mini": Price(base: Rates(input: 0.25, output: 2, cacheRead: 0.025, cacheCreation: nil)),
        "gpt-5-2": Price(base: Rates(input: 1.75, output: 14, cacheRead: 0.175, cacheCreation: nil)),
        "gpt-5-2-chat-latest": Price(base: Rates(input: 1.75, output: 14, cacheRead: 0.175, cacheCreation: nil)),
        "gpt-5-2-codex": Price(base: Rates(input: 1.75, output: 14, cacheRead: 0.175, cacheCreation: nil)),
        "gpt-5-2-pro": Price(base: Rates(input: 21, output: 168, cacheRead: nil, cacheCreation: nil)),
        "gpt-5-3-chat-latest": Price(base: Rates(input: 1.75, output: 14, cacheRead: 0.175, cacheCreation: nil)),
        "gpt-5-3-codex": Price(base: Rates(input: 1.75, output: 14, cacheRead: 0.175, cacheCreation: nil)),
        "gpt-5-3-codex-spark": Price(base: Rates(input: 1.75, output: 14, cacheRead: 0.175, cacheCreation: nil)),
        "gpt-5-4": Price(base: Rates(input: 2.5, output: 15, cacheRead: 0.25, cacheCreation: nil), threshold: 272000, longContext: Rates(input: 5, output: 22.5, cacheRead: 0.5, cacheCreation: nil)),
        "gpt-5-4-mini": Price(base: Rates(input: 0.75, output: 4.5, cacheRead: 0.075, cacheCreation: nil)),
        "gpt-5-4-nano": Price(base: Rates(input: 0.2, output: 1.25, cacheRead: 0.02, cacheCreation: nil)),
        "gpt-5-4-pro": Price(base: Rates(input: 30, output: 180, cacheRead: nil, cacheCreation: nil), threshold: 272000, longContext: Rates(input: 60, output: 270, cacheRead: nil, cacheCreation: nil)),
        "gpt-5-5": Price(base: Rates(input: 5, output: 30, cacheRead: 0.5, cacheCreation: nil), threshold: 272000, longContext: Rates(input: 10, output: 45, cacheRead: 1, cacheCreation: nil)),
        "gpt-5-5-pro": Price(base: Rates(input: 30, output: 180, cacheRead: nil, cacheCreation: nil), threshold: 272000, longContext: Rates(input: 60, output: 270, cacheRead: nil, cacheCreation: nil)),
        "gpt-5-6-luna": Price(base: Rates(input: 0.2, output: 1.2, cacheRead: 0.02, cacheCreation: 0.25), threshold: 272000, longContext: Rates(input: 0.4, output: 1.8, cacheRead: 0.04, cacheCreation: 0.5)),
        "gpt-5-6-sol": Price(base: Rates(input: 4, output: 20, cacheRead: 0.4, cacheCreation: 5), threshold: 272000, longContext: Rates(input: 8, output: 30, cacheRead: 0.8, cacheCreation: 10)),
        "gpt-5-6-terra": Price(base: Rates(input: 2, output: 12, cacheRead: 0.2, cacheCreation: 2.5), threshold: 272000, longContext: Rates(input: 4, output: 18, cacheRead: 0.4, cacheCreation: 5)),
        "gpt-6-astra": Price(base: Rates(input: 10, output: 50, cacheRead: 1, cacheCreation: 12.5), threshold: 272000, longContext: Rates(input: 20, output: 75, cacheRead: 2, cacheCreation: 25)),
        "grok-3": Price(base: Rates(input: 3, output: 15, cacheRead: 0.75, cacheCreation: nil)),
        "grok-3-mini": Price(base: Rates(input: 0.3, output: 0.5, cacheRead: 0.075, cacheCreation: nil)),
        "grok-4": Price(base: Rates(input: 3, output: 15, cacheRead: 0.75, cacheCreation: nil)),
        "grok-4-1-fast-non-reasoning": Price(base: Rates(input: 0.2, output: 0.5, cacheRead: 0.05, cacheCreation: nil)),
        "grok-4-1-fast-reasoning": Price(base: Rates(input: 0.2, output: 0.5, cacheRead: 0.05, cacheCreation: nil)),
        "grok-4-fast-non-reasoning": Price(base: Rates(input: 0.2, output: 0.5, cacheRead: 0.05, cacheCreation: nil)),
        "grok-4-fast-reasoning": Price(base: Rates(input: 0.2, output: 0.5, cacheRead: 0.05, cacheCreation: nil)),
        "grok-4-20-0309-non-reasoning": Price(base: Rates(input: 1.25, output: 2.5, cacheRead: 0.2, cacheCreation: nil), threshold: 200000, longContext: Rates(input: 2.5, output: 5, cacheRead: 0.4, cacheCreation: nil)),
        "grok-4-20-0309-reasoning": Price(base: Rates(input: 1.25, output: 2.5, cacheRead: 0.2, cacheCreation: nil), threshold: 200000, longContext: Rates(input: 2.5, output: 5, cacheRead: 0.4, cacheCreation: nil)),
        "grok-4-3": Price(base: Rates(input: 1.25, output: 2.5, cacheRead: 0.2, cacheCreation: nil), threshold: 200000, longContext: Rates(input: 2.5, output: 5, cacheRead: 0.4, cacheCreation: nil)),
        "grok-4-5": Price(base: Rates(input: 2, output: 6, cacheRead: 0.3, cacheCreation: nil), threshold: 200000, longContext: Rates(input: 4, output: 12, cacheRead: 0.6, cacheCreation: nil)),
        "grok-4-6": Price(base: Rates(input: 2, output: 6, cacheRead: 0.5, cacheCreation: nil), threshold: 200000, longContext: Rates(input: 4, output: 12, cacheRead: 1, cacheCreation: nil)),
        "grok-build-0-1": Price(base: Rates(input: 1, output: 2, cacheRead: 0.2, cacheCreation: nil), threshold: 200000, longContext: Rates(input: 2, output: 4, cacheRead: 0.4, cacheCreation: nil)),
        "grok-code-fast-1": Price(base: Rates(input: 0.2, output: 1.5, cacheRead: 0.02, cacheCreation: nil)),
        "kimi-k2-5": Price(base: Rates(input: 0.6, output: 3, cacheRead: 0.1, cacheCreation: nil)),
        "o1": Price(base: Rates(input: 15, output: 60, cacheRead: 7.5, cacheCreation: nil)),
        "o1-pro": Price(base: Rates(input: 150, output: 600, cacheRead: nil, cacheCreation: nil)),
        "o3": Price(base: Rates(input: 2, output: 8, cacheRead: 0.5, cacheCreation: nil)),
        "o3-mini": Price(base: Rates(input: 1.1, output: 4.4, cacheRead: 0.55, cacheCreation: nil)),
        "o3-pro": Price(base: Rates(input: 20, output: 80, cacheRead: nil, cacheCreation: nil)),
        "o4-mini": Price(base: Rates(input: 1.1, output: 4.4, cacheRead: 0.275, cacheCreation: nil)),
    ]
}
