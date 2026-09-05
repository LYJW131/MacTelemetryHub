import Foundation

public enum CodingUsagePrecision: String, Codable, Sendable {
    case measured, estimated, mixed
}

public struct CodingUsageStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case ok, error, unavailable }
    public var state: State
    public var collectedAt: String?
    public var error: String?
    public var coverageStart: String?
    public var coverageEnd: String?
    public var precision: CodingUsagePrecision
    public var costComplete: Bool

    public init(state: State, collectedAt: String? = nil, error: String? = nil,
                coverageStart: String? = nil, coverageEnd: String? = nil,
                precision: CodingUsagePrecision = .measured, costComplete: Bool = false) {
        self.state = state; self.collectedAt = collectedAt; self.error = error
        self.coverageStart = coverageStart; self.coverageEnd = coverageEnd
        self.precision = precision; self.costComplete = costComplete
    }
    enum CodingKeys: String, CodingKey { case state, collectedAt, error, coverageStart, coverageEnd, precision, costComplete }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state); try c.encode(collectedAt, forKey: .collectedAt)
        try c.encode(error, forKey: .error); try c.encode(coverageStart, forKey: .coverageStart)
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

    public init(date: String, inputTokens: Int64 = 0, outputTokens: Int64 = 0,
                cacheReadTokens: Int64 = 0, cacheCreationTokens: Int64 = 0,
                reasoningTokens: Int64 = 0, totalTokens: Int64 = 0,
                apiEquivalentCostUSD: Double? = nil, models: [String: Int64] = [:], unclassifiedTokens: Int64? = nil) {
        self.date = date; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheCreationTokens = cacheCreationTokens
        self.reasoningTokens = reasoningTokens; self.totalTokens = totalTokens
        self.apiEquivalentCostUSD = apiEquivalentCostUSD; self.models = models
        self.unclassifiedTokens = unclassifiedTokens
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
    public var precision: CodingUsagePrecision
    public var costComplete: Bool
    /// Dates confirmed by a complete scan, including genuine zero-use days.
    public var completeDates: Set<String>
    /// Allows a complete date's explicit correction, including deletion to zero.
    /// Missing historical dates are otherwise preserved and surfaced as a coverage error.
    public var authoritative: Bool
    public var diagnosticError: String?

    public init(sourceID: String, accountID: String? = nil, days: [CodingUsageDayRecord],
                sessions: [CodingUsageSessionRecord] = [], collectedAt: Date = Date(),
                coverageStart: String? = nil, coverageEnd: String? = nil,
                precision: CodingUsagePrecision = .measured, costComplete: Bool = false,
                completeDates: Set<String> = [], authoritative: Bool = true, diagnosticError: String? = nil) {
        self.sourceID = sourceID; self.accountID = accountID; self.days = days
        self.sessions = sessions; self.collectedAt = collectedAt
        self.coverageStart = coverageStart; self.coverageEnd = coverageEnd
        self.precision = precision; self.costComplete = costComplete
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
}

public struct CodingUsageAgentSpec: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var icon: String
    public init(id: String, label: String, icon: String) { self.id = id; self.label = label; self.icon = icon }
    public static let defaults: [Self] = [
        .init(id: "claude", label: "Claude Code", icon: "anthropic"),
        .init(id: "codex", label: "Codex", icon: "openai"),
        .init(id: "cursor", label: "Cursor", icon: "cursor"),
        .init(id: "grok", label: "Grok Build", icon: "grok"),
        .init(id: "antigravity", label: "Antigravity", icon: "antigravity"),
    ]
}

public struct CodingUsageDayPayload: Codable, Equatable, Sendable {
    public let date: String
    public let inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, totalTokens: Int64
    public let apiEquivalentCostUSD: Double
    init(_ record: CodingUsageDayRecord) {
        date = record.date; inputTokens = record.inputTokens; outputTokens = record.outputTokens
        cacheReadTokens = record.cacheReadTokens; cacheCreationTokens = record.cacheCreationTokens
        totalTokens = record.totalTokens; apiEquivalentCostUSD = record.apiEquivalentCostUSD ?? 0
    }
}

public struct CodingUsageAgentPayload: Codable, Equatable, Sendable {
    public let id, label, icon: String
    public let models: [String]
    public let currentModel, topModel: String?
    public let today: CodingUsageDayPayload?
    public let usageStatus: CodingUsageStatus
    enum CodingKeys: String, CodingKey { case id, label, icon, models, currentModel, topModel, today, usageStatus }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(label, forKey: .label); try c.encode(icon, forKey: .icon)
        try c.encode(models, forKey: .models); try c.encode(currentModel, forKey: .currentModel)
        try c.encode(topModel, forKey: .topModel); try c.encode(today, forKey: .today)
        try c.encode(usageStatus, forKey: .usageStatus)
    }
}

public struct CodingUsageTotalsPayload: Codable, Equatable, Sendable {
    public var inputTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var cacheReadTokens: Int64 = 0
    public var cacheCreationTokens: Int64 = 0
    public var reasoningTokens: Int64 = 0
    public var totalTokens: Int64 = 0
    public var apiEquivalentCostUSD: Double = 0
    public var activeDays: Int = 0
    public var sessionCount: Int = 0
    public var costComplete: Bool = true
}

public struct CodingUsageModelPayload: Codable, Equatable, Sendable {
    public let model: String
    public let tokens: Int64
}
public struct CodingUsagePayload: Codable, Equatable, Sendable {
    public let agents: [CodingUsageAgentPayload]
    public let totals: CodingUsageTotalsPayload
    public let topModels: [CodingUsageModelPayload]
    public let collectedAt: String
}
public struct CodingUsageNowAgentPayload: Codable, Equatable, Sendable {
    public let id: String
    public let currentModel: String?
    public let lastActivityAt: String?
    public let active: Bool
    enum CodingKeys: String, CodingKey { case id, currentModel, lastActivityAt, active }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(currentModel, forKey: .currentModel)
        try c.encode(lastActivityAt, forKey: .lastActivityAt); try c.encode(active, forKey: .active)
    }
}
public struct CodingUsageNowPayload: Codable, Equatable, Sendable {
    public let agents: [CodingUsageNowAgentPayload]
}
public struct CodingUsageYearPayload: Codable, Equatable, Sendable {
    public let origin: String
    public let days: [Int64]
    public let models: [String]
    public let mix: [[Int64]]
}
public struct CodingUsageSnapshot: Codable, Equatable, Sendable {
    public let usage: CodingUsagePayload
    public let now: CodingUsageNowPayload
    public let year: CodingUsageYearPayload
}
