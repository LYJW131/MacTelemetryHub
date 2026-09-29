import Foundation
import Combine
import CodingUsageKit

private let usageEngine = CodingUsageEngine(ledgerURL: CodingUsageEngine.defaultLedgerURL)

/**
 * Monitoring only schedules work and publishes upload payloads. Collection lives in CodingUsageKit.
 *
 * 每一轮成功的采集都换上最新那一份载荷（带着最新的采集时刻），内容和整份各自的变化时刻
 * 由 `CodingPayload.next` 记；发不发、什么时候保活重发归上报循环（`ReportDecision`）。
 */
@MainActor
class CodingUsageMonitor: ObservableObject {
    @Published private(set) var payloads: [CodingModule: CodingPayload] = [:]
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastError: String?
    var onChange: (() -> Void)?
    private var refreshing = false
    private var lastAttempt: Date?
    private var generation = 0
    private var collectionTask: Task<([CodingModule: JSONValue], String?), Error>?

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
        payloads = [:]
        lastSuccess = nil
        lastError = nil
    }

    func isDue(_ interval: Double) -> Bool {
        !refreshing && (lastAttempt.map { Date().timeIntervalSince($0) >= interval } ?? true)
    }

    /// `work` 返回这一轮的几份载荷（没有的那格不放）和给界面看的问题
    func refresh(
        _ work: @escaping @MainActor () async throws -> ([CodingModule: any Encodable & Sendable], String?)
    ) async -> Bool {
        guard !refreshing else { return false }
        refreshing = true
        let startedGeneration = generation
        defer {
            if generation == startedGeneration { refreshing = false; collectionTask = nil }
        }
        do {
            let task = Task {
                let (values, warning) = try await work()
                try Task.checkCancellation()
                var encoded: [CodingModule: JSONValue] = [:]
                for (module, value) in values {
                    encoded[module] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
                }
                return (encoded, warning)
            }
            collectionTask = task
            let (values, warning) = try await withTaskCancellationHandler(
                operation: { try await task.value }, onCancel: { task.cancel() }
            )
            guard generation == startedGeneration, !Task.isCancelled else { return false }
            // 间隔从这次结束算起。采集本身若已超过间隔，下一圈 5 秒 tick 不该立刻再开一轮。
            let now = Date()
            lastAttempt = now
            var contentChanged = false
            for (module, value) in values {
                let next = CodingPayload.next(after: payloads[module], value: value, module: module, at: now)
                contentChanged = contentChanged || next.contentChangedAt == now
                payloads[module] = next
            }
            // 只有内容变了才叫醒上报循环；保活由循环自己每圈判
            if contentChanged { onChange?() }
            lastSuccess = now
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
 * `codingUsage` 两档节奏。每轮 `interval` 只刷 Claude、报告只带 Claude；全部来源按
 * `fullInterval` 采集。未保存的间隔由 `App/MacTelemetryHub/AppSettings.swift#load` 填上，
 * 完整采集的缺省是 `defaultFullInterval`。其余来源在两次完整采集之间留在账本里。
 * 手动刷新总是完整的。
 *
 * 完整那一轮还没发出去时，下一轮只刷 Claude 的报告会顶掉它，其余来源要等再下一次完整采集。
 */
@MainActor
final class VibeCodingUsageMonitor: CodingUsageMonitor {
    static let everyRoundSources: Set<String> = ["claude"]
    nonisolated static let defaultFullInterval: TimeInterval = 3_600
    private var lastFullRefresh: Date?

    override func invalidateSchedule() {
        super.invalidateSchedule()
        lastFullRefresh = nil
    }

    func refreshIfNeeded(ccusageCLIPath: String, interval: Double, fullInterval: Double) async {
        guard isDue(interval) else { return }
        let full = lastFullRefresh.map { Date().timeIntervalSince($0) >= fullInterval } ?? true
        await refreshNow(ccusageCLIPath: ccusageCLIPath, full: full)
    }

    @discardableResult
    func refreshNow(ccusageCLIPath: String, full: Bool = true) async -> Bool {
        let succeeded = await refresh {
            let result = try await usageEngine.refresh(
                executableURL: URL(fileURLWithPath: ccusageCLIPath),
                only: full ? nil : Self.everyRoundSources
            )
            let warning = result.problems.isEmpty ? nil : result.problems.joined(separator: "；")
            // 账本里还一个来源都没有：站点不收空的 agents，这一轮不出载荷
            guard !result.report.agents.isEmpty else { return ([:], warning) }
            return ([.usage: result.report], warning)
        }
        if succeeded && full { lastFullRefresh = Date() }
        return succeeded
    }
}

/// `codingActivity` 与 `codingTokenBuckets`：一次会话扫描同时产出两份
@MainActor
final class CodingSessionMonitor: CodingUsageMonitor {
    func refreshIfNeeded(ccusageCLIPath: String, interval: Double) async {
        if isDue(interval) { _ = await refreshNow(ccusageCLIPath: ccusageCLIPath, forceCcusage: false) }
    }

    /// Codex 和 Claude 每轮都由增量扫描器更新；其余来源的 ccusage session
    /// 由引擎按 `Sources/CodingUsageKit/CodingUsageEngine.swift#ccusageSessionInterval` 节流，
    /// 手动刷新时 `forceCcusage` 让它立刻跑一次。
    @discardableResult
    func refreshNow(ccusageCLIPath: String, forceCcusage: Bool = true) async -> Bool {
        await refresh {
            let result = try await usageEngine.refreshSessions(
                executableURL: URL(fileURLWithPath: ccusageCLIPath), forceCcusage: forceCcusage
            )
            return (
                [.activity: result.activity, .buckets: result.buckets],
                result.problems.isEmpty ? nil : result.problems.joined(separator: "；")
            )
        }
    }
}
