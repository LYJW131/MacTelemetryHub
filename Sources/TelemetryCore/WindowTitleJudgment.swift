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
}

/// 结论是谁给的。用户拍过板的那条永远压过模型。
enum WindowTitleJudgmentSource: String, Codable, Equatable, Sendable {
    case jev
    case user
}

/**
 * 概率到三档的映射。
 *
 * 看 `probabilities` 而不是 `choice`：`choice` 只是最高的那一项，
 * `choice: "public"` 也可能只有 0.53（实测就是这个数，见下），那种把握
 * 不该直接公开。三个常量就是这个功能全部的策略，所以它们必须是
 * 有名字的、可以被单测钉住的数，而不是散在判断流程里的字面量。
 *
 * 阈值按实测定（jev-1.13.0，2026-09-22，题面见 `JevWindowTitleQuestion`）：
 *
 * | 标题 | public | private | unsure | 落档 |
 * | --- | --- | --- | --- | --- |
 * | `ReportDecision.swift — MacTelemetryHub`（Xcode） | 0.91 | 0.01 | 0.08 | 放行 |
 * | `liangyangjunwei@Mac: ~/Developer/lyjwpage — zsh` | 0.95 | 0.04 | 0.01 | 放行 |
 * | `Swift Concurrency — Apple Developer Documentation` | 1.00 | 0.00 | 0.00 | 放行 |
 * | `招商银行 — 个人账户余额与最近交易` | 0.00 | 1.00 | 0.00 | 锁定 |
 * | `Cloudflare R2 production access key — password` | 0.00 | 1.00 | 0.00 | 锁定 |
 * | `Re: 合同签署 — 张伟`（Mail） | 0.00 | 1.00 | 0.00 | 锁定 |
 * | `Q4 planning notes`（Notes） | 0.70 | 0.04 | 0.26 | 需要确认 |
 *
 * 最后一行正是这三档存在的理由：它既不明显安全也不明显危险，模型自己也
 * 说不准，只能让人看一眼。放行线压到 0.7 的话它会被自动公开。
 *
 * ⚠️ 阈值和题面是一对，改一个必须重测另一个。同一份标题在早一版题面下
 * （没写明「陌生项目名默认算站长自己的」）只拿到 public 0.53 —— 那版题面配
 * 0.8 的话，几乎每条代码标题都会掉进「需要确认」，通知会变成常态。
 */
enum WindowTitleJudgmentThresholds {
    static let publicOption = "public"
    static let privateOption = "private"
    static let unsureOption = "unsure"

    /// 放行线：public 要到这个概率才自动公开。
    static let publishMinimumProbability = 0.8
    /// 锁定线：private 到这个概率就直接锁死，不打扰用户。
    static let lockMinimumProbability = 0.6

    static func verdict(probabilities: [String: Double]) -> WindowTitleVerdict {
        let publicProbability = probabilities[publicOption] ?? 0
        let privateProbability = probabilities[privateOption] ?? 0
        if publicProbability >= publishMinimumProbability { return .published }
        if privateProbability >= lockMinimumProbability { return .locked }
        return .needsConfirmation
    }
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
