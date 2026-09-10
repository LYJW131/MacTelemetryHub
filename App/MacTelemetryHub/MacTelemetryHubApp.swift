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
        service.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
    @ObservedObject private var chargerLink: BluetoothService
    @ObservedObject private var powerBankLink: BluetoothService
    /// 单独订阅：ServiceController 是 ObservableObject，但它内部这个 monitor 的
    /// @Published 不会冒泡上来，挂在 service 下面读的话菜单里会是一份旧值。
    @ObservedObject private var desktopActivity: DesktopActivityMonitor
    @Environment(\.openWindow) private var openWindow

    init(service: ServiceController) {
        self.service = service
        chargerLink = service.chargerLink
        powerBankLink = service.powerBankLink
        desktopActivity = service.desktopActivity
    }

    var body: some View {
        Text("Mac Telemetry Hub")
        // 正在用的那个应用。菜单栏的菜单弹出来不会把本应用变成前台，所以这里
        // 读到的仍是用户真正在用的那个。
        if service.settings.desktopModuleEnabled {
            Label {
                Text(foregroundActivityLabel)
                    .lineLimit(1)
            } icon: {
                foregroundAppIcon
            }
        }
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

    @ViewBuilder
    private func chargingMenuStatus(_ link: BluetoothService) -> some View {
        if link.slot.isEnabled(service.settings) {
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
        if link.slot.isEnabled(service.settings) {
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
        return "\(appName) — \(title)"
    }
}
