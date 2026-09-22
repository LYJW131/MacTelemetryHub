import AppKit
import SwiftUI

/**
 * 关控制面板不能把上报器一起带走。
 *
 * SwiftUI 的 `Window` 算一个普通窗口，`MenuBarExtra` 不算。关掉面板以后系统
 * 以为一个窗口都不剩了，默认就把进程杀掉 —— 菜单栏图标跟着消失，看起来像
 * 上报器自己退出。登录项只在登录时拉起，不会在这里补救。
 */
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /**
     * 采集服务归 AppDelegate 持有。
     *
     * 以前是控制面板 `onAppear` 才 start()：登录自启拉起来时面板并不打开，采集要等
     * 到用户第一次点开窗口才真正开始。启动本来就该跟窗口无关。
     */
    let service = ServiceController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 先接上再 start()：start() 里就把通知 delegate 装好了，晚一步的话
        // 紧接着点进来的那一条没有落点。
        service.windowTitleJudge.onReviewRequested = { Self.openSettings() }
        service.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /**
     * 打开设置窗口。
     *
     * SwiftUI 到 macOS 15 都只给了 `SettingsLink` 这个视图，没有能在回调里调的
     * 接口，所以只能发 AppKit 那个选择器。`Settings` 场景装的就是它，发不出去
     * 也不算坏事 —— 前面已经把应用叫到前台了。跳到哪一页由
     * `WindowTitleJudge.reviewRequest` 说了算，设置页自己收。
     */
    private static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

@main
struct MacTelemetryHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Mac Telemetry Hub", id: "dashboard") {
            DashboardView(service: appDelegate.service)
        }
        .defaultSize(width: 940, height: 640)

        Settings {
            SettingsView(service: appDelegate.service)
        }
        .defaultSize(width: 860, height: 600)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarView(service: appDelegate.service)
        } label: {
            // 图标要跟着上报状态变，所以订阅收在这一小块里 —— App 的 body 自己
            // 不观察任何东西，直接在这里读 service 的话图标会一直停在启动那一帧。
            MenuBarLabel(service: appDelegate.service)
        }
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var service: ServiceController

    var body: some View {
        Image(systemName: service.reporterLastError == nil
            ? "wave.3.right.circle.fill"
            : "exclamationmark.arrow.triangle.2.circlepath")
    }
}

private struct MenuBarView: View {
    @ObservedObject var service: ServiceController
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var chargerLink: BluetoothService
    @ObservedObject private var powerBankLink: BluetoothService
    /// 单独订阅：ServiceController 是 ObservableObject，但它内部这个 monitor 的
    /// @Published 不会冒泡上来，挂在 service 下面读的话菜单里会是一份旧值。
    @ObservedObject private var desktopActivity: DesktopActivityMonitor
    /// 同理单独订阅：待确认的那几条要在菜单里当场能拍板，不然只能进设置页。
    @ObservedObject private var judge: WindowTitleJudge
    @Environment(\.openWindow) private var openWindow

    /// 菜单里最多列几条待确认。再多就该去设置页一口气处理了。
    private static let pendingLimit = 5
    /// 菜单项不认 `lineLimit`，长标题会把整个菜单撑宽，只能自己截。
    private static let pendingTitleLimit = 48

    init(service: ServiceController) {
        self.service = service
        settings = service.settings
        chargerLink = service.chargerLink
        powerBankLink = service.powerBankLink
        desktopActivity = service.desktopActivity
        judge = service.windowTitleJudge
    }

    var body: some View {
        Text("Mac Telemetry Hub")
        windowTitlePendingSection
        // 正在用的那个应用。菜单栏的菜单弹出来不会把本应用变成前台，所以这里
        // 读到的仍是用户真正在用的那个。
        if settings.desktopModuleEnabled {
            Label {
                Text(foregroundActivityLabel)
                    .lineLimit(1)
            } icon: {
                foregroundAppIcon
            }
        }
        windowTitleReportingToggle
        chargingMenuStatus(chargerLink)
        chargingMenuStatus(powerBankLink)
        // 上报断了要在菜单里看得见。菜单栏图标只换了个符号，说不出坏在哪。
        if let error = service.reporterLastError {
            Text("上报异常：\(error)")
                .lineLimit(2)
        }
        Divider()
        Button("打开控制面板", systemImage: "rectangle.inset.filled") {
            openWindow(id: "dashboard")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        SettingsLink {
            Label("设置", systemImage: "gearshape")
        }
        chargingMenuActions(chargerLink)
        chargingMenuActions(powerBankLink)
        Divider()
        Button("退出") {
            service.stop()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /**
     * 待确认的标题，摆在菜单最上面。
     *
     * 通知上只剩「公开」一个按钮，错过或者关掉之后总得有个地方补拍板；设置页
     * 要开窗口、切页，菜单栏这里点开图标就是两次点击的事。一条一个子菜单，
     * 平铺成「标题 + 两个按钮」的话五条就是十五行。
     */
    @ViewBuilder
    private var windowTitlePendingSection: some View {
        let pending = judge.awaitingConfirmation
        if !pending.isEmpty {
            Section("待确认标题") {
                ForEach(pending.prefix(Self.pendingLimit), id: \.key) { entry in
                    Menu(Self.pendingLabel(entry)) {
                        Button("公开") { judge.decide(key: entry.key, verdict: .published) }
                        Button("锁定") { judge.decide(key: entry.key, verdict: .locked) }
                    }
                }
                if pending.count > Self.pendingLimit {
                    Button("还有 \(pending.count - Self.pendingLimit) 条，去设置处理") {
                        judge.requestReview()
                    }
                }
            }
            Divider()
        }
    }

    private static func pendingLabel(_ entry: WindowTitleJudgmentEntry) -> String {
        let title = entry.title.count > pendingTitleLimit
            ? entry.title.prefix(pendingTitleLimit) + "…"
            : entry.title[...]
        return "\(entry.applicationName) — \(title)"
    }

    /**
     * 窗口标题的总开关，就摆在菜单里。
     *
     * 一键的意思是不开设置窗口：这里拨一下当场落盘、当场生效。绑定走
     * `service.setWindowTitleReporting` 而不是 `$settings.…` —— 后者会先改
     * @Published 再想办法补落盘，多出一个只存在半拍的状态源。
     */
    @ViewBuilder
    private var windowTitleReportingToggle: some View {
        if settings.desktopModuleEnabled {
            Toggle("上报窗口标题", isOn: Binding(
                get: { settings.windowTitleReportingEnabled },
                set: { service.setWindowTitleReporting($0) }
            ))
        }
    }

    @ViewBuilder
    private func chargingMenuStatus(_ link: BluetoothService) -> some View {
        if link.slot.isEnabled(settings) {
            Text("\(link.slot.displayName) · \(link.phase.label)")
            if let power = link.chargerState?.totalOutputPowerW {
                Text(String(format: "总输出 %.2f W", power))
            }
            if let percent = link.powerBankState?.batteryPercent {
                Text(String(format: "电量 %.1f%%", percent))
            }
        }
    }

    @ViewBuilder
    private func chargingMenuActions(_ link: BluetoothService) -> some View {
        if link.slot.isEnabled(settings) {
            // 判据跟控制面板保持一致：没连上就没什么可断的。desiredConnection 只是
            // 「想连」，链路正在重试时它也是 true，菜单里那一项就一直亮着。
            Button("断开\(link.slot.displayName)", systemImage: "bolt.slash") { link.disconnect() }
                .disabled(!link.isConnected)
            Button("重连\(link.slot.displayName)", systemImage: "arrow.clockwise") { link.reconnect() }
        }
    }

    /// 用采集时那份图标，跟上报出去的是同一张；没有就退回一个符号。
    @ViewBuilder
    private var foregroundAppIcon: some View {
        if let data = desktopActivity.snapshot?.iconData, let icon = NSImage(data: data) {
            Image(nsImage: icon)
        } else {
            Image(systemName: "macwindow")
        }
    }

    private var foregroundActivityLabel: String {
        let appName = desktopActivity.snapshot?.applicationName ?? "等待活动"
        guard let title = desktopActivity.windowTitle else { return appName }
        // 菜单里也要说出这条标题到底有没有公开出去。
        return "\(appName) — \(title)（\(desktopActivity.windowTitleStatus.displayName)）"
    }
}
