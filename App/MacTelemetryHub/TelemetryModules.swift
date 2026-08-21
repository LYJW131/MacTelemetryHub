import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import Security

enum JSONValue: Codable, Equatable, Sendable {
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

/**
 * TokenTracker 本机面板的接口。
 *
 * 用量、限额、会话三份都从这里取。从前是 CodexBar CLI 两条命令加 ccusage 两条、
 * 一共四次进程；现在是同一个本机 HTTP 服务的几个 GET，快了两个数量级。代价是
 * 它得开着 —— 面板没跑的时候三份各自留下自己的错误，互不牵连。
 *
 * 走的是它面板 SPA 用的那套 `functions` 接口，不是它文档里承诺的 CLI：形状
 * 随版本变的风险更大，坏掉的表现是某一块数据变空而不是报错。
 */
private enum TokenTrackerAPI {
    /// 它按时区切「天」，不给就按 UTC 切 —— 东八区会把今天错开八小时
    private static let timeZone = TimeZone.current.identifier

    nonisolated static func get(
        baseURL: String,
        function: String,
        query: [String: String] = [:]
    ) async throws -> Any {
        guard var components = URLComponents(string: "\(baseURL)/functions/\(function)") else {
            throw TelemetryModuleError.tokenTracker("地址不合法：\(baseURL)")
        }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "tz", value: timeZone)]
        guard let url = components.url else {
            throw TelemetryModuleError.tokenTracker("地址不合法：\(baseURL)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw TelemetryModuleError.tokenTracker("\(function)：HTTP \(code)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw TelemetryModuleError.tokenTracker("\(function)：输出不是有效 JSON")
        }
        return json
    }

    /// `total_cost_usd` 在按天那份里是数字、按来源那份里是字符串，两种都要收
    nonisolated static func number(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) ?? 0 }
        return 0
    }

    /// 重置时刻：Codex 给 epoch 秒，其余几家给 ISO8601（带小数秒）
    nonisolated static func unixSeconds(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber, number.doubleValue > 0 {
            return Int64(number.doubleValue)
        }
        guard let text = (value as? String)?.nilIfEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        guard let date = fractional.date(from: text) ?? standard.date(from: text) else { return nil }
        return Int64(date.timeIntervalSince1970)
    }
}

/**
 * 信封里五个来源同一形状。站点按 id 决定展示形态：`claude` / `grok` 画全量面板，
 * 其余只取限额那一行。加一个来源只动这个数组。
 *
 * `icon` 是牌子，不是 TokenTracker 的来源键：id 是上游那份数据里的名字，
 * 这个是站点图标注册表的键，认不出来的退回首字母。
 */
private struct VibeCodingAgentSpec: Equatable, Sendable {
    let id: String
    let label: String
    let icon: String
}

private let vibeCodingAgents: [VibeCodingAgentSpec] = [
    .init(id: "claude", label: "Claude Code", icon: "anthropic"),
    .init(id: "codex", label: "Codex", icon: "openai"),
    .init(id: "cursor", label: "Cursor", icon: "cursor"),
    .init(id: "grok", label: "Grok Build", icon: "grok"),
    .init(id: "antigravity", label: "Antigravity", icon: "antigravity"),
]

private let vibeCodingAgentIDs = vibeCodingAgents.map(\.id)

struct CodingSessionSnapshot: Codable, Equatable, Sendable {
    let currentModel: String?
    let lastActivityAt: String?
    let active: Bool
    let sessionCount: Int
}

@MainActor
final class CodingSessionMonitor: ObservableObject {
    @Published private(set) var snapshots: [String: CodingSessionSnapshot] = [:]
    /// 所有来源的会话总数，和头部那一栏是同一个口径
    @Published private(set) var sessionCount = 0
    /// `vibeCodingNow` 模块的载荷。刻意不带采集时刻：内容没变就不该重发，
    /// 而 60 秒一轮的扫描里绝大多数轮次什么都没变。
    @Published private(set) var uploadPayload: JSONValue?
    /// 载荷**真正变化**的时刻，上报侧的判变门闩看它而不是 lastSuccess ——
    /// 后者每次成功采集都会动，拿它当门闩会把「扫过一遍、什么都没变」也算成新数据。
    @Published private(set) var payloadUpdatedAt: Date?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastError: String?
    /// 载荷变化时叫醒上报循环。采集不再挂在那条循环上，所以得跟前台应用、
    /// 音乐一样自己回头敲一下门。
    var onChange: (() -> Void)?
    private var refreshing = false
    private var lastAttempt: Date?

    func stop() {
        snapshots = [:]
        sessionCount = 0
        uploadPayload = nil
        payloadUpdatedAt = nil
        lastSuccess = nil
        lastError = nil
        refreshing = false
        lastAttempt = nil
    }

    func refreshIfNeeded(baseURL: String, interval: Double) async {
        guard !refreshing else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < interval { return }
        await refreshNow(baseURL: baseURL)
    }

    func refreshNow(baseURL: String) async {
        guard !refreshing else { return }
        refreshing = true
        lastAttempt = Date()
        defer { refreshing = false }

        let outcome = await CodingSessionCollector.collect(baseURL: baseURL)
        var fresh = outcome.snapshots
        for agent in vibeCodingAgentIDs where fresh[agent] == nil {
            if let previous = snapshots[agent] { fresh[agent] = previous }
        }
        snapshots = fresh
        // 整轮失败时会话总数留着上一次的，理由同上面那几份快照
        if outcome.sessionCount > 0 { sessionCount = outcome.sessionCount }
        let payload = fresh.isEmpty ? nil : Self.makeUploadPayload(fresh)
        if uploadPayload != payload {
            uploadPayload = payload
            payloadUpdatedAt = Date()
            onChange?()
        }
        lastError = outcome.errors.isEmpty ? nil : outcome.errors.joined(separator: "；")
        if !fresh.isEmpty { lastSuccess = Date() }
    }

    /**
     * 站点按 `id` 把这几个字段并回用量模块的 agent 上，所以除了 id 只发状态本身。
     *
     * 会话总数不在这里：它是「一共开过多少次」，一个累计量，跟 token 和费用一起
     * 走十几分钟那份（见 VibeCodingUsagePayload.withSessionCount）。放这里的话，它一涨就得
     * 发一封 60 秒那轮的信 —— 而这条路是为「此刻」留的。
     */
    private static func makeUploadPayload(
        _ snapshots: [String: CodingSessionSnapshot]
    ) -> JSONValue {
        let agents = vibeCodingAgentIDs.compactMap { id -> JSONValue? in
            guard let snapshot = snapshots[id] else { return nil }
            return .object([
                "id": .string(id),
                "currentModel": snapshot.currentModel.map(JSONValue.string) ?? .null,
                "lastActivityAt": snapshot.lastActivityAt.map(JSONValue.string) ?? .null,
                "active": .bool(snapshot.active),
            ])
        }
        return .object(["agents": .array(agents)])
    }
}

private struct CodingSessionOutcome: Sendable {
    let snapshots: [String: CodingSessionSnapshot]
    /// 所有来源的会话总数。跟头部那一栏的口径一致 —— 它数的是「一共开过多少次」，
    /// 不是下面两块面板各自的那部分。Grok 也在里面，Cursor 没有会话记录。
    let sessionCount: Int
    let errors: [String]
}

private enum CodingSessionCollector {
    /// 和页面「正在使用」的窗口保持一致。60 秒扫描一次，五分钟内有会话活动就点亮。
    private static let activeWindow: TimeInterval = 5 * 60
    private static let agents = vibeCodingAgentIDs

    /**
     * 会话状态：此刻在用哪个模型、活没活着、历史会话数。
     *
     * 用不带 `refresh` 的那一版 —— 强制重扫要十秒多，而这条循环是 60 秒一轮。
     * 不强制也拿得到刚结束的会话，它自己按文件改动增量更新。
     *
     * 响应里带着项目路径和可续接的 session id，这里一个都不往外发：只留下
     * 模型名、最后活动时刻和条数。
     */
    nonisolated static func collect(baseURL: String) async -> CodingSessionOutcome {
        do {
            let root = try await TokenTrackerAPI.get(
                baseURL: baseURL,
                function: "tokentracker-sessions",
                query: ["limit": "0"]
            )
            guard let object = root as? [String: Any],
                  let rows = object["sessions"] as? [[String: Any]]
            else {
                throw TelemetryModuleError.tokenTracker("sessions 响应缺少 sessions")
            }
            let now = Date()
            var snapshots: [String: CodingSessionSnapshot] = [:]
            for agent in agents {
                let mine = rows.filter { ($0["source"] as? String) == agent }
                let ordered = mine.sorted {
                    (endedAt($0) ?? .distantPast) > (endedAt($1) ?? .distantPast)
                }
                let latest = ordered.first
                let age = latest.flatMap(endedAt).map { now.timeIntervalSince($0) }
                // 最新那条可能是自动 review，它用的模型不是使用者选的；模型向下找，
                // 但活动时间仍严格取最新那条，不能把旧会话说成正在使用。
                let model = ordered.lazy.compactMap(currentModel).first
                snapshots[agent] = CodingSessionSnapshot(
                    currentModel: model,
                    lastActivityAt: latest?["ended_at"] as? String,
                    active: age.map { $0 >= 0 && $0 <= activeWindow } ?? false,
                    sessionCount: mine.count
                )
            }
            return CodingSessionOutcome(
                snapshots: snapshots,
                sessionCount: rows.count,
                errors: []
            )
        } catch {
            return CodingSessionOutcome(
                snapshots: [:],
                sessionCount: 0,
                errors: ["TokenTracker 会话：\(error.localizedDescription)"]
            )
        }
    }

    nonisolated private static func currentModel(_ session: [String: Any]) -> String? {
        guard let name = (session["model"] as? String)?.nilIfEmpty, !isHiddenModel(name) else {
            return nil
        }
        return name
    }

    /// 自动 review 是独立会话，它用的模型对使用者没有意义；模型没记下来的记成 unknown
    nonisolated private static func isHiddenModel(_ name: String) -> Bool {
        name == "codex-auto-review" || name == "unknown"
    }

    nonisolated private static func endedAt(_ session: [String: Any]) -> Date? {
        guard let value = (session["ended_at"] as? String)?.nilIfEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct DesktopActivitySnapshot: Codable, Equatable, Sendable {
    let applicationName: String
    let bundleIdentifier: String?
    /**
     * 这个应用的图标身份，取自**源图标**而不是编码产物。
     *
     * 关键在于：应用有图标它就非空，哪怕缩放/编码失败、哪怕还没传上 R2。
     * 从前它取自编码后的字节，于是「这个应用没有图标」和「图标没准备好」在
     * 协议上长得一模一样，站点把后者也当成一切正常，补传信号永远发不出来 ——
     * 实测因此整批图标静默消失，且不报错、不重试。
     */
    let iconHash: String?
    /// 待上传的编码产物。只在本机流转，发出去之前一定被置空。
    let iconData: Data?
    /// 直传 R2 成功后的对象键（`<sha256>.png`），是那份字节的内容地址。
    let iconObjectKey: String?
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
    /// Playing Next。来源不是公开 API，字段本身带 `beta: true`。
    let queue: AppleMusicQueueSnapshot?
}

/**
 * 并入统一遥测信封的 Apple Music token 增量。
 *
 * 两个 token 分别判变，所以字段都是可选的；developer token 的 expiresAt 和它
 * 同进同出。远端信封只带变化的字段；本机不再另开遥测 HTTP。
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
    let chargingDevices: ChargingDevicesPayload?
    let desktop: DesktopActivitySnapshot?
    let appleMusic: AppleMusicSnapshot?
    let appleMusicCredentials: AppleMusicCredentialsPayload?
    let timezone: TimeZoneSnapshot?
    /**
     * Vibe coding 两个模块，按**多久变一次**分。
     *
     * - `vibeCodingNow`：此刻在不在用、用的是哪个模型。60 秒一轮，站点收到就推
     *   给浏览器。
     * - `vibeCodingUsage`：token、费用、套餐、限额、会话总数 —— 全是累计
     *   事实，十几分钟才动一次，站点只拿它刷缓存。
     *
     * 从前是三个：用量、限额、会话状态各一个，一个采集器一个。那条线是按「哪条
     * 命令产出的」划的 —— 当年限额和用量分别来自 CodexBar 的两条命令，其中那条
     * 十几秒的扫描一失败，同一轮刚取到的限额也跟着发不出去。如今都来自
     * TokenTracker 同一个本机服务、跟着同两个间隔转，那道线就只剩历史了，采集器
     * 也跟着并成两个：一个模块一个采集器一个间隔。
     *
     * 唯一的例外是会话总数：数出它的是短间隔那个采集器，但它是累计量，归这份
     * 发 —— 发信封那一刻才补进去，见 VibeCodingUsagePayload.withSessionCount。
     *
     * - `vibeCodingYear`：过去 53 周的日合计 token，外加每天前五的模型拆分，给
     *   站点画热力图。整年一次发，间隔单独控，不跟用量那 10 分钟绑在一起。
     */
    let vibeCodingUsage: JSONValue?
    let vibeCodingNow: JSONValue?
    let vibeCodingYear: JSONValue?
    let includeDesktop: Bool
    let includeAppleMusic: Bool

    private enum CodingKeys: String, CodingKey {
        case chargingDevices, desktop, appleMusic, appleMusicCredentials, timezone
        case vibeCodingUsage, vibeCodingNow, vibeCodingYear
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(chargingDevices, forKey: .chargingDevices)
        if includeDesktop { try container.encode(desktop, forKey: .desktop) }
        if includeAppleMusic { try container.encode(appleMusic, forKey: .appleMusic) }
        try container.encodeIfPresent(appleMusicCredentials, forKey: .appleMusicCredentials)
        try container.encodeIfPresent(timezone, forKey: .timezone)
        try container.encodeIfPresent(vibeCodingUsage, forKey: .vibeCodingUsage)
        try container.encodeIfPresent(vibeCodingNow, forKey: .vibeCodingNow)
        try container.encodeIfPresent(vibeCodingYear, forKey: .vibeCodingYear)
    }
}

/**
 * 发往站点的唯一信封。
 *
 * v4 把从前那个独立的 presence 端点并了进来：`modules` 里一个模块都没有的信封
 * 就是一次纯心跳，靠 `presence` 和 `heartbeatAt` 起作用。从前心跳走另一个 URL、
 * 另一套请求组装，「这台 Mac 还活着」这件事在两边各写了一遍。
 */
struct TelemetryEnvelope: Encodable, Sendable {
    let version = 4
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
    /// 只供本机 UI 展示。它不属于 DesktopActivitySnapshot，因此任何遥测或本地
    /// JSON 端点都无法把窗口标题编码出去。
    @Published private(set) var windowTitle: String?
    @Published private(set) var windowTitleAccessGranted = AXIsProcessTrusted()
    /// snapshot 变化时通知上报循环，让它别干等到下一个周期
    var onChange: (() -> Void)?
    private var observer: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?
    private var accessibilityObserver: AXObserver?
    private var accessibilityObserverIdentity: UInt?
    private var observedApplicationElement: AXUIElement?
    private var observedWindowElement: AXUIElement?
    private var observedApplicationPID: pid_t?
    private var windowTitleApplicationWhitelist = BundleIdentifierList(rawValue: "")
    private static let fallbackPollInterval = Duration.seconds(5)
    /// 一个应用的图标：身份指纹 + 待上传的 PNG（编码失败时 png 为 nil）
    struct IconEntry {
        let identity: String
        let png: Data?
    }
    private var iconCache: [String: IconEntry] = [:]

    /**
     * 前台应用以 `didActivateApplicationNotification` 为主，再加一条兜底轮询。
     *
     * 激活通知在绝大多数切换里都会来，但全屏 Space、某些 Electron 应用、
     * 隐藏窗口把前台让出去这类路径上会漏。漏了就一直显示上一个应用，直到
     * 下一次「会发通知」的切换 —— 这就是「有时候名字不跟着变」的来源。
     * 轮询读 `frontmostApplication`：那是稳态下的真相，只有通知刚到那一瞬
     * 才不能信它（所以通知回调仍然用 userInfo 里那份）。
     *
     * Cmd-Tab 途经的应用照样会在这里被采成 snapshot，防抖不在这一层：
     * 上报侧收到 onChange 后压一个 400ms 的窗口，只有最后停下的那个才发得出去。
     */
    func start() {
        capture()
        startFallbackPoll()
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
        pollTask?.cancel()
        pollTask = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        detachAccessibilityObserver()
        snapshot = nil
        windowTitle = nil
    }

    func setWindowTitleApplicationWhitelist(_ whitelist: BundleIdentifierList) {
        guard windowTitleApplicationWhitelist != whitelist else { return }
        windowTitleApplicationWhitelist = whitelist
        // 尚未 start 时留给 start() 的首次 capture；运行中则立刻停止旧观察或启用新观察。
        if observer != nil || pollTask != nil { capture() }
    }

    /// 权限提示只允许由设置页上的明确操作触发；后台启动和轮询都只做无副作用检查。
    func requestWindowTitleAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        windowTitleAccessGranted = AXIsProcessTrustedWithOptions(options)
        if windowTitleAccessGranted { capture() }
    }

    func openWindowTitlePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func startFallbackPoll() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.fallbackPollInterval)
                guard !Task.isCancelled else { return }
                self?.capture()
            }
        }
    }

    /// 传 nil 表示「自己去问当前前台是谁」：启动时的第一次采集，以及兜底轮询。
    func capture(_ activated: NSRunningApplication? = nil) {
        guard let app = activated ?? NSWorkspace.shared.frontmostApplication else { return }
        updateWindowTitleMonitoring(for: app)
        let iconKey = app.bundleIdentifier ?? app.bundleURL?.path ?? app.localizedName ?? "unknown"
        let previous = snapshot

        /*
         * 身份和字节一起缓存。
         *
         * 身份取自源图标的 TIFF，那玩意儿动辄上兆，每次 Cmd-Tab 都算一遍 SHA-256
         * 纯属浪费；一个应用一进程只算一次就够。跨进程重启后 TIFF 字节未必逐位
         * 相同，那样最多多传一次 —— 对象是内容寻址的，落到 R2 还是同一个键。
         */
        let entry: IconEntry?
        if let cached = iconCache[iconKey] {
            entry = cached
        } else if let icon = app.icon {
            entry = IconEntry(identity: Self.sha256Hex(icon.tiffRepresentation ?? Data()),
                              png: Self.pngData(for: icon))
            iconCache[iconKey] = entry
        } else {
            // 应用真的没有图标。这才是 iconHash 允许为空的唯一情形。
            entry = nil
        }

        let next = DesktopActivitySnapshot(
            applicationName: app.localizedName ?? "Unknown",
            bundleIdentifier: app.bundleIdentifier,
            iconHash: entry?.identity,
            iconData: entry?.png,
            iconObjectKey: nil,
            observedAt: Self.nowMilliseconds
        )
        let identityChanged =
            previous?.applicationName != next.applicationName ||
            previous?.bundleIdentifier != next.bundleIdentifier ||
            previous?.iconHash != next.iconHash
        guard identityChanged else { return }
        snapshot = next
        onChange?()
    }

    private func updateWindowTitleMonitoring(for app: NSRunningApplication) {
        guard windowTitleApplicationWhitelist.contains(bundleIdentifier: app.bundleIdentifier) else {
            detachAccessibilityObserver()
            if windowTitle != nil { windowTitle = nil }
            return
        }
        refreshWindowTitle(for: app)
        attachAccessibilityObserver(to: app)
    }

    private func refreshWindowTitle(for app: NSRunningApplication) {
        guard windowTitleApplicationWhitelist.contains(bundleIdentifier: app.bundleIdentifier) else {
            if windowTitle != nil { windowTitle = nil }
            return
        }
        let granted = AXIsProcessTrusted()
        if windowTitleAccessGranted != granted { windowTitleAccessGranted = granted }
        guard granted else {
            if windowTitle != nil { windowTitle = nil }
            return
        }

        let next = Self.normalizedWindowTitle(Self.windowTitle(forPID: app.processIdentifier))
        if windowTitle != next { windowTitle = next }
    }

    private func attachAccessibilityObserver(to app: NSRunningApplication) {
        guard windowTitleApplicationWhitelist.contains(bundleIdentifier: app.bundleIdentifier),
              windowTitleAccessGranted else {
            detachAccessibilityObserver()
            return
        }
        guard observedApplicationPID != app.processIdentifier || accessibilityObserver == nil else {
            return
        }

        detachAccessibilityObserver()
        var observer: AXObserver?
        guard AXObserverCreate(
            app.processIdentifier,
            Self.accessibilityNotificationCallback,
            &observer
        ) == .success, let observer else { return }

        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(
            observer,
            applicationElement,
            kAXFocusedWindowChangedNotification as CFString,
            context
        ) == .success else { return }

        accessibilityObserver = observer
        accessibilityObserverIdentity = Self.identity(of: observer)
        observedApplicationElement = applicationElement
        observedApplicationPID = app.processIdentifier
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        refreshObservedWindow()
    }

    private func refreshObservedWindow() {
        guard let observer = accessibilityObserver,
              let applicationElement = observedApplicationElement else { return }

        if let oldWindow = observedWindowElement {
            AXObserverRemoveNotification(
                observer,
                oldWindow,
                kAXTitleChangedNotification as CFString
            )
            observedWindowElement = nil
        }

        guard let window = Self.windowElement(for: applicationElement) else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(
            observer,
            window,
            kAXTitleChangedNotification as CFString,
            context
        ) == .success else { return }
        observedWindowElement = window
    }

    private func detachAccessibilityObserver() {
        guard let observer = accessibilityObserver else {
            accessibilityObserverIdentity = nil
            observedApplicationElement = nil
            observedWindowElement = nil
            observedApplicationPID = nil
            return
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        accessibilityObserver = nil
        accessibilityObserverIdentity = nil
        observedApplicationElement = nil
        observedWindowElement = nil
        observedApplicationPID = nil
    }

    private static func windowElement(for applicationElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        if focusedResult != .success {
            value = nil
            guard AXUIElementCopyAttributeValue(
                applicationElement,
                kAXMainWindowAttribute as CFString,
                &value
            ) == .success else { return nil }
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func windowTitle(forPID processID: pid_t) -> String? {
        let applicationElement = AXUIElementCreateApplication(processID)
        guard let window = windowElement(for: applicationElement) else { return nil }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success else { return nil }
        return titleValue as? String
    }

    private static func normalizedWindowTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(240))
    }

    private static func identity(of observer: AXObserver) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(observer).toOpaque())
    }

    private static let accessibilityNotificationCallback: AXObserverCallback = {
        observer, _, notification, context in
        guard let context else { return }
        let monitor = Unmanaged<DesktopActivityMonitor>.fromOpaque(context).takeUnretainedValue()
        let observerIdentity = identity(of: observer)
        let focusedWindowChanged = notification as String == kAXFocusedWindowChangedNotification

        Task { @MainActor in
            guard monitor.accessibilityObserverIdentity == observerIdentity else { return }
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            guard monitor.windowTitleApplicationWhitelist.contains(
                bundleIdentifier: app.bundleIdentifier
            ) else {
                monitor.detachAccessibilityObserver()
                if monitor.windowTitle != nil { monitor.windowTitle = nil }
                return
            }
            if focusedWindowChanged { monitor.refreshObservedWindow() }
            monitor.refreshWindowTitle(for: app)
        }
    }

    private static var nowMilliseconds: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /**
     * 图标编码。用系统原生的 PNG 写出，不依赖任何外部二进制。
     *
     * 从前这里 fork 出 Homebrew 的 cwebp：签名 app 里那个子进程起不来，返回 nil，
     * 而 nil 一路被下游当成「这个应用没图标」，于是整批图标静默消失。图标是
     * 大片纯色加硬边缘的小图，PNG 无损、96px 也就十几 KB，没必要为它引一个
     * 装不装全看运气的外部依赖。
     *
     * 网页只显示 40 CSS px，96px 覆盖 Retina 所需的 80px 还有余量。
     */
    private static func pngData(for icon: NSImage) -> Data? {
        /*
         * 画进一个显式的 96×96 位图，而不是 NSImage(size:) + lockFocus。
         *
         * 后者的后备存储跟着屏幕缩放走：Retina 上会悄悄画成 192×192，出来的 PNG
         * 有 96KB，而网页上那个位置只有 40 CSS px。显式指定像素数就与屏幕无关，
         * 换台机器采出来的字节也一致（内容寻址，字节一致才不会白白多出一个对象）。
         */
        let pixels = 96
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = NSSize(width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        context.flushGraphics()

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
     * 之所以不去判断「是不是单曲循环」：song repeat 只有 off/one/all，而 all
     * 会不会回到同一首取决于 Playing Next。那份队列现在能从 Queue.dat 读到
     * （beta），但循环绕回仍然不发通知，到点了直接去看更省事。
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
                observedAt: Int64(Date().timeIntervalSince1970 * 1_000),
                queue: nil
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
        let title = item(2).nilIfEmpty
        let trackID = item(5).nilIfEmpty
        let queue = state == "stopped" ? nil : MusicPlayingQueue.read(
            currentTrackID: trackID,
            currentTitle: title
        )
        return AppleMusicSnapshot(
            state: state,
            title: title,
            artist: item(3).nilIfEmpty,
            album: item(4).nilIfEmpty,
            trackID: trackID,
            positionMs: Int((Double(item(6)) ?? 0) * 1_000),
            durationMs: Int((Double(item(7)) ?? 0) * 1_000),
            repeatOne: item(9) == "one",
            observedAt: Int64(Date().timeIntervalSince1970 * 1_000),
            queue: queue
        )
    }

}

extension DesktopActivitySnapshot {
    /// 黑名单命中时发送的虚拟应用身份。站点像处理 Codex / Claude 一样按 Bundle ID
    /// 替换名称和图标；载荷里不保留真实应用的任何身份或图标信息。
    static let hiddenBundleIdentifier = "com.liangyangjunwei.MacTelemetryHub.hidden"

    static func hidden(observedAt: Int64) -> DesktopActivitySnapshot {
        DesktopActivitySnapshot(
            applicationName: "Hidden Application",
            bundleIdentifier: hiddenBundleIdentifier,
            iconHash: nil,
            iconData: nil,
            iconObjectKey: nil,
            observedAt: observedAt
        )
    }

    func withIconData(_ iconData: Data?, iconObjectKey: String? = nil) -> DesktopActivitySnapshot {
        DesktopActivitySnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            iconHash: iconHash,
            iconData: iconData,
            iconObjectKey: iconObjectKey,
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
    /// 后端原始值，如 "prolite" / "Max"。上游不报套餐时为 nil，页面上那一格不渲染
    let tier: String?
    /// 展示名，如 "Pro Lite"。tier 为 nil 时同样为 nil
    let label: String?
    let limits: [AgentLimitWindow]
}

/// Providers report raw plan enums ("prolite"). Preserve the display labels used
/// before the collector migrations so changing sources does not leak enum IDs into
/// the website.
func agentPlanLabel(agent: String, tier: String) -> String {
    switch agent {
    case "codex":
        switch tier.lowercased() {
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
        if tier.hasPrefix("Claude ") {
            return String(tier.dropFirst("Claude ".count))
        }
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

private struct AgentLimitsOutcome: Sendable {
    let plans: [String: AgentPlanSnapshot]
    let errors: [String]
    /// 按 agent 分开的限额失败原因，要跟着载荷发给网页 —— 页面得能把
    /// 「这个 agent 没配」和「配了但取不到」分开，两者都是空数组。
    let limitErrors: [String: String]
}

private enum AgentLimitsCollector {
    /**
     * 套餐与限额窗口，一次请求全拿到。
     *
     * TokenTracker 的 `usage-limits` 一次给十三家，信封里那五个来源都在里面 ——
     * 从前是四条 CodexBar 命令并发跑，任意一条挂掉都要单独兜底。
     * 现在整条挂了就是整条挂了，每家各自留下自己的 error。
     *
     * 每家还带 `configured`：没配就是没配，不算失败 —— 页面据此整块不渲染，
     * 和「配了但取不到」分得开。
     */
    nonisolated static func collect(baseURL: String) async -> AgentLimitsOutcome {
        let root: [String: Any]
        do {
            guard let object = try await TokenTrackerAPI.get(
                baseURL: baseURL,
                function: "tokentracker-usage-limits"
            ) as? [String: Any] else {
                throw TelemetryModuleError.tokenTracker("usage-limits 输出不是对象")
            }
            root = object
        } catch {
            let message = error.localizedDescription
            return AgentLimitsOutcome(
                plans: [:],
                errors: [message],
                limitErrors: Dictionary(
                    uniqueKeysWithValues: vibeCodingAgentIDs.map { ($0, message) }
                )
            )
        }

        var plans: [String: AgentPlanSnapshot] = [:]
        var errors: [String] = []
        var limitErrors: [String: String] = [:]

        for provider in vibeCodingAgentIDs {
            guard let node = root[provider] as? [String: Any] else { continue }
            if let failure = (node["error"] as? String)?.nilIfEmpty {
                let message = "TokenTracker \(provider)：\(failure)"
                errors.append(message)
                limitErrors[provider] = message
                continue
            }
            // 没配的那几家直接跳过：不是失败，页面上整块不渲染
            guard node["configured"] as? Bool ?? false else { continue }

            let windows: [AgentLimitWindow]
            switch provider {
            case "claude": windows = claudeWindows(node)
            case "codex": windows = codexWindows(node)
            default: windows = genericWindows(provider: provider, node: node)
            }
            let tier = planTier(provider: provider, node: node)
            plans[provider] = AgentPlanSnapshot(
                tier: tier,
                label: tier.map { agentPlanLabel(agent: provider, tier: $0) },
                limits: windows
            )
            if windows.isEmpty {
                let message = "TokenTracker \(provider) 响应里没有限额窗口"
                errors.append(message)
                limitErrors[provider] = message
            }
        }
        return AgentLimitsOutcome(plans: plans, errors: errors, limitErrors: limitErrors)
    }

    /**
     * Claude 的窗口按名字给，不给时长。
     *
     * `five_hour` / `seven_day` 这两个名字本身就是时长声明，站点那边要拿分钟数
     * 算窗口名（「5-hour limit」「Weekly」），所以在这里翻译成 300 / 10080。
     * 这不是「由分组反推时长」那种猜测 —— 字段名说的就是五小时和七天。
     */
    nonisolated private static func claudeWindows(_ node: [String: Any]) -> [AgentLimitWindow] {
        var windows: [AgentLimitWindow] = []
        if let five = node["five_hour"] as? [String: Any] {
            windows.append(window(key: "claude.primary", label: nil, minutes: 300, node: five))
        }
        let weekly = node["seven_day"] as? [String: Any]
        if let weekly {
            windows.append(window(key: "weekly_all", label: nil, minutes: 10_080, node: weekly))
        }
        // 作用域周额度（Fable / Opus）不带自己的重置时刻，它跟总的周窗口同时翻篇。
        // 从前 CodexBar 那版也是拿总周窗口的时刻补上的，页面上那行的倒计时靠它。
        let weeklyReset = weekly.flatMap { TokenTrackerAPI.unixSeconds(resetValue($0)) }
        if let opus = node["seven_day_opus"] as? [String: Any] {
            windows.append(window(
                key: "claude-weekly-scoped-opus",
                label: "Opus only",
                minutes: 10_080,
                node: opus,
                fallbackReset: weeklyReset
            ))
        }
        for scoped in node["weekly_scoped"] as? [[String: Any]] ?? [] {
            guard let name = (scoped["label"] as? String)?.nilIfEmpty else { continue }
            windows.append(window(
                key: "claude-weekly-scoped-\(name.lowercased())",
                label: "\(name) only",
                minutes: 10_080,
                node: scoped,
                fallbackReset: weeklyReset
            ))
        }
        return windows
    }

    /// Codex 反过来：窗口自带 `limit_window_seconds`，名字里没有时长。
    /// Spark 是和主额度并列的独立配额，不是它的子集，所以各占一行。
    nonisolated private static func codexWindows(_ node: [String: Any]) -> [AgentLimitWindow] {
        let slots: [(key: String, label: String?, field: String)] = [
            ("codex.primary", nil, "primary_window"),
            ("codex.secondary", nil, "secondary_window"),
            ("codex-spark-session", "Codex Spark 5h", "spark_primary_window"),
            ("codex-spark-weekly", "Codex Spark Weekly", "spark_secondary_window"),
        ]
        return slots.compactMap { slot in
            guard let value = node[slot.field] as? [String: Any] else { return nil }
            return window(key: slot.key, label: slot.label, minutes: minutes(value), node: value)
        }
    }

    /**
     * 其余几家的窗口都在 primary / secondary / tertiary / quaternary 槽里。
     *
     * 全部送出去，不在这里按展示形态挑一条 —— 那是站点 compact 行自己的事
     *（用量最高的那一扇）。加一列明细不该再改信封。
     */
    nonisolated private static func genericWindows(
        provider: String,
        node: [String: Any]
    ) -> [AgentLimitWindow] {
        let slots: [(suffix: String, field: String)] = [
            ("primary", "primary_window"),
            ("secondary", "secondary_window"),
            ("tertiary", "tertiary_window"),
            ("quaternary", "quaternary_window"),
        ]
        return slots.compactMap { slot in
            guard let value = node[slot.field] as? [String: Any] else { return nil }
            return window(
                key: "\(provider).\(slot.suffix)",
                label: (value["label"] as? String)?.nilIfEmpty,
                minutes: minutes(value),
                node: value
            )
        }
    }

    nonisolated private static func window(
        key: String,
        label: String?,
        minutes: Int?,
        node: [String: Any],
        fallbackReset: Int64? = nil
    ) -> AgentLimitWindow {
        AgentLimitWindow(
            key: key,
            label: label,
            group: nil,
            windowMinutes: minutes,
            usedPercent: percent(node),
            resetsAt: TokenTrackerAPI.unixSeconds(resetValue(node)) ?? fallbackReset
        )
    }

    /// Claude 那几个窗口叫 `utilization`，其余几家叫 `used_percent`
    nonisolated private static func percent(_ node: [String: Any]) -> Double {
        TokenTrackerAPI.number(node["utilization"] ?? node["used_percent"])
    }

    /// 同理，Claude 是 `resets_at`，其余几家是 `reset_at`
    nonisolated private static func resetValue(_ node: [String: Any]) -> Any? {
        node["resets_at"] ?? node["reset_at"]
    }

    nonisolated private static func minutes(_ node: [String: Any]) -> Int? {
        let seconds = TokenTrackerAPI.number(node["limit_window_seconds"])
        return seconds > 0 ? Int(seconds / 60) : nil
    }

    /// Codex 报的是枚举值（"prolite"），其余几家直接给展示名；都为空就是没有套餐信息
    nonisolated private static func planTier(provider: String, node: [String: Any]) -> String? {
        if provider == "codex" {
            return (node["plan_type"] as? String)?.nilIfEmpty
                ?? (node["plan_label"] as? String)?.nilIfEmpty
        }
        return (node["plan_label"] as? String)?.nilIfEmpty
    }

}

/**
 * 长间隔那份的采集器：token / 费用，加上套餐与限额，一轮转出一整个
 * `vibeCodingUsage` 载荷（只差会话总数，那个发信封时才补，见
 * `VibeCodingUsagePayload.withSessionCount`）。
 *
 * 从前限额单独一个采集器、单独一个模块。那条线是按「哪条命令产出的」划的 ——
 * 当年用量来自 CodexBar 一条要跑十几秒的扫描，它一失败会把同一轮刚取到的限额
 * 一起拖下水，拆开才有意义。如今两半都是同一个本机服务上的 GET、跟着同一个
 * 间隔转，拆着只剩两份状态和两个要对齐的地方。
 *
 * 并成一个采集器**不等于共命**，两半的失败各走各的：
 *
 * - **限额挂了**：用量照发。限额沿用上一次的好值，并带上 limitsError ——
 *   页面据此把「没配」和「配了但取不到」分开，两者都是空数组。
 * - **用量挂了**：整轮不发。限额是按 id 贴在 agents 上的，站点那边没有主干就
 *   没有 agents 可贴，硬发出去也是整份被判废。限额仍然收进状态，下一轮用量
 *   成功时一起出去。
 */
@MainActor
final class VibeCodingUsageMonitor: ObservableObject {
    /// 各 provider 最近一次取到的套餐与限额窗口。这一轮取不到就留着上次的好值
    @Published private(set) var plans: [String: AgentPlanSnapshot] = [:]
    @Published private(set) var uploadPayload: JSONValue?
    /// 载荷真正变化的时刻，判变门闩看它 —— 理由同 CodingSessionMonitor。
    /// 这份载荷带着 `collectedAt`，所以每采一次都算变化，仍是一个间隔发一次。
    @Published private(set) var payloadUpdatedAt: Date?
    @Published private(set) var lastSuccess: Date?
    /// 用量那半的失败原因。它挂了就整轮不发，所以这条为空才谈得上有新数据
    @Published private(set) var lastError: String?
    /// 限额那半的失败原因，合成一句给界面看；按 provider 分开的那份在 limitErrors 里
    @Published private(set) var limitsError: String?
    /// 按 provider 分开的限额失败原因，随载荷发给网页 —— 页面要能把「没配」和「取不到」分开
    @Published private(set) var limitErrors: [String: String] = [:]
    /// 载荷变化时叫醒上报循环。采集不再挂在那条循环上，所以得跟前台应用、
    /// 音乐一样自己回头敲一下门。
    var onChange: (() -> Void)?
    private var refreshing = false
    /// 上一次**尝试**采集的时刻。间隔门闩看它而不是 lastSuccess：失败或被判废
    /// 时 lastSuccess 不动，光看它的话 2 秒一圈的主循环会每圈都重跑一次采集。
    private var lastAttempt: Date?

    func stop() {
        plans = [:]
        uploadPayload = nil
        payloadUpdatedAt = nil
        lastSuccess = nil
        lastError = nil
        limitsError = nil
        limitErrors = [:]
        lastAttempt = nil
        refreshing = false
    }

    func refreshIfNeeded(baseURL: String, interval: Double) async {
        guard !refreshing else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < interval { return }
        _ = await refreshNow(baseURL: baseURL)
    }

    /// Bypasses the interval gate for an explicit user refresh, while preserving
    /// the monitor's single-flight guard.
    @discardableResult
    func refreshNow(baseURL: String) async -> Bool {
        guard !refreshing else { return false }
        refreshing = true
        lastAttempt = Date()
        defer { refreshing = false }

        // 两半并发取：限额只有一次请求，用量要两百多次，串着跑等于白等一次往返
        async let usageTask = TokenTrackerUsageCollector.collect(baseURL: baseURL)
        // 限额那条自己吞错误、把原因分到各 provider 上，所以先接它，
        // 不管用量成不成都先把状态收下
        applyLimits(await AgentLimitsCollector.collect(baseURL: baseURL))

        let usage: VibeCodingUsageCollection
        do {
            usage = try await usageTask
        } catch {
            lastError = error.localizedDescription
            return false
        }
        lastError = nil

        let payload = VibeCodingUsagePayload.withLimits(usage.uploadPayload, limits: limitsPayload())
        if uploadPayload != payload {
            uploadPayload = payload
            payloadUpdatedAt = Date()
            onChange?()
        }
        lastSuccess = Date()
        return true
    }

    /// 把这一轮的限额收进状态：取到的更新，没取到的留着上次的好值。
    private func applyLimits(_ outcome: AgentLimitsOutcome) {
        // 内容没变就留着旧快照，下游（上传门闩、@Published 订阅者）才不会被
        // 每一轮采集都惊动一次。
        var fresh = outcome.plans
        // 某一 provider 本轮完全失败时也保留它上次的好值；错误通过
        // limitErrors 单独标记。统一命令的一边失败不能把另一边或旧快照清掉。
        for agent in vibeCodingAgentIDs where fresh[agent] == nil {
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
                    limits: previous.limits
                )
            }
            if let previous = plans[agent], previous == merged {
                fresh[agent] = previous
            } else {
                fresh[agent] = merged
            }
        }
        plans = fresh
        limitsError = outcome.errors.isEmpty ? nil : outcome.errors.joined(separator: "；")
        limitErrors = outcome.limitErrors
    }

    /**
     * 限额那半的载荷。全都失败时也要发：空 limits 加上 limitsError 才是
     * 「配了但取不到」，什么都不发在站点那边和「没配」长得一模一样。
     *
     * 五个来源同一形状，按 id 贴到用量那份的 agents 上。展示名和图标在用量
     * 那一行里，这里只补套餐和窗口。
     */
    private func limitsPayload() -> JSONValue? {
        if plans.isEmpty && limitErrors.isEmpty { return nil }
        func windows(_ limits: [AgentLimitWindow]) -> JSONValue {
            .array(limits.map { window in
                .object([
                    "key": .string(window.key),
                    "label": window.label.map(JSONValue.string) ?? .null,
                    "group": window.group.map(JSONValue.string) ?? .null,
                    "windowMinutes": window.windowMinutes.map { .number(Double($0)) } ?? .null,
                    "usedPercent": .number(window.usedPercent),
                    "resetsAt": window.resetsAt.map { .number(Double($0)) } ?? .null,
                ])
            })
        }
        let agents: [JSONValue] = vibeCodingAgents.map { spec in
            let plan = plans[spec.id]
            return .object([
                "id": .string(spec.id),
                "plan": plan.flatMap(Self.planValue) ?? .null,
                "limits": windows(plan?.limits ?? []),
                "limitsError": limitErrors[spec.id].map(JSONValue.string) ?? .null,
            ])
        }
        return .object(["agents": .array(agents)])
    }

    /// 套餐取不到时整格不发。发一个空字符串会在页面上留下一块没有内容的标签
    private static func planValue(_ snapshot: AgentPlanSnapshot) -> JSONValue? {
        guard let tier = snapshot.tier, let label = snapshot.label else { return nil }
        return .object(["tier": .string(tier), "label": .string(label)])
    }
}

/**
 * `vibeCodingUsage` 模块载荷的两道拼装。
 *
 * 拼出来的形状和站点的读法一一对应：限额按 `id` 贴到对应的 agent 上，
 * 会话总数落进 totals。不再拆 `quotaProviders`。
 *
 * 分两道是因为两样东西不在同一个地方就位：限额和用量在同一个采集器里，
 * 采完就能贴；会话总数在另一个采集器手上，发信封那一刻才拿得到。
 */
enum VibeCodingUsagePayload {
    /**
     * 限额贴进用量。
     *
     * 限额缺席时整片字段都不发，而不是发一串 null —— 站点那边「没有这几个键」
     * 就是「没配」，整块不渲染；「配了但取不到」由 limitsError 表达，那是有键的。
     */
    static func withLimits(_ usage: JSONValue, limits: JSONValue?) -> JSONValue {
        guard case .object(var root) = usage else { return usage }

        var limitsRoot: [String: JSONValue] = [:]
        if case let .object(fields)? = limits { limitsRoot = fields }

        var limitsByAgent: [String: [String: JSONValue]] = [:]
        if case let .array(rows)? = limitsRoot["agents"] {
            for row in rows {
                guard case let .object(fields) = row,
                      case let .string(id)? = fields["id"] else { continue }
                limitsByAgent[id] = fields
            }
        }
        if !limitsByAgent.isEmpty, case let .array(agents)? = root["agents"] {
            root["agents"] = .array(agents.map { agent in
                guard case .object(var fields) = agent,
                      case let .string(id)? = fields["id"],
                      let limit = limitsByAgent[id] else { return agent }
                fields["plan"] = limit["plan"] ?? .null
                fields["limits"] = limit["limits"] ?? .array([])
                fields["limitsError"] = limit["limitsError"] ?? .null
                return .object(fields)
            })
        }
        return .object(root)
    }

    /**
     * 会话总数落进 totals。
     *
     * 它是「一共开过多少次」，一个累计量，所以归这份而不是 60 秒那轮的
     * `vibeCodingNow`；但数出它的是那边的扫描，所以只能在发信封时补上。
     */
    static func withSessionCount(_ usage: JSONValue, _ sessionCount: Int) -> JSONValue {
        guard case .object(var root) = usage,
              case .object(var totals)? = root["totals"] else { return usage }
        totals["sessionCount"] = .number(Double(sessionCount))
        root["totals"] = .object(totals)
        return .object(root)
    }
}

private struct VibeCodingUsageCollection: Sendable {
    let uploadPayload: JSONValue
}

private enum TokenTrackerUsageCollector {
    private static let agents = vibeCodingAgents
    /**
     * 总量和模型排行从有记录的第一天算起，不设窗口。
     *
     * 从前跟着 CodexBar 那条 `cost --days 365` 划一年，于是「总计」会随时间
     * 悄悄漏掉早期的量 —— 那一栏说的是总计，划窗口就名不副实。
     *
     * 代价是按天的请求数跟「有数据的天数」成正比（眼下 210 天，不到一秒）。
     * 它涨得比日历慢：没用过的日子根本不占一次往返。
     */
    private static let historyStart = "2000-01-01"

    /// 一个来源在某一天的用量
    private struct DayUsage {
        var input = 0.0
        var output = 0.0
        var cacheRead = 0.0
        var cacheCreation = 0.0
        var reasoning = 0.0
        var total = 0.0
        var cost = 0.0
        /// 模型 → token；「主力模型」和排行都从它来
        var models: [String: Double] = [:]
    }

    /**
     * 本地用量、费用和模型排行。
     *
     * 要的是「每天 × 每个 agent」，而 TokenTracker 没有一个接口直接给这个格子：
     * 按天那份把所有来源合在一起，按来源那份只给一个区间的合计。所以先问哪几天
     * 有数据，再按天各要一次按来源的拆分 —— `source` 是它自己标好的，比按模型名
     * 猜厂商可靠（它那份里还有一个 unknown 桶，猜不出来）。
     *
     * 一天一次请求听着多，但它服务端整份都在内存里，一年 200 个有数据的日子加
     * 起来不到一秒；从前 CodexBar 那条 `--refresh` 要十几秒。
     */
    nonisolated static func collect(baseURL: String) async throws -> VibeCodingUsageCollection {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let daily = try await TokenTrackerAPI.get(
            baseURL: baseURL,
            function: "tokentracker-usage-daily",
            query: ["from": historyStart, "to": dayString(today)]
        )
        guard let dailyRoot = daily as? [String: Any],
              let dailyRows = dailyRoot["data"] as? [[String: Any]]
        else {
            throw TelemetryModuleError.tokenTracker("usage-daily 响应缺少 data")
        }
        // 空日子不必往返一次；今天即使还没有数据也要问，那一行要显示 0 而不是缺失
        var days = Set(dailyRows.compactMap { row -> String? in
            guard let day = row["day"] as? String,
                  TokenTrackerAPI.number(row["total_tokens"]) > 0
            else { return nil }
            return day
        })
        days.insert(dayString(today))

        var usage: [String: [String: DayUsage]] = [:]
        for day in days.sorted() {
            let breakdown = try await TokenTrackerAPI.get(
                baseURL: baseURL,
                function: "tokentracker-usage-model-breakdown",
                query: ["from": day, "to": day]
            )
            guard let root = breakdown as? [String: Any],
                  let sources = root["sources"] as? [[String: Any]]
            else { continue }
            for source in sources {
                guard let id = source["source"] as? String else { continue }
                usage[day, default: [:]][id] = dayUsage(source)
            }
        }

        /*
         * 头部那一栏说的是「总计」，所以它把 TokenTracker 里所有来源都算进来，
         * 不只信封里那五行 —— 名单外的工具漏掉的话那一栏就名不副实。
         * 行内的今日用量、当前模型按 vibeCodingAgents 分。
         */
        var aggregate = DayUsage()
        var mergedModels: [String: Double] = [:]
        var activeDates = Set<String>()
        for (day, bySource) in usage {
            var dayTotal = 0.0
            for row in bySource.values {
                aggregate.input += row.input
                aggregate.output += row.output
                aggregate.cacheRead += row.cacheRead
                aggregate.cacheCreation += row.cacheCreation
                aggregate.reasoning += row.reasoning
                aggregate.total += row.total
                aggregate.cost += row.cost
                for (name, tokens) in rankable(row.models) { mergedModels[name, default: 0] += tokens }
                dayTotal += row.total
            }
            if dayTotal > 0 { activeDates.insert(day) }
        }

        var agentPayloads: [[String: Any]] = []
        for spec in agents {
            var models: [String: Double] = [:]
            for bySource in usage.values {
                guard let row = bySource[spec.id] else { continue }
                for (name, tokens) in row.models { models[name, default: 0] += tokens }
            }

            let todayKey = dayString(today)
            let todayUsage = usage[todayKey]?[spec.id] ?? DayUsage()

            // 「最近一个有用量日里的主力模型」。真正的「此刻在用哪个」由会话那份
            // 送来，站点优先用它、取不到才落到这个值上。
            let currentModel = days.sorted().reversed().lazy.compactMap { day -> String? in
                guard let row = usage[day]?[spec.id], row.total > 0 else { return nil }
                return topModel(row.models)
            }.first

            agentPayloads.append([
                "id": spec.id,
                "label": spec.label,
                "icon": spec.icon,
                // unknown 不是模型，是它没记下来的那部分；auto review 留着 —— 它确实跑过
                "models": models.keys.filter { $0 != "unknown" }.sorted(),
                "currentModel": currentModel ?? NSNull(),
                "topModel": topModel(models) ?? NSNull(),
                "today": [
                    "date": todayKey,
                    "inputTokens": todayUsage.input,
                    "outputTokens": todayUsage.output,
                    "cacheReadTokens": todayUsage.cacheRead,
                    "cacheCreationTokens": todayUsage.cacheCreation,
                    "totalTokens": todayUsage.total,
                    "apiEquivalentCostUSD": todayUsage.cost,
                ],
            ])
        }

        let summary: [String: Any] = [
            "agents": agentPayloads,
            "totals": [
                "inputTokens": aggregate.input,
                "outputTokens": aggregate.output,
                "cacheReadTokens": aggregate.cacheRead,
                "cacheCreationTokens": aggregate.cacheCreation,
                "reasoningTokens": aggregate.reasoning,
                "totalTokens": aggregate.total,
                "apiEquivalentCostUSD": aggregate.cost,
                "activeDays": Double(activeDates.count),
            ],
            "topModels": mergedModels
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { ["model": $0.key, "tokens": $0.value] },
            "collectedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: summary)
        return VibeCodingUsageCollection(
            uploadPayload: try JSONDecoder().decode(JSONValue.self, from: data)
        )
    }

    /**
     * 一个来源在一天里的合计。
     *
     * 不再像 CodexBar 那版那样把 cached 从 input 里扣掉：TokenTracker 的 input
     * 本来就不含缓存（input + output + cached + creation 正好等于 total），
     * 再扣一次就是扣两遍。
     */
    nonisolated private static func dayUsage(_ source: [String: Any]) -> DayUsage {
        let totals = source["totals"] as? [String: Any] ?? [:]
        var usage = DayUsage()
        usage.input = TokenTrackerAPI.number(totals["input_tokens"])
        usage.output = TokenTrackerAPI.number(totals["output_tokens"])
        usage.cacheRead = TokenTrackerAPI.number(totals["cached_input_tokens"])
        usage.cacheCreation = TokenTrackerAPI.number(totals["cache_creation_input_tokens"])
        usage.reasoning = TokenTrackerAPI.number(totals["reasoning_output_tokens"])
        usage.total = TokenTrackerAPI.number(totals["total_tokens"])
        usage.cost = TokenTrackerAPI.number(totals["total_cost_usd"])
        for model in source["models"] as? [[String: Any]] ?? [] {
            guard let name = (model["model"] as? String)?.nilIfEmpty else { continue }
            let row = model["totals"] as? [String: Any] ?? [:]
            usage.models[name, default: 0] += TokenTrackerAPI.number(row["total_tokens"])
        }
        return usage
    }

    /**
     * 参与排名的模型。
     *
     * 隐藏规则见 `TokenTrackerModels`。它们烧掉的 token 仍然照实计入总量，那条
     * 路走的是 totals，不看这里。
     */
    nonisolated private static func rankable(_ models: [String: Double]) -> [String: Double] {
        models.filter { TokenTrackerModels.shown($0.key) && $0.value > 0 }
    }

    nonisolated private static func topModel(_ models: [String: Double]) -> String? {
        rankable(models).max { $0.value < $1.value }?.key
    }

    nonisolated private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// 按本机时区切天，和请求里那个 tz 参数说的是同一件事
    nonisolated private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/**
 * 过去 53 周的日合计，外加每天前五的模型拆分。
 *
 * `days[i]` 是 origin 起第 i 天的 token，空日子是 0。`models` 是这一年里出现在
 * 每日前五里的名字表；`mix` 一行是 `[offset, idx, tokens, …]`，只给有拆分的
 * 日子。切块省不下多少，请求头反而更亏。
 */
struct VibeCodingYearSnapshot: Equatable, Sendable {
    let origin: String
    let days: [Int]
    let models: [String]
    let mix: [[Int]]

    var json: JSONValue {
        .object([
            "origin": .string(origin),
            "days": .array(days.map { .number(Double($0)) }),
            "models": .array(models.map { .string($0) }),
            "mix": .array(mix.map { row in .array(row.map { .number(Double($0)) }) }),
        ])
    }
}

/**
 * 过去一年的日合计和每天前五模型。
 *
 * 合计仍来自一次 `tokentracker-usage-daily`。拆分没有按天的接口，只对有量的
 * 日子再问一次 `tokentracker-usage-model-breakdown`，编成模型表 + 稀疏 offset
 * 对。和用量那份错开：那边要今日明细和排行，这边给热力图。间隔单独控，默认
 * 一小时；格子按天变，绑在用量那 10 分钟车上会白发。
 */
@MainActor
final class VibeCodingYearMonitor: ObservableObject {
    /// GitHub 贡献图同样是 53 列（含本周）。
    nonisolated static let weeksInWindow = 53
    nonisolated static let daysInWindow = weeksInWindow * 7
    nonisolated static let mixTopModels = 5
    nonisolated static let defaultRefreshInterval: TimeInterval = 3_600

    @Published private(set) var uploadPayload: JSONValue?
    @Published private(set) var payloadUpdatedAt: Date?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastError: String?
    var onChange: (() -> Void)?

    private var refreshing = false
    private var lastAttempt: Date?

    func stop() {
        uploadPayload = nil
        payloadUpdatedAt = nil
        lastSuccess = nil
        lastError = nil
        lastAttempt = nil
        refreshing = false
    }

    func refreshIfNeeded(baseURL: String, interval: Double) async {
        guard !refreshing else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < interval { return }
        await refreshNow(baseURL: baseURL)
    }

    @discardableResult
    func refreshNow(baseURL: String) async -> Bool {
        guard !refreshing else { return false }
        refreshing = true
        lastAttempt = Date()
        defer { refreshing = false }

        do {
            let snapshot = try await VibeCodingYearCollector.collect(baseURL: baseURL)
            let payload = snapshot.json
            if uploadPayload != payload {
                uploadPayload = payload
                payloadUpdatedAt = Date()
                onChange?()
            }
            lastError = nil
            lastSuccess = Date()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}

private enum TokenTrackerModels {
    /// unknown 不是模型；codex 自动 review 不是使用者选的。烧掉的 token 仍进合计。
    nonisolated static func shown(_ name: String) -> Bool {
        name != "codex-auto-review" && name != "unknown"
    }
}

private enum VibeCodingYearCollector {
    nonisolated static func collect(baseURL: String) async throws -> VibeCodingYearSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let originDate = sunday(onOrBefore: weeksAgo(VibeCodingYearMonitor.weeksInWindow - 1, from: today, calendar: calendar), calendar: calendar)
        let endDate = calendar.date(byAdding: .day, value: VibeCodingYearMonitor.daysInWindow - 1, to: originDate) ?? today
        let origin = dayString(originDate)
        let to = dayString(min(today, endDate))

        let daily = try await TokenTrackerAPI.get(
            baseURL: baseURL,
            function: "tokentracker-usage-daily",
            query: ["from": origin, "to": to]
        )
        guard let root = daily as? [String: Any],
              let rows = root["data"] as? [[String: Any]]
        else {
            throw TelemetryModuleError.tokenTracker("usage-daily 响应缺少 data")
        }

        var tokens: [String: Int] = [:]
        for row in rows {
            guard let day = row["day"] as? String else { continue }
            tokens[day] = Int(TokenTrackerAPI.number(row["total_tokens"]).rounded())
        }

        var days: [Int] = []
        days.reserveCapacity(VibeCodingYearMonitor.daysInWindow)
        var dates: [String] = []
        dates.reserveCapacity(VibeCodingYearMonitor.daysInWindow)
        for offset in 0..<VibeCodingYearMonitor.daysInWindow {
            let date = calendar.date(byAdding: .day, value: offset, to: originDate) ?? originDate
            let key = dayString(date)
            dates.append(key)
            days.append(tokens[key] ?? 0)
        }

        var mixByOffset: [Int: [(name: String, tokens: Int)]] = [:]
        try await withThrowingTaskGroup(of: (Int, [(String, Int)]).self) { group in
            for offset in 0..<VibeCodingYearMonitor.daysInWindow {
                guard days[offset] > 0 else { continue }
                let date = dates[offset]
                group.addTask {
                    let breakdown = try await TokenTrackerAPI.get(
                        baseURL: baseURL,
                        function: "tokentracker-usage-model-breakdown",
                        query: ["from": date, "to": date]
                    )
                    return (offset, Self.topModels(from: breakdown, limit: VibeCodingYearMonitor.mixTopModels))
                }
            }
            for try await (offset, parts) in group {
                if !parts.isEmpty { mixByOffset[offset] = parts }
            }
        }

        var totals: [String: Int] = [:]
        for parts in mixByOffset.values {
            for part in parts { totals[part.name, default: 0] += part.tokens }
        }
        let models = totals.keys.sorted { left, right in
            if totals[left] != totals[right] { return (totals[left] ?? 0) > (totals[right] ?? 0) }
            return left < right
        }
        let index = Dictionary(uniqueKeysWithValues: models.enumerated().map { ($1, $0) })
        let mix: [[Int]] = mixByOffset.keys.sorted().compactMap { offset in
            let parts = mixByOffset[offset] ?? []
            guard !parts.isEmpty else { return nil }
            var row = [offset]
            for part in parts {
                guard let idx = index[part.name] else { continue }
                row.append(idx)
                row.append(part.tokens)
            }
            return row.count > 1 ? row : nil
        }
        return VibeCodingYearSnapshot(origin: origin, days: days, models: models, mix: mix)
    }

    /// 所有来源合并后的前 N；hidden 的模型不进表，token 仍在 `days` 里。
    nonisolated private static func topModels(from breakdown: Any, limit: Int) -> [(String, Int)] {
        guard let root = breakdown as? [String: Any],
              let sources = root["sources"] as? [[String: Any]]
        else { return [] }
        var totals: [String: Double] = [:]
        for source in sources {
            for model in source["models"] as? [[String: Any]] ?? [] {
                guard let name = (model["model"] as? String)?.nilIfEmpty,
                      TokenTrackerModels.shown(name)
                else { continue }
                let row = model["totals"] as? [String: Any] ?? [:]
                totals[name, default: 0] += TokenTrackerAPI.number(row["total_tokens"])
            }
        }
        return totals
            .filter { $0.value > 0 }
            .sorted { left, right in
                if left.value != right.value { return left.value > right.value }
                return left.key < right.key
            }
            .prefix(limit)
            .map { ($0.key, Int($0.value.rounded())) }
            .filter { $0.1 > 0 }
    }

    nonisolated private static func weeksAgo(_ weeks: Int, from date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .weekOfYear, value: -weeks, to: date) ?? date
    }

    /// Calendar weekday：1 是周日。
    nonisolated private static func sunday(onOrBefore date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        return calendar.date(byAdding: .day, value: -(weekday - 1), to: day) ?? day
    }

    nonisolated private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    nonisolated private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private enum TelemetryModuleError: LocalizedError {
    case appleMusic(String)
    case tokenTracker(String)
    case agentLimits(String)

    var errorDescription: String? {
        switch self {
        case let .appleMusic(message): "Apple Music：\(message)"
        case let .tokenTracker(message): "TokenTracker：\(message)"
        case let .agentLimits(message): "套餐额度：\(message)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
