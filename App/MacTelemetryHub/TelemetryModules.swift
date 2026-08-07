import AppKit
import Foundation

enum JSONValue: Codable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct DesktopActivitySnapshot: Codable, Equatable, Sendable {
    let applicationName: String
    let bundleIdentifier: String?
    let iconData: Data?
    let observedAt: Int64
}

struct AppleMusicSnapshot: Codable, Equatable, Sendable {
    let state: String
    let title: String?
    let artist: String?
    let album: String?
    let trackID: String?
    let artworkData: Data?
    let positionMs: Int
    let durationMs: Int
    /**
     * 单曲循环。
     *
     * Music.app 在循环绕回时**不发** playerInfo 通知（实测跳到距结尾 4 秒，
     * 16 秒观测窗口里绕回那一刻一条都没有），上报器因此不知道进度归零了。
     * 把循环状态告诉网页，让它按 elapsed % duration 自己绕，而不是钉在 100%
     * 干等 25 秒兜底轮询把它当成 seek 才纠正。
     */
    let repeatOne: Bool
    let observedAt: Int64
}

struct TelemetryModulesPayload: Encodable, Sendable {
    let charger: StatusPayload?
    let desktop: DesktopActivitySnapshot?
    let appleMusic: AppleMusicSnapshot?
    let vibeCoding: JSONValue?
    let includeDesktop: Bool
    let includeAppleMusic: Bool

    private enum CodingKeys: String, CodingKey {
        case charger, desktop, appleMusic, vibeCoding
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(charger, forKey: .charger)
        if includeDesktop { try container.encode(desktop, forKey: .desktop) }
        if includeAppleMusic { try container.encode(appleMusic, forKey: .appleMusic) }
        try container.encodeIfPresent(vibeCoding, forKey: .vibeCoding)
    }
}

struct TelemetryEnvelope: Encodable, Sendable {
    let version = 2
    let heartbeatAt: Int64
    let activeModules: [String]
    let modules: TelemetryModulesPayload
}

@MainActor
final class DesktopActivityMonitor: ObservableObject {
    @Published private(set) var snapshot: DesktopActivitySnapshot?
    /// snapshot 变化时通知上报循环，让它别干等到下一个周期
    var onChange: (() -> Void)?
    private var observer: NSObjectProtocol?
    private var iconCache: [String: Data] = [:]

    /// 前台应用完全由 `didActivateApplicationNotification` 驱动，不参与 2 秒轮询。
    /// 上报侧仍然是每 2 秒采样一次 snapshot，所以 Cmd-Tab 途经的应用只会在
    /// 这里被覆盖掉、不会被采到，防抖是采样天然带来的，不需要额外机制。
    func start() {
        capture()
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // 用通知自带的那个应用，而不是回头再读 frontmostApplication —— 后者
            // 在通知送达时可能还是旧值，一旦读偏就会一直错到下次切换。
            let activated = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication
            Task { @MainActor in self?.capture(activated) }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        snapshot = nil
    }

    /// 传 nil 表示「自己去问当前前台是谁」，只有启动时的第一次采集这么用。
    func capture(_ activated: NSRunningApplication? = nil) {
        guard let app = activated ?? NSWorkspace.shared.frontmostApplication else { return }
        let iconKey = app.bundleIdentifier ?? app.bundleURL?.path ?? app.localizedName ?? "unknown"
        let iconData: Data?
        if let cached = iconCache[iconKey] {
            iconData = cached
        } else {
            iconData = Self.pngData(for: app.icon)
            if let iconData { iconCache[iconKey] = iconData }
        }
        snapshot = DesktopActivitySnapshot(
            applicationName: app.localizedName ?? "Unknown",
            bundleIdentifier: app.bundleIdentifier,
            iconData: iconData,
            observedAt: Self.nowMilliseconds
        )
        onChange?()
    }

    private static var nowMilliseconds: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    private static func pngData(for icon: NSImage?) -> Data? {
        guard let icon else { return nil }
        let size = NSSize(width: 128, height: 128)
        let resized = NSImage(size: size)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(origin: .zero, size: size))
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

@MainActor
final class AppleMusicMonitor: ObservableObject {
    @Published private(set) var snapshot: AppleMusicSnapshot?
    @Published private(set) var lastError: String?
    /// snapshot 变化时通知上报循环，让它别干等到下一个周期
    var onChange: (() -> Void)?

    private var observer: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?
    private var refreshing = false
    private var pendingRefresh = false

    /**
     * 兜底轮询间隔。
     *
     * 拖动进度条**不发**通知，是唯一漏网的状态变化，只能靠定时重读把进度锚点
     * 校回来。换歌、播放、暂停都有通知，所以这里可以给得很松。
     */
    private static let seekPollInterval = Duration.seconds(25)

    /// 通知送达和 Music.app 状态落定之间的确认读延迟，实测足够盖住这个竞态
    private static let settleDelay = Duration.milliseconds(400)

    /**
     * 播放状态改由 Music.app 的跨进程通知驱动，不再 2 秒轮询一次 AppleScript。
     *
     * `com.apple.Music.playerInfo` 在每次换歌和播放/暂停时发出，带了 Player State、
     * 曲目身份和 Total Time —— 但**没有播放进度，也没有封面**。所以这里只把它
     * 当触发器：收到就跑一次 AppleScript，专门取那两样拿不到的。
     */
    func start() {
        Task { await refresh() }
        guard observer == nil else { return }

        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // 通知可能赶在 Music.app 自己的状态落定之前送达 —— 实测按下暂停后
                // 紧跟着读，player state 拿到的还是 playing。所以先立刻读一次保证
                // 响应快，再补一次确认读把这个竞态消掉。
                await self?.refresh()
                try? await Task.sleep(for: Self.settleDelay)
                await self?.refresh()
            }
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.seekPollInterval)
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
    }

    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        pollTask?.cancel()
        pollTask = nil
        snapshot = nil
        lastError = nil
    }

    /**
     * 同一次换歌 Music.app 会连发好几条通知，实测两次 playpause 收到四条。
     * 这里做合并：已有一次在飞就只记一个待办，等它回来再补跑一次 ——
     * 既不会把 AppleScript 打成串，也不会把最后一次状态变化漏掉。
     */
    func refresh() async {
        if refreshing {
            pendingRefresh = true
            return
        }
        refreshing = true
        defer { refreshing = false }

        repeat {
            pendingRefresh = false
            let previous = snapshot
            do {
                snapshot = try await Task.detached(priority: .utility) {
                    try Self.readSnapshot()
                }.value
                lastError = nil
            } catch {
                snapshot = nil
                lastError = error.localizedDescription
            }
            // 25 秒兜底轮询多数时候读到的和上次一样，没必要为此叫醒上报循环
            if snapshot != previous { onChange?() }
        } while pendingRefresh
    }

    nonisolated private static func readSnapshot() throws -> AppleMusicSnapshot? {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Music"
        ).isEmpty else {
            return AppleMusicSnapshot(
                state: "stopped",
                title: nil,
                artist: nil,
                album: nil,
                trackID: nil,
                artworkData: nil,
                positionMs: 0,
                durationMs: 0,
                repeatOne: false,
                observedAt: Int64(Date().timeIntervalSince1970 * 1_000)
            )
        }

        let source = """
        tell application "Music"
            set stateText to (player state as text)
            if stateText is "stopped" then return {stateText, "", "", "", "", "0", "0"}
            set currentSong to current track
            set songName to ""
            set songArtist to ""
            set songAlbum to ""
            set songID to ""
            set songDuration to 0
            try
                set songName to name of currentSong
            end try
            try
                set songArtist to artist of currentSong
            end try
            try
                set songAlbum to album of currentSong
            end try
            try
                set songID to persistent ID of currentSong
            end try
            try
                set songDuration to duration of currentSong
            end try
            set songArtwork to ""
            try
                if (count of artworks of currentSong) > 0 then set songArtwork to raw data of artwork 1 of currentSong
            end try
            set repeatMode to "off"
        try
            set repeatMode to (song repeat as text)
        end try
        return {stateText, songName, songArtist, songAlbum, songID, (player position as text), (songDuration as text), songArtwork, repeatMode}
        end tell
        """
        var errorInfo: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo) else {
            let message = errorInfo?[NSAppleScript.errorMessage] as? String ?? "无法读取 Music.app"
            throw TelemetryModuleError.appleMusic(message)
        }

        func item(_ index: Int) -> String {
            result.atIndex(index)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let rawState = item(1)
        let state = rawState == "playing" || rawState == "paused" ? rawState : "stopped"
        return AppleMusicSnapshot(
            state: state,
            title: item(2).nilIfEmpty,
            artist: item(3).nilIfEmpty,
            album: item(4).nilIfEmpty,
            trackID: item(5).nilIfEmpty,
            artworkData: optimizedArtworkData(result.atIndex(8)?.data),
            positionMs: Int((Double(item(6)) ?? 0) * 1_000),
            durationMs: Int((Double(item(7)) ?? 0) * 1_000),
            // 封面是二进制，占 8；循环状态接在它后面
            repeatOne: item(9) == "one",
            observedAt: Int64(Date().timeIntervalSince1970 * 1_000)
        )
    }

    nonisolated private static func optimizedArtworkData(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        guard let bitmap = NSBitmapImageRep(data: data),
              let jpeg = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.82]
              ) else { return data }
        return jpeg
    }
}

extension DesktopActivitySnapshot {
    func withIconData(_ iconData: Data?) -> DesktopActivitySnapshot {
        DesktopActivitySnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            iconData: iconData,
            observedAt: observedAt
        )
    }
}

extension AppleMusicSnapshot {
    func withArtworkData(_ artworkData: Data?) -> AppleMusicSnapshot {
        AppleMusicSnapshot(
            state: state,
            title: title,
            artist: artist,
            album: album,
            trackID: trackID,
            artworkData: artworkData,
            positionMs: positionMs,
            durationMs: durationMs,
            repeatOne: repeatOne,
            observedAt: observedAt
        )
    }
}

@MainActor
final class CcusageMonitor: ObservableObject {
    @Published private(set) var payload: JSONValue?
    @Published private(set) var uploadPayload: JSONValue?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastError: String?
    private var refreshing = false

    func stop() {
        payload = nil
        uploadPayload = nil
        lastSuccess = nil
        lastError = nil
        refreshing = false
    }

    func refreshIfNeeded(nodePath: String, cliPath: String, interval: Double) async {
        guard !refreshing else { return }
        if let lastSuccess, Date().timeIntervalSince(lastSuccess) < interval { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let collection = try await Task.detached(priority: .utility) {
                try CcusageCollector.collect(nodePath: nodePath, cliPath: cliPath)
            }.value
            payload = collection.localPayload
            uploadPayload = collection.uploadPayload
            lastSuccess = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

private struct CcusageCollection: Sendable {
    let localPayload: JSONValue
    let uploadPayload: JSONValue
}

private enum CcusageCollector {
    nonisolated static func collect(nodePath: String, cliPath: String) throws -> CcusageCollection {
        guard FileManager.default.isExecutableFile(atPath: nodePath) else {
            throw TelemetryModuleError.ccusage("Node 路径不可执行：\(nodePath)")
        }
        guard FileManager.default.fileExists(atPath: cliPath) else {
            throw TelemetryModuleError.ccusage("找不到 ccusage CLI：\(cliPath)")
        }

        var reports: [String: Any] = [:]
        for agent in ["claude", "codex"] {
            let onlineArgs = [cliPath, agent, "daily", "--json", "--mode", "calculate"]
            let dailyData: Data
            do {
                dailyData = try run(nodePath, onlineArgs)
            } catch {
                dailyData = try run(nodePath, onlineArgs + ["--offline"])
            }
            let sessionData = try run(
                nodePath,
                [cliPath, agent, "session", "--json", "--offline"]
            )
            guard var daily = try JSONSerialization.jsonObject(with: dailyData) as? [String: Any],
                  let session = try JSONSerialization.jsonObject(with: sessionData) as? [String: Any] else {
                throw TelemetryModuleError.ccusage("\(agent) 输出不是有效 JSON")
            }
            daily["sessionSummary"] = summarize(session)
            reports[agent] = daily
        }
        let data = try JSONSerialization.data(withJSONObject: reports)
        let localPayload = try JSONDecoder().decode(JSONValue.self, from: data)
        let uploadData = try JSONSerialization.data(withJSONObject: makeUploadSummary(reports))
        return CcusageCollection(
            localPayload: localPayload,
            uploadPayload: try JSONDecoder().decode(JSONValue.self, from: uploadData)
        )
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TelemetryModuleError.ccusage("ccusage 退出码 \(process.terminationStatus)")
        }
        return data
    }

    private static func summarize(_ report: [String: Any]) -> [String: Any] {
        let sessions = report["sessions"] as? [[String: Any]] ?? []
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardFormatter = ISO8601DateFormatter()
        let dated = sessions.compactMap { session -> ([String: Any], Date)? in
            guard let value = session["lastActivity"] as? String,
                  let date = fractionalFormatter.date(from: value)
                    ?? standardFormatter.date(from: value) else { return nil }
            return (session, date)
        }
        let latest = dated.max { $0.1 < $1.1 }
        let latestDate = latest?.1 ?? .distantPast
        var modelTotals: [String: Double] = [:]

        for (session, date) in dated where latestDate.timeIntervalSince(date) <= 300 {
            if let models = session["models"] as? [String: [String: Any]] {
                for (name, row) in models {
                    modelTotals[name, default: 0] += number(row["totalTokens"])
                }
            } else if let rows = session["modelBreakdowns"] as? [[String: Any]] {
                for row in rows {
                    guard let name = row["modelName"] as? String else { continue }
                    modelTotals[name, default: 0] +=
                        number(row["inputTokens"]) + number(row["outputTokens"]) +
                        number(row["cacheReadTokens"]) + number(row["cacheCreationTokens"])
                }
            }
        }

        let bucketMs: Double = 12 * 60 * 60 * 1_000
        let current = floor(Date().timeIntervalSince1970 * 1_000 / bucketMs) * bucketMs
        let start = current - 59 * bucketMs
        var activity = (0..<60).map { ["t": start + Double($0) * bucketMs, "tokens": 0.0] }
        for (session, date) in dated {
            let timestamp = date.timeIntervalSince1970 * 1_000
            let index = Int(floor((timestamp - start) / bucketMs))
            if activity.indices.contains(index) {
                activity[index]["tokens"] = (activity[index]["tokens"] ?? 0) + number(session["totalTokens"])
            }
        }

        return [
            "count": sessions.count,
            "lastActivity": latest?.0["lastActivity"] ?? NSNull(),
            "currentModel": modelTotals.max { $0.value < $1.value }?.key ?? NSNull(),
            "activity": activity,
        ]
    }

    /// The website only needs display-ready aggregates. Keep ccusage's complete
    /// daily/model output on the Mac and send this bounded summary instead.
    private static func makeUploadSummary(_ reports: [String: Any]) -> [String: Any] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start30 = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        var agents: [[String: Any]] = []
        var aggregate = emptyTotals()
        var activeDates = Set<String>()
        var sessionCount = 0.0
        var modelTotals: [String: Double] = [:]

        for agent in ["claude", "codex"] {
            guard let report = reports[agent] as? [String: Any] else { continue }
            let rawDays = report["daily"] as? [[String: Any]] ?? []
            for row in rawDays { addModelUsage(row, to: &modelTotals) }
            let allDays = rawDays.compactMap(normalizeDay)
            let recentDays = allDays.filter { row in
                guard let date = dayDate(row["date"] as? String) else { return false }
                return date >= start30
            }
            let recentByDate = Dictionary(uniqueKeysWithValues: recentDays.compactMap { row in
                (row["date"] as? String).map { ($0, row) }
            })
            let last7Days = (0..<7).map { offset -> [String: Any] in
                let date = calendar.date(byAdding: .day, value: offset - 6, to: today) ?? today
                let key = dayString(date)
                return preparedDay(recentByDate[key] ?? normalizedEmptyDay(date: key))
            }
            let todayText = dayString(today)
            let todayRow = preparedDay(recentByDate[todayText] ?? normalizedEmptyDay(date: todayText))
            let summary = report["sessionSummary"] as? [String: Any] ?? [:]
            let totals = normalizeTotals(report["totals"] as? [String: Any] ?? [:])
            let models = Set(allDays.flatMap { $0["models"] as? [String] ?? [] }).sorted()

            sessionCount += number(summary["count"])
            for row in allDays where number(row["totalTokens"]) > 0 {
                if let date = row["date"] as? String { activeDates.insert(date) }
            }
            addTotals(totals, to: &aggregate)

            agents.append([
                "id": agent,
                "label": agent == "claude" ? "Claude Code" : "Codex",
                "models": models,
                "currentModel": summary["currentModel"] ?? NSNull(),
                "lastActivityAt": summary["lastActivity"] ?? NSNull(),
                "activity": summary["activity"] ?? [],
                "today": todayRow,
                "last7Days": last7Days,
                "last30DaysTokens": recentDays.reduce(0.0) { $0 + number($1["totalTokens"]) },
            ])
        }

        aggregate["activeDays"] = Double(activeDates.count)
        aggregate["sessions"] = sessionCount
        return [
            "agents": agents,
            "totals": aggregate,
            "topModels": modelTotals
                .filter { $0.value > 0 }
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { ["model": $0.key, "tokens": $0.value] },
            "collectedAt": ISO8601DateFormatter().string(from: Date()),
        ]
    }

    private static func addModelUsage(
        _ row: [String: Any],
        to totals: inout [String: Double]
    ) {
        if let models = row["models"] as? [String: Any] {
            for (name, value) in models {
                guard let detail = value as? [String: Any] else { continue }
                let explicit = number(detail["totalTokens"])
                let tokens = explicit > 0 ? explicit :
                    number(detail["inputTokens"]) + number(detail["outputTokens"]) +
                    number(detail["cacheReadTokens"]) + number(detail["cacheCreationTokens"])
                totals[name, default: 0] += tokens
            }
            return
        }
        for detail in row["modelBreakdowns"] as? [[String: Any]] ?? [] {
            guard let name = detail["modelName"] as? String else { continue }
            totals[name, default: 0] +=
                number(detail["inputTokens"]) + number(detail["outputTokens"]) +
                number(detail["cacheReadTokens"]) + number(detail["cacheCreationTokens"])
        }
    }

    private static func normalizeDay(_ row: [String: Any]) -> [String: Any]? {
        guard let date = row["date"] as? String, dayDate(date) != nil else { return nil }
        let input = number(row["inputTokens"])
        let output = number(row["outputTokens"])
        let cacheRead = number(row["cacheReadTokens"])
        let cacheCreation = number(row["cacheCreationTokens"])
        let reasoning = number(row["reasoningOutputTokens"])
        let total = number(row["totalTokens"])
        let modelNames: [String]
        if let models = row["models"] as? [String: Any] {
            modelNames = models.keys.sorted()
        } else {
            modelNames = (row["modelsUsed"] as? [String] ?? []).sorted()
        }
        return [
            "date": date,
            "inputTokens": input,
            "outputTokens": output,
            "cacheReadTokens": cacheRead,
            "cacheCreationTokens": cacheCreation,
            "reasoningTokens": reasoning,
            "totalTokens": total > 0 ? total : input + output + cacheRead + cacheCreation,
            "apiEquivalentCostUSD": number(row["totalCost"] ?? row["costUSD"]),
            "models": modelNames,
        ]
    }

    private static func normalizedEmptyDay(date: String) -> [String: Any] {
        [
            "date": date,
            "inputTokens": 0.0,
            "outputTokens": 0.0,
            "cacheReadTokens": 0.0,
            "cacheCreationTokens": 0.0,
            "reasoningTokens": 0.0,
            "totalTokens": 0.0,
            "apiEquivalentCostUSD": 0.0,
            "models": [],
        ]
    }

    private static func preparedDay(_ row: [String: Any]) -> [String: Any] {
        [
            "date": row["date"] ?? "",
            "inputTokens": number(row["inputTokens"]),
            "outputTokens": number(row["outputTokens"]),
            "cacheReadTokens": number(row["cacheReadTokens"]),
            "cacheCreationTokens": number(row["cacheCreationTokens"]),
            "totalTokens": number(row["totalTokens"]),
            "apiEquivalentCostUSD": number(row["apiEquivalentCostUSD"]),
        ]
    }

    private static func normalizeTotals(_ row: [String: Any]) -> [String: Double] {
        let input = number(row["inputTokens"])
        let output = number(row["outputTokens"])
        let cacheRead = number(row["cacheReadTokens"])
        let cacheCreation = number(row["cacheCreationTokens"])
        let total = number(row["totalTokens"])
        return [
            "inputTokens": input,
            "outputTokens": output,
            "cacheReadTokens": cacheRead,
            "cacheCreationTokens": cacheCreation,
            "reasoningTokens": number(row["reasoningOutputTokens"]),
            "totalTokens": total > 0 ? total : input + output + cacheRead + cacheCreation,
            "apiEquivalentCostUSD": number(row["totalCost"] ?? row["costUSD"]),
        ]
    }

    private static func emptyTotals() -> [String: Double] {
        [
            "inputTokens": 0,
            "outputTokens": 0,
            "cacheReadTokens": 0,
            "cacheCreationTokens": 0,
            "reasoningTokens": 0,
            "totalTokens": 0,
            "apiEquivalentCostUSD": 0,
        ]
    }

    private static func addTotals(_ source: [String: Double], to destination: inout [String: Double]) {
        for (key, value) in source { destination[key, default: 0] += value }
    }

    private static func dayDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return dayFormatter.date(from: value)
    }

    private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }
}

private enum TelemetryModuleError: LocalizedError {
    case appleMusic(String)
    case ccusage(String)

    var errorDescription: String? {
        switch self {
        case let .appleMusic(message): "Apple Music：\(message)"
        case let .ccusage(message): "ccusage：\(message)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
