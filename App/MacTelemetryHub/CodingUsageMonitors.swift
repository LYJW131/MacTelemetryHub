import Foundation
import Combine
import CoreServices
import Darwin
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

    func setLastError(_ message: String?) { lastError = message }
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

    /// Publish a payload that another refresh already collected, and start this monitor's interval from now.
    func accept<T: Encodable & Sendable>(_ value: T, warning: String?) {
        lastAttempt = Date()
        lastSuccess = Date()
        lastError = warning
        guard let payload = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)),
              payload != uploadPayload else { return }
        uploadPayload = payload
        payloadUpdatedAt = Date()
        onChange?()
    }

    /// Same as `accept`, but a ledger republish must not postpone the next full history collect.
    func publishKeepingSchedule<T: Encodable & Sendable>(_ value: T) {
        lastSuccess = Date()
        guard let payload = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)),
              payload != uploadPayload else { return }
        uploadPayload = payload
        payloadUpdatedAt = Date()
        onChange?()
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
            let snapshot = try await usageEngine.refresh(
                executableURL: URL(fileURLWithPath: ccusageCLIPath),
                includeCursor: false,
                omitting: cursorOwnedElsewhere,
                scope: .claudeToday
            )
            let errors = snapshot.usage.agents.compactMap { agent in
                agent.usageStatus.error.map { "\(agent.label)：\($0)" }
            }
            return (snapshot.usage, errors.isEmpty ? nil : errors.joined(separator: "；"))
        }
    }
}

@MainActor
final class CodingSessionMonitor: CodingUsageMonitor {
    private var watcher: DirectoryWatch?
    private var transcripts: TreeWatch?
    private var model: String?
    private var lastActivity: Date?
    private var lastPublished: Date?

    /// Register the Claude Code hook and publish whatever activity is already on disk.
    /// Publishing only Claude clears activity lights for agents this Mac no longer tracks.
    func start() {
        let command = Bundle.main.url(forAuxiliaryExecutable: ClaudeActivityHook.helperExecutableName)?.path
        guard let command else {
            setLastError("应用里没有 claude-activity-hook，正在使用无法接收 Claude Code hook")
            publishCurrent()
            return
        }
        do {
            try ClaudeActivityHook.install(command: command)
            if lastError?.contains("hook") == true { setLastError(nil) }
        } catch {
            setLastError(error.localizedDescription)
        }
        let directory = ClaudeActivityHook.directory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        watcher?.cancel()
        watcher = try? DirectoryWatch(directory: directory) { [weak self] in
            Task { @MainActor in self?.readLatest() }
        }
        // Sessions that started before the hook was registered never call it.
        // A transcript write is enough to keep the light on; the file itself is not read.
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        transcripts?.cancel()
        if FileManager.default.fileExists(atPath: projects.path) {
            transcripts = TreeWatch(path: projects.path) { [weak self] in
                Task { @MainActor in self?.noteTranscript() }
            }
        }
        seedFromTranscripts()
        readLatest(force: true)
    }

    /// Newest session file's modification time. Does not open the file.
    private func seedFromTranscripts() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        var newest: Date?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        if let newest, lastActivity == nil || newest > (lastActivity ?? .distantPast) {
            lastActivity = newest
        }
    }

    private func noteTranscript() {
        let now = Date()
        let due = lastPublished.map { now.timeIntervalSince($0) >= ClaudeActivityHook.publishInterval } ?? true
        lastActivity = now
        guard due else { return }
        publishCurrent()
    }

    private func readLatest(force: Bool = false) {
        guard let data = try? Data(contentsOf: ClaudeActivityHook.latestURL()),
              let notice = ClaudeActivityHook.notice(from: data) else {
            if force { publishCurrent() }
            return
        }
        if let model = notice.model { self.model = model }
        let previous = lastActivity
        lastActivity = notice.at
        let modelChanged = notice.model != nil && notice.model != modelPublished
        let due = lastPublished.map { notice.at.timeIntervalSince($0) >= ClaudeActivityHook.publishInterval } ?? true
        guard force || previous != notice.at && (modelChanged || due) else { return }
        publishCurrent()
    }

    private var modelPublished: String?
    private func publishCurrent() {
        let now = Date()
        let recent = lastActivity.map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= ClaudeActivityHook.activeWindow } ?? false
        accept(CodingUsageNowPayload(agents: [
            CodingUsageNowAgentPayload(
                id: "claude",
                currentModel: model,
                lastActivityAt: lastActivity.map(CodingUsageDates.instant),
                active: recent
            ),
        ]), warning: lastError)
        lastPublished = lastActivity ?? now
        modelPublished = model
    }

    override func stop() {
        watcher?.cancel()
        watcher = nil
        transcripts?.cancel()
        transcripts = nil
        model = nil
        lastActivity = nil
        lastPublished = nil
        modelPublished = nil
        super.stop()
    }

    func stop(removeHook: Bool) {
        if removeHook { try? ClaudeActivityHook.remove() }
        stop()
    }
}

/// Watches a directory for the hook helper's atomic replace of `latest.json`.
private final class DirectoryWatch: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let fd: CInt

    init(directory: URL, handler: @escaping @Sendable () -> Void) throws {
        fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .global()
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
    }

    func cancel() { source.cancel() }
}

/// Recursive file events for `~/.claude/projects`. Only the fact of a write is used.
private final class TreeWatch: @unchecked Sendable {
    private final class HandlerBox: @unchecked Sendable {
        let handler: @Sendable () -> Void
        init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
    }

    private var stream: FSEventStreamRef?
    private let box: HandlerBox

    init(path: String, handler: @escaping @Sendable () -> Void) {
        box = HandlerBox(handler)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<HandlerBox>.fromOpaque(info).takeUnretainedValue().handler()
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global())
            FSEventStreamStart(stream)
        }
    }

    func cancel() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

@MainActor
final class VibeCodingYearMonitor: CodingUsageMonitor {
    nonisolated static let defaultRefreshInterval: TimeInterval = 3_600

    func refreshIfNeeded(ccusageCLIPath: String, interval: Double, usage: VibeCodingUsageMonitor) async {
        if isDue(interval) { _ = await refreshNow(ccusageCLIPath: ccusageCLIPath, usage: usage) }
    }

    /// Full history for every local agent, then both the year chart and the usage totals.
    @discardableResult
    func refreshNow(ccusageCLIPath: String, usage: VibeCodingUsageMonitor) async -> Bool {
        await refresh {
            let snapshot = try await usageEngine.refresh(
                executableURL: URL(fileURLWithPath: ccusageCLIPath),
                includeCursor: false,
                omitting: cursorOwnedElsewhere,
                scope: .allHistory
            )
            let errors = snapshot.usage.agents.compactMap { agent in
                agent.usageStatus.error.map { "\(agent.label)：\($0)" }
            }
            usage.accept(snapshot.usage, warning: errors.isEmpty ? nil : errors.joined(separator: "；"))
            return (snapshot.year, nil)
        }
    }

    /// Year window from the ledger after a Claude-only today refresh. Does not run ccusage or reset the hourly timer.
    func republishFromLedger() async {
        guard let year = try? await usageEngine.snapshot(omitting: cursorOwnedElsewhere).year else { return }
        publishKeepingSchedule(year)
    }
}
