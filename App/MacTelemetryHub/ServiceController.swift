import AppKit
import Foundation

private struct ChargerUploadSignature: Equatable {
    let connected: Bool
    let totalOutputPowerW: Double?
    let device: StatusDevicePayload
    let ports: [String: StatusPortPayload]

    init(_ payload: StatusPayload) {
        connected = payload.connected
        totalOutputPowerW = payload.totalOutputPowerW
        device = payload.device
        ports = payload.ports
    }
}

private struct DesktopUploadSignature: Equatable {
    let applicationName: String
    let bundleIdentifier: String?
    let iconData: Data?

    init(_ snapshot: DesktopActivitySnapshot) {
        applicationName = snapshot.applicationName
        bundleIdentifier = snapshot.bundleIdentifier
        iconData = snapshot.iconData
    }
}

/// 播放进度刻意不进签名：播放时它每次采集都在变，会让「有变化才发」退化成定时轮询。
/// 网页拿 positionMs + observedAt 自己插值，进度条不需要上报器喂。
/// 拖动进度条这类跳变由 `AppleMusicPositionAnchor` 单独识别。
private struct AppleMusicUploadSignature: Equatable {
    let state: String
    let title: String?
    let artist: String?
    let album: String?
    let trackID: String?
    let artworkData: Data?
    let durationMs: Int
    /// 切换循环模式要让网页知道，所以它进签名
    let repeatOne: Bool

    init(_ snapshot: AppleMusicSnapshot) {
        state = snapshot.state
        title = snapshot.title
        artist = snapshot.artist
        album = snapshot.album
        trackID = snapshot.trackID
        artworkData = snapshot.artworkData
        durationMs = snapshot.durationMs
        repeatOne = snapshot.repeatOne
    }
}

/// 上一次发出去的播放锚点。网页就是照这个往前推的，
/// 所以「要不要重新发」等价于「网页现在推出来的值还准不准」。
private struct AppleMusicPositionAnchor {
    let state: String
    let positionMs: Int
    let observedAt: Int64

    init(_ snapshot: AppleMusicSnapshot) {
        state = snapshot.state
        positionMs = snapshot.positionMs
        observedAt = snapshot.observedAt
    }

    /// 网页在 `observedAt` 这一刻会显示的进度
    func predicted(at observedAt: Int64) -> Int {
        guard state == "playing" else { return positionMs }
        return positionMs + Int(max(0, observedAt - self.observedAt))
    }
}

@MainActor
final class ServiceController: ObservableObject {
    let settings: AppSettings
    let bluetooth: BluetoothService
    let desktopActivity = DesktopActivityMonitor()
    let appleMusic = AppleMusicMonitor()
    let ccusage = CcusageMonitor()
    lazy private(set) var httpServer = LocalHTTPServer { [weak self] request in
        guard let self else { return .text("Unavailable\n", status: 503, reason: "Service Unavailable") }
        return await self.route(request)
    }

    @Published private(set) var reporterLastSuccess: Date?
    @Published private(set) var reporterLastError: String?

    private var reporterTask: Task<Void, Never>?
    private var lastPostedCcusageAt: Date?
    private var lastPostedCharger: ChargerUploadSignature?
    private var lastPostedDesktop: DesktopUploadSignature?
    private var lastPostedAppleMusic: AppleMusicUploadSignature?
    private var lastPostedMusicAnchor: AppleMusicPositionAnchor?
    private var lastHeartbeatAt: Date?
    private var started = false

    /// 事件驱动的模块用它把上报循环提前叫醒，不必干等到下一个周期
    private var wakeContinuation: CheckedContinuation<Void, Never>?
    /// 事件发生在循环正忙的时候，等待还没开始 —— 记下来，下次别睡
    private var pendingWake = false
    private var desktopSettleTask: Task<Void, Never>?

    /// 循环的常规周期。前台应用和音乐都会提前叫醒它，所以这个只用来照顾
    /// 没有事件源的活：充电器采样、30 秒心跳、ccusage 的刷新间隔检查。
    private static let tickInterval = Duration.seconds(5)

    /**
     * 前台应用的防抖窗口。
     *
     * 每收到一次激活通知就重新计时，所以连续 Cmd-Tab 只会在最后停下来的那个
     * 应用上触发一次上报 —— 路过的应用停留远不到这个时长。
     * 从前这个防抖是 2 秒采样「顺便」带来的，把延迟和防抖强度焊死成了同一个
     * 数字；拆开之后延迟降到这个量级，而防抖强度可以单独调。
     */
    private static let desktopSettleDelay = Duration.milliseconds(400)

    /// 进度偏离预测多少才算被拖过。留 2.5 秒，既不会把采样抖动当 seek，
    /// 也接得住真的拖动。
    private static let musicSeekToleranceMs = 2_500

    init() {
        let settings = AppSettings()
        self.settings = settings
        bluetooth = BluetoothService(settings: settings)
    }

    deinit {
        reporterTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        configureModules()
        httpServer.start(port: settings.httpPort)
        restartReporter()
    }

    func stop() {
        reporterTask?.cancel()
        // 循环可能正挂在 waitForNextTick 上，叫醒它才能立刻看到 cancel 并退出
        wakeReporter()
        reporterTask = nil
        desktopSettleTask?.cancel()
        desktopSettleTask = nil
        desktopActivity.stop()
        appleMusic.stop()
        ccusage.stop()
        httpServer.stop()
        bluetooth.shutdown()
    }

    func applySettings() throws {
        let oldPort = httpServer.listeningURL?.port
        try settings.save()
        if oldPort != settings.httpPort { httpServer.start(port: settings.httpPort) }
        configureModules()
        restartReporter()
    }

    var statusPayload: StatusPayload {
        StatusPayload(connected: bluetooth.isConnected, state: bluetooth.state)
    }

    private func wakeReporter() {
        if let continuation = wakeContinuation {
            wakeContinuation = nil
            continuation.resume()
        } else {
            pendingWake = true
        }
    }

    /// 等到下一个周期，或者被事件提前叫醒 —— 谁先来算谁
    private func waitForNextTick() async {
        if pendingWake {
            pendingWake = false
            return
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: Self.tickInterval)
            // 被 cancel 说明已经有事件把循环叫醒了，别再多放行一次
            guard !Task.isCancelled else { return }
            self?.wakeReporter()
        }
        await withCheckedContinuation { continuation in
            wakeContinuation = continuation
        }
        timer.cancel()
    }

    private func configureModules() {
        if settings.chargerModuleEnabled {
            bluetooth.start()
            bluetooth.reconnect()
        } else {
            bluetooth.disconnect()
        }

        if settings.desktopModuleEnabled {
            // 每次激活都重排，连续 Cmd-Tab 只在最后停下的那个应用上叫醒一次
            desktopActivity.onChange = { [weak self] in
                guard let self else { return }
                desktopSettleTask?.cancel()
                desktopSettleTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.desktopSettleDelay)
                    guard !Task.isCancelled else { return }
                    self?.wakeReporter()
                }
            }
            desktopActivity.start()
        } else {
            desktopActivity.onChange = nil
            desktopSettleTask?.cancel()
            desktopSettleTask = nil
            desktopActivity.stop()
        }

        if settings.appleMusicModuleEnabled {
            // 音乐不用防抖：playerInfo 的竞态已经由 monitor 内部那次确认读消掉了
            appleMusic.onChange = { [weak self] in self?.wakeReporter() }
            appleMusic.start()
        } else {
            appleMusic.onChange = nil
            appleMusic.stop()
        }
        if !settings.ccusageModuleEnabled { ccusage.stop() }
    }

    private func restartReporter() {
        reporterTask?.cancel()
        // 旧循环可能还挂在等待上，先放行让它认领 cancel 并退出
        wakeReporter()
        reporterTask = nil
        // 上一轮遗留的唤醒标记不能带进新循环，否则第一圈会白转一次
        pendingWake = false
        reporterLastError = nil
        lastPostedCcusageAt = nil
        lastPostedCharger = nil
        lastPostedDesktop = nil
        lastPostedAppleMusic = nil
        lastPostedMusicAnchor = nil
        lastHeartbeatAt = nil
        let url = settings.postEnabled ? URL(string: settings.postURL) : nil
        let interval = settings.postInterval
        let timeout = settings.postTimeout
        reporterTask = Task { [weak self] in
            guard let self else { return }
            var nextPostAt = Date.distantPast
            /// 上报失败后的退避截止时刻，只用来挡住即时上报的绕行
            var backoffUntil = Date.distantPast
            while !Task.isCancelled {
                do {
                    // 前台应用和 Apple Music 都不在这里采集：前者由 NSWorkspace
                    // 的激活通知驱动，后者由 Music.app 的 playerInfo 跨进程通知驱动，
                    // 各自带一个兜底轮询。循环只管每 2 秒采样一次它们留下的 snapshot。
                    if settings.ccusageModuleEnabled {
                        await ccusage.refreshIfNeeded(
                            nodePath: settings.nodePath,
                            cliPath: settings.ccusageCLIPath,
                            interval: settings.ccusageRefreshInterval
                        )
                    }

                    // 变化判断全是本地计算，每圈都做；nextPostAt 只管「什么时候允许发」。
                    let charger = settings.chargerModuleEnabled && statusPayload.updatedAt != nil
                        ? statusPayload
                        : nil
                    let chargerSignature = charger.map(ChargerUploadSignature.init)
                    let desktop = settings.desktopModuleEnabled ? desktopActivity.snapshot : nil
                    let desktopSignature = desktop.map(DesktopUploadSignature.init)
                    let music = settings.appleMusicModuleEnabled ? appleMusic.snapshot : nil
                    let musicSignature = music.map(AppleMusicUploadSignature.init)
                    let chargerChanged = chargerSignature != nil && chargerSignature != lastPostedCharger
                    let desktopChanged = desktopSignature != nil && desktopSignature != lastPostedDesktop
                    // 进度不参与变化判断，只在它偏离网页的预测值时才重新对锚点，
                    // 否则播放中每一轮都会「有变化」，按需上报就退化成了定时轮询。
                    // 单曲循环时 trackID 不变，靠进度跳回开头被这里认出来。
                    let musicSeeked = music.map {
                        guard let anchor = lastPostedMusicAnchor else { return true }
                        let drift = $0.positionMs - anchor.predicted(at: $0.observedAt)
                        return abs(drift) > Self.musicSeekToleranceMs
                    } ?? false
                    // snapshot 从有值变成 nil 时也要发送一次 null，避免网页保留旧歌曲。
                    let musicChanged = settings.appleMusicModuleEnabled &&
                        (musicSignature != lastPostedAppleMusic || musicSeeked)
                    let ccusageChanged: Bool
                    if settings.ccusageModuleEnabled, let refreshedAt = ccusage.lastSuccess {
                        ccusageChanged = lastPostedCcusageAt.map { refreshedAt > $0 } ?? true
                    } else {
                        ccusageChanged = false
                    }
                    let heartbeatDue = lastHeartbeatAt.map { Date().timeIntervalSince($0) >= 30 } ?? true
                    let anythingChanged =
                        chargerChanged || desktopChanged || musicChanged || ccusageChanged || heartbeatDue

                    // 播放/暂停、换歌、换前台应用是用户正盯着的事，不值得为它们等满节流窗口。
                    // 这些变化本来也会上报，即时化只是把等待砍掉，不增加请求总数；
                    // 而且同一个 envelope 会把此刻待发的充电器 / ccusage 一起捎走。
                    // 进度跳变也算紧急。单曲循环时曲目和状态都没变，只有进度
                    // 从结尾跳回开头 —— 不放行的话网页会把进度条钉在 100%，
                    // 一直等到下一个节流窗口（实测 postInterval=30 时要等 30 秒）。
                    // 拖动进度条同理。这不会变吵：seek 只在通知或兜底重读时才
                    // 被发现，而通知只在换歌/播放状态变化时来。
                    let musicUrgent = musicChanged && (
                        musicSeeked ||
                        music?.state != lastPostedAppleMusic?.state ||
                        music?.trackID != lastPostedAppleMusic?.trackID
                    )
                    // 只有换 App 才算紧急。窗口标题不算 —— 终端和浏览器的标题可能一直在动，
                    // 放它绕过闸门会把上报频率顶回 2 秒一次。
                    // 换 App 也不从 NSWorkspace 通知触发，而是等这圈自己采到：
                    // 2 秒采样天然滤掉 Cmd-Tab 路过的中间应用，不用另做防抖。
                    let desktopUrgent = desktopChanged && (
                        desktop?.bundleIdentifier != lastPostedDesktop?.bundleIdentifier ||
                        desktop?.applicationName != lastPostedDesktop?.applicationName
                    )
                    // 退避期内一律不放行。否则服务端挂掉时，未推进的 lastPosted 会让
                    // urgent 一直为真，即时上报就变成 2 秒一次的重试风暴。
                    let urgent = (musicUrgent || desktopUrgent) && Date() >= backoffUntil

                    if let url, anythingChanged, urgent || Date() >= nextPostAt {
                        let desktopPayload = desktop.map {
                            let shouldSendIcon =
                                $0.bundleIdentifier != lastPostedDesktop?.bundleIdentifier ||
                                $0.iconData != lastPostedDesktop?.iconData
                            return $0.withIconData(shouldSendIcon ? $0.iconData : nil)
                        }
                        let musicPayload = music.map {
                            // 进度更新不重复带封面；换歌时即使封面二进制相同也重新发送，
                            // 因为服务端以 track ID 决定能否复用旧封面。
                            let shouldSendArtwork =
                                $0.trackID != lastPostedAppleMusic?.trackID ||
                                $0.artworkData != lastPostedAppleMusic?.artworkData
                            return $0.withArtworkData(shouldSendArtwork ? $0.artworkData : nil)
                        }
                        let envelope = makeTelemetryEnvelope(
                            charger: chargerChanged ? charger : nil,
                            desktop: desktopChanged ? desktopPayload : nil,
                            appleMusic: musicChanged ? musicPayload : nil,
                            vibeCoding: ccusageChanged ? ccusage.uploadPayload : nil,
                            includeDesktop: desktopChanged,
                            includeAppleMusic: musicChanged
                        )
                        var request = URLRequest(url: url)
                        request.httpMethod = "POST"
                        request.httpBody = try JSONCoding.encoder().encode(envelope)
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.setValue("mac-telemetry-hub/2", forHTTPHeaderField: "User-Agent")
                        if !settings.telemetrySecret.isEmpty {
                            request.setValue("Bearer \(settings.telemetrySecret)", forHTTPHeaderField: "Authorization")
                        }
                        request.timeoutInterval = timeout
                        let (_, response) = try await URLSession.shared.data(for: request)
                        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                            throw ReporterError.httpStatus(response.statusCode)
                        }
                        reporterLastSuccess = Date()
                        reporterLastError = nil
                        lastHeartbeatAt = Date()
                        if chargerChanged { lastPostedCharger = chargerSignature }
                        if desktopChanged { lastPostedDesktop = desktopSignature }
                        if musicChanged {
                            lastPostedAppleMusic = musicSignature
                            lastPostedMusicAnchor = music.map(AppleMusicPositionAnchor.init)
                        }
                        if ccusageChanged { lastPostedCcusageAt = ccusage.lastSuccess }
                        backoffUntil = .distantPast
                        // 即时上报同样重置整个窗口，免得「刚提前发过一次、转头又到点发一次」
                        nextPostAt = Date().addingTimeInterval(interval)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    reporterLastError = error.localizedDescription
                    backoffUntil = Date().addingTimeInterval(min(interval, 10))
                    nextPostAt = backoffUntil
                }
                // 采集和发送解耦：前台应用和音乐由各自的通知驱动，变化时会把
                // 这里提前叫醒；没有事件时按 tickInterval 转一圈照顾充电器和心跳。
                // 远端 POST 仍按用户设置的 interval 节流。
                await waitForNextTick()
            }
        }
    }

    var telemetryEnvelope: TelemetryEnvelope {
        makeTelemetryEnvelope(
            charger: settings.chargerModuleEnabled && statusPayload.updatedAt != nil ? statusPayload : nil,
            desktop: settings.desktopModuleEnabled ? desktopActivity.snapshot : nil,
            appleMusic: settings.appleMusicModuleEnabled ? appleMusic.snapshot : nil,
            vibeCoding: settings.ccusageModuleEnabled ? ccusage.uploadPayload : nil,
            includeDesktop: settings.desktopModuleEnabled,
            includeAppleMusic: settings.appleMusicModuleEnabled
        )
    }

    private func makeTelemetryEnvelope(
        charger: StatusPayload?,
        desktop: DesktopActivitySnapshot?,
        appleMusic: AppleMusicSnapshot?,
        vibeCoding: JSONValue?,
        includeDesktop: Bool,
        includeAppleMusic: Bool
    ) -> TelemetryEnvelope {
        return TelemetryEnvelope(
            heartbeatAt: Int64(Date().timeIntervalSince1970 * 1_000),
            activeModules: activeModuleNames,
            modules: TelemetryModulesPayload(
                charger: charger,
                desktop: desktop,
                appleMusic: appleMusic,
                vibeCoding: vibeCoding,
                includeDesktop: includeDesktop,
                includeAppleMusic: includeAppleMusic
            )
        )
    }

    private var activeModuleNames: [String] {
        var names: [String] = []
        if settings.chargerModuleEnabled { names.append("charger") }
        if settings.desktopModuleEnabled { names.append("desktop") }
        if settings.appleMusicModuleEnabled { names.append("apple_music") }
        if settings.ccusageModuleEnabled { names.append("vibe_coding") }
        return names
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "OPTIONS" { return .text("") }
        switch (request.method, request.path) {
        case ("GET", "/"):
            if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
               let data = try? Data(contentsOf: url) {
                return HTTPResponse(status: 200, reason: "OK", contentType: "text/html; charset=utf-8", body: data)
            }
            return .text("Mac Telemetry Hub\n", contentType: "text/plain; charset=utf-8")
        case ("GET", "/status"):
            return encode(statusPayload)
        case ("GET", "/activity"):
            return encode(ActivityLocalPayload(
                desktop: desktopActivity.snapshot,
                appleMusic: appleMusic.snapshot
            ))
        case ("GET", "/telemetry"):
            return encode(telemetryEnvelope)
        case ("GET", "/health"):
            return encode(HealthPayload(
                ok: true,
                connected: bluetooth.isConnected,
                autoConnect: bluetooth.desiredConnection,
                lastError: bluetooth.lastError,
                updatedAt: bluetooth.state.updatedAt
            ))
        case ("GET", "/debug/status"):
            return encode(DebugPayload(
                connected: bluetooth.isConnected,
                autoConnect: bluetooth.desiredConnection,
                lastError: bluetooth.lastError,
                phase: bluetooth.phase.label,
                state: bluetooth.state
            ))
        case ("GET", "/ports"):
            return encode(statusPayload.ports)
        case ("GET", let path) where path.hasPrefix("/ports/"):
            let key = String(path.dropFirst("/ports/".count)).uppercased()
            guard let port = statusPayload.ports[key] else {
                return .text("{\"detail\":\"unknown port\"}", contentType: "application/json", status: 404, reason: "Not Found")
            }
            return encode(port)
        case ("GET", "/metrics"):
            return .text(metrics(), contentType: "text/plain; version=0.0.4; charset=utf-8")
        case ("POST", "/disconnect"):
            bluetooth.disconnect()
            return encode(ActionPayload(ok: true, connected: false, autoConnect: false, lastError: bluetooth.lastError))
        case ("POST", "/reconnect"):
            bluetooth.reconnect()
            return encode(ActionPayload(ok: true, connected: bluetooth.isConnected, autoConnect: true, lastError: bluetooth.lastError))
        default:
            return .text("{\"detail\":\"not found\"}", contentType: "application/json", status: 404, reason: "Not Found")
        }
    }

    private func encode<T: Encodable>(_ value: T) -> HTTPResponse {
        do { return .json(try JSONCoding.encoder().encode(value)) }
        catch { return .text("{\"detail\":\"encoding failed\"}", contentType: "application/json", status: 500, reason: "Internal Server Error") }
    }

    private func metrics() -> String {
        let payload = statusPayload
        var lines = [
            "# HELP a2687_connected Charger BLE session is live.",
            "# TYPE a2687_connected gauge",
            "a2687_connected \(payload.connected ? 1 : 0)",
            "# HELP a2687_total_output_power_watts Total output power across all ports.",
            "# TYPE a2687_total_output_power_watts gauge",
        ]
        if let total = payload.totalOutputPowerW { lines.append("a2687_total_output_power_watts \(total)") }
        for (field, unit, value) in [
            ("voltage", "volts", { (port: StatusPortPayload) in port.voltageV }),
            ("current", "amperes", { (port: StatusPortPayload) in port.currentA }),
            ("power", "watts", { (port: StatusPortPayload) in port.powerW }),
        ] as [(String, String, (StatusPortPayload) -> Double?)] {
            let metric = "a2687_port_\(field)_\(unit)"
            lines.append("# TYPE \(metric) gauge")
            for key in ["C1", "C2", "C3"] {
                if let port = payload.ports[key], let number = value(port) {
                    lines.append("\(metric){port=\"\(key)\"} \(number)")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private struct HealthPayload: Encodable {
    let ok: Bool
    let connected: Bool
    let autoConnect: Bool
    let lastError: String?
    let updatedAt: TimeInterval?
}

private struct DebugPayload: Encodable {
    let connected: Bool
    let autoConnect: Bool
    let lastError: String?
    let phase: String
    let state: ChargerState
}

private struct ActionPayload: Encodable {
    let ok: Bool
    let connected: Bool
    let autoConnect: Bool
    let lastError: String?
}

private struct ActivityLocalPayload: Encodable {
    let desktop: DesktopActivitySnapshot?
    let appleMusic: AppleMusicSnapshot?
}

private enum ReporterError: LocalizedError {
    case httpStatus(Int)
    var errorDescription: String? {
        switch self { case let .httpStatus(code): "POST 端点返回 HTTP \(code)" }
    }
}
