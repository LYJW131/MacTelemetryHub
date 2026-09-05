import Foundation
import Combine
import CodingUsageKit

private let usageEngine = CodingUsageEngine(ledgerURL: CodingUsageEngine.defaultLedgerURL)

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
        _ work: @escaping @MainActor () async throws -> (T, String?)
    ) async -> Bool {
        guard !refreshing else { return false }
        refreshing = true
        lastAttempt = Date()
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
            if payload != uploadPayload {
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
                    lastError = error.localizedDescription
                }
            }
            return false
        }
    }
}

@MainActor
final class VibeCodingUsageMonitor: CodingUsageMonitor {
    func refreshIfNeeded(ccusageCLIPath: String, interval: Double) async {
        if isDue(interval) { _ = await refreshNow(ccusageCLIPath: ccusageCLIPath) }
    }

    @discardableResult
    func refreshNow(ccusageCLIPath: String) async -> Bool {
        await refresh {
            let snapshot = try await usageEngine.refresh(executableURL: URL(fileURLWithPath: ccusageCLIPath))
            let errors = snapshot.usage.agents.compactMap { agent in
                agent.usageStatus.error.map { "\(agent.label)：\($0)" }
            }
            return (snapshot.usage, errors.isEmpty ? nil : errors.joined(separator: "；"))
        }
    }
}

@MainActor
final class CodingSessionMonitor: CodingUsageMonitor {
    func refreshIfNeeded(ccusageCLIPath: String, interval: Double) async {
        if isDue(interval) { _ = await refreshNow(ccusageCLIPath: ccusageCLIPath) }
    }

    @discardableResult
    func refreshNow(ccusageCLIPath: String) async -> Bool {
        await refresh {
            let result = try await usageEngine.refreshSessions(executableURL: URL(fileURLWithPath: ccusageCLIPath))
            return (result.snapshot.now, result.errors.isEmpty ? nil : result.errors.joined(separator: "；"))
        }
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
        await refresh { (try await usageEngine.snapshot().year, nil) }
    }
}
