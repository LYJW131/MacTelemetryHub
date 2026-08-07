import AppKit
import Foundation
import Security

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
    /**
     * 上报器自己声明的在线状态。
     *
     * 平时恒为 online —— 能发出这个包本身就说明在线。有意义的是 offline：
     * 退出、睡眠这类**优雅**离开时抢在断开前发一条，网页就不用等心跳超时。
     *
     * 但它取代不了超时判定：崩溃、断网、强制关机时上报器根本没机会发这一条，
     * 那些情况只能靠「多久没收到心跳」兜底。两者是互补的，不是二选一。
     */
    let presence: String
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

        reschedulePoll()
    }

    /**
     * 下一次兜底重读等多久。
     *
     * 曲目该放完的那一刻必须立刻去看：接下来要么循环回开头、要么换了下一首，
     * 两种都需要新锚点，而 Music.app 这两种情况都不发通知（换歌发，循环不发）。
     *
     * 之所以不去判断「是不是单曲循环」：那个问题根本答不了。song repeat 只有
     * off/one/all，而 all 到底会不会回到同一首取决于播放队列 —— 实测从资料库
     * 播放时 current playlist 是「音乐」共 730 首，专辑自己有几首完全不相干，
     * AppleScript 又拿不到队列。与其猜，不如到点了直接去看。
     */
    /**
     * 每次 snapshot 变化后重排下一次兜底重读。
     *
     * 不能用「固定间隔的循环」：那样延迟是进入睡眠前算好的，而通知驱动的
     * refresh 随时会换掉锚点，循环还按旧计划睡，「到点去看」就落空了。
     */
    private func reschedulePoll() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            let delay = self?.nextPollDelay() ?? Self.seekPollInterval
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // refresh 结束时会再排下一次
            await self?.refresh()
        }
    }

    private func nextPollDelay() -> Duration {
        guard let snapshot, snapshot.state == "playing", snapshot.durationMs > 0 else {
            return Self.seekPollInterval
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let elapsed = Int(max(0, now - snapshot.observedAt))
        let remaining = snapshot.durationMs - (snapshot.positionMs + elapsed)
        // 已经过点了（比如刚从睡眠醒来）就尽快补一次
        guard remaining > 0 else { return .milliseconds(1_500) }
        // 结束后再多等 1 秒，让 Music.app 把新状态落定
        return min(Self.seekPollInterval, .milliseconds(remaining + 1_000))
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
            // 兜底重读多数时候读到的和上次一样，没必要为此叫醒上报循环
            if snapshot != previous { onChange?() }
        } while pendingRefresh

        // 锚点可能变了，下一次该什么时候看也跟着变
        reschedulePoll()
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

struct AgentLimitWindow: Codable, Equatable, Sendable {
    /// 桶 + 窗口的稳定标识，如 "codex.primary" / "weekly_scoped"
    let key: String
    /// 桶名 / 作用域名，如 "GPT-5.3-Codex-Spark" / "Fable"；没有就 nil
    let label: String?
    /**
     * 来源方给的粗分组，如 "session" / "weekly"。
     *
     * 和 `windowMinutes` 是互补的：Codex 给分钟数不给分组，Claude 给分组不给时长，
     * 两个都可能为 nil 但不会同时为 nil —— UI 就靠这个不变量出窗口名。
     * 不许由 group 反推分钟数，「session 就是 5 小时」是猜的。
     */
    let group: String?
    let windowMinutes: Int?
    let usedPercent: Double
    /// Unix 秒
    let resetsAt: Int64?
}

struct AgentPlanSnapshot: Codable, Equatable, Sendable {
    /// 后端原始值，如 "prolite" / "default_claude_max_5x"
    let tier: String
    /// 展示名，如 "Pro Lite" / "Max 5x"
    let label: String
    let limits: [AgentLimitWindow]
    /// 毫秒
    let observedAt: Int64

    /// 除采集时刻外是否完全一致。observedAt 每次采集都会变，直接用 == 判断
    /// 「套餐有没有变」会把每一次采集都算成变化。
    func hasSameContent(as other: AgentPlanSnapshot) -> Bool {
        tier == other.tier && label == other.label && limits == other.limits
    }
}

/// tier → 展示名。没收录的值原样回显 —— 后端随时会加新套餐（planType 里已经有
/// unknown 和几个按量计费的长名字），映射不到就显示空白反而更糟。
func agentPlanLabel(agent: String, tier: String) -> String {
    switch agent {
    case "codex":
        switch tier {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        default: return tier
        }
    case "claude":
        switch tier {
        case "default_claude_max_5x": return "Max 5x"
        case "default_claude_max_20x": return "Max 20x"
        case "default_claude_pro": return "Pro"
        case "claude_max": return "Max"
        case "claude_pro": return "Pro"
        case "claude_free": return "Free"
        default: return tier
        }
    default:
        return tier
    }
}

@MainActor
final class AgentLimitsMonitor: ObservableObject {
    @Published private(set) var plans: [String: AgentPlanSnapshot] = [:]
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastError: String?

    private var refreshing = false
    /// 间隔门闩看的是「上次尝试」而不是 lastSuccess：codex 路径配错时每次采集都要
    /// 起一次子进程、等满超时，按失败重试会变成每个上报周期都来一遍。
    private var lastAttempt: Date?

    func stop() {
        plans = [:]
        lastSuccess = nil
        lastError = nil
        lastAttempt = nil
        refreshing = false
    }

    func refreshIfNeeded(codexPath: String, interval: Double) async {
        guard !refreshing else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < interval { return }
        refreshing = true
        lastAttempt = Date()
        defer { refreshing = false }

        let outcome = await AgentLimitsCollector.collect(codexPath: codexPath)

        // 内容没变就留着旧快照。换成时间戳更新的那份会让下游（上传门闩、
        // @Published 订阅者）把每次采集都当成「套餐变了」。
        var fresh = outcome.plans
        for (agent, snapshot) in fresh {
            if let previous = plans[agent], previous.hasSameContent(as: snapshot) {
                fresh[agent] = previous
            }
        }
        plans = fresh
        lastError = outcome.errors.isEmpty ? nil : outcome.errors.joined(separator: "；")
        if !fresh.isEmpty { lastSuccess = Date() }
    }
}

private struct AgentLimitsOutcome: Sendable {
    let plans: [String: AgentPlanSnapshot]
    let errors: [String]
}

/// Process 不是 Sendable，超时看门狗又必须在另一个队列上摸它。这里只碰
/// isRunning / terminate 两个调用。
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

private struct ClaudeCredentials: Sendable {
    let accessToken: String
    let subscriptionType: String?
}

private enum AgentLimitsCollector {
    private static let codexTimeout: Double = 20
    private static let claudeUsageEndpoint = "https://api.anthropic.com/api/oauth/usage"
    /**
     * 必须冒充 Claude Code 的 User-Agent。
     *
     * 不带这个头会被归进另一个很凶的限流桶，稳定 429。版本号写死在这里，
     * 端点是未公开的，升不升跟本机装的 Claude Code 没关系。
     */
    private static let claudeUserAgent = "claude-code/2.1.224"

    /// codex 起子进程、claude 读钥匙串 + 打接口，两边分别 catch：
    /// 一边失败不能把另一边一起拖没。
    nonisolated static func collect(codexPath: String) async -> AgentLimitsOutcome {
        var plans: [String: AgentPlanSnapshot] = [:]
        var errors: [String] = []
        do {
            // 子进程那套是纯阻塞的，丢进 detached 里跑，别占着协作线程
            plans["codex"] = try await Task.detached(priority: .utility) {
                try Self.codexPlan(codexPath: codexPath)
            }.value
        } catch {
            errors.append(error.localizedDescription)
        }

        // tier 和 limits 再分一层：usage 接口挂了（限流 / 凭据过期）不该把套餐名
        // 也一起弄没，那个是本地读的，跟网络无关。
        let credentials = claudeCredentials()
        do {
            let tier = try claudeTier(credentials: credentials)
            var limits: [AgentLimitWindow] = []
            do {
                limits = try await claudeLimits(credentials: credentials)
            } catch {
                errors.append(error.localizedDescription)
            }
            plans["claude"] = AgentPlanSnapshot(
                tier: tier,
                label: agentPlanLabel(agent: "claude", tier: tier),
                limits: limits,
                observedAt: nowMilliseconds
            )
        } catch {
            errors.append(error.localizedDescription)
        }
        return AgentLimitsOutcome(plans: plans, errors: errors)
    }

    nonisolated private static func codexPlan(codexPath: String) throws -> AgentPlanSnapshot {
        let result = try readRateLimits(codexPath: codexPath)
        /**
         * 只读 rateLimitsByLimitId（多桶）。
         *
         * 顶层 rateLimits 是官方标注的向后兼容单桶视图 —— 同一份数据的降级投影，
         * 不是另一个来源，只读它会把 codex_bengalfox 这类附加额度整个丢掉。
         * 也不给它留回退分支：平时永远走不到，真走到那天说明后端换了结构，
         * 那条几年没执行过的路径大概率也是错的，不如空着让问题立刻暴露。
         */
        let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]

        var limits: [AgentLimitWindow] = []
        for (bucketKey, bucket) in buckets {
            let limitId = (bucket["limitId"] as? String)?.nilIfEmpty ?? bucketKey
            let label = bucket["limitName"] as? String
            // primary / secondary 都可能是 null —— OpenAI 现在临时去掉了 5 小时窗口，
            // 以后可能加回来。所以窗口数量和时长一律按返回的走，不认死任何一档。
            for slot in ["primary", "secondary"] {
                guard let window = bucket[slot] as? [String: Any] else { continue }
                limits.append(AgentLimitWindow(
                    key: "\(limitId).\(slot)",
                    label: label,
                    // Codex 只给分钟数，没有粗分组
                    group: nil,
                    windowMinutes: (window["windowDurationMins"] as? NSNumber)?.intValue,
                    usedPercent: (window["usedPercent"] as? NSNumber)?.doubleValue ?? 0,
                    resetsAt: (window["resetsAt"] as? NSNumber)?.int64Value
                ))
            }
        }
        // 字典遍历顺序不稳定，排序后等值的两次采集才比得出「没变」
        limits.sort { $0.key < $1.key }

        let mainBucket = buckets["codex"] ?? buckets.keys.sorted().first.flatMap { buckets[$0] }
        guard let tier = (mainBucket?["planType"] as? String)?.nilIfEmpty else {
            throw TelemetryModuleError.agentLimits("codex 响应里没有套餐类型")
        }
        return AgentPlanSnapshot(
            tier: tier,
            label: agentPlanLabel(agent: "codex", tier: tier),
            limits: limits,
            observedAt: nowMilliseconds
        )
    }

    /// `codex app-server` 走 stdio 上的行分隔 JSON-RPC：initialize → initialized →
    /// account/rateLimits/read，读到 id 2 的响应就收工。
    nonisolated private static func readRateLimits(codexPath: String) throws -> [String: Any] {
        guard FileManager.default.isExecutableFile(atPath: codexPath) else {
            throw TelemetryModuleError.agentLimits("Codex 路径不可执行：\(codexPath)")
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw TelemetryModuleError.agentLimits("起不来 codex app-server：\(error.localizedDescription)")
        }

        // app-server 应答完不会自己退出，拿到结果和超时两条路都必须显式杀掉，
        // 否则每次采集都留一个常驻子进程。
        let box = ProcessBox(process)
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + codexTimeout)
        watchdog.setEventHandler { if box.process.isRunning { box.process.terminate() } }
        watchdog.resume()
        defer {
            watchdog.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"mac-telemetry-hub","title":"Mac Telemetry Hub","version":"2.0.0"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"#,
        ]
        for request in requests {
            try input.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))
        }

        let handle = output.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            // 空读 = 对端关了，要么是超时被杀，要么是 codex 自己提前退了
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (message["id"] as? NSNumber)?.intValue == 2 else { continue }
                if let failure = message["error"] as? [String: Any] {
                    let text = failure["message"] as? String ?? "\(failure)"
                    throw TelemetryModuleError.agentLimits("codex 返回错误：\(text)")
                }
                guard let result = message["result"] as? [String: Any] else {
                    throw TelemetryModuleError.agentLimits("codex 响应缺少 result")
                }
                return result
            }
        }
        throw TelemetryModuleError.agentLimits("codex app-server 超时或提前退出")
    }

    /// Claude 套餐等级不起子进程：它就躺在 ~/.claude.json 里，而且
    /// organizationRateLimitTier 比 `claude auth status` 给的 "max" 更细。
    /// 那个文件读不到时才退到钥匙串凭据里的 subscriptionType。
    nonisolated private static func claudeTier(credentials: ClaudeCredentials?) throws -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let account = root["oauthAccount"] as? [String: Any],
           let tier = (account["organizationRateLimitTier"] as? String)?.nilIfEmpty
            ?? (account["organizationType"] as? String)?.nilIfEmpty {
            return tier
        }
        if let fallback = credentials?.subscriptionType { return fallback }
        throw TelemetryModuleError.agentLimits("读不到 Claude 套餐等级")
    }

    /**
     * Claude Code 的 OAuth 凭据。
     *
     * 严格只读：绝不写回钥匙串，也绝不调刷新接口 —— 刷新会轮换 access token，
     * 可能把用户正在跑的 Claude Code 挤下线。token 也不许进日志和 lastError。
     */
    nonisolated private static func claudeCredentials() -> ClaudeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = (oauth["accessToken"] as? String)?.nilIfEmpty else { return nil }
        return ClaudeCredentials(
            accessToken: token,
            subscriptionType: (oauth["subscriptionType"] as? String)?.nilIfEmpty
        )
    }

    nonisolated private static func claudeLimits(
        credentials: ClaudeCredentials?
    ) async throws -> [AgentLimitWindow] {
        guard let credentials else {
            throw TelemetryModuleError.agentLimits("钥匙串里没有 Claude Code 凭据")
        }
        guard let endpoint = URL(string: claudeUsageEndpoint) else { return [] }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(claudeUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401, 403:
            // 不重试也不刷新，见 claudeCredentials 的说明
            throw TelemetryModuleError.agentLimits("Claude 凭据已失效，请重新登录 Claude Code")
        case 429:
            throw TelemetryModuleError.agentLimits("Claude 用量接口限流，等下一轮再取")
        case let status:
            throw TelemetryModuleError.agentLimits("Claude 用量接口返回 \(status)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TelemetryModuleError.agentLimits("Claude 用量响应不是有效 JSON")
        }
        return parseClaudeLimits(root)
    }

    nonisolated private static func parseClaudeLimits(_ root: [String: Any]) -> [AgentLimitWindow] {
        var windows: [AgentLimitWindow] = []
        for entry in root["limits"] as? [[String: Any]] ?? [] {
            guard let kind = (entry["kind"] as? String)?.nilIfEmpty else { continue }
            let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
            windows.append(AgentLimitWindow(
                key: kind,
                label: (model?["display_name"] as? String)?.nilIfEmpty,
                group: (entry["group"] as? String)?.nilIfEmpty,
                // 这个端点不给窗口时长。别按 group 反填 300 / 10080，那是猜的。
                windowMinutes: nil,
                usedPercent: (entry["percent"] as? NSNumber)?.doubleValue ?? 0,
                resetsAt: unixSeconds(entry["resets_at"] as? String)
            ))
        }

        // 不给 five_hour / seven_day* 那批老字段留回退：它们和 limits 数组是同一份
        // 数据的两种视图，不是互补的两个来源。缺了就当没拿到，空着比拼一份可疑的强。

        // 和 codex 侧同理：排序后等值的两次采集才比得出「没变」
        windows.sort { $0.key < $1.key }
        return windows
    }

    /// resets_at 是带小数秒的 ISO8601（`2026-08-10T03:00:00.673155+00:00`），
    /// 不带 .withFractionalSeconds 的 formatter 会整条解析失败。
    nonisolated private static func unixSeconds(_ value: String?) -> Int64? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        guard let date = fractional.date(from: value) ?? standard.date(from: value) else {
            return nil
        }
        return Int64(date.timeIntervalSince1970)
    }

    nonisolated private static var nowMilliseconds: Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

@MainActor
final class CcusageMonitor: ObservableObject {
    @Published private(set) var payload: JSONValue?
    @Published private(set) var uploadPayload: JSONValue?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastError: String?
    private var refreshing = false
    private var lastPlans: [String: AgentPlanSnapshot] = [:]

    func stop() {
        payload = nil
        uploadPayload = nil
        lastSuccess = nil
        lastError = nil
        lastPlans = [:]
        refreshing = false
    }

    func refreshIfNeeded(
        nodePath: String,
        cliPath: String,
        interval: Double,
        plans: [String: AgentPlanSnapshot]
    ) async {
        guard !refreshing else { return }
        // 套餐变了要立刻重采：plans 是随 ccusage 一起上报的，光等间隔门闩的话
        // 换套餐 / 额度跳档最长会被压 60 秒才发出去。
        if let lastSuccess, Date().timeIntervalSince(lastSuccess) < interval,
           plans == lastPlans { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let collection = try await Task.detached(priority: .utility) {
                try CcusageCollector.collect(nodePath: nodePath, cliPath: cliPath, plans: plans)
            }.value
            payload = collection.localPayload
            uploadPayload = collection.uploadPayload
            lastSuccess = Date()
            lastPlans = plans
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
    nonisolated static func collect(
        nodePath: String,
        cliPath: String,
        plans: [String: AgentPlanSnapshot]
    ) throws -> CcusageCollection {
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
        let uploadData = try JSONSerialization.data(
            withJSONObject: makeUploadSummary(reports, plans: plans)
        )
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

    /// codex 的自动 review 用的是 `codex-auto-review`，ccusage 的价目表里没有它，
    /// 于是折算成兜底定价模型（眼下是 gpt-5.5）并打上 isFallback。两种写法都排掉：
    /// 名字是留给 ccusage 将来如实上报的那天，标记才是眼下真正生效的那条。
    private static func isHiddenModel(_ name: String, _ row: [String: Any]) -> Bool {
        name == "codex-auto-review" || row["isFallback"] as? Bool == true
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
        let ordered = dated.sorted { $0.1 > $1.1 }
        let latest = ordered.first

        // 「当前模型」只看最近的那次会话。自动 review 是独立会话，它用的模型对使用者
        // 没有意义，遇到就继续往前找上一次真正的会话。
        var currentModel: String?
        for (session, _) in ordered {
            var modelTotals: [String: Double] = [:]
            if let models = session["models"] as? [String: [String: Any]] {
                for (name, row) in models where !isHiddenModel(name, row) {
                    modelTotals[name, default: 0] += number(row["totalTokens"])
                }
            } else if let rows = session["modelBreakdowns"] as? [[String: Any]] {
                for row in rows {
                    guard let name = row["modelName"] as? String, !isHiddenModel(name, row) else { continue }
                    modelTotals[name, default: 0] +=
                        number(row["inputTokens"]) + number(row["outputTokens"]) +
                        number(row["cacheReadTokens"]) + number(row["cacheCreationTokens"])
                }
            }
            // 一次会话里主模型和子代理模型会同时出现，取用量大的那个
            if let winner = modelTotals.max(by: { $0.value < $1.value })?.key {
                currentModel = winner
                break
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
            "currentModel": currentModel ?? NSNull(),
            "activity": activity,
        ]
    }

    /// The website only needs display-ready aggregates. Keep ccusage's complete
    /// daily/model output on the Mac and send this bounded summary instead.
    private static func makeUploadSummary(
        _ reports: [String: Any],
        plans: [String: AgentPlanSnapshot]
    ) -> [String: Any] {
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
            // 先按 agent 单独累一份再并进全局：站点上不使用时要显示「这个 agent
            // 历史用得最多的模型」，而全局 topModels 是两个 agent 合并后的排名，
            // 拆不回单个 agent。
            var agentModelTotals: [String: Double] = [:]
            for row in rawDays { addModelUsage(row, to: &agentModelTotals) }
            modelTotals.merge(agentModelTotals, uniquingKeysWith: +)
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

            // 套餐 / 额度必须从这条 [String: Any] 路走。直接把 AgentPlanSnapshot 当
            // Codable 编进 JSONValue 的话，编码器的 .convertToSnakeCase 会把
            // CodingKeys 转成蛇形，站点那边的白名单读不到就静默丢掉。
            let plan = plans[agent]
            let planValue: Any = plan.map { ["tier": $0.tier, "label": $0.label] } ?? NSNull()
            let limitValues: [[String: Any]] = plan?.limits.map { window in
                [
                    "key": window.key,
                    "label": window.label ?? NSNull(),
                    "group": window.group ?? NSNull(),
                    "windowMinutes": window.windowMinutes ?? NSNull(),
                    "usedPercent": window.usedPercent,
                    "resetsAt": window.resetsAt ?? NSNull(),
                ]
            } ?? []

            agents.append([
                "id": agent,
                "label": agent == "claude" ? "Claude Code" : "Codex",
                "models": models,
                "currentModel": summary["currentModel"] ?? NSNull(),
                // 零用量的模型只是出现在 daily 里，不代表用过，不参与排名
                "topModel": agentModelTotals
                    .filter { $0.value > 0 }
                    .max { $0.value < $1.value }?.key ?? NSNull(),
                "lastActivityAt": summary["lastActivity"] ?? NSNull(),
                "activity": summary["activity"] ?? [],
                "today": todayRow,
                "last7Days": last7Days,
                "last30DaysTokens": recentDays.reduce(0.0) { $0 + number($1["totalTokens"]) },
                "plan": planValue,
                "limits": limitValues,
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

    /**
     * 按模型累计 token，喂给「历史主力模型」和全局排行。
     *
     * 和 `summarize` 里取当前模型一样过滤掉隐藏模型：自动 review 是独立会话，
     * 它用的模型对使用者没有意义，fallback 同理。两处口径必须一致 —— 否则会
     * 出现「当前模型」里被滤掉的东西反而排进了历史榜。
     *
     * 只影响「用了哪些模型」这类排名，不影响 token 与费用总计 —— 那些走
     * `normalizeTotals`，是另一条路，隐藏模型烧掉的量仍然照实计入。
     */
    private static func addModelUsage(
        _ row: [String: Any],
        to totals: inout [String: Double]
    ) {
        if let models = row["models"] as? [String: Any] {
            for (name, value) in models {
                guard let detail = value as? [String: Any], !isHiddenModel(name, detail) else { continue }
                let explicit = number(detail["totalTokens"])
                let tokens = explicit > 0 ? explicit :
                    number(detail["inputTokens"]) + number(detail["outputTokens"]) +
                    number(detail["cacheReadTokens"]) + number(detail["cacheCreationTokens"])
                totals[name, default: 0] += tokens
            }
            return
        }
        for detail in row["modelBreakdowns"] as? [[String: Any]] ?? [] {
            guard let name = detail["modelName"] as? String, !isHiddenModel(name, detail) else { continue }
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
    case agentLimits(String)

    var errorDescription: String? {
        switch self {
        case let .appleMusic(message): "Apple Music：\(message)"
        case let .ccusage(message): "ccusage：\(message)"
        case let .agentLimits(message): "套餐额度：\(message)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
