import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import Security

@MainActor
final class DesktopActivityMonitor: ObservableObject {
    @Published private(set) var snapshot: DesktopActivitySnapshot?
    /**
     * 此刻读到的窗口标题，已归一化。
     *
     * 这是**本机**那一份：锁定、待确认、判断中的标题在自己的屏幕上照样看得见，
     * 只是进不了信封。能进信封的是 `reportableWindowTitle`，由 `windowTitleStatus`
     * 一处决定 —— 界面和快照别各判一遍。
     */
    @Published private(set) var windowTitle: String?
    /// 这条标题停在判断流程的哪一步。仪表盘、菜单栏、设置页都读它。
    @Published private(set) var windowTitleStatus: WindowTitleStatus = .none
    /**
     * 落在这一档的理由，比如「政治敏感」。没有可说的就是 nil。
     *
     * 从判断缓存里取，所以它只在锁定和待确认两档上有值。放在这里而不是让
     * 每个界面自己去查缓存：`onVerdict` 之后本来就要重采一次，理由跟着状态
     * 一起更新，三处界面看到的是同一份。
     */
    @Published private(set) var windowTitleReason: String?
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
    /**
     * 标题的三档规则、缓存和通知都归它。
     *
     * monitor 只问一个同步问题「这条标题现在算什么」，不等判断 —— 应用名的
     * 上报一秒都不该被它挡住。判断回来之后 judge 叫一声，
     * ServiceController 让这里重采一次。
     */
    weak var judge: WindowTitleJudge?
    /**
     * 兜底轮询间隔：5 秒。
     *
     * 同一个窗口内的标题变化（终端 cd、浏览器切标签）主要靠
     * `kAXTitleChangedNotification` —— 它挂在**焦点窗口元素**上，换窗口时由
     * `kAXFocusedWindowChangedNotification` 重挂。不发 AX 通知的应用（部分
     * Electron 壳）只能靠这条轮询，最坏迟 5 秒。
     *
     * 判断那侧的 2 秒稳定期是配着这个数定的：通知随叫随到，轮询最慢 5 秒，
     * 2 秒既盖得住连续敲命令带出的一串中间标题，又不会让「判断中」挂太久。
     */
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
        windowTitleStatus = .none
        windowTitleReason = nil
    }

    /// 判断放行之后才允许进信封的那一份。判断中、锁定、待确认、失败一律为 nil。
    var reportableWindowTitle: String? {
        windowTitleStatus.isReportable ? windowTitle : nil
    }

    /// 规则或判断结论变了，重采一次让快照跟上。
    func refreshAfterJudgment() {
        guard observer != nil || pollTask != nil else { return }
        capture()
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
            windowTitle: reportableWindowTitle,
            observedAt: Self.nowMilliseconds
        )
        // 标题必须进这个比较：判断是异步的，放行的结论回来时应用身份和图标
        // 一个都没变，不比标题的话这里直接 return，补发那一轮永远不会发生。
        let identityChanged =
            previous?.applicationName != next.applicationName ||
            previous?.bundleIdentifier != next.bundleIdentifier ||
            previous?.iconHash != next.iconHash ||
            previous?.windowTitle != next.windowTitle
        guard identityChanged else { return }
        snapshot = next
        onChange?()
    }

    /// 黑名单命中就连辅助功能元素都不读 —— 不读也就没什么可泄漏的。
    private func updateWindowTitleMonitoring(for app: NSRunningApplication) {
        guard judge?.isBlacklisted(app.bundleIdentifier) != true else {
            detachAccessibilityObserver()
            setWindowTitle(nil, status: .blacklisted)
            return
        }
        refreshWindowTitle(for: app)
        attachAccessibilityObserver(to: app)
    }

    private func refreshWindowTitle(for app: NSRunningApplication) {
        guard judge?.isBlacklisted(app.bundleIdentifier) != true else {
            setWindowTitle(nil, status: .blacklisted)
            return
        }
        let granted = AXIsProcessTrusted()
        if windowTitleAccessGranted != granted { windowTitleAccessGranted = granted }
        guard granted else {
            setWindowTitle(nil, status: .noAccess)
            return
        }

        let next = WindowTitleNormalizer.normalize(
            Self.windowTitle(forPID: app.processIdentifier),
            applicationNames: Self.applicationNames(of: app)
        )
        let status = judge?.resolve(
            applicationName: app.localizedName ?? "Unknown",
            bundleIdentifier: app.bundleIdentifier,
            normalizedTitle: next
        ) ?? .unavailable
        setWindowTitle(
            next,
            status: status,
            reason: judge?.reason(bundleIdentifier: app.bundleIdentifier, normalizedTitle: next)
        )
    }

    private func setWindowTitle(
        _ title: String?,
        status: WindowTitleStatus,
        reason: String? = nil
    ) {
        if windowTitle != title { windowTitle = title }
        if windowTitleStatus != status { windowTitleStatus = status }
        if windowTitleReason != reason { windowTitleReason = reason }
    }

    private func attachAccessibilityObserver(to app: NSRunningApplication) {
        guard judge?.isBlacklisted(app.bundleIdentifier) != true,
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

    /// 应用可能用来给标题署名的几个名字，交给归一化剥末尾那段；见 `WindowTitleNormalizer`。
    private static func applicationNames(of app: NSRunningApplication) -> [String] {
        var names: [String] = []
        if let name = app.localizedName { names.append(name) }
        if let url = app.bundleURL, let info = Bundle(url: url)?.infoDictionary {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = info[key] as? String { names.append(name) }
            }
        }
        return names
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
            guard monitor.judge?.isBlacklisted(app.bundleIdentifier) != true else {
                monitor.detachAccessibilityObserver()
                monitor.setWindowTitle(nil, status: .blacklisted)
                return
            }
            if focusedWindowChanged { monitor.refreshObservedWindow() }
            // 走整条 capture：标题进了快照，光刷新本机那一份的话补发不会发生。
            monitor.capture(app)
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
        let artist = item(3).nilIfEmpty
        let album = item(4).nilIfEmpty
        let queue = state == "stopped" ? nil : MusicPlayingQueue.read(
            currentTrackID: trackID,
            currentTitle: title,
            currentArtist: artist,
            currentAlbum: album
        )
        return AppleMusicSnapshot(
            state: state,
            title: title,
            artist: artist,
            album: album,
            trackID: trackID,
            positionMs: Int((Double(item(6)) ?? 0) * 1_000),
            durationMs: Int((Double(item(7)) ?? 0) * 1_000),
            repeatOne: item(9) == "one",
            observedAt: Int64(Date().timeIntervalSince1970 * 1_000),
            queue: queue
        )
    }

}


private enum TelemetryModuleError: LocalizedError {
    case appleMusic(String)

    var errorDescription: String? {
        switch self {
        case let .appleMusic(message): "Apple Music：\(message)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
