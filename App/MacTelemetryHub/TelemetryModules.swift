import AppKit
import CryptoKit
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
    /// 缩放后 PNG 的内容指纹；协议用它引用图标，`iconData` 只负责首次传输。
    let iconHash: String?
    let iconData: Data?
    let observedAt: Int64
}

struct AppleMusicSnapshot: Codable, Equatable, Sendable {
    let state: String
    let title: String?
    let artist: String?
    let album: String?
    let trackID: String?
    let positionMs: Int
    let durationMs: Int
    /**
     * 单曲循环。
     *
     * Music.app 在循环绕回时**不发** playerInfo 通知（实测跳到距结尾 4 秒，
     * 16 秒观测窗口里绕回那一刻一条都没有），上报器因此不知道进度归零了。
     * 兜底重读已经会掐着曲目结束的点去看（见 `nextPollDelay`），但那也要等上
     * 一秒多；把循环状态告诉网页，它就能按 elapsed % duration 自己绕回开头，
     * 那一秒里进度条不会先钉在 100%。
     */
    let repeatOne: Bool
    let observedAt: Int64
}

/**
 * 并入统一遥测信封的 Apple Music token 增量。
 *
 * 两个 token 分别判变，所以字段都是可选的；developer token 的 expiresAt 和它
 * 同进同出。GET /telemetry 使用同一结构，但会把当前三项完整返回。
 */
struct AppleMusicCredentialsPayload: Encodable, Sendable {
    let musicUserToken: String?
    let developerToken: String?
    let expiresAt: Int?
}

struct TimeZoneSnapshot: Codable, Equatable, Sendable {
    let identifier: String
    let abbreviation: String?
    let secondsFromGMT: Int
    let observedAt: Int64
}

struct TelemetryModulesPayload: Encodable, Sendable {
    let charger: StatusPayload?
    let desktop: DesktopActivitySnapshot?
    let appleMusic: AppleMusicSnapshot?
    let appleMusicCredentials: AppleMusicCredentialsPayload?
    let timezone: TimeZoneSnapshot?
    let vibeCoding: JSONValue?
    let includeDesktop: Bool
    let includeAppleMusic: Bool

    private enum CodingKeys: String, CodingKey {
        case charger, desktop, appleMusic, appleMusicCredentials, timezone, vibeCoding
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(charger, forKey: .charger)
        if includeDesktop { try container.encode(desktop, forKey: .desktop) }
        if includeAppleMusic { try container.encode(appleMusic, forKey: .appleMusic) }
        try container.encodeIfPresent(appleMusicCredentials, forKey: .appleMusicCredentials)
        try container.encodeIfPresent(timezone, forKey: .timezone)
        try container.encodeIfPresent(vibeCoding, forKey: .vibeCoding)
    }
}

struct TelemetryEnvelope: Encodable, Sendable {
    let version = 3
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

    /// 前台应用完全由 `didActivateApplicationNotification` 驱动，没有兜底轮询 ——
    /// 前台是谁这件事不存在「不发通知的变化」，不像音乐的进度还要防着 seek。
    /// Cmd-Tab 途经的应用照样会在这里被采成 snapshot，防抖不在这一层：
    /// 上报侧收到 onChange 后压一个 400ms 的窗口，只有最后停下的那个才发得出去。
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
            iconHash: iconData.map(Self.sha256Hex),
            iconData: iconData,
            observedAt: Self.nowMilliseconds
        )
        onChange?()
    }

    private static var nowMilliseconds: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func pngData(for icon: NSImage?) -> Data? {
        guard let icon else { return nil }
        /**
         * 128pt 在 Retina 上会渲成 256px、约 125KB，而网页那个位置只有 40 CSS px。
         * 站点入口还会再压一道，但没必要先把这么大一坨传上去 —— 换一次前台应用
         * 就是一次上传。64pt（Retina 上 128px）已经比展示所需的 80px 富余。
         */
        let size = NSSize(width: 64, height: 64)
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
final class TimeZoneMonitor: ObservableObject {
    @Published private(set) var snapshot: TimeZoneSnapshot?
    /// 时区或当前偏移变化时通知上报循环
    var onChange: (() -> Void)?

    private var observer: NSObjectProtocol?

    func start() {
        refresh()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        snapshot = nil
    }

    /// 每轮上报前也刷新一次，覆盖夏令时切换这类没有明确系统通知的情况。
    func refresh() {
        let zone = TimeZone.current
        let next = TimeZoneSnapshot(
            identifier: zone.identifier,
            abbreviation: zone.abbreviation(),
            secondsFromGMT: zone.secondsFromGMT(),
            observedAt: Self.nowMilliseconds
        )
        guard snapshot?.identifier != next.identifier ||
            snapshot?.abbreviation != next.abbreviation ||
            snapshot?.secondsFromGMT != next.secondsFromGMT else { return }
        snapshot = next
        onChange?()
    }

    private static var nowMilliseconds: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
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
     * 兜底重读的间隔上限。
     *
     * 不发通知的状态变化有两种：拖动进度条，以及单曲循环绕回开头。前者没有任何
     * 可预测的时刻，只能靠定时重读把进度锚点校回来；后者掐得准，由 `nextPollDelay`
     * 单独排到曲目结束那一刻，所以这个数只是「什么都没发生时最久多久看一次」，
     * 可以给得很松。换歌、播放、暂停都有通知，不靠这条路。
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

    /**
     * 下一次兜底重读等多久。
     *
     * 曲目该放完的那一刻必须立刻去看：接下来要么循环回开头、要么换了下一首，
     * 两种都需要新锚点，而循环那种 Music.app 不发通知（换歌才发）。
     *
     * 之所以不去判断「是不是单曲循环」：那个问题根本答不了。song repeat 只有
     * off/one/all，而 all 到底会不会回到同一首取决于播放队列 —— 实测从资料库
     * 播放时 current playlist 是「音乐」共 730 首，专辑自己有几首完全不相干，
     * AppleScript 又拿不到队列。与其猜，不如到点了直接去看。
     */
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
            set cloudState to ""
            try
                set cloudState to (cloud status of currentSong as text)
            end try
            set repeatMode to "off"
        try
            set repeatMode to (song repeat as text)
        end try
        return {stateText, songName, songArtist, songAlbum, songID, (player position as text), (songDuration as text), cloudState, repeatMode}
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
        /**
         * 只上报 Apple Music 目录里的曲子，本地导入的跳过。
         *
         * 判据用 `cloud status` 而不是 `class`：下载到本机的订阅歌曲 class 也是
         * `file track`（实测），分不出来；cloud status 才区分内容来源。
         *
         * 排除的是 `uploaded` / `not uploaded` —— 那两个就是「你自己的文件」。
         * 其余一律放行，包括读不到这个属性的情况：宁可偶尔多报一首本地歌
         * （后果只是网页那边查不到封面），也不能因为某台机器读不到它就把整个
         * 音乐模块哑掉。
         */
        let cloudStatus = item(8).lowercased()
        if cloudStatus == "uploaded" || cloudStatus == "not uploaded" { return nil }
        let state = rawState == "playing" || rawState == "paused" ? rawState : "stopped"
        return AppleMusicSnapshot(
            state: state,
            title: item(2).nilIfEmpty,
            artist: item(3).nilIfEmpty,
            album: item(4).nilIfEmpty,
            trackID: item(5).nilIfEmpty,
            positionMs: Int((Double(item(6)) ?? 0) * 1_000),
            durationMs: Int((Double(item(7)) ?? 0) * 1_000),
            repeatOne: item(9) == "one",
            observedAt: Int64(Date().timeIntervalSince1970 * 1_000)
        )
    }

}

extension DesktopActivitySnapshot {
    func withIconData(_ iconData: Data?) -> DesktopActivitySnapshot {
        DesktopActivitySnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            iconHash: iconHash,
            iconData: iconData,
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

@MainActor
final class AgentLimitsMonitor: ObservableObject {
    @Published private(set) var plans: [String: AgentPlanSnapshot] = [:]
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastError: String?
    /// 按 agent 分开的限额失败原因，随载荷发给网页 —— 页面要能把「没配」和「取不到」分开
    @Published private(set) var limitErrors: [String: String] = [:]

    private var refreshing = false
    /// 间隔门闩看的是「上次尝试」而不是 lastSuccess：CLI 配错或 Web 临时失败时，
    /// 不能让主循环每一圈都重跑一次 CodexBar。
    private var lastAttempt: Date?

    func stop() {
        plans = [:]
        lastSuccess = nil
        lastError = nil
        limitErrors = [:]
        lastAttempt = nil
        refreshing = false
    }

    func refreshIfNeeded(codexBarPath: String, interval: Double) async {
        guard !refreshing else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < interval { return }
        await refreshNow(codexBarPath: codexBarPath)
    }

    /// Bypasses the interval gate for an explicit user refresh, while preserving
    /// the monitor's single-flight guard.
    func refreshNow(codexBarPath: String) async {
        guard !refreshing else { return }
        refreshing = true
        lastAttempt = Date()
        defer { refreshing = false }

        let outcome = await AgentLimitsCollector.collect(codexBarPath: codexBarPath)

        // 内容没变就留着旧快照。换成时间戳更新的那份会让下游（上传门闩、
        // @Published 订阅者）把每次采集都当成「套餐变了」。
        var fresh = outcome.plans
        // 某一 provider 本轮完全失败时也保留它上次的好值；错误通过
        // limitErrors 单独标记。统一命令的一边失败不能把另一边或旧快照清掉。
        for agent in ["claude", "codex"] where fresh[agent] == nil {
            if outcome.limitErrors[agent] != nil, let previous = plans[agent] {
                fresh[agent] = previous
            }
        }
        for (agent, snapshot) in fresh {
            /**
             * 这一轮没取到限额时，沿用上一次拿到的那几条，不要清空。
             *
             * 清空会让页面上那几根条整个消失 —— 而「取不到」和「没有限额」是
             * 两回事，前者该继续显示上次的值并标明它不是当前值。失败原因走
             * limitErrors 单独送出去，页面据此决定怎么标。
             */
            var merged = snapshot
            if snapshot.limits.isEmpty,
               outcome.limitErrors[agent] != nil,
               let previous = plans[agent], !previous.limits.isEmpty {
                merged = AgentPlanSnapshot(
                    tier: snapshot.tier,
                    label: snapshot.label,
                    limits: previous.limits,
                    observedAt: previous.observedAt
                )
            }
            if let previous = plans[agent], previous.hasSameContent(as: merged) {
                fresh[agent] = previous
            } else {
                fresh[agent] = merged
            }
        }
        plans = fresh
        lastError = outcome.errors.isEmpty ? nil : outcome.errors.joined(separator: "；")
        limitErrors = outcome.limitErrors
        if !fresh.isEmpty { lastSuccess = Date() }
    }
}

private struct AgentLimitsOutcome: Sendable {
    let plans: [String: AgentPlanSnapshot]
    let errors: [String]
    /// 按 agent 分开的限额失败原因，要跟着载荷发给网页 —— 页面得能把
    /// 「这个 agent 没配」和「配了但取不到」分开，两者都是空数组。
    let limitErrors: [String: String]
}

private enum AgentLimitsCollector {
    /// 一条 CodexBar Web 命令同时取 Claude 与 Codex。CLI 的真实 App 内置路径可
    /// 共享 GUI 写入的 Cookie Keychain cache；Homebrew 符号链接会被保存逻辑解析掉。
    nonisolated static func collect(codexBarPath: String) async -> AgentLimitsOutcome {
        await Task.detached(priority: .utility) {
            Self.collectBlocking(codexBarPath: codexBarPath)
        }.value
    }

    nonisolated private static func collectBlocking(codexBarPath: String) -> AgentLimitsOutcome {
        let providers = ["claude", "codex"]
        func failed(_ message: String) -> AgentLimitsOutcome {
            AgentLimitsOutcome(
                plans: [:],
                errors: [message],
                limitErrors: Dictionary(uniqueKeysWithValues: providers.map { ($0, message) })
            )
        }
        guard FileManager.default.isExecutableFile(atPath: codexBarPath) else {
            return failed("CodexBar CLI 路径不可执行：\(codexBarPath)")
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: codexBarPath)
        process.arguments = [
            "usage", "--provider", "both", "--source", "web",
            "--no-credits", "--format", "json",
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return failed("CodexBar usage 启动失败：\(error.localizedDescription)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return failed("CodexBar usage 输出不是有效 JSON")
        }

        var plans: [String: AgentPlanSnapshot] = [:]
        var errors: [String] = []
        var limitErrors: [String: String] = [:]
        for row in rows {
            guard let provider = row["provider"] as? String,
                  providers.contains(provider) else { continue }
            if let failure = row["error"] as? [String: Any] {
                let detail = failure["message"] as? String ?? "未知错误"
                let message = "CodexBar \(provider) Web：\(detail)"
                errors.append(message)
                limitErrors[provider] = message
                continue
            }
            guard let usage = row["usage"] as? [String: Any] else {
                let message = "CodexBar \(provider) Web 响应缺少 usage"
                errors.append(message)
                limitErrors[provider] = message
                continue
            }
            let identity = usage["identity"] as? [String: Any]
            let loginMethod = (identity?["loginMethod"] as? String)?.nilIfEmpty
                ?? (usage["loginMethod"] as? String)?.nilIfEmpty
            let tier = loginMethod ?? provider
            let label = provider == "claude" && tier.hasPrefix("Claude ")
                ? String(tier.dropFirst("Claude ".count))
                : tier
            let windows = parseWebLimits(provider: provider, usage: usage)
            plans[provider] = AgentPlanSnapshot(
                tier: tier,
                label: label,
                limits: windows,
                observedAt: nowMilliseconds
            )
            if windows.isEmpty {
                let message = "CodexBar \(provider) Web 响应里没有限额窗口"
                errors.append(message)
                limitErrors[provider] = message
            }
        }
        for provider in providers where plans[provider] == nil && limitErrors[provider] == nil {
            let suffix = process.terminationStatus == 0
                ? "响应里没有该 provider"
                : "退出码 \(process.terminationStatus)"
            let message = "CodexBar \(provider) Web \(suffix)"
            errors.append(message)
            limitErrors[provider] = message
        }
        return AgentLimitsOutcome(plans: plans, errors: errors, limitErrors: limitErrors)
    }

    nonisolated private static func parseWebLimits(
        provider: String,
        usage: [String: Any]
    ) -> [AgentLimitWindow] {
        var windows: [AgentLimitWindow] = []
        for slot in ["primary", "secondary", "tertiary"] {
            guard let window = usage[slot] as? [String: Any] else { continue }
            windows.append(AgentLimitWindow(
                key: "\(provider).\(slot)",
                label: nil,
                group: nil,
                windowMinutes: (window["windowMinutes"] as? NSNumber)?.intValue,
                usedPercent: (window["usedPercent"] as? NSNumber)?.doubleValue ?? 0,
                resetsAt: unixSeconds(window["resetsAt"] as? String)
            ))
        }
        for extra in usage["extraRateWindows"] as? [[String: Any]] ?? [] {
            guard let window = extra["window"] as? [String: Any] else { continue }
            let key = (extra["id"] as? String)?.nilIfEmpty ?? "\(provider).extra.\(windows.count)"
            windows.append(AgentLimitWindow(
                key: key,
                label: (extra["title"] as? String)?.nilIfEmpty,
                group: nil,
                windowMinutes: (window["windowMinutes"] as? NSNumber)?.intValue,
                usedPercent: (window["usedPercent"] as? NSNumber)?.doubleValue ?? 0,
                resetsAt: unixSeconds(window["resetsAt"] as? String)
            ))
        }
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
final class CodexBarCostMonitor: ObservableObject {
    @Published private(set) var uploadPayload: JSONValue?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastError: String?
    private var refreshing = false
    private var lastPlans: [String: AgentPlanSnapshot] = [:]
    /// 上一次**尝试**采集的时刻。间隔门闩看它而不是 lastSuccess：失败或被判废
    /// 时 lastSuccess 不动，光看它的话 2 秒一圈的主循环会每圈都重跑一次 CodexBar。
    private var lastAttempt: Date?

    func stop() {
        uploadPayload = nil
        lastSuccess = nil
        lastError = nil
        lastPlans = [:]
        lastAttempt = nil
        refreshing = false
    }

    func refreshIfNeeded(
        cliPath: String,
        interval: Double,
        plans: [String: AgentPlanSnapshot],
        limitErrors: [String: String]
    ) async {
        guard !refreshing else { return }
        // 套餐变了要立刻重采：plans 是随本地统计一起上报的，光等间隔门闩的话
        // 换套餐 / 额度跳档最长会被压 60 秒才发出去。
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < interval,
           plans == lastPlans { return }
        _ = await refreshNow(cliPath: cliPath, plans: plans, limitErrors: limitErrors)
    }

    /// Bypasses the interval gate for an explicit user refresh, while preserving
    /// the monitor's single-flight guard.
    @discardableResult
    func refreshNow(
        cliPath: String,
        plans: [String: AgentPlanSnapshot],
        limitErrors: [String: String]
    ) async -> Bool {
        guard !refreshing else { return false }
        refreshing = true
        lastAttempt = Date()
        defer { refreshing = false }
        do {
            let collection = try await Task.detached(priority: .utility) {
                try CodexBarCostCollector.collect(
                    cliPath: cliPath,
                    plans: plans,
                    limitErrors: limitErrors
                )
            }.value
            uploadPayload = collection.uploadPayload
            lastSuccess = Date()
            lastPlans = plans
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

}

private struct CodexBarCostCollection: Sendable {
    let uploadPayload: JSONValue
}

private enum CodexBarCostCollector {
    nonisolated static func collect(
        cliPath: String,
        plans: [String: AgentPlanSnapshot],
        limitErrors: [String: String]
    ) throws -> CodexBarCostCollection {
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            throw TelemetryModuleError.codexBar("CodexBar CLI 路径不可执行：\(cliPath)")
        }

        let commandOutput = try run(cliPath, [
            "cost", "--provider", "both", "--provider-native-only",
            "--days", "365", "--format", "json", "--refresh",
        ])
        guard let rows = try JSONSerialization.jsonObject(with: commandOutput) as? [[String: Any]] else {
            throw TelemetryModuleError.codexBar("cost 输出不是有效 JSON")
        }
        var reports: [String: Any] = [:]
        for raw in rows {
            guard let agent = raw["provider"] as? String,
                  ["claude", "codex"].contains(agent) else { continue }
            var report = normalizeCostReport(raw, provider: agent)
            report["usageSummary"] = summarize(report)
            reports[agent] = report
        }
        guard !reports.isEmpty else {
            throw TelemetryModuleError.codexBar("cost 响应里没有 Claude/Codex 报告")
        }
        let uploadData = try JSONSerialization.data(
            withJSONObject: makeUploadSummary(reports, plans: plans, limitErrors: limitErrors)
        )
        return CodexBarCostCollection(
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
            throw TelemetryModuleError.codexBar("cost 退出码 \(process.terminationStatus)")
        }
        return data
    }

    /// codex 的自动 review 不是用户选择的模型，排除在模型排名之外；它烧掉的
    /// token 仍由 daily/totals 计入总量。
    private static func isHiddenModel(_ name: String, _ row: [String: Any]) -> Bool {
        name == "codex-auto-review" || row["isFallback"] as? Bool == true
    }

    /// CodexBar 的 Codex scanner 把 cached input 包含在 inputTokens 里；Claude scanner
    /// 则与旧前端协议一致、把 cache 分开。这里把 Codex input 调整成非缓存 input，
    /// 避免现有 UI 的 Input + Output + Cache 合计把缓存重复计算一次。
    private static func normalizeCostReport(_ raw: [String: Any], provider: String) -> [String: Any] {
        guard provider == "codex" else { return raw }
        var report = raw
        if var days = report["daily"] as? [[String: Any]] {
            for index in days.indices { days[index] = normalizeCodexTokens(days[index]) }
            report["daily"] = days
        }
        if let totals = report["totals"] as? [String: Any] {
            report["totals"] = normalizeCodexTokens(totals)
        }
        return report
    }

    private static func normalizeCodexTokens(_ row: [String: Any]) -> [String: Any] {
        var normalized = row
        normalized["inputTokens"] = max(
            0,
            number(row["inputTokens"])
                - number(row["cacheReadTokens"])
                - number(row["cacheCreationTokens"])
        )
        return normalized
    }

    private static func summarize(_ report: [String: Any]) -> [String: Any] {
        let days = report["daily"] as? [[String: Any]] ?? []
        let ordered = days.sorted {
            ($0["date"] as? String ?? "") > ($1["date"] as? String ?? "")
        }
        var currentModel: String?
        for day in ordered {
            var modelTotals: [String: Double] = [:]
            if let models = day["models"] as? [String: [String: Any]] {
                for (name, row) in models where !isHiddenModel(name, row) {
                    modelTotals[name, default: 0] += number(row["totalTokens"])
                }
            } else if let rows = day["modelBreakdowns"] as? [[String: Any]] {
                for row in rows {
                    guard let name = row["modelName"] as? String, !isHiddenModel(name, row) else { continue }
                    let components = number(row["inputTokens"]) + number(row["outputTokens"])
                        + number(row["cacheReadTokens"]) + number(row["cacheCreationTokens"])
                    modelTotals[name, default: 0] += max(number(row["totalTokens"]), components)
                }
            }
            if let winner = modelTotals.max(by: { $0.value < $1.value })?.key {
                currentModel = winner
                break
            }
        }

        // 一天一桶。原来是 12 小时，同一天被劈成两半，看曲线时得自己把相邻两根
        // 加起来才对得上「今天用了多少」。桶数不变，跨度从 30 天变成 60 天。
        let bucketMs: Double = 24 * 60 * 60 * 1_000
        let current = floor(Date().timeIntervalSince1970 * 1_000 / bucketMs) * bucketMs
        let start = current - 59 * bucketMs
        var activity = (0..<60).map { ["t": start + Double($0) * bucketMs, "tokens": 0.0] }
        for day in days {
            guard let date = dayDate(day["date"] as? String) else { continue }
            let timestamp = date.timeIntervalSince1970 * 1_000
            let index = Int(floor((timestamp - start) / bucketMs))
            if activity.indices.contains(index) {
                activity[index]["tokens"] = (activity[index]["tokens"] ?? 0) + number(day["totalTokens"])
            }
        }

        return [
            // CodexBar cost JSON 不公开 session 数与精确最后活动时间，因此协议也
            // 不再伪造这两个字段。currentModel 是最近一个有用量日的主力模型。
            "currentModel": currentModel ?? NSNull(),
            "activity": activity,
        ]
    }

    /// The website only needs display-ready aggregates. Keep CodexBar's complete
    /// daily/model output on the Mac and send this bounded summary instead.
    private static func makeUploadSummary(
        _ reports: [String: Any],
        plans: [String: AgentPlanSnapshot],
        limitErrors: [String: String]
    ) -> [String: Any] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start30 = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        var agents: [[String: Any]] = []
        var aggregate = emptyTotals()
        var activeDates = Set<String>()
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
            let todayText = dayString(today)
            let todayRow = preparedDay(recentByDate[todayText] ?? normalizedEmptyDay(date: todayText))
            let summary = report["usageSummary"] as? [String: Any] ?? [:]
            let totals = normalizeTotals(report["totals"] as? [String: Any] ?? [:])
            let models = Set(allDays.flatMap { $0["models"] as? [String] ?? [] }).sorted()

            for row in allDays where number(row["totalTokens"]) > 0 {
                if let date = row["date"] as? String { activeDates.insert(date) }
            }
            addTotals(totals, to: &aggregate)

            // 套餐 / 额度走 [String: Any] 这条路。历史原因是编码器当年开着
            // .convertToSnakeCase，Codable 结构会被转成蛇形、站点白名单读不到；
            // 现在编码器不转了，这条路只是还没回头改成 Codable。
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
                "activity": summary["activity"] ?? [],
                "today": todayRow,
                "last30DaysTokens": recentDays.reduce(0.0) { $0 + number($1["totalTokens"]) },
                "plan": planValue,
                "limits": limitValues,
                // 空 limits 有两种含义：这个 agent 没配，或者配了但取不到。
                // 页面得能分开 —— 前者该整块不渲染，后者该渲染并说明取不到。
                "limitsError": limitErrors[agent] ?? NSNull(),
            ])
        }

        aggregate["activeDays"] = Double(activeDates.count)
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
            let components = number(detail["inputTokens"]) + number(detail["outputTokens"])
                + number(detail["cacheReadTokens"]) + number(detail["cacheCreationTokens"])
            totals[name, default: 0] += max(number(detail["totalTokens"]), components)
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
    case codexBar(String)
    case agentLimits(String)

    var errorDescription: String? {
        switch self {
        case let .appleMusic(message): "Apple Music：\(message)"
        case let .codexBar(message): "CodexBar：\(message)"
        case let .agentLimits(message): "套餐额度：\(message)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
