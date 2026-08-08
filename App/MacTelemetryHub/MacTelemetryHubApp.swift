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
    @Environment(\.openWindow) private var openWindow

    init(service: ServiceController) {
        self.service = service
        bluetooth = service.bluetooth
    }

    var body: some View {
        Text("Mac Telemetry Hub")
        Text(bluetooth.phase.label)
        if let power = bluetooth.state.totalOutputPowerW {
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
}
