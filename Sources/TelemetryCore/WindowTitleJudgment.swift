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
    /// 锁定：不公开。Jev 判有风险、失败、没配 key 都落在这里。
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

extension WindowTitleVerdict {
    /**
     * 复核列表里的先后：锁定、待确认、已省略、已公开。
     *
     * 按最近使用排的话，需要过目的条目会被一串早就放行的标题冲到看不见的地方。
     * 拦下来的排最前 —— 误锁一条标题，站点上就一直缺着它；紧随其后的是等人
     * 拍板的那些，再往后两档都已经有定论，只是留着备查。
     */
    var reviewOrder: Int {
        switch self {
        case .locked: 0
        case .needsConfirmation: 1
        case .omitted: 2
        case .published: 3
        }
    }
}

/// 结论是谁给的。用户拍过板的那条永远压过模型。
enum WindowTitleJudgmentSource: String, Codable, Equatable, Sendable {
    case jev
    case user
}

/**
 * 一条标题被问到的六个维度。
 *
 * rawValue 就是送给 TypeSafe 的题目 ID，也是 `probabilities` 落盘时的键 ——
 * 一个名字管到底，代码里没有第二套映射要对齐。前五个是风险，最后一个是信息量；
 * `allCases` 的顺序同时是界面排版和 `lockedBy` 落盘的顺序，所以它是稳定的。
 *
 * 为什么拆成六道而不是一道「敏感吗」：见 `JevWindowTitleQuestion` 开头那段。
 * 简版是模型只会回答被问到的事 —— 揉在一起的那道题里没有「政治」这个词，
 * 一条键政标题就永远拿不到高分。
 */
enum WindowTitleDimension: String, Codable, CaseIterable, Equatable, Sendable {
    /// 凭据、密钥、令牌、密码、账号号码。
    case exposesSecret
    /// 财务、医疗、法律、感情婚恋，具名的私人个体，私信 / 邮件主题。
    case exposesPrivateMatter
    /// 雇主或客户的内部材料。站长自己的仓库和 hobby 项目不算。
    case exposesConfidentialWork
    /// 色情、露骨性内容、NSFW。
    case isAdultContent
    /// 政治人物、政权、运动或事件，民族宗教争议；含谐音、代号、梗指代。
    case isPoliticallySensitive
    /// 这条标题在应用名之外还说了什么。唯一一个「越高越好」的维度。
    case isInformative

    /// 五道风险题。共用同一对阈值，按「任一严重违规即拦」组合。
    static let risks: [WindowTitleDimension] = allCases.filter { $0 != .isInformative }

    var isRisk: Bool { self != .isInformative }

    /// 界面上说理由用的短名。「已锁定 · 政治敏感」里的后半截就是它。
    var displayName: String {
        switch self {
        case .exposesSecret: "密钥凭据"
        case .exposesPrivateMatter: "私人事务"
        case .exposesConfidentialWork: "工作机密"
        case .isAdultContent: "成人内容"
        case .isPoliticallySensitive: "政治敏感"
        case .isInformative: "信息量"
        }
    }
}

/**
 * 六道是非题的概率到四档的映射。
 *
 * 一次请求问六件独立的事，每道都是 noul（「是」的概率）：五道风险
 * （`exposesSecret` / `exposesPrivateMatter` / `exposesConfidentialWork` /
 * `isAdultContent` / `isPoliticallySensitive`）加一道 `isInformative`。
 *
 * 组合规则是「任一严重违规即拦」，不是加权平均：五道风险里只要有一道越过锁定
 * 线就锁，触发的维度全部记进 `lockedBy`。加权的话一条政治 0.9、其余 0.03 的
 * 标题会被四个干净分数稀释成中间值。TypeSafe 文档把这两种组合分得很清楚：
 * 权衡型偏好用加权分，「任一严重违规」要单独的条件。
 *
 * 为什么不是一道多选：noul 回的是一个概率，中间地带天然就是「模型也说不准」，
 * 低于放行线走一边、高于锁定线走另一边、中间交给人。把「拿不准」做成选项，
 * 等于让模型替我们表达把握不足，而那本来就是概率自己的事。
 *
 * 判定顺序也是策略的一部分：**先风险，再信息量，最后才放行**。一条银行标题
 * 哪怕信息量满格也先锁掉；反过来把「省略」排在风险前面的话，一条敏感又没信息
 * 的标题会以「已省略」的名义留在界面上，说不清它到底被挡在哪一层。
 *
 * 这三条线就是这个功能全部的策略，所以它们必须是有名字的、可以被单测钉住
 * 的数，而不是散在判断流程里的字面量。站长能在设置页里挪动它们，`standard`
 * 是下面实测出来的那一组默认值。
 *
 * 实测（jev-1.13.0，2026-09-22，题面见 `JevWindowTitleQuestion`，六题同问；
 * 请求体由本仓库的 `request(...)` 编码出字节后原样发出，代码和实测是同一串字）：
 *
 * | 标题（应用） | 密钥 | 私人 | 工作 | 成人 | 政治 | 信息 | 落档 |
 * | --- | --- | --- | --- | --- | --- | --- | --- |
 * | `Swift Concurrency — Apple Developer Documentation`（Safari） | 0.01 | 0.02 | 0.03 | 0.01 | 0.02 | 0.96 | 放行 |
 * | `TypeSafe - Google Chrome`（Google Chrome） | 0.03 | 0.04 | 0.05 | 0.01 | 0.03 | 0.94 | 放行 |
 * | `user@mac: ~/Developer/project — zsh`（终端） | 0.03 | 0.04 | 0.02 | 0.01 | 0.02 | 0.95 | 放行 |
 * | `ReportDecision.swift — MacTelemetryHub`（Xcode） | 0.03 | 0.04 | 0.10 | 0.01 | 0.04 | 0.97 | 放行 |
 * | `Q4 planning notes`（备忘录） | 0.02 | 0.06 | 0.04 | 0.01 | 0.03 | 0.95 | 放行 |
 * | `Meeting agenda.txt`（文本编辑） | 0.02 | 0.07 | 0.03 | 0.01 | 0.02 | 0.97 | 放行 |
 * | `Running: pnpm test - Add realtime status card - claude`（Ghostty） | 0.02 | 0.05 | 0.03 | 0.01 | 0.03 | 0.92 | 放行 |
 * | `Thinking - Deploy preview for API workers - codex`（Ghostty） | 0.03 | 0.04 | 0.05 | 0.01 | 0.03 | 0.87 | 放行 |
 * | `Untitled`（TextEdit） | 0.02 | 0.03 | 0.02 | 0.01 | 0.02 | 0.04 | 省略 |
 * | `Claude`（Claude） | 0.04 | 0.05 | 0.04 | 0.01 | 0.03 | 0.10 | 省略 |
 * | `Mac Telemetry Hub`（Mac Telemetry Hub） | 0.02 | 0.02 | 0.02 | 0.01 | 0.03 | 0.04 | 省略 |
 * | `Interview notes.txt`（文本编辑） | 0.02 | 0.16 | 0.04 | 0.01 | 0.03 | 0.97 | 待确认 |
 * | `Budget draft.txt`（文本编辑） | 0.02 | 0.54 | 0.05 | 0.01 | 0.02 | 0.97 | 待确认 |
 * | `Call with the landlord.txt`（文本编辑） | 0.02 | 0.71 | 0.08 | 0.01 | 0.03 | 0.97 | 锁定（私人事务） |
 * | `Re: 合同签署 — 张伟`（Mail） | 0.02 | 0.98 | 0.47 | 0.01 | 0.03 | 0.97 | 锁定（私人事务） |
 * | `Cloudflare R2 production access key — password`（1Password） | 0.95 | 0.08 | 0.07 | 0.01 | 0.02 | 0.95 | 锁定（密钥凭据） |
 * | `招商银行 — 个人账户余额与最近交易`（Safari） | 0.07 | 0.97 | 0.62 | 0.01 | 0.03 | 0.97 | 锁定（私人事务、工作机密） |
 * | `Running: kubectl - Migrate Contoso tenant to prod cluster …`（Ghostty） | 0.04 | 0.05 | 0.87 | 0.01 | 0.03 | 0.97 | 锁定（工作机密） |
 * | `CONFIDENTIAL — Project Phoenix launch plan.docx`（Word） | 0.03 | 0.11 | 0.90 | 0.01 | 0.04 | 0.99 | 锁定（工作机密） |
 * | `二次元毛邓江胡！Mygo 动漫少女代指中国五代领导人的键政密码本｜毛泽东｜邓小平｜江泽民`（YouTube） | 0.02 | 0.03 | 0.02 | 0.02 | 0.98 | 0.98 | 锁定（政治敏感） |
 * | `习近平 - 维基百科`（Safari） | 0.02 | 0.03 | 0.02 | 0.01 | 0.98 | 0.98 | 锁定（政治敏感） |
 * | `六四事件 - YouTube`（Safari） | 0.02 | 0.05 | 0.03 | 0.02 | 0.98 | 0.98 | 锁定（政治敏感） |
 */
struct WindowTitleJudgmentThresholds: Equatable, Sendable {
    /// 锁定线：五道风险题里任何一道到了这个概率就直接锁死，不打扰用户。
    var riskLockMinimum: Double
    /// 放行线：五道风险题全都低到这个数才算干净，可以自动公开。
    var riskClearMaximum: Double
    /// 值得展示线：`isInformative` 低于这个数就当没信息，省略掉。
    var informativeMinimum: Double

    /// 上面那张实测表跑出来的一组。设置页里没动过就是它。
    static let standard = WindowTitleJudgmentThresholds(
        riskLockMinimum: 0.6,
        riskClearMaximum: 0.10,
        informativeMinimum: 0.5
    )

    /// 缺答案按最坏算。解析那侧六道缺一即失败，所以这里的兜底只是防御。
    private func risk(
        _ probabilities: [WindowTitleDimension: Double],
        _ dimension: WindowTitleDimension
    ) -> Double {
        probabilities[dimension] ?? 1
    }

    /// 越过锁定线的维度。界面上「已锁定 · 政治敏感」的后半截。
    func lockingDimensions(
        _ probabilities: [WindowTitleDimension: Double]
    ) -> [WindowTitleDimension] {
        WindowTitleDimension.risks.filter { risk(probabilities, $0) >= riskLockMinimum }
    }

    /**
     * 卡在两条线中间的维度。
     *
     * 只有它非空才需要人拍板，所以「待确认」的理由也是它 —— 不落盘，随时从
     * `probabilities` 算得回来，阈值改了旧条目的理由跟着改。
     */
    func unsettledDimensions(
        _ probabilities: [WindowTitleDimension: Double]
    ) -> [WindowTitleDimension] {
        WindowTitleDimension.risks.filter {
            let value = risk(probabilities, $0)
            return value > riskClearMaximum && value < riskLockMinimum
        }
    }

    /**
     * 这一维在这份概率里扮演的角色，给界面加重点用。
     *
     * 六个数排成一行时，落在线内的那几个和其它的长得一样，扫一眼分不出是
     * 哪道题把标题拦下来的。规则和 `judge` 同一套：风险题越过锁定线是
     * `locking`，卡在两线之间是 `unsettled`，信息量没到线是 `uninformative`。
     */
    func emphasis(
        for dimension: WindowTitleDimension,
        in probabilities: [WindowTitleDimension: Double]
    ) -> WindowTitleDimensionEmphasis {
        guard let value = probabilities[dimension] else { return .none }
        if dimension.isRisk {
            if value >= riskLockMinimum { return .locking }
            if value > riskClearMaximum { return .unsettled }
            return .none
        }
        return value < informativeMinimum ? .uninformative : .none
    }

    func judge(
        _ probabilities: [WindowTitleDimension: Double]
    ) -> (verdict: WindowTitleVerdict, lockedBy: [WindowTitleDimension]) {
        let locking = lockingDimensions(probabilities)
        if !locking.isEmpty { return (.locked, locking) }
        if (probabilities[.isInformative] ?? 0) < informativeMinimum { return (.omitted, []) }
        if unsettledDimensions(probabilities).isEmpty { return (.published, []) }
        return (.needsConfirmation, [])
    }
}

/// 一个维度在一行概率里该不该被标出来，以及为什么。见 `WindowTitleJudgmentThresholds.emphasis`。
public enum WindowTitleDimensionEmphasis: Equatable, Sendable {
    /// 没越任何线，照常淡显。
    case none
    /// 风险题卡在放行线和锁定线之间，是「待确认」的由头。
    case unsettled
    /// 风险题越过锁定线，是「已锁定」的由头。
    case locking
    /// 信息量没到线，是「已省略」的由头。
    case uninformative
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
    /// Jev 那次回的六个概率，键是维度的 rawValue。用户拍板的条目是空字典。
    var probabilities: [String: Double]
    /**
     * 触发锁定的维度。
     *
     * 落盘而不是每次现算：界面要说「已锁定 · 政治敏感」，而用户自己拍板锁的
     * 条目这里是空的 —— 那条没有模型理由可言，现算只会凭空替它编一个。
     * 站长在设置页里挪动三条线时，Jev 判的条目连 `verdict` 一起按新线重算
     * （见 `WindowTitleJudgmentCache.rejudge(with:)`），拍过板的那些一律不动。
     */
    var lockedBy: [WindowTitleDimension]
    var judgedAt: Date
    var lastSeenAt: Date

    var key: String {
        WindowTitleJudgmentCache.key(bundleIdentifier: bundleIdentifier, title: title)
    }

    /// 六个概率按维度取回来。界面和阈值都吃这一份。
    var dimensionProbabilities: [WindowTitleDimension: Double] {
        var result: [WindowTitleDimension: Double] = [:]
        for dimension in WindowTitleDimension.allCases {
            if let value = probabilities[dimension.rawValue] { result[dimension] = value }
        }
        return result
    }

    /**
     * 把标题拦下来的是哪几道题。
     *
     * 锁定说的是落盘的 `lockedBy`，待确认说的是此刻卡在两条线中间的那几道。
     * 放行和省略没有理由可说 —— 前者哪道都没越线，后者的理由就是「已省略」
     * 这三个字本身。
     */
    func reasonDimensions(thresholds: WindowTitleJudgmentThresholds) -> [WindowTitleDimension] {
        switch verdict {
        case .locked: return lockedBy
        case .needsConfirmation:
            return thresholds.unsettledDimensions(dimensionProbabilities)
        case .published, .omitted: return []
        }
    }

    /// 这一档的理由，给界面用。概率表就在同一行里，这里只报维度名。
    func reasonText(thresholds: WindowTitleJudgmentThresholds) -> String? {
        let dimensions = reasonDimensions(thresholds: thresholds)
        guard !dimensions.isEmpty else { return nil }
        return dimensions.map(\.displayName).joined(separator: "、")
    }

    /**
     * 同一份理由带上概率，给通知用。
     *
     * 通知里没有那张六个数的概率表，光说「政治敏感」看不出是 0.11 还是 0.58 ——
     * 前者随手点公开，后者得先把标题看清楚。数字必须跟着理由一起进通知。
     */
    func reasonDetailText(thresholds: WindowTitleJudgmentThresholds) -> String? {
        let dimensions = reasonDimensions(thresholds: thresholds)
        guard !dimensions.isEmpty else { return nil }
        let probabilities = dimensionProbabilities
        return dimensions.map { dimension in
            guard let value = probabilities[dimension] else { return dimension.displayName }
            return String(format: "%@ %.2f", dimension.displayName, value)
        }.joined(separator: "、")
    }
}

/// 一条窗口标题此刻停在哪一步。仪表盘、菜单栏、设置页都按它显示。
enum WindowTitleStatus: String, Equatable, Sendable {
    /// 没有标题：窗口没标题、应用没窗口，或者前台应用采集关着。
    case none
    /**
     * 窗口标题这件事整个关掉了。
     *
     * 站长在设置页或菜单栏上拨的那个总开关。和黑名单一样是「不读、不判、
     * 不报」，区别只在范围：黑名单挑应用，这一档一刀切。判断缓存原样留着，
     * 拨回来之后那些标题不用重新问 Jev。
     */
    case disabled
    /// 应用在标题黑名单里：从头到尾不读、不判、不报。
    case blacklisted
    /// 命中远端隐藏黑名单。本机照旧显示，但绝不送去 TypeSafe，也不上报。
    case hidden
    /// 没有辅助功能权限，读不到标题。
    case noAccess
    /// 免判放行名单里的应用，标题直接上报。
    case trusted
    case published
    case locked
    case needsConfirmation
    /// 能公开但没什么可公开的：标题只是应用名或者通用占位。不报，也不打扰。
    case omitted
    case judging
    /// 没配 API key，或者判断失败。按锁定处理。
    case unavailable

    var displayName: String {
        switch self {
        case .none: "无标题"
        case .disabled: "已关闭"
        case .blacklisted: "黑名单"
        case .hidden: "远端已隐藏"
        case .noAccess: "缺少辅助功能权限"
        case .trusted: "免判"
        case .published: "已公开"
        case .locked: "已锁定"
        case .needsConfirmation: "待确认"
        case .omitted: "已省略"
        case .judging: "判断中"
        case .unavailable: "无法判断"
        }
    }

    /// 这一档的标题能不能进信封。界面之外别再各自判一遍。
    var isReportable: Bool {
        self == .published || self == .trusted
    }

    /**
     * 标题还没被读出来就已经定下来的那两档。
     *
     * 总开关和黑名单是同一件事的两个范围，合在一处是为了让「谁压过谁」只有
     * 一个答案：总开关关着时连黑名单都不必查，一律 `.disabled`。返回 nil 才
     * 表示这条标题该照常读、照常判。
     *
     * 远端隐藏名单（`hidden`）不在这里：那一档照旧读标题、本机照旧显示，
     * 只是不送去 TypeSafe、不进信封，判断顺序归 `WindowTitleJudge.resolve`。
     */
    static func suppressed(
        reportingEnabled: Bool,
        blacklisted: Bool
    ) -> WindowTitleStatus? {
        if !reportingEnabled { return .disabled }
        if blacklisted { return .blacklisted }
        return nil
    }
}

/**
 * 判断中的标题接力。
 *
 * 切一个没判过的标签页时，新标题要等 Jev 回话才知道能不能公开；这几秒里把
 * 上一条**已经放行过**的标题继续挂着，而不是先清空再补上 —— 站点上那行字
 * 不会闪一下，看起来就是「换了一下」。挂出去的是站长已经放行过的那条，不是
 * 还没判的新标题，所以这不是抢跑。
 *
 * 三条边界：
 * - 只有「判断中」这一档接力。锁定、待确认、已省略、无标题、黑名单、缺权限、
 *   无法判断都当场清空 —— 这几档说的是这条标题不该出去，而接力只是在等结论。
 *   短暂读到空标题也会断掉接力，这是故意的：空标题配着上一条旧字才是真的错。
 * - 应用必须还是同一个。Cmd-Tab 走到别的应用时，旧标题配新应用名就成了假消息。
 * - 最长 `maximumDuration`。429 退避能让「判断中」挂上好几分钟，那时候站点上
 *   这条标题已经和屏幕差得太远。到点清空，宁可空着。
 *
 * 过期只在有人来问的时候才生效：问它的是 AX 事件、5 秒兜底轮询和判断回调，
 * 所以最坏情况下超时会晚一个轮询周期才被抹掉。
 */
struct WindowTitleHold: Equatable, Sendable {
    private struct Held: Equatable, Sendable {
        let bundleIdentifier: String?
        let title: String
    }

    static let maximumDuration: TimeInterval = 20

    private var held: Held?
    private var holdingSince: Date?

    /// 此刻能进信封的那一条：放行的就是它本身，判断中的可能是上一条。
    mutating func reportableTitle(
        status: WindowTitleStatus,
        bundleIdentifier: String?,
        title: String?,
        now: Date = Date()
    ) -> String? {
        if status.isReportable, let title, !title.isEmpty {
            held = Held(bundleIdentifier: bundleIdentifier, title: title)
            holdingSince = nil
            return title
        }
        guard status == .judging, let current = held,
              current.bundleIdentifier == bundleIdentifier else {
            clear()
            return nil
        }
        let since = holdingSince ?? now
        holdingSince = since
        guard now.timeIntervalSince(since) < Self.maximumDuration else {
            clear()
            return nil
        }
        return current.title
    }

    mutating func clear() {
        held = nil
        holdingSince = nil
    }
}
