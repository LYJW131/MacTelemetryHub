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


/**
 * 六道概率到四档的落法。
 *
 * 组合规则（任一严重违规即拦）、判定顺序（风险 → 信息量 → 放行）、两条线的
 * 等号侧，以及实测那张表逐条 —— 这四件是这个功能的全部策略，挪一位就会让
 * 「待确认」要么变成常态要么形同虚设。
 */
struct WindowTitleThresholdTests {
    /// 五道风险题全干净、而且确实说了点什么，才自动公开。
    private func probabilities(
        secret: Double = 0.02,
        privateMatter: Double = 0.03,
        work: Double = 0.03,
        adult: Double = 0.01,
        political: Double = 0.02,
        informative: Double = 0.97
    ) -> [WindowTitleDimension: Double] {
        [
            .exposesSecret: secret,
            .exposesPrivateMatter: privateMatter,
            .exposesConfidentialWork: work,
            .isAdultContent: adult,
            .isPoliticallySensitive: political,
            .isInformative: informative,
        ]
    }

    @Test func cleanAndInformativeIsPublished() {
        // 实测：ReportDecision.swift — MacTelemetryHub（Xcode）
        let judged = WindowTitleJudgmentThresholds.judge(
            probabilities(secret: 0.04, privateMatter: 0.05, work: 0.07, political: 0.05)
        )
        #expect(judged.verdict == .published)
        #expect(judged.lockedBy.isEmpty)
    }

    /**
     * 这条就是拆题的理由。
     *
     * 一道揉在一起的「敏感吗」给过它 0.07，于是一条键政标题被自动公开了。
     * 拆开之后政治那道是 0.98，另外四道照旧干净 —— 挡下它的是被问到的那一道。
     */
    @Test func politicalTitleIsLockedEvenWhenEveryOtherRiskIsClean() {
        let judged = WindowTitleJudgmentThresholds.judge(probabilities(political: 0.98))
        #expect(judged.verdict == .locked)
        #expect(judged.lockedBy == [.isPoliticallySensitive])
    }

    @Test func adultContentIsLocked() {
        // 实测：Pornhub - Free Porn Videos（Safari）
        let judged = WindowTitleJudgmentThresholds.judge(
            probabilities(privateMatter: 0.08, adult: 0.99, political: 0.03, informative: 0.98)
        )
        #expect(judged.verdict == .locked)
        #expect(judged.lockedBy == [.isAdultContent])
    }

    @Test func bankTitleIsLocked() {
        // 实测：招商银行 — 个人账户余额与最近交易（Safari）。信息量满格也先锁掉。
        let judged = WindowTitleJudgmentThresholds.judge(
            probabilities(secret: 0.07, privateMatter: 0.97, work: 0.31, political: 0.03)
        )
        #expect(judged.verdict == .locked)
        #expect(judged.lockedBy == [.exposesPrivateMatter])
    }

    /// 多道同时越线时 `lockedBy` 要全记下来，顺序跟着 `allCases`。
    /// 只记第一个的话，界面会把一条「密码 + 工作机密」说成单一理由。
    @Test func everyTriggeredDimensionIsRecorded() {
        let judged = WindowTitleJudgmentThresholds.judge(
            probabilities(secret: 0.92, work: 0.71, political: 0.88)
        )
        #expect(judged.verdict == .locked)
        #expect(judged.lockedBy == [
            .exposesSecret,
            .exposesConfidentialWork,
            .isPoliticallySensitive,
        ])
    }

    @Test func uninformativeTitleIsOmitted() {
        // 实测：Claude（Claude）。公开它毫无风险，也毫无意义。
        let judged = WindowTitleJudgmentThresholds.judge(
            probabilities(privateMatter: 0.03, work: 0.03, political: 0.03, informative: 0.06)
        )
        #expect(judged.verdict == .omitted)
        #expect(judged.lockedBy.isEmpty)
    }

    /// 顺序是策略的一部分：风险先于信息量。两条都不满足时必须落在锁定上，
    /// 否则一条敏感又没信息的标题会以「已省略」的名义留在界面上。
    @Test func riskOutranksOmission() {
        let judged = WindowTitleJudgmentThresholds.judge(
            probabilities(privateMatter: 0.9, informative: 0.04)
        )
        #expect(judged.verdict == .locked)
        #expect(judged.lockedBy == [.exposesPrivateMatter])
    }

    @Test func middleGroundNeedsConfirmation() {
        // 实测：Interview notes.txt 私人 0.13、Budget draft.txt 私人 0.55。
        // 既不够干净也不够危险，只能让人看一眼 —— 这正是中间地带存在的理由。
        for value in [0.13, 0.55] {
            let judged = WindowTitleJudgmentThresholds.judge(probabilities(privateMatter: value))
            #expect(judged.verdict == .needsConfirmation)
            // 待确认不写 lockedBy：没有任何一道越过锁定线。
            #expect(judged.lockedBy.isEmpty)
        }
    }

    /// 待确认的理由不落盘，从概率现算 —— 阈值挪一位，旧条目的理由跟着改。
    @Test func unsettledDimensionsExplainTheConfirmation() {
        let unsettled = WindowTitleJudgmentThresholds.unsettledDimensions(
            probabilities(privateMatter: 0.55, political: 0.31)
        )
        #expect(unsettled == [.exposesPrivateMatter, .isPoliticallySensitive])
    }

    @Test func thresholdsAreExactBoundaries() {
        // 三条线都取到等号那一侧：0.6 就锁，0.10 就放行，0.5 就算有信息。
        #expect(
            WindowTitleJudgmentThresholds.judge(
                probabilities(political: WindowTitleJudgmentThresholds.riskLockMinimum)
            ).verdict == .locked
        )
        #expect(
            WindowTitleJudgmentThresholds.judge(
                probabilities(privateMatter: WindowTitleJudgmentThresholds.riskClearMaximum)
            ).verdict == .published
        )
        // 刚过放行线一点点就该问人了
        #expect(
            WindowTitleJudgmentThresholds.judge(probabilities(privateMatter: 0.11)).verdict
                == .needsConfirmation
        )
        #expect(
            WindowTitleJudgmentThresholds.judge(
                probabilities(informative: WindowTitleJudgmentThresholds.informativeMinimum)
            ).verdict == .published
        )
        #expect(
            WindowTitleJudgmentThresholds.judge(probabilities(informative: 0.49)).verdict
                == .omitted
        )
    }

    /**
     * 实测那张表整条跑一遍。
     *
     * 六列按 `WindowTitleDimension.allCases` 的顺序：密钥、私人、工作、成人、
     * 政治、信息量。题面和阈值是一对，谁动了这里都会红。
     */
    @Test func measuredTitlesLandWhereTheTableSays() {
        let measured: [(String, [Double], WindowTitleVerdict, [WindowTitleDimension])] = [
            ("Swift Concurrency — Apple Developer Documentation",
             [0.01, 0.02, 0.02, 0.01, 0.02, 0.96], .published, []),
            ("TypeSafe - Google Chrome",
             [0.04, 0.05, 0.05, 0.02, 0.05, 0.85], .published, []),
            ("user@mac: ~/Developer/project — zsh",
             [0.03, 0.04, 0.03, 0.01, 0.02, 0.96], .published, []),
            ("ReportDecision.swift — MacTelemetryHub",
             [0.04, 0.05, 0.07, 0.01, 0.05, 0.97], .published, []),
            ("Q4 planning notes",
             [0.02, 0.05, 0.05, 0.01, 0.02, 0.94], .published, []),
            ("Meeting agenda.txt",
             [0.02, 0.06, 0.05, 0.01, 0.03, 0.97], .published, []),
            ("Untitled",
             [0.02, 0.03, 0.03, 0.01, 0.02, 0.04], .omitted, []),
            ("Claude",
             [0.02, 0.03, 0.03, 0.01, 0.03, 0.06], .omitted, []),
            ("Mac Telemetry Hub",
             [0.02, 0.03, 0.03, 0.01, 0.03, 0.06], .omitted, []),
            ("Interview notes.txt",
             [0.03, 0.13, 0.07, 0.01, 0.04, 0.97], .needsConfirmation, []),
            ("Budget draft.txt",
             [0.02, 0.55, 0.05, 0.01, 0.03, 0.97], .needsConfirmation, []),
            ("Call with the landlord.txt",
             [0.03, 0.74, 0.07, 0.01, 0.02, 0.98], .locked, [.exposesPrivateMatter]),
            ("Re: 合同签署 — 张伟",
             [0.02, 0.98, 0.52, 0.01, 0.03, 0.97], .locked, [.exposesPrivateMatter]),
            ("Cloudflare R2 production access key — password",
             [0.92, 0.09, 0.09, 0.01, 0.03, 0.95], .locked, [.exposesSecret]),
            ("招商银行 — 个人账户余额与最近交易",
             [0.07, 0.97, 0.31, 0.01, 0.03, 0.97], .locked, [.exposesPrivateMatter]),
            ("二次元毛邓江胡！Mygo 动漫少女代指中国五代领导人的键政密码本",
             [0.02, 0.03, 0.03, 0.02, 0.98, 0.96], .locked, [.isPoliticallySensitive]),
            ("习近平 - 维基百科",
             [0.02, 0.04, 0.03, 0.01, 0.98, 0.97], .locked, [.isPoliticallySensitive]),
            ("六四事件 - YouTube",
             [0.02, 0.05, 0.03, 0.02, 0.98, 0.98], .locked, [.isPoliticallySensitive]),
            ("Pornhub - Free Porn Videos",
             [0.02, 0.08, 0.03, 0.99, 0.03, 0.98], .locked, [.isAdultContent]),
            ("r/nsfw - Reddit",
             [0.02, 0.06, 0.03, 0.97, 0.07, 0.97], .locked, [.isAdultContent]),
            ("Bank of America - Accounts",
             [0.04, 0.94, 0.20, 0.01, 0.03, 0.96], .locked, [.exposesPrivateMatter]),
            ("Ozempic dosage guide — Reddit",
             [0.02, 0.74, 0.03, 0.01, 0.04, 0.97], .locked, [.exposesPrivateMatter]),
            ("Genshin Impact — Steam",
             [0.02, 0.03, 0.07, 0.01, 0.03, 0.85], .published, []),
            ("村上春树《挪威的森林》 - 微信读书",
             [0.01, 0.03, 0.02, 0.01, 0.02, 0.97], .published, []),
            ("The Economist — China's economy",
             [0.01, 0.03, 0.03, 0.01, 0.31, 0.98], .needsConfirmation, []),
        ]
        for (title, values, expectedVerdict, expectedLockedBy) in measured {
            let judged = WindowTitleJudgmentThresholds.judge(
                Dictionary(uniqueKeysWithValues: zip(WindowTitleDimension.allCases, values))
            )
            #expect(judged.verdict == expectedVerdict, "\(title)")
            #expect(judged.lockedBy == expectedLockedBy, "\(title)")
        }
    }
}

struct WindowTitleJudgmentCacheTests {
    private let t0 = Date(timeIntervalSince1970: 1_789_099_506)

    /// 实测的 `ReportDecision.swift — MacTelemetryHub`，六个键。
    static let cleanProbabilities: [String: Double] = [
        "exposesSecret": 0.04,
        "exposesPrivateMatter": 0.05,
        "exposesConfidentialWork": 0.07,
        "isAdultContent": 0.01,
        "isPoliticallySensitive": 0.05,
        "isInformative": 0.97,
    ]

    private func entry(
        bundle: String = "com.apple.dt.Xcode",
        title: String,
        verdict: WindowTitleVerdict = .published,
        source: WindowTitleJudgmentSource = .jev,
        probabilities: [String: Double] = cleanProbabilities,
        lockedBy: [WindowTitleDimension] = [],
        at offset: TimeInterval = 0
    ) -> WindowTitleJudgmentEntry {
        WindowTitleJudgmentEntry(
            bundleIdentifier: bundle,
            applicationName: "Xcode",
            title: title,
            verdict: verdict,
            source: source,
            probabilities: probabilities,
            lockedBy: lockedBy,
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
            lockedBy: renamed.lockedBy,
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
        cache.store(entry(title: "A", verdict: .locked, source: .user, probabilities: [:]))
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
            entry(
                title: "招商银行",
                verdict: .locked,
                source: .user,
                probabilities: [:],
                at: 20
            ),
        ])
        let restored = WindowTitleJudgmentCache.decoded(from: try cache.encoded())
        #expect(restored == cache)
        // 顺序也要保住：LRU 的淘汰顺序就藏在数组顺序里
        #expect(restored.entries.map(\.title) == cache.entries.map(\.title))
    }

    /**
     * `lockedBy` 要能落盘、能读回来。
     *
     * 界面上「已锁定 · 政治敏感」的后半截就存在这里；丢了的话重启之后一屋子
     * 锁定条目都说不清自己是被哪道题挡下来的，而重判一次要重新花一次钱。
     */
    @Test func lockedBySurvivesARoundTrip() throws {
        let cache = WindowTitleJudgmentCache(entries: [
            entry(
                title: "六四事件 - YouTube",
                verdict: .locked,
                probabilities: [
                    "exposesSecret": 0.02,
                    "exposesPrivateMatter": 0.05,
                    "exposesConfidentialWork": 0.03,
                    "isAdultContent": 0.02,
                    "isPoliticallySensitive": 0.98,
                    "isInformative": 0.98,
                ],
                lockedBy: [.isPoliticallySensitive]
            ),
            entry(
                title: "两道一起越线",
                verdict: .locked,
                probabilities: [
                    "exposesSecret": 0.92,
                    "exposesPrivateMatter": 0.03,
                    "exposesConfidentialWork": 0.71,
                    "isAdultContent": 0.01,
                    "isPoliticallySensitive": 0.02,
                    "isInformative": 0.95,
                ],
                lockedBy: [.exposesSecret, .exposesConfidentialWork],
                at: 10
            ),
        ])
        let restored = WindowTitleJudgmentCache.decoded(from: try cache.encoded())
        #expect(restored == cache)
        #expect(restored.entries.first?.lockedBy == [.isPoliticallySensitive])
        #expect(restored.entries.first?.reasonText == "政治敏感")
        #expect(restored.entries.last?.reasonText == "密钥凭据、工作机密")
    }

    /// 待确认的理由不落盘，从概率现算：卡在两条线中间的那几道就是理由。
    @Test func confirmationReasonComesFromTheProbabilities() {
        let pending = entry(
            title: "Interview notes.txt",
            verdict: .needsConfirmation,
            probabilities: [
                "exposesSecret": 0.03,
                "exposesPrivateMatter": 0.13,
                "exposesConfidentialWork": 0.07,
                "isAdultContent": 0.01,
                "isPoliticallySensitive": 0.04,
                "isInformative": 0.97,
            ]
        )
        #expect(pending.reasonText == "私人事务")
        // 放行和省略没有理由可说
        #expect(entry(title: "A").reasonText == nil)
        #expect(entry(title: "Claude", verdict: .omitted).reasonText == nil)
        // 用户拍板锁的那条没有模型理由：probabilities 和 lockedBy 都是空的
        #expect(
            entry(title: "B", verdict: .locked, source: .user, probabilities: [:]).reasonText == nil
        )
    }

    @Test func rejectsForeignFormatInsteadOfCrashing() {
        #expect(WindowTitleJudgmentCache.decoded(from: Data("not json".utf8)).entries.isEmpty)
        // 版本号对不上就整份丢掉重判，不做迁移
        let old = Data(#"{"version":0,"entries":[]}"#.utf8)
        #expect(WindowTitleJudgmentCache.decoded(from: old).entries.isEmpty)
    }

    /**
     * 版本 2 的文件整份作废。
     *
     * 下面这条是真实发生过的漏：一道揉在一起的「敏感吗」给了这条键政标题
     * 0.07，于是它以「已公开」的身份躺在名单里。版本 2 从来没问过政治和成人
     * 内容，留着它等于把那次误判永久保存 —— 整份丢掉重判才是唯一稳的做法。
     */
    @Test func formatVersionTwoIsDiscarded() {
        let version2 = Data("""
            {
              "version": 2,
              "entries": [
                {
                  "bundleIdentifier": "com.google.Chrome",
                  "applicationName": "YouTube",
                  "title": "二次元毛邓江胡！Mygo 动漫少女代指中国五代领导人的键政密码本",
                  "verdict": "published",
                  "source": "jev",
                  "probabilities": { "sensitive": 0.07, "informative": 0.96 },
                  "judgedAt": 1789099506000,
                  "lastSeenAt": 1789099506000
                }
              ]
            }
            """.utf8)
        #expect(WindowTitleJudgmentCache.decoded(from: version2).entries.isEmpty)
        #expect(WindowTitleJudgmentCache.formatVersion == 3)
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

        // 六道题在同一个请求里：同一份 state，互相看不到对方的答案，
        // 一次往返就完。拆成六次请求只是把延迟和限额都翻六倍。
        let questions = body?["questions"] as? [String: Any]
        #expect(
            Set(questions?.keys ?? [:].keys)
                == Set(WindowTitleDimension.allCases.map(\.rawValue))
        )

        // 六道都是是非题，criteria 的键固定是 true / false —— 这是 TypeSafe
        // 那侧的形状，不是我们自己起的名字。
        for dimension in WindowTitleDimension.allCases {
            let question = questions?[dimension.rawValue] as? [String: Any]
            #expect(question?["type"] as? String == "noul", "\(dimension.rawValue)")
            let instructions = question?["instructions"] as? String
            #expect(instructions?.isEmpty == false, "\(dimension.rawValue)")
            let criteria = question?["criteria"] as? [String: String]
            #expect(Set(criteria?.keys ?? [:].keys) == ["true", "false"], "\(dimension.rawValue)")
        }
    }

    /// 五道风险题都要带上「别的维度有别的题在问」那句围栏。少一句，一条政治
    /// 标题就会顺手把私人事务和成人内容一起点亮，`lockedBy` 成了噪声。
    @Test func riskQuestionsFenceTheirOwnScope() {
        for dimension in WindowTitleDimension.risks {
            let instructions = JevWindowTitleQuestion.question(for: dimension).instructions
            #expect(
                instructions.contains("are judged by separate questions asked alongside this one"),
                "\(dimension.rawValue)"
            )
        }
    }

    /// 「陌生项目名默认算站长自己的」这句归工作机密那道题。没有它的时候
    /// `ReportDecision.swift — MacTelemetryHub` 会被当成未公开的工作内容。
    @Test func confidentialWorkAssumesUnfamiliarProjectsAreTheOwnersOwn() {
        #expect(
            JevWindowTitleQuestion.question(for: .exposesConfidentialWork).instructions
                .contains("assume an unfamiliar project name is the owner's own")
        )
    }

    /// 政治那道必须明说「谐音、代号、梗」也算 —— 漏了它，那条把领导人写成
    /// 二次元梗的 YouTube 标题就还是挡不住。
    @Test func politicalQuestionCoversCodedReferences() {
        let instructions = JevWindowTitleQuestion
            .question(for: .isPoliticallySensitive).instructions
        #expect(instructions.contains("homophone"))
        #expect(instructions.contains("meme"))
    }

    /**
     * 真实响应的形状。
     *
     * 这几段是 2026-09-22 对 `https://api.typesafe.ai/v1/systemone` 实测回来的
     * 原样 JSON（`jev-1.13.0`，六道是非题一次问），只是重新缩进过。解析代码要
     * 对着真东西测，不是对着我以为的形状：noul 的答案里只有一个 `noul`，
     * 没有 `confidence`，也没有分布。
     */
    static let livePublishedResponse = Data("""
        {
          "model": "jev-1.13.0",
          "answers": {
            "exposesSecret": { "type": "noul", "noul": 0.04 },
            "exposesPrivateMatter": { "type": "noul", "noul": 0.05 },
            "exposesConfidentialWork": { "type": "noul", "noul": 0.07 },
            "isAdultContent": { "type": "noul", "noul": 0.01 },
            "isPoliticallySensitive": { "type": "noul", "noul": 0.05 },
            "isInformative": { "type": "noul", "noul": 0.97 }
          },
          "usage": { "input_tokens": 2293, "output_tokens": 127 }
        }
        """.utf8)

    /**
     * 同一批实测里那条键政标题（YouTube 上「…代指中国五代领导人的键政密码本」）。
     *
     * 拆题之前它在一道揉起来的「敏感吗」上只拿到 0.07，直接被公开了；拆开之后
     * 政治那道是 0.98，另外四道照旧干净。这一段就是这次改动的存在理由。
     */
    static let livePoliticalResponse = Data("""
        {
          "model": "jev-1.13.0",
          "answers": {
            "exposesSecret": { "type": "noul", "noul": 0.02 },
            "exposesPrivateMatter": { "type": "noul", "noul": 0.03 },
            "exposesConfidentialWork": { "type": "noul", "noul": 0.03 },
            "isAdultContent": { "type": "noul", "noul": 0.02 },
            "isPoliticallySensitive": { "type": "noul", "noul": 0.98 },
            "isInformative": { "type": "noul", "noul": 0.96 }
          },
          "usage": { "input_tokens": 2308, "output_tokens": 127 }
        }
        """.utf8)

    /// 同一批实测里的 `Re: 合同签署 — 张伟`（Mail）：私人事务满格，工作机密
    /// 0.52 卡在两条线中间 —— 锁定的理由只记越线的那一道。
    static let liveContractResponse = Data("""
        {
          "model": "jev-1.13.0",
          "answers": {
            "exposesSecret": { "type": "noul", "noul": 0.02 },
            "exposesPrivateMatter": { "type": "noul", "noul": 0.98 },
            "exposesConfidentialWork": { "type": "noul", "noul": 0.52 },
            "isAdultContent": { "type": "noul", "noul": 0.01 },
            "isPoliticallySensitive": { "type": "noul", "noul": 0.03 },
            "isInformative": { "type": "noul", "noul": 0.97 }
          },
          "usage": { "input_tokens": 2291, "output_tokens": 127 }
        }
        """.utf8)

    /// 同一批实测里的 `Claude`（Claude）：五道风险一点不沾，也一点没说。
    static let liveOmittedResponse = Data("""
        {
          "model": "jev-1.13.0",
          "answers": {
            "exposesSecret": { "type": "noul", "noul": 0.02 },
            "exposesPrivateMatter": { "type": "noul", "noul": 0.03 },
            "exposesConfidentialWork": { "type": "noul", "noul": 0.03 },
            "isAdultContent": { "type": "noul", "noul": 0.01 },
            "isPoliticallySensitive": { "type": "noul", "noul": 0.03 },
            "isInformative": { "type": "noul", "noul": 0.06 }
          },
          "usage": { "input_tokens": 2288, "output_tokens": 127 }
        }
        """.utf8)

    @Test func parsesLivePublishedResponse() throws {
        let outcome = try JevClient.outcome(from: Self.livePublishedResponse)
        #expect(outcome.verdict == .published)
        #expect(outcome.lockedBy.isEmpty)
        // 落盘形状：六个概率合成一个字典，键就是题目 ID。
        #expect(outcome.probabilities == [
            "exposesSecret": 0.04,
            "exposesPrivateMatter": 0.05,
            "exposesConfidentialWork": 0.07,
            "isAdultContent": 0.01,
            "isPoliticallySensitive": 0.05,
            "isInformative": 0.97,
        ])
        #expect(outcome.probability(of: .isInformative) == 0.97)
    }

    @Test func parsesLivePoliticalResponse() throws {
        let outcome = try JevClient.outcome(from: Self.livePoliticalResponse)
        #expect(outcome.verdict == .locked)
        #expect(outcome.lockedBy == [.isPoliticallySensitive])
        #expect(outcome.probability(of: .isPoliticallySensitive) == 0.98)
    }

    @Test func parsesLiveContractResponse() throws {
        let outcome = try JevClient.outcome(from: Self.liveContractResponse)
        #expect(outcome.verdict == .locked)
        // 工作机密 0.52 没越线，不进理由
        #expect(outcome.lockedBy == [.exposesPrivateMatter])
    }

    @Test func parsesLiveOmittedResponse() throws {
        let outcome = try JevClient.outcome(from: Self.liveOmittedResponse)
        #expect(outcome.verdict == .omitted)
        #expect(outcome.probability(of: .isInformative) == 0.06)
    }

    /**
     * 六道题缺哪一道都算失败。
     *
     * 它们出自同一次调用，少一个说明那次回答本身不对劲 —— 宁可当判断失败重试，
     * 也不能拿残缺的答案落档：缺的偏偏是政治那道的话，一条键政标题会以
     * 「风险题全干净」的名义直接公开出去。
     */
    @Test func missingAnswerIsAnError() throws {
        let empty = Data(#"{"model":"jev-1.13.0","answers":{},"usage":{}}"#.utf8)
        #expect(throws: JevError.missingAnswer) { try JevClient.outcome(from: empty) }

        // 逐道抽掉一个，六次都该报错
        let full = try JSONSerialization.jsonObject(with: Self.livePublishedResponse)
        guard var object = full as? [String: Any],
              let answers = object["answers"] as? [String: Any]
        else {
            Issue.record("实测响应解不开")
            return
        }
        for dimension in WindowTitleDimension.allCases {
            var missing = answers
            missing[dimension.rawValue] = nil
            object["answers"] = missing
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: JevError.missingAnswer, "\(dimension.rawValue)") {
                try JevClient.outcome(from: data)
            }
        }
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
