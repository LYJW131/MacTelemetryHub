import SwiftUI

@main
struct MacTelemetryHubApp: App {
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
    @ObservedObject private var bluetooth: BluetoothService
    /// 单独订阅：ServiceController 是 ObservableObject，但它内部这个 monitor 的
    /// @Published 不会冒泡上来，挂在 service 下面读的话菜单里会是一份旧值。
    @ObservedObject private var desktopActivity: DesktopActivityMonitor
    @Environment(\.openWindow) private var openWindow

    init(service: ServiceController) {
        self.service = service
        bluetooth = service.chargerLink
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
        Text(bluetooth.phase.label)
        if let power = bluetooth.chargerStateForDisplay.totalOutputPowerW {
            Text(String(format: "总输出 %.2f W", power))
        }
        Divider()
        Button("打开控制面板", systemImage: "rectangle.inset.filled") {
            openWindow(id: "dashboard")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        SettingsLink {
            Label("设置", systemImage: "gearshape")
        }
        if service.settings.chargerModuleEnabled {
            Button("断开充电器", systemImage: "bolt.slash") { bluetooth.disconnect() }
                .disabled(!bluetooth.isConnected)
            Button("重连充电器", systemImage: "arrow.clockwise") { bluetooth.reconnect() }
        }
        Divider()
        Button("退出") {
            service.stop()
            NSApplication.shared.terminate(nil)
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
