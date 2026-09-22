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
        #expect(WindowTitleNormalizer.normalize("⠋ Building project") == "Building project")
        #expect(WindowTitleNormalizer.normalize("⠹ Building project") == "Building project")
        #expect(WindowTitleNormalizer.normalize("⣿ Building project") == "Building project")
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
    /// 两道题都满意才公开：不敏感，而且确实说了点什么。
    @Test func cleanAndInformativeIsPublished() {
        // 实测：ReportDecision.swift — MacTelemetryHub（Xcode）
        #expect(
            WindowTitleJudgmentThresholds.verdict(sensitive: 0.07, informative: 0.97)
                == .published
        )
    }

    @Test func sensitiveAboveLockLineIsLocked() {
        // 实测：招商银行 — 个人账户余额与最近交易（Safari）。信息量满格也先锁掉。
        #expect(
            WindowTitleJudgmentThresholds.verdict(sensitive: 0.97, informative: 0.98) == .locked
        )
    }

    @Test func uninformativeTitleIsOmitted() {
        // 实测：Claude（Claude）。公开它毫无风险，也毫无意义。
        #expect(
            WindowTitleJudgmentThresholds.verdict(sensitive: 0.03, informative: 0.04) == .omitted
        )
    }

    /// 顺序是策略的一部分：隐私先于信息量。两条都不满足时必须落在锁定上，
    /// 否则一条敏感又没信息的标题会以「已省略」的名义留在界面上。
    @Test func privacyOutranksOmission() {
        #expect(
            WindowTitleJudgmentThresholds.verdict(sensitive: 0.9, informative: 0.04) == .locked
        )
    }

    @Test func middleGroundNeedsConfirmation() {
        // 实测：Interview notes.txt 0.24、Budget draft.txt 0.26。
        // 既不够干净也不够危险，只能让人看一眼 —— 这正是中间地带存在的理由。
        #expect(
            WindowTitleJudgmentThresholds.verdict(sensitive: 0.24, informative: 0.98)
                == .needsConfirmation
        )
        #expect(
            WindowTitleJudgmentThresholds.verdict(sensitive: 0.26, informative: 0.98)
                == .needsConfirmation
        )
    }

    @Test func thresholdsAreExactBoundaries() {
        // 三条线都取到等号那一侧：0.6 就锁，0.15 就放行，0.5 就算有信息。
        #expect(
            WindowTitleJudgmentThresholds.verdict(
                sensitive: WindowTitleJudgmentThresholds.sensitiveLockMinimum,
                informative: 0.98
            ) == .locked
        )
        #expect(
            WindowTitleJudgmentThresholds.verdict(
                sensitive: WindowTitleJudgmentThresholds.sensitiveClearMaximum,
                informative: 0.98
            ) == .published
        )
        #expect(
            WindowTitleJudgmentThresholds.verdict(
                sensitive: 0.16,
                informative: 0.98
            ) == .needsConfirmation
        )
        #expect(
            WindowTitleJudgmentThresholds.verdict(
                sensitive: 0.02,
                informative: WindowTitleJudgmentThresholds.informativeMinimum
            ) == .published
        )
        #expect(
            WindowTitleJudgmentThresholds.verdict(sensitive: 0.02, informative: 0.49) == .omitted
        )
    }

    /// 实测那张表整条跑一遍：题面和阈值是一对，谁动了这里都会红。
    @Test func measuredTitlesLandWhereTheTableSays() {
        let measured: [(String, Double, Double, WindowTitleVerdict)] = [
            ("Swift Concurrency — Apple Developer Documentation", 0.02, 0.97, .published),
            ("TypeSafe - Google Chrome", 0.04, 0.93, .published),
            ("user@mac: ~/Developer/project — zsh", 0.04, 0.96, .published),
            ("ReportDecision.swift — MacTelemetryHub", 0.07, 0.97, .published),
            ("Q4 planning notes", 0.09, 0.96, .published),
            ("Meeting agenda.txt", 0.11, 0.98, .published),
            ("Untitled", 0.02, 0.04, .omitted),
            ("Claude", 0.03, 0.04, .omitted),
            ("Mac Telemetry Hub", 0.03, 0.04, .omitted),
            ("Interview notes.txt", 0.24, 0.98, .needsConfirmation),
            ("Budget draft.txt", 0.26, 0.98, .needsConfirmation),
            ("Call with the landlord.txt", 0.68, 0.98, .locked),
            ("Re: 合同签署 — 张伟", 0.95, 0.97, .locked),
            ("Cloudflare R2 production access key — password", 0.96, 0.97, .locked),
            ("招商银行 — 个人账户余额与最近交易", 0.97, 0.98, .locked),
        ]
        for (title, sensitive, informative, expected) in measured {
            #expect(
                WindowTitleJudgmentThresholds.verdict(
                    sensitive: sensitive,
                    informative: informative
                ) == expected,
                "\(title)"
            )
        }
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
            probabilities: ["sensitive": 0.07, "informative": 0.97],
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

    /**
     * 版本 1 的文件整份作废。
     *
     * 字段形状没变，它完全解得开 —— 正因为如此这条测试才必要：
     * 里面的 `Claude` 当时被判成「已公开」，不丢掉的话它永远进不了新加的
     * 「已省略」一档，首页上就一直挂着一个和应用名重复的标题。
     */
    @Test func formatVersionOneIsDiscarded() {
        let version1 = Data("""
            {
              "version": 1,
              "entries": [
                {
                  "bundleIdentifier": "com.anthropic.claudefordesktop",
                  "applicationName": "Claude",
                  "title": "Claude",
                  "verdict": "published",
                  "source": "jev",
                  "probabilities": { "public": 1, "private": 0, "unsure": 0 },
                  "judgedAt": 1789099506000,
                  "lastSeenAt": 1789099506000
                }
              ]
            }
            """.utf8)
        #expect(WindowTitleJudgmentCache.decoded(from: version1).entries.isEmpty)
        #expect(WindowTitleJudgmentCache.formatVersion == 2)
    }

    /// 已省略这一档要能落盘、能读回来 —— 否则每次重启都要把
    /// 「Claude」这类标题重新问一遍。
    @Test func omittedVerdictSurvivesARoundTrip() throws {
        let cache = WindowTitleJudgmentCache(entries: [entry(title: "Claude", verdict: .omitted)])
        let restored = WindowTitleJudgmentCache.decoded(from: try cache.encoded())
        #expect(restored.entries.first?.verdict == .omitted)
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

        // 两道题在同一个请求里：同一份 state，互相看不到对方的答案，
        // 一次往返就完。拆成两次请求只是把延迟和限额都翻倍。
        let questions = body?["questions"] as? [String: Any]
        #expect(Set(questions?.keys ?? [:].keys) == [
            JevWindowTitleQuestion.sensitiveQuestionID,
            JevWindowTitleQuestion.informativeQuestionID,
        ])

        // 两道都是是非题，criteria 的键固定是 true / false —— 这是 TypeSafe
        // 那侧的形状，不是我们自己起的名字。
        for id in [
            JevWindowTitleQuestion.sensitiveQuestionID,
            JevWindowTitleQuestion.informativeQuestionID,
        ] {
            let question = questions?[id] as? [String: Any]
            #expect(question?["type"] as? String == "noul")
            #expect((question?["instructions"] as? String)?.isEmpty == false)
            let criteria = question?["criteria"] as? [String: String]
            #expect(Set(criteria?.keys ?? [:].keys) == ["true", "false"])
        }
    }

    /**
     * 真实响应的形状。
     *
     * 这几段是 2026-09-22 对 `https://api.typesafe.ai/v1/systemone` 实测回来的
     * 原样 JSON（`jev-1.13.0`，两道是非题一次问），只是重新缩进过。解析代码要
     * 对着真东西测，不是对着我以为的形状：noul 的答案里只有一个 `noul`，
     * 没有 `confidence`，也没有分布。
     */
    static let livePublishedResponse = Data("""
        {
          "model": "jev-1.13.0",
          "answers": {
            "windowTitleSensitive": { "type": "noul", "noul": 0.07 },
            "windowTitleInformative": { "type": "noul", "noul": 0.97 }
          },
          "usage": { "input_tokens": 978, "output_tokens": 47 }
        }
        """.utf8)

    /// 同一批实测里私密那一条（`招商银行 — 个人账户余额与最近交易`）。
    static let liveLockedResponse = Data("""
        {
          "model": "jev-1.13.0",
          "answers": {
            "windowTitleSensitive": { "type": "noul", "noul": 0.97 },
            "windowTitleInformative": { "type": "noul", "noul": 0.98 }
          },
          "usage": { "input_tokens": 983, "output_tokens": 47 }
        }
        """.utf8)

    /// 同一批实测里的 `Claude`（Claude）：一点不敏感，也一点没说。
    static let liveOmittedResponse = Data("""
        {
          "model": "jev-1.13.0",
          "answers": {
            "windowTitleSensitive": { "type": "noul", "noul": 0.03 },
            "windowTitleInformative": { "type": "noul", "noul": 0.04 }
          },
          "usage": { "input_tokens": 973, "output_tokens": 47 }
        }
        """.utf8)

    @Test func parsesLivePublishedResponse() throws {
        let outcome = try JevClient.outcome(from: Self.livePublishedResponse)
        #expect(outcome.verdict == .published)
        #expect(outcome.sensitive == 0.07)
        #expect(outcome.informative == 0.97)
        // 落盘形状：两个概率合成一个字典，缓存和设置页都看这一份。
        #expect(outcome.probabilities == ["sensitive": 0.07, "informative": 0.97])
    }

    @Test func parsesLiveLockedResponse() throws {
        let outcome = try JevClient.outcome(from: Self.liveLockedResponse)
        #expect(outcome.verdict == .locked)
        #expect(outcome.sensitive == 0.97)
    }

    @Test func parsesLiveOmittedResponse() throws {
        let outcome = try JevClient.outcome(from: Self.liveOmittedResponse)
        #expect(outcome.verdict == .omitted)
        #expect(outcome.informative == 0.04)
    }

    /// 两道题缺哪一道都算失败。它们出自同一次调用，少一个说明那次回答本身
    /// 不对劲 —— 宁可当判断失败重试，也不用半份答案把标题钉死。
    @Test func missingAnswerIsAnError() {
        let empty = Data(#"{"model":"jev-1.13.0","answers":{},"usage":{}}"#.utf8)
        #expect(throws: JevError.missingAnswer) { try JevClient.outcome(from: empty) }

        let withoutInformative = Data("""
            {
              "model": "jev-1.13.0",
              "answers": { "windowTitleSensitive": { "type": "noul", "noul": 0.07 } }
            }
            """.utf8)
        #expect(throws: JevError.missingAnswer) { try JevClient.outcome(from: withoutInformative) }

        let withoutSensitive = Data("""
            {
              "model": "jev-1.13.0",
              "answers": { "windowTitleInformative": { "type": "noul", "noul": 0.97 } }
            }
            """.utf8)
        #expect(throws: JevError.missingAnswer) { try JevClient.outcome(from: withoutSensitive) }
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

/**
 * 通知上的那两个标识。
 *
 * 值得钉住是因为它们写进了每一条已经发出去的通知：分类标识一改，通知中心里
 * 躺着的旧条目就再也找不到自己的动作，「公开」按钮当场消失。动作标识也不能
 * 和分类撞名 —— 撞了的话 delegate 那个 switch 会把分类名当成动作。
 */
struct WindowTitleNotificationTests {
    @Test func identifiersAreStable() {
        #expect(WindowTitleNotification.categoryIdentifier == "window-title-review")
        #expect(WindowTitleNotification.publishActionIdentifier == "window-title-publish")
        #expect(WindowTitleNotification.categoryIdentifier != WindowTitleNotification.publishActionIdentifier)
    }
}
