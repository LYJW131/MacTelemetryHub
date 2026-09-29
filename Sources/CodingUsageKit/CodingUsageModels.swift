import Foundation

public enum CodingUsagePrecision: String, Codable, Sendable {
    case measured, estimated, mixed
}

/**
 * 账本里一个来源的采集状态。只在本机账本里落盘，上报的是由它换算出的 `CodingUsageAgent`。
 *
 * `error` 只放真正采集失败的原因（这一轮什么都没拿到，数据停在 `collectedAt`）；
 * 采集成功但数据有缺口（token 未分列、本地历史变短、会话元数据失败……）
 * 时 `state` 仍是 ok，缺口写进 `warning`。
 *
 * `precision` 与 `costComplete` 不再上报（费用估没估全改为按天记在日行上），仍然落盘，
 * 是为了让账本文件对旧版 App 保持可读：旧版解码时这两格必须在。
 */
public struct CodingUsageStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case ok, error, unavailable }
    public var state: State
    public var collectedAt: String?
    public var error: String?
    public var warning: String?
    public var coverageStart: String?
    public var coverageEnd: String?
    public var precision: CodingUsagePrecision
    public var costComplete: Bool

    public init(state: State, collectedAt: String? = nil, error: String? = nil, warning: String? = nil,
                coverageStart: String? = nil, coverageEnd: String? = nil,
                precision: CodingUsagePrecision = .measured, costComplete: Bool = false) {
        self.state = state; self.collectedAt = collectedAt; self.error = error; self.warning = warning
        self.coverageStart = coverageStart; self.coverageEnd = coverageEnd
        self.precision = precision; self.costComplete = costComplete
    }
    enum CodingKeys: String, CodingKey {
        case state, collectedAt, error, warning, coverageStart, coverageEnd, precision, costComplete
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state); try c.encode(collectedAt, forKey: .collectedAt)
        try c.encode(error, forKey: .error); try c.encode(warning, forKey: .warning)
        try c.encode(coverageStart, forKey: .coverageStart)
        try c.encode(coverageEnd, forKey: .coverageEnd); try c.encode(precision, forKey: .precision)
        try c.encode(costComplete, forKey: .costComplete)
    }
}

/// Input excludes cached input. Reasoning is a subset of output, never added to total again.
/// Monetary amounts are API-equivalent estimates, never a subscription's deducted balance.
public struct CodingUsageDayRecord: Codable, Equatable, Sendable {
    public var date: String
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheCreationTokens: Int64
    public var reasoningTokens: Int64
    public var totalTokens: Int64
    /// A provider's measured total can exceed the available split in older records. Preserve
    /// that residual explicitly instead of inventing input/output attribution or dropping a day.
    public var unclassifiedTokens: Int64?
    public var apiEquivalentCostUSD: Double?
    public var models: [String: Int64]
    /// 这一天所有有 token 的请求都估到了价。旧账本的日行没有这一格（nil），上报时有 token 的
    /// 那天按没估全算，下一次完整采集把 ccusage 还返回的日子补上
    public var costComplete: Bool?

    public init(date: String, inputTokens: Int64 = 0, outputTokens: Int64 = 0,
                cacheReadTokens: Int64 = 0, cacheCreationTokens: Int64 = 0,
                reasoningTokens: Int64 = 0, totalTokens: Int64 = 0,
                apiEquivalentCostUSD: Double? = nil, models: [String: Int64] = [:], unclassifiedTokens: Int64? = nil,
                costComplete: Bool? = nil) {
        self.date = date; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheCreationTokens = cacheCreationTokens
        self.reasoningTokens = reasoningTokens; self.totalTokens = totalTokens
        self.apiEquivalentCostUSD = apiEquivalentCostUSD; self.models = models
        self.unclassifiedTokens = unclassifiedTokens; self.costComplete = costComplete
    }
}

/// Only a one-way identity hash and display metadata are persisted. No path, prompt or reply.
public struct CodingUsageSessionRecord: Codable, Equatable, Sendable {
    public var identityHash: String
    public var lastActivityAt: Date?
    public var currentModel: String?

    public init(identityHash: String, lastActivityAt: Date? = nil, currentModel: String? = nil) {
        self.identityHash = identityHash; self.lastActivityAt = lastActivityAt
        self.currentModel = currentModel
    }
}

public struct CodingUsageSourceReport: Sendable {
    public var sourceID: String
    /// An account hash. A changed account selects a separate ledger rather than merging histories.
    public var accountID: String?
    public var days: [CodingUsageDayRecord]
    public var sessions: [CodingUsageSessionRecord]
    public var collectedAt: Date
    public var coverageStart: String?
    public var coverageEnd: String?
    /// Dates confirmed by a complete scan, including genuine zero-use days.
    public var completeDates: Set<String>
    /// Allows a complete date's explicit correction, including deletion to zero.
    /// Missing historical dates are otherwise preserved and surfaced as a coverage warning.
    public var authoritative: Bool
    public var diagnosticError: String?

    public init(sourceID: String, accountID: String? = nil, days: [CodingUsageDayRecord],
                sessions: [CodingUsageSessionRecord] = [], collectedAt: Date = Date(),
                coverageStart: String? = nil, coverageEnd: String? = nil,
                completeDates: Set<String> = [], authoritative: Bool = true, diagnosticError: String? = nil) {
        self.sourceID = sourceID; self.accountID = accountID; self.days = days
        self.sessions = sessions; self.collectedAt = collectedAt
        self.coverageStart = coverageStart; self.coverageEnd = coverageEnd
        self.completeDates = completeDates; self.authoritative = authoritative
        self.diagnosticError = diagnosticError
    }
}

public enum CodingUsageSourceResult: Sendable {
    case success(CodingUsageSourceReport)
    case failure(sourceID: String, message: String, unavailable: Bool)
}

public enum CodingUsageError: Error, LocalizedError, Sendable {
    case invalid(String)
    case command(String)
    case persistence(String)
    public var errorDescription: String? {
        switch self { case .invalid(let s), .command(let s), .persistence(let s): s }
    }
}

public enum CodingUsageDates {
    public static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    public static func day(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public static func parseDay(_ value: String) -> Date? {
        guard value.count == 10 else { return nil }
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              self.day(date) == value else { return nil }
        return date
    }
    public static func instant(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    public static func parseInstant(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    /// 上报里的时刻一律是 epoch 毫秒
    public static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}

// MARK: - 上报契约
//
// 站点那一侧是 lyjwpage 的 shared/coding-usage.ts：Mac 只报本机观测到的原始事实（日用量行、
// 最近一条用量事件、五分钟 token 桶），合计、排名、「今天」、年度格子、展示名都由站点算。
// 时刻一律 epoch 毫秒，日期是 Asia/Shanghai 的站点日。可空字段为 nil 时整格省略，站点按 null 收。

/// `modules.codingUsage`：本机各来源的账本。站点把一封里出现的 agent 整份替换，没出现的不动。
public struct CodingUsageReport: Codable, Equatable, Sendable {
    public var agents: [CodingUsageAgent]
}

/// 一个 agent 在本机账本里的完整历史和采集状态
public struct CodingUsageAgent: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case ok, error }
    public var id: String
    public var state: State
    /// 最近一次成功采集；从没成功过为 nil
    public var collectedAt: Int64?
    /// state = error：这一轮什么都没采到的原因
    public var error: String?
    /// 采到了但有缺口（token 未分列、历史变短而保留旧日子……）
    public var warning: String?
    /// 本机账本见过的不同会话数（去重后的累计量）
    public var sessionCount: Int?
    /// state = ok：完整历史，按日期升序；state = error：缺省，站点留着已有的日子只换状态
    public var days: [CodingUsageDay]?
}

/// 一天 × 一个 agent。有这一行 = 这一天确认过；各列全 0 = 确认那天没用
public struct CodingUsageDay: Codable, Equatable, Sendable {
    public var date: String
    /// 不含缓存读写
    public var inputTokens: Int64
    /// 含 reasoning
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheCreationTokens: Int64
    /// outputTokens 的子集
    public var reasoningTokens: Int64
    /// ≥ 前四列之和，多出来的是来源没分列的量
    public var totalTokens: Int64
    /// 已估到价的那部分，按公开 API 价估算；不是账单
    public var apiEquivalentCostUSD: Double
    /// 这一天所有有 token 的请求都估到了价
    public var costComplete: Bool
    /// tokens > 0，按用量降序
    public var models: [CodingUsageModelTokens]
}

public struct CodingUsageModelTokens: Codable, Equatable, Sendable {
    public var model: String
    public var tokens: Int64
}

/// `modules.codingActivity`：各 agent 最近一条用量事件。`collectedAt` 前进 = 采集器还活着
public struct CodingActivityReport: Codable, Equatable, Sendable {
    public var collectedAt: Int64
    public var agents: [CodingActivityAgent]
}

public struct CodingActivityAgent: Codable, Equatable, Sendable {
    public var id: String
    /// nil = 这台 Mac 从没见过它的用量事件
    public var lastActivityAt: Int64?
    public var model: String?
}

/// `modules.codingTokenBuckets`：`[from, to)` 范围内的五分钟 token 桶，范围内没有行的桶 = 0
public struct CodingTokenBucketReport: Codable, Equatable, Sendable {
    public var from: Int64
    /// ≤ collectedAt
    public var to: Int64
    public var collectedAt: Int64
    /// 这封覆盖了哪些 agent、各自数没数全；窗口里的行只会是这里列出的 agent
    public var agents: [CodingTokenBucketAgent]
    /// 按 from 升序
    public var windows: [CodingTokenBucketWindow]
}

public enum CodingTokenBucketState: String, Codable, Sendable {
    case ok, partial, unavailable
}

public struct CodingTokenBucketAgent: Codable, Equatable, Sendable {
    public var id: String
    public var state: CodingTokenBucketState
}

public struct CodingTokenBucketWindow: Codable, Equatable, Sendable {
    /// 300_000 的整数倍，桶是 [from, from + 5 分钟)
    public var from: Int64
    public var agents: [CodingTokenBucketRow]
}

public struct CodingTokenBucketRow: Codable, Equatable, Sendable {
    public var id: String
    public var model: String?
    public var inputTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var cacheReadTokens: Int64 = 0
    public var cacheCreationTokens: Int64 = 0
    public var reasoningTokens: Int64 = 0
    /// 去重后的用量事件数
    public var eventCount: Int64 = 0
}
