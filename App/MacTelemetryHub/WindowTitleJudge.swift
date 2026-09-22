import CryptoKit
import Foundation
import UserNotifications

/// 一条窗口标题此刻停在哪一步。仪表盘、菜单栏、设置页都按它显示。
enum WindowTitleStatus: String, Equatable, Sendable {
    /// 没有标题：窗口没标题、应用没窗口，或者前台应用采集关着。
    case none
    /// 应用在标题黑名单里：从头到尾不读、不判、不报。
    case blacklisted
    /// 命中远端隐藏黑名单。本机照旧显示，但绝不送去 TypeSafe，也不上报。
    case hidden
    /// 没有辅助功能权限，读不到标题。
    case noAccess
    /// 免判放行名单里的应用，标题直接上报。
    case trusted
    case published
    case locked
    case needsConfirmation
    /// 能公开但没什么可公开的：标题只是应用名或者通用占位。不报，也不打扰。
    case omitted
    case judging
    /// 没配 API key，或者判断失败。按锁定处理。
    case unavailable

    var displayName: String {
        switch self {
        case .none: "无标题"
        case .blacklisted: "黑名单"
        case .hidden: "远端已隐藏"
        case .noAccess: "缺少辅助功能权限"
        case .trusted: "免判"
        case .published: "已公开"
        case .locked: "已锁定"
        case .needsConfirmation: "待确认"
        case .omitted: "已省略"
        case .judging: "判断中"
        case .unavailable: "无法判断"
        }
    }

    /// 这一档的标题能不能进信封。界面之外别再各自判一遍。
    var isReportable: Bool {
        self == .published || self == .trusted
    }
}

/**
 * 窗口标题的「能不能公开」判断。
 *
 * 名单是三档的：标题黑名单里的应用从头到尾不读；免判放行名单里的直接上报；
 * 其余每一条**归一化后**的标题都问一次 Jev，按六道题的概率落成公开 /
 * 锁定 / 已省略 / 待确认（顺序和阈值见 `WindowTitleJudgmentThresholds`）。
 * 命中远端隐藏黑名单的应用一律不问 —— 那份载荷连真实应用叫什么都不说，
 * 把它的标题送去第三方毫无道理。
 *
 * 为什么它不在 `DesktopActivityMonitor` 里：monitor 的职责是读辅助功能 API，
 * 这里的职责是节流、缓存、落盘和通知，两件事的失败方式完全不同。monitor 只
 * 调一个同步方法（`resolve`），拿到此刻能用的结论就继续；判断回来之后这边
 * 调 `onVerdict`，monitor 重新采一次，走的还是原来那条
 * 「快照变化 → 400ms 防抖 → 叫醒上报循环」，不另开路径。
 *
 * 节流有三层，缺一层都会变成每秒问一次：
 *
 * 1. 归一化（`WindowTitleNormalizer`）。转动的圆点、跑动的进度条被剥掉之后，
 *    一个正在下载的窗口始终只有一个标题。
 * 2. 稳定期 2 秒。终端里 `cd` 一路敲过去会连出好几个标题，只有停下来的那个
 *    值得问。这个数配的是 monitor 那边 5 秒的兜底轮询和随叫随到的
 *    `kAXTitleChangedNotification`：通知来得比轮询快，2 秒既盖得住连打，
 *    又不会让用户盯着「判断中」太久。
 * 3. 每个应用 10 秒最多问一次。期间的变动合并成最后那一条，不排队。
 *
 * 再加上「同一个缓存键只允许一次在途请求」——重复的问法在缓存回来之前不会
 * 叠着发出去。
 */
@MainActor
final class WindowTitleJudge: ObservableObject {
    struct Rules: Equatable {
        /// 永不抓取、永不判断、永不上报。
        var blacklist = BundleIdentifierList(rawValue: "")
        /// 免判放行：标题直接上报。
        var trusted = BundleIdentifierList(rawValue: "")
        /// 远端隐藏黑名单。本机照旧显示标题，但不问 Jev、不上报。
        var hiddenApplications = BundleIdentifierList(rawValue: "")
        var apiKey = ""
    }

    /// 归一化文本稳定多久才值得问。见类型注释里的三层节流。
    static let settleDelay: TimeInterval = 2
    /// 同一个应用两次提问的最小间隔。
    static let perApplicationInterval: TimeInterval = 10
    /// 单次请求超时。实测一次判断约 0.7 秒，10 秒是「网络出事了」的界线。
    static let requestTimeout: TimeInterval = 10
    /// 失败退避的首个间隔，之后翻倍。
    static let retryBaseDelay: TimeInterval = 5
    static let maximumRetryDelay: TimeInterval = 300
    /// 连续失败多少次之后就不再自动重试，等标题再变或用户手动重判。
    static let maximumRetries = 4

    @Published private(set) var cache = WindowTitleJudgmentCache()
    @Published private(set) var lastError: String?
    /// 第一次出现「待确认」时才去要通知权限，不在启动时打扰。
    @Published private(set) var notificationAuthorizationRequested = false
    @Published private(set) var notificationAuthorizationGranted = false
    /// 「去看看这一条」的一次性令牌。设置页收到就跳到窗口标题页再消费掉 ——
    /// 存一个 UUID 而不是 Bool，是因为连点两次通知也该各跳一次。
    @Published private(set) var reviewRequest: UUID?

    /// 判断有结果时叫一声。ServiceController 把它接到重新采集上。
    var onVerdict: (() -> Void)?
    /// 点通知本体时叫一声。AppDelegate 把它接到「打开设置窗口」上 ——
    /// 这里不 import AppKit，窗口归界面层管。
    var onReviewRequested: (() -> Void)?

    /// 等用户拍板的那些。设置页按它列表。
    var awaitingConfirmation: [WindowTitleJudgmentEntry] {
        cache.entries
            .filter { $0.verdict == .needsConfirmation }
            .sorted { $0.judgedAt > $1.judgedAt }
    }

    /// 一个应用此刻等着判的那条标题。
    private struct Pending {
        let applicationName: String
        let bundleIdentifier: String?
        let title: String
    }

    private var rules = Rules()
    /// 每个应用一个待判的最新标题。变动合并到这里，不排队。
    private var pendingTitles: [String: Pending] = [:]
    /// 每个应用一个定时器。同一条标题重复观察不会重排。
    private var scheduled: [String: (title: String, task: Task<Void, Never>)] = [:]
    private var lastAskedAt: [String: Date] = [:]
    /// 在途的缓存键。同一条标题在结果回来之前不会被问第二次。
    private var inFlight: Set<String> = []
    private var failureCounts: [String: Int] = [:]
    /// 429 / 529 是账号级的限额和过载，退避也该是账号级的。
    private var globalBackoffUntil = Date.distantPast
    /// 上一次真正解析过的缓存键。只有它变了才动 LRU 的 `lastSeenAt` ——
    /// 兜底轮询每 5 秒问一次同一条标题，跟着写盘毫无意义。
    private var lastResolvedKey: String?
    private var notificationDelegate: WindowTitleNotificationDelegate?

    init() {
        cache = Self.loadCache()
    }

    // MARK: - 配置

    func configure(_ rules: Rules) {
        let previous = self.rules
        self.rules = rules
        guard previous != rules else { return }
        // key 换了就把失败记录清空 —— 填错一次 key 会让每条标题连吃四个 401
        // 然后永久停在「无法判断」，换上正确的 key 也醒不过来。
        if previous.apiKey != rules.apiKey {
            lastError = nil
            failureCounts.removeAll()
            globalBackoffUntil = .distantPast
        }
        lastResolvedKey = nil
        onVerdict?()
    }

    func isBlacklisted(_ bundleIdentifier: String?) -> Bool {
        rules.blacklist.contains(bundleIdentifier: bundleIdentifier)
    }

    // MARK: - 判断

    /**
     * 此刻这条标题算什么。
     *
     * 同步、只查缓存：应用名的上报一秒都不该等判断。没判过的在这里被排上队，
     * 结论回来之后走 `onVerdict`。所以切到一个没判过的标签页时，标题会先消失
     * 再出现 —— 宁可空着，也不能把还没判过的字先发出去。
     */
    func resolve(
        applicationName: String,
        bundleIdentifier: String?,
        normalizedTitle: String?
    ) -> WindowTitleStatus {
        guard let title = normalizedTitle, !title.isEmpty else {
            lastResolvedKey = nil
            return .none
        }
        if rules.blacklist.contains(bundleIdentifier: bundleIdentifier) { return .blacklisted }
        // 隐藏应用的标题绝不出本机：不问 Jev，也不进信封。
        if rules.hiddenApplications.contains(bundleIdentifier: bundleIdentifier) { return .hidden }
        if rules.trusted.contains(bundleIdentifier: bundleIdentifier) { return .trusted }

        let key = WindowTitleJudgmentCache.key(bundleIdentifier: bundleIdentifier, title: title)
        if let entry = cachedEntry(forKey: key) {
            switch entry.verdict {
            case .published: return .published
            case .locked: return .locked
            case .needsConfirmation: return .needsConfirmation
            case .omitted: return .omitted
            }
        }
        // 没 key 和「试了几次都失败」都按锁定处理，而且到此为止 —— 再排一次
        // 只会让同一个必然失败的请求每 5 秒重来一遍。
        guard !rules.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              failureCounts[key, default: 0] < Self.maximumRetries else {
            return .unavailable
        }
        schedule(applicationName: applicationName, bundleIdentifier: bundleIdentifier, title: title)
        return .judging
    }

    /**
     * 这条标题落在这一档的理由，给界面用。
     *
     * 「已锁定 · 政治敏感」的后半截。只有缓存里已经有结论的标题说得出理由；
     * 黑名单、免判、判断中这些档位本身就是理由，`WindowTitleStatus.displayName`
     * 已经说完了。不读 LRU，也不写盘 —— 它只是 `resolve` 之后的一句补充。
     */
    func reason(bundleIdentifier: String?, normalizedTitle: String?) -> String? {
        guard let title = normalizedTitle, !title.isEmpty else { return nil }
        let key = WindowTitleJudgmentCache.key(bundleIdentifier: bundleIdentifier, title: title)
        return cache.entry(forKey: key)?.reasonText
    }

    /// 查表。只有键真的变了才推进 LRU，免得兜底轮询把这份名单写成流水账。
    private func cachedEntry(forKey key: String) -> WindowTitleJudgmentEntry? {
        guard lastResolvedKey != key else { return cache.entry(forKey: key) }
        lastResolvedKey = key
        guard let entry = cache.lookup(key: key, at: Date()) else { return nil }
        persist()
        return entry
    }

    // MARK: - 用户拍板

    /// 在通知或设置页里拍板。用户的结论压过模型，并且立刻刷新快照。
    func decide(key: String, verdict: WindowTitleVerdict) {
        guard var entry = cache.entry(forKey: key) else { return }
        entry.verdict = verdict
        entry.source = .user
        entry.probabilities = [:]
        // 理由跟着概率一起抹掉：这条是用户拍的板，不该再挂着模型的说辞。
        entry.lockedBy = []
        entry.judgedAt = Date()
        entry.lastSeenAt = Date()
        cache.store(entry)
        persist()
        removeDeliveredNotification(for: key)
        onVerdict?()
    }

    /// 丢掉这一条结论，下次再遇到这条标题重新问一次。
    func rejudge(key: String) {
        cache.remove(key: key)
        failureCounts[key] = nil
        lastResolvedKey = nil
        persist()
        removeDeliveredNotification(for: key)
        onVerdict?()
    }

    func forget(key: String) {
        cache.remove(key: key)
        failureCounts[key] = nil
        lastResolvedKey = nil
        persist()
        removeDeliveredNotification(for: key)
        onVerdict?()
    }

    func forgetAll() {
        cache.removeAll()
        failureCounts.removeAll()
        lastResolvedKey = nil
        persist()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        onVerdict?()
    }

    // MARK: - 排期

    private func schedule(
        applicationName: String,
        bundleIdentifier: String?,
        title: String,
        extraDelay: TimeInterval = 0
    ) {
        let app = bundleIdentifier ?? applicationName
        pendingTitles[app] = Pending(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            title: title
        )
        // 同一条标题已经在等了就别重排，否则 5 秒一次的兜底轮询会把稳定期
        // 无限往后推，永远等不到「稳定 2 秒」。
        if let existing = scheduled[app], existing.title == title, extraDelay == 0 { return }
        scheduled[app]?.task.cancel()

        let now = Date()
        let readyAt = max(
            now.addingTimeInterval(Self.settleDelay + extraDelay),
            (lastAskedAt[app] ?? .distantPast).addingTimeInterval(Self.perApplicationInterval),
            globalBackoffUntil
        )
        let delay = max(0, readyAt.timeIntervalSince(now))
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.fire(app: app)
        }
        scheduled[app] = (title, task)
    }

    private func fire(app: String) async {
        scheduled[app] = nil
        guard let pending = pendingTitles[app] else { return }
        let bundleIdentifier = pending.bundleIdentifier
        let key = WindowTitleJudgmentCache.key(
            bundleIdentifier: bundleIdentifier,
            title: pending.title
        )
        guard cache.entry(forKey: key) == nil, !inFlight.contains(key) else { return }
        let apiKey = rules.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return }

        inFlight.insert(key)
        lastAskedAt[app] = Date()
        do {
            let outcome = try await JevClient.judgeWindowTitle(
                applicationName: pending.applicationName,
                bundleIdentifier: bundleIdentifier,
                title: pending.title,
                apiKey: apiKey,
                timeout: Self.requestTimeout
            )
            inFlight.remove(key)
            record(
                outcome,
                key: key,
                applicationName: pending.applicationName,
                bundleIdentifier: bundleIdentifier,
                title: pending.title
            )
        } catch {
            inFlight.remove(key)
            handleFailure(
                error,
                key: key,
                app: app,
                applicationName: pending.applicationName,
                bundleIdentifier: bundleIdentifier,
                title: pending.title
            )
        }
    }

    private func record(
        _ outcome: WindowTitleJudgmentOutcome,
        key: String,
        applicationName: String,
        bundleIdentifier: String?,
        title: String
    ) {
        failureCounts[key] = nil
        lastError = nil
        let now = Date()
        cache.store(WindowTitleJudgmentEntry(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            title: title,
            verdict: outcome.verdict,
            source: .jev,
            probabilities: outcome.probabilities,
            lockedBy: outcome.lockedBy,
            judgedAt: now,
            lastSeenAt: now
        ))
        persist()
        lastResolvedKey = nil
        if outcome.verdict == .needsConfirmation {
            Task { await askForConfirmation(key: key, applicationName: applicationName, title: title) }
        }
        onVerdict?()
    }

    /**
     * 判断失败一律按锁定处理，而且**不写缓存**。
     *
     * 写进去的话一次网络抖动会把这条标题永久钉在「不可公开」上；不写的代价
     * 只是下次再问一次。429 / 529 是账号级的，退避也做成账号级的。
     */
    private func handleFailure(
        _ error: Error,
        key: String,
        app: String,
        applicationName: String,
        bundleIdentifier: String?,
        title: String
    ) {
        let attempts = (failureCounts[key] ?? 0) + 1
        failureCounts[key] = attempts
        lastError = "窗口标题判断失败：\(error.localizedDescription)"
        lastResolvedKey = nil

        let retryable = (error as? JevError)?.isRetryable ?? true
        let backoff = min(
            Self.maximumRetryDelay,
            Self.retryBaseDelay * pow(2, Double(attempts - 1))
        )
        if let jevError = error as? JevError,
           case let .httpStatus(code, _) = jevError,
           code == 429 || code >= 500 {
            globalBackoffUntil = Date().addingTimeInterval(backoff)
        }
        guard retryable, attempts <= Self.maximumRetries else {
            onVerdict?()
            return
        }
        schedule(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            title: title,
            extraDelay: backoff
        )
        onVerdict?()
    }

    // MARK: - 通知

    /**
     * 启动时装好 delegate 和那一个动作按钮。授权留到真的需要确认时再要。
     *
     * 只挂「公开」：实测挂两个动作时，无论临时还是持续样式，按钮都被收进
     * 「选项」下拉，拍一次板要点两下。锁定改走 `.customDismissAction` ——
     * 关掉通知就是锁定，一次点击。
     */
    func installNotificationHandling() {
        guard notificationDelegate == nil else { return }
        let delegate = WindowTitleNotificationDelegate(judge: self)
        notificationDelegate = delegate
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: WindowTitleNotification.categoryIdentifier,
                actions: [
                    UNNotificationAction(
                        identifier: WindowTitleNotification.publishActionIdentifier,
                        title: "公开",
                        options: []
                    ),
                ],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
        ])
        Task { await refreshNotificationAuthorization() }
    }

    /// 去设置页的「窗口标题」看这些条目。点通知本体和菜单栏里那一项都走这里。
    func requestReview() {
        reviewRequest = UUID()
        onReviewRequested?()
    }

    /// 设置页跳过去之后把令牌消费掉，免得下次打开窗口又自己跳一次。
    func consumeReviewRequest() {
        reviewRequest = nil
    }

    func refreshNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthorizationRequested = settings.authorizationStatus != .notDetermined
        notificationAuthorizationGranted = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    private func askForConfirmation(key: String, applicationName: String, title: String) async {
        await refreshNotificationAuthorization()
        if !notificationAuthorizationRequested {
            // 第一条待确认才要权限。要不到也不算错：条目仍然留在设置页里等人看。
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            notificationAuthorizationRequested = true
            notificationAuthorizationGranted = granted
        }
        guard notificationAuthorizationGranted else { return }

        let content = UNMutableNotificationContent()
        content.title = "窗口标题待确认"
        content.subtitle = applicationName
        // 正文还是那条标题，末尾补一句去处：只有「公开」是按钮，别的都靠关闭。
        content.body = "\(title)\n关闭这条通知即锁定。"
        content.categoryIdentifier = WindowTitleNotification.categoryIdentifier
        content.userInfo = ["cacheKey": key]
        // 通知 ID 用键的哈希：键里有换行、还可能有两百个字符，直接当标识符不稳。
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: Self.notificationIdentifier(for: key),
                content: content,
                trigger: nil
            )
        )
    }

    /**
     * 通知上的三种落点。
     *
     * 关闭即锁定，但只锁还停在「待确认」的那一条：通知中心里可能躺着一条早就
     * 在设置页拍过板的旧通知，过几天一键清空不该把它从「已公开」翻回锁定。
     * 点通知本体不改结论 —— 拿不准才点开看，看之前先别替他决定。
     */
    fileprivate func handleNotificationAction(_ action: String, key: String) {
        switch action {
        case WindowTitleNotification.publishActionIdentifier:
            decide(key: key, verdict: .published)
        case UNNotificationDismissActionIdentifier:
            guard cache.entry(forKey: key)?.verdict == .needsConfirmation else { return }
            decide(key: key, verdict: .locked)
        case UNNotificationDefaultActionIdentifier:
            requestReview()
        default:
            break
        }
    }

    private static func notificationIdentifier(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func removeDeliveredNotification(for key: String) {
        let identifier = Self.notificationIdentifier(for: key)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    // MARK: - 落盘

    private static var cacheURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacTelemetryHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("window-title-judgments.json")
    }

    private static func loadCache() -> WindowTitleJudgmentCache {
        guard let data = try? Data(contentsOf: cacheURL) else { return WindowTitleJudgmentCache() }
        return WindowTitleJudgmentCache.decoded(from: data)
    }

    /**
     * 同步写。
     *
     * 这份文件最多五百条、不到一百 KB，主线程上写一次的代价可以忽略；而丢进
     * 后台任务的话，「拍板」紧跟着「删除」的两次原子写可能反序落地，盘上留下
     * 的是先写的那一份。缓存的正确性比这点耗时值钱。
     */
    private func persist() {
        guard let data = try? cache.encoded() else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
}

/**
 * 通知回调的落点。
 *
 * 单独一个 NSObject 而不是让 AppDelegate 兼任：delegate 方法是 nonisolated 的，
 * 挂在 @MainActor 的类型上会一路报隔离错误。这里先把要用的两个字符串取出来，
 * 再跳回主 actor —— `UNNotificationResponse` 本身不是 Sendable。
 */
private final class WindowTitleNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let judge: WindowTitleJudge

    init(judge: WindowTitleJudge) {
        self.judge = judge
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let key = response.notification.request.content.userInfo["cacheKey"] as? String
        completionHandler()
        guard let key else { return }
        Task { @MainActor [judge] in judge.handleNotificationAction(action, key: key) }
    }

    /// Hub 自己在前台时也要弹出来 —— 待确认的标题正是用户此刻在看的那个窗口。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
