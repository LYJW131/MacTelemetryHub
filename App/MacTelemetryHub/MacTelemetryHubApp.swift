import AppKit
import SwiftUI

/**
 * 关控制面板不能把上报器一起带走。
 *
 * SwiftUI 的 `Window` 算一个普通窗口，`MenuBarExtra` 不算。关掉面板以后系统
 * 以为一个窗口都不剩了，默认就把进程杀掉 —— 菜单栏图标跟着消失，看起来像
 * 上报器自己退出。登录项只在登录时拉起，不会在这里补救。
 */
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct MacTelemetryHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var service = ServiceController()

    var body: some Scene {
        Window("Mac Telemetry Hub", id: "dashboard") {
            DashboardView(service: service)
                .onAppear { service.start() }
        }
        .defaultSize(width: 940, height: 640)

        Settings {
            SettingsView(service: service)
        }
        .defaultSize(width: 860, height: 600)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarView(service: service)
        } label: {
            Image(systemName: service.reporterLastError == nil ? "wave.3.right.circle.fill" : "exclamationmark.arrow.triangle.2.circlepath")
        }
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
