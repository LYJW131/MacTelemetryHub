import Foundation

/**
 * 一条窗口标题的结论。
 *
 * 只有 `published` 会让标题进信封；另外两档在协议上和「没有标题」完全一样
 * （`windowTitle` 为 null），区别只在本机界面上还看得见它停在哪一步。
 */
enum WindowTitleVerdict: String, Codable, Equatable, Sendable {
    /// 放行：标题可以随前台应用一起公开。
    case published
    /// 锁定：不公开。Jev 判私密、失败、没配 key 都落在这里。
    case locked
    /// 需要确认：Jev 没给出足够把握的一档，等用户在通知或设置页里拍板。
    case needsConfirmation
    /**
     * 省略：能公开，但没什么可公开的。
     *
     * Claude Desktop 的窗口标题就是「Claude」，和应用名重复；「无标题」、
     * `Untitled`、「主窗口」也一样，访客从这几个字里得不到任何东西。这一档
     * 不上报也**不弹通知** —— 为了一条没信息的标题打扰用户是本末倒置。
     * 条目照样进缓存，站长在设置页里想公开随时能改。
     */
    case omitted
}

/// 结论是谁给的。用户拍过板的那条永远压过模型。
enum WindowTitleJudgmentSource: String, Codable, Equatable, Sendable {
    case jev
    case user
}

/**
 * 两道是非题的概率到四档的映射。
 *
 * 一次请求问两件独立的事，两道都是 noul（「是」的概率）：
 *
 * - `sensitive`：公开这条标题会不会暴露必须保密的东西。
 * - `informative`：这条标题在应用名之外还说了什么。
 *
 * 为什么不是一道三选一：noul 回的是一个概率，中间地带天然就是「模型也说不
 * 准」，按 TypeSafe 的说法就是低于一条线走一边、高于另一条线走另一边、
 * 中间交给人。把「拿不准」做成 choice 的第三个选项，等于让模型替我们表达
 * 把握不足，而那本来就是概率自己的事。两件事也确实互不蕴含：Claude Desktop
 * 的标题就是「Claude」，公开它毫无风险，也毫无意义。
 *
 * 这四个常量就是这个功能全部的策略，所以它们必须是有名字的、可以被单测钉住
 * 的数，而不是散在判断流程里的字面量。
 *
 * 顺序也是策略的一部分：**先隐私，再信息量，最后才放行**。一条银行标题哪怕
 * 信息量满格也先锁掉；反过来把「省略」排在隐私前面的话，一条敏感又没信息的
 * 标题会以「已省略」的名义留在界面上，说不清它到底被挡在哪一层。
 *
 * 实测（jev-1.13.0，2026-09-22，题面见 `JevWindowTitleQuestion`，两题同问）：
 *
 * | 标题（应用） | sensitive | informative | 落档 |
 * | --- | --- | --- | --- |
 * | `Swift Concurrency — Apple Developer Documentation`（Safari） | 0.02 | 0.97 | 放行 |
 * | `TypeSafe - Google Chrome`（Google Chrome） | 0.04 | 0.93 | 放行 |
 * | `user@mac: ~/Developer/project — zsh`（终端） | 0.04 | 0.96 | 放行 |
 * | `ReportDecision.swift — MacTelemetryHub`（Xcode） | 0.07 | 0.97 | 放行 |
 * | `Q4 planning notes`（Notes） | 0.09 | 0.96 | 放行 |
 * | `Meeting agenda.txt`（文本编辑） | 0.11 | 0.98 | 放行 |
 * | `Untitled`（TextEdit） | 0.02 | 0.04 | 省略 |
 * | `Claude`（Claude） | 0.03 | 0.04 | 省略 |
 * | `Mac Telemetry Hub`（Mac Telemetry Hub） | 0.03 | 0.04 | 省略 |
 * | `Interview notes.txt`（文本编辑） | 0.24 | 0.98 | 需要确认 |
 * | `Budget draft.txt`（文本编辑） | 0.26 | 0.98 | 需要确认 |
 * | `Call with the landlord.txt`（文本编辑） | 0.68 | 0.98 | 锁定 |
 * | `Re: 合同签署 — 张伟`（Mail） | 0.95 | 0.97 | 锁定 |
 * | `Cloudflare R2 production access key — password`（1Password） | 0.96 | 0.97 | 锁定 |
 * | `招商银行 — 个人账户余额与最近交易`（Safari） | 0.97 | 0.98 | 锁定 |
 *
 * 三条线都划在实测数的空档里，不是拍出来的：
 *
 * - 放行线 0.15：自己的代码、shell、文档页、公开网页全在 0.02–0.11，
 *   而第一条需要人看的（`Interview notes.txt`）是 0.24。线压到 0.3 的话
 *   面试笔记和预算草稿会被自动公开。
 * - 锁定线 0.6：「该问人」的最高是 0.26，「不用问、直接锁」的最低是 0.68，
 *   中间整段是空的。线提到 0.8 的话房东那条会变成一次通知 —— 那种事没什么
 *   可商量的，不该打扰用户。
 * - 值得展示线 0.5：没信息的三条落在 0.04，有信息的十二条落在 0.93–0.98，
 *   中间什么都没有。noul 本来就是「是」的概率，0.5 就是两边一样可能的那点。
 *
 * ⚠️ 阈值和题面是一对，改一个必须重测另一个。敏感那一题里「陌生项目名默认
 * 算站长自己的」这句尤其要留着：早一版题面（choice 形状）没写它的时候，
 * `ReportDecision.swift — MacTelemetryHub` 只拿到 public 0.53，自家仓库被
 * 当成了「未公开的工作内容」，几乎每条代码标题都会掉进「需要确认」。
 */
enum WindowTitleJudgmentThresholds {
    /// 两道题的概率存进同一个 `probabilities` 字典时用的键。
    static let sensitiveOption = "sensitive"
    static let informativeOption = "informative"

    /// 锁定线：敏感到这个概率就直接锁死，不打扰用户。
    static let sensitiveLockMinimum = 0.6
    /// 放行线：敏感概率低到这个数才算干净，可以自动公开。
    static let sensitiveClearMaximum = 0.15
    /// 值得展示线：informative 低于这个数就当没信息，省略掉。
    static let informativeMinimum = 0.5

    static func verdict(sensitive: Double, informative: Double) -> WindowTitleVerdict {
        if sensitive >= sensitiveLockMinimum { return .locked }
        if informative < informativeMinimum { return .omitted }
        if sensitive <= sensitiveClearMaximum { return .published }
        return .needsConfirmation
    }
}

/**
 * 「待确认」通知上的标识。
 *
 * 放在这里而不是 `WindowTitleJudge` 里，是为了能被单测钉住 —— App target 里
 * 那个类是 `@MainActor`，还要一个真的通知中心才跑得起来。
 *
 * 只挂一个动作：macOS 上一旦挂两个，两个按钮都会被收进「选项」下拉，拍一次板
 * 要点两下；只有单个动作才直接显示成按钮。所以「锁定」不再是一个动作，而是
 * 「关掉这条通知」—— 分类带 `.customDismissAction`，关闭即锁定。
 */
enum WindowTitleNotification {
    static let categoryIdentifier = "window-title-review"
    static let publishActionIdentifier = "window-title-publish"
}

/**
 * 缓存里的一条。
 *
 * `title` 已经是归一化文本 —— 键、问题、上报三处用的是同一串字，所以这里
 * 不必再另存一份原文。
 */
struct WindowTitleJudgmentEntry: Codable, Equatable, Sendable {
    /// 可能为 nil：少数非 bundle 进程没有 Bundle ID。键里有固定占位，
    /// 所以这里必须原样保留 nil —— 拿应用名顶上去会让条目算不回自己的键。
    let bundleIdentifier: String?
    /// 只用于界面显示。键不含它，同一个应用改了名不会让结论作废。
    let applicationName: String
    let title: String
    var verdict: WindowTitleVerdict
    var source: WindowTitleJudgmentSource
    /// Jev 那次回的完整分布。用户拍板的条目是空字典。
    var probabilities: [String: Double]
    var judgedAt: Date
    var lastSeenAt: Date

    var key: String {
        WindowTitleJudgmentCache.key(bundleIdentifier: bundleIdentifier, title: title)
    }
}
