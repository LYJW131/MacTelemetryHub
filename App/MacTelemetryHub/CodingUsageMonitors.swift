import Foundation
import Combine
import CodingUsageKit

private let usageEngine = CodingUsageEngine(ledgerURL: CodingUsageEngine.defaultLedgerURL)

/// Cursor 的云端历史由常驻的 agent-limits-reporter 上报。这里再拉一遍，Mac 合盖时站点就停更。
private let cursorOwnedElsewhere: Set<String> = ["cursor"]

/// Monitoring only schedules work and publishes display payloads. Collection lives in CodingUsageKit.
@MainActor
class CodingUsageMonitor: ObservableObject {
    @Published private(set) var uploadPayload: JSONValue?
    @Published private(set) var payloadUpdatedAt: Date?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastError: String?
    var onChange: (() -> Void)?
    private var refreshing = false
    private var lastAttempt: Date?
    private var generation = 0
    private var collectionTask: Task<(JSONValue, String?), Error>?

    /// A changed configuration starts a new scan while retaining the last successful payload.
    func invalidateSchedule() {
        collectionTask?.cancel()
        collectionTask = nil
        generation &+= 1
        refreshing = false
        lastAttempt = nil
    }

    func stop() {
        invalidateSchedule()
        uploadPayload = nil
        payloadUpdatedAt = nil
        lastSuccess = nil
        lastError = nil
    }

    func isDue(_ interval: Double) -> Bool {
        !refreshing && (lastAttempt.map { Date().timeIntervalSince($0) >= interval } ?? true)
    }

    func refresh<T: Encodable & Sendable>(
        _ work: @escaping @MainActor () async throws -> (T, String?),
        comparable: ((JSONValue) -> JSONValue)? = nil
    ) async -> Bool {
        guard !refreshing else { return false }
        refreshing = true
        let startedGeneration = generation
        defer {
            if generation == startedGeneration { refreshing = false; collectionTask = nil }
        }
        do {
            let task = Task {
                let (value, warning) = try await work()
                try Task.checkCancellation()
                return (try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), warning)
            }
            collectionTask = task
            let (payload, warning) = try await withTaskCancellationHandler(
                operation: { try await task.value }, onCancel: { task.cancel() }
            )
            guard generation == startedGeneration, !Task.isCancelled else { return false }
            // 间隔从这次结束算起。采集本身若已超过间隔，下一圈 5 秒 tick 不该立刻再开一轮。
            lastAttempt = Date()
            let signature = comparable?(payload) ?? payload
            let previous = uploadPayload.map { comparable?($0) ?? $0 }
            if signature != previous {
                uploadPayload = payload
                payloadUpdatedAt = Date()
                onChange?()
            }
            lastSuccess = Date()
            lastError = warning
            return true
        } catch {
            if generation == startedGeneration {
                if error is CancellationError || Task.isCancelled {
                    lastAttempt = nil
                } else {
                    lastAttempt = Date()
                    lastError = error.localizedDescription
                }
            }
            return false
        }
    }
}

/**
 * 两档节奏：卡片上只有 Claude Code 要看当天的实时用量，所以每轮（`interval`，默认 10 分钟）
 * 只刷 Claude；所有来源的完整采集给年度热力图和累计用，按 `fullInterval`（默认 1 小时）
 * 跑一次。其余来源在两次完整采集之间原样留在账本里。手动刷新总是完整的。
 */
@MainActor
final class VibeCodingUsageMonitor: CodingUsageMonitor {
    static let everyRoundSources: Set<String> = ["claude"]
    private var lastFullRefresh: Date?

    override func invalidateSchedule() {
        super.invalidateSchedule()
        lastFullRefresh = nil
    }

    /// 返回这一轮是不是成功的完整采集：是的话年度热力图该跟着重算
    @discardableResult
    func refreshIfNeeded(ccusageCLIPath: String, interval: Double, fullInterval: Double) async -> Bool {
        guard isDue(interval) else { return false }
        let full = lastFullRefresh.map { Date().timeIntervalSince($0) >= fullInterval } ?? true
        return await refreshNow(ccusageCLIPath: ccusageCLIPath, full: full) && full
    }

    @discardableResult
    func refreshNow(ccusageCLIPath: String, full: Bool = true) async -> Bool {
        let succeeded = await refresh {
            let snapshot = try await usageEngine.refresh(
                executableURL: URL(fileURLWithPath: ccusageCLIPath),
                includeCursor: false,
                omitting: cursorOwnedElsewhere,
                only: full ? nil : Self.everyRoundSources
            )
            let errors = snapshot.usage.agents.compactMap { agent in
                agent.usageStatus.error.map { "\(agent.label)：\($0)" }
            }
            return (snapshot.usage, errors.isEmpty ? nil : errors.joined(separator: "；"))
        }
        if succeeded && full { lastFullRefresh = Date() }
        return succeeded
    }
}

@MainActor
final class CodingSessionMonitor: CodingUsageMonitor {
    func refreshIfNeeded(ccusageCLIPath: String, interval: Double) async {
        if isDue(interval) { _ = await refreshNow(ccusageCLIPath: ccusageCLIPath, forceCcusage: false) }
    }

    /// Codex 和 Claude 每轮都由增量扫描器更新；其余来源的 ccusage session
    /// 由引擎按 5 分钟节流，手动刷新时 `forceCcusage` 让它立刻跑一次。
    @discardableResult
    func refreshNow(ccusageCLIPath: String, forceCcusage: Bool = true) async -> Bool {
        await refresh({
            let result = try await usageEngine.refreshSessions(
                executableURL: URL(fileURLWithPath: ccusageCLIPath), forceCcusage: forceCcusage
            )
            return (result.snapshot.now, result.errors.isEmpty ? nil : result.errors.joined(separator: "；"))
        }, comparable: Self.ignoringScanClock)
    }
}

extension CodingSessionMonitor {
    /// 滚动窗口的起止和采集时刻每扫一次都变，用量窗口本身没变就不该再上报。
    fileprivate static func ignoringScanClock(_ value: JSONValue) -> JSONValue {
        guard case var .object(object) = value else { return value }
        guard case var .object(usage) = object["tokenUsage"] else { return value }
        usage.removeValue(forKey: "from")
        usage.removeValue(forKey: "to")
        usage.removeValue(forKey: "collectedAt")
        object["tokenUsage"] = .object(usage)
        return .object(object)
    }
}

@MainActor
final class VibeCodingYearMonitor: CodingUsageMonitor {
    nonisolated static let defaultRefreshInterval: TimeInterval = 3_600

    func refreshIfNeeded(interval: Double) async {
        if isDue(interval) { _ = await refreshNow() }
    }

    @discardableResult
    func refreshNow() async -> Bool {
        await refresh { (try await usageEngine.snapshot(omitting: cursorOwnedElsewhere).year, nil) }
    }
}
