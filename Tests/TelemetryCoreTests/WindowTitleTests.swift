import Foundation
import Testing

@testable import TelemetryCore

/**
 * 窗口标题那条链：归一化 → 阈值 → 缓存 → Jev 请求 / 响应。
 *
 * 这四件是纯的，也是整条链上最容易被无声改坏的：归一化漏掉一类转轮，
 * 缓存键就跟着转轮每秒变一次，于是每秒问一次 Jev；阈值挪一位，
 * 「需要确认」要么变成常态要么形同虚设。所以逐条钉住。
 */
struct WindowTitleNormalizerTests {
    @Test func stripsBrailleSpinner() {
        // npm / cargo 那一类转轮。整个 U+2800–U+28FF 都要剥，不是只剥见过的几个。
        #expect(WindowTitleNormalizer.normalize("⠋ Building lyjwpage") == "Building lyjwpage")
        #expect(WindowTitleNormalizer.normalize("⠹ Building lyjwpage") == "Building lyjwpage")
        #expect(WindowTitleNormalizer.normalize("⣿ Building lyjwpage") == "Building lyjwpage")
    }

    @Test func spinnerFramesCollapseToOneKey() {
        // 这才是归一化存在的理由：转动的圆点一直只算同一个标题。
        let frames = ["●", "○", "◐", "◓", "◑", "◒", "▪", "▫", "◌", "◍", "◉"]
        let normalized = Set(frames.map { WindowTitleNormalizer.normalize("\($0) Recording") })
        #expect(normalized == ["Recording"])
    }

    @Test func stripsProgressAndPercent() {
        #expect(WindowTitleNormalizer.normalize("[3/10] Compiling TelemetryCore") == "Compiling TelemetryCore")
        #expect(WindowTitleNormalizer.normalize("Downloading 47% — Safari") == "Downloading — Safari")
        #expect(WindowTitleNormalizer.normalize("Downloading 12.5% — Safari") == "Downloading — Safari")
    }

    @Test func stripsUnreadBadgeAtBothEnds() {
        // 规范写的是末尾，但 Gmail / Slack 把它放在开头。同一类东西，两头都剥。
        #expect(WindowTitleNormalizer.normalize("Inbox (3)") == "Inbox")
        #expect(WindowTitleNormalizer.normalize("(12) Inbox") == "Inbox")
    }

    @Test func collapsesWhitespaceAndTrimsSeparators() {
        #expect(WindowTitleNormalizer.normalize("  Report\tDecision \n Swift  ") == "Report Decision Swift")
        // 剥掉开头的装饰之后常常裸着一个破折号
        #expect(WindowTitleNormalizer.normalize("● — MacTelemetryHub") == "MacTelemetryHub")
    }

    @Test func emptyBecomesNil() {
        #expect(WindowTitleNormalizer.normalize(nil) == nil)
        #expect(WindowTitleNormalizer.normalize("   ") == nil)
        // 只剩装饰也等于没有标题
        #expect(WindowTitleNormalizer.normalize("⠋ ⠙ ●") == nil)
    }

    @Test func capsAtTwoHundredScalars() {
        // 单位是 Unicode 标量，和 Worker 侧同一个数法 —— 用字素簇数的话
        // 两边会在 emoji 和组合字符上对不齐。
        let long = String(repeating: "标", count: 300)
        let normalized = WindowTitleNormalizer.normalize(long)
        #expect(normalized?.unicodeScalars.count == WindowTitleNormalizer.maximumScalarCount)
    }
}

struct WindowTitleThresholdTests {
    @Test func publicAboveThresholdIsPublished() {
        // 实测：ReportDecision.swift — MacTelemetryHub（Xcode）
        let verdict = WindowTitleJudgmentThresholds.verdict(
            probabilities: ["public": 0.91, "private": 0.01, "unsure": 0.08]
        )
        #expect(verdict == .published)
    }

    @Test func privateAboveThresholdIsLocked() {
        // 实测：招商银行 — 个人账户余额与最近交易（Safari）
        let verdict = WindowTitleJudgmentThresholds.verdict(
            probabilities: ["public": 0.0, "private": 1.0, "unsure": 0.0]
        )
        #expect(verdict == .locked)
    }

    @Test func spreadDistributionNeedsConfirmation() {
        // 实测：Q4 planning notes（Notes）。既不够安全也不够危险，只能问人。
        let verdict = WindowTitleJudgmentThresholds.verdict(
            probabilities: ["public": 0.70, "private": 0.04, "unsure": 0.26]
        )
        #expect(verdict == .needsConfirmation)
    }

    @Test func choiceIsNotTheDecision() {
        // choice 只是最高那一项。public 0.53 的 choice 也是 "public"，
        // 但那种把握不该自动公开 —— 分档只看概率。
        let verdict = WindowTitleJudgmentThresholds.verdict(
            probabilities: ["public": 0.53, "private": 0.19, "unsure": 0.28]
        )
        #expect(verdict == .needsConfirmation)
    }

    @Test func thresholdsAreExactBoundaries() {
        #expect(WindowTitleJudgmentThresholds.verdict(probabilities: ["public": 0.8]) == .published)
        #expect(WindowTitleJudgmentThresholds.verdict(probabilities: ["public": 0.79, "private": 0.6]) == .locked)
        #expect(WindowTitleJudgmentThresholds.verdict(probabilities: [:]) == .needsConfirmation)
    }
}

struct WindowTitleJudgmentCacheTests {
    private let t0 = Date(timeIntervalSince1970: 1_789_099_506)

    private func entry(
        bundle: String = "com.apple.dt.Xcode",
        title: String,
        verdict: WindowTitleVerdict = .published,
        source: WindowTitleJudgmentSource = .jev,
        at offset: TimeInterval = 0
    ) -> WindowTitleJudgmentEntry {
        WindowTitleJudgmentEntry(
            bundleIdentifier: bundle,
            applicationName: "Xcode",
            title: title,
            verdict: verdict,
            source: source,
            probabilities: ["public": 0.91, "private": 0.01, "unsure": 0.08],
            judgedAt: t0.addingTimeInterval(offset),
            lastSeenAt: t0.addingTimeInterval(offset)
        )
    }

    @Test func keyCombinesBundleAndTitle() {
        // 同一条标题在两个应用里是两条独立结论。
        let a = WindowTitleJudgmentCache.key(bundleIdentifier: "com.apple.Safari", title: "Inbox")
        let b = WindowTitleJudgmentCache.key(bundleIdentifier: "com.apple.mail", title: "Inbox")
        #expect(a != b)
        // Bundle ID 缺失的进程有固定占位，不会互相串键
        #expect(WindowTitleJudgmentCache.key(bundleIdentifier: nil, title: "Inbox") == "-\nInbox")
    }

    /// 应用名只用来显示，不进键 —— 应用改了本地化名字不该让一屋子结论作废。
    @Test func applicationNameIsNotPartOfTheKey() {
        var renamed = entry(title: "A")
        renamed = WindowTitleJudgmentEntry(
            bundleIdentifier: renamed.bundleIdentifier,
            applicationName: "Xcode-beta",
            title: renamed.title,
            verdict: renamed.verdict,
            source: renamed.source,
            probabilities: renamed.probabilities,
            judgedAt: renamed.judgedAt,
            lastSeenAt: renamed.lastSeenAt
        )
        #expect(renamed.key == entry(title: "A").key)
    }

    @Test func lookupTouchesLastSeen() {
        var cache = WindowTitleJudgmentCache(entries: [entry(title: "A"), entry(title: "B")])
        let later = t0.addingTimeInterval(600)
        let found = cache.lookup(key: entry(title: "A").key, at: later)
        #expect(found?.verdict == .published)
        #expect(found?.lastSeenAt == later)
        // 摸过之后 A 排到最后，B 变成最旧的那条
        #expect(cache.entries.last?.title == "A")
    }

    @Test func storeReplacesSameKey() {
        var cache = WindowTitleJudgmentCache(entries: [entry(title: "A")])
        cache.store(entry(title: "A", verdict: .locked, source: .user))
        #expect(cache.entries.count == 1)
        #expect(cache.entries.first?.verdict == .locked)
        #expect(cache.entries.first?.source == .user)
    }

    @Test func evictsLeastRecentlyUsed() {
        var cache = WindowTitleJudgmentCache()
        for index in 0..<(WindowTitleJudgmentCache.capacity + 5) {
            cache.store(entry(title: "title-\(index)", at: Double(index)))
        }
        #expect(cache.entries.count == WindowTitleJudgmentCache.capacity)
        // 最早那五条被顶掉，最后一条还在
        #expect(cache.entry(forKey: entry(title: "title-0").key) == nil)
        #expect(cache.entry(forKey: entry(title: "title-4").key) == nil)
        #expect(cache.entry(forKey: entry(title: "title-5").key) != nil)
        #expect(cache.entries.last?.title == "title-\(WindowTitleJudgmentCache.capacity + 4)")
    }

    @Test func roundTripsThroughJSON() throws {
        let cache = WindowTitleJudgmentCache(entries: [
            entry(title: "ReportDecision.swift — MacTelemetryHub"),
            entry(title: "Q4 planning notes", verdict: .needsConfirmation, at: 10),
            entry(title: "招商银行", verdict: .locked, source: .user, at: 20),
        ])
        let restored = WindowTitleJudgmentCache.decoded(from: try cache.encoded())
        #expect(restored == cache)
        // 顺序也要保住：LRU 的淘汰顺序就藏在数组顺序里
        #expect(restored.entries.map(\.title) == cache.entries.map(\.title))
    }

    @Test func rejectsForeignFormatInsteadOfCrashing() {
        #expect(WindowTitleJudgmentCache.decoded(from: Data("not json".utf8)).entries.isEmpty)
        // 版本号对不上就整份丢掉重判，不做迁移
        let old = Data(#"{"version":0,"entries":[]}"#.utf8)
        #expect(WindowTitleJudgmentCache.decoded(from: old).entries.isEmpty)
    }
}

struct JevWindowTitleQuestionTests {
    @Test func requestBodyMatchesTheWireContract() throws {
        let body = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                JevWindowTitleQuestion.request(
                    applicationName: "Xcode",
                    bundleIdentifier: "com.apple.dt.Xcode",
                    title: "ReportDecision.swift — MacTelemetryHub"
                )
            )
        ) as? [String: Any]

        #expect(body?["model"] as? String == "jev-latest")
        let state = body?["state"] as? [String: Any]
        #expect(state?["applicationName"] as? String == "Xcode")
        #expect(state?["bundleIdentifier"] as? String == "com.apple.dt.Xcode")
        #expect(state?["title"] as? String == "ReportDecision.swift — MacTelemetryHub")
        // 语境说明必须在 state 里：问题 ID 不会送给模型。
        #expect((state?["purpose"] as? String)?.isEmpty == false)

        let questions = body?["questions"] as? [String: Any]
        let question = questions?[JevWindowTitleQuestion.questionID] as? [String: Any]
        #expect(question?["type"] as? String == "choice")
        #expect((question?["instructions"] as? String)?.isEmpty == false)
        let criteria = question?["criteria"] as? [String: String]
        #expect(Set(criteria?.keys ?? [:].keys) == ["public", "private", "unsure"])
    }

    /**
     * 真实响应的形状。
     *
     * 这一段是 2026-09-22 对 `https://api.typesafe.ai/v1/systemone` 实测回来的
     * 原样 JSON（`jev-1.13.0`，标题 `ReportDecision.swift — MacTelemetryHub`），
     * 只是重新缩进过。解析代码要对着真东西测，不是对着我以为的形状。
     */
    static let liveResponse = Data("""
        {
          "model": "jev-1.13.0",
          "answers": {
            "windowTitlePublishable": {
              "type": "choice",
              "choice": "public",
              "confidence": 0.86,
              "probabilities": { "unsure": 0.08, "public": 0.91, "private": 0.01 }
            }
          },
          "usage": { "input_tokens": 674, "output_tokens": 45 }
        }
        """.utf8)

    /// 同一次实测里私密那一条。概率是精确的 0 和 1，解析不能被它绊住。
    static let liveLockedResponse = Data("""
        {
          "model": "jev-1.13.0",
          "answers": {
            "windowTitlePublishable": {
              "type": "choice",
              "choice": "private",
              "confidence": 1.0,
              "probabilities": { "unsure": 0.0, "private": 1.0, "public": 0.0 }
            }
          },
          "usage": { "input_tokens": 679, "output_tokens": 45 }
        }
        """.utf8)

    @Test func parsesLiveResponse() throws {
        let outcome = try JevClient.outcome(from: Self.liveResponse)
        #expect(outcome.choice == "public")
        #expect(outcome.probabilities["public"] == 0.91)
        #expect(outcome.verdict == .published)
    }

    @Test func parsesLiveLockedResponse() throws {
        let outcome = try JevClient.outcome(from: Self.liveLockedResponse)
        #expect(outcome.verdict == .locked)
        #expect(outcome.probabilities["private"] == 1.0)
    }

    @Test func missingAnswerIsAnError() {
        let body = Data(#"{"model":"jev-1.13.0","answers":{},"usage":{}}"#.utf8)
        #expect(throws: JevError.missingAnswer) { try JevClient.outcome(from: body) }
    }

    @Test func onlyRateLimitAndServerErrorsRetry() {
        #expect(JevError.httpStatus(429, detail: nil).isRetryable)
        #expect(JevError.httpStatus(529, detail: nil).isRetryable)
        // key 不对、题面写坏了，重试多少次都一样
        #expect(!JevError.httpStatus(401, detail: nil).isRetryable)
        #expect(!JevError.httpStatus(422, detail: nil).isRetryable)
        #expect(!JevError.missingAPIKey.isRetryable)
    }

    @Test func authorizationHeaderCarriesTheKey() {
        let request = JevClient.request(apiKey: "k", body: Data(), timeout: 10)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpMethod == "POST")
        #expect(request.url == JevWindowTitleQuestion.endpoint)
    }

    @Test func missingKeyFailsBeforeAnyRequest() async {
        await #expect(throws: JevError.missingAPIKey) {
            try await JevClient.judgeWindowTitle(
                applicationName: "Xcode",
                bundleIdentifier: nil,
                title: "x",
                apiKey: "   "
            )
        }
    }
}
