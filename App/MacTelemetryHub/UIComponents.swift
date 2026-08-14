import SwiftUI

enum StatusBadgeStyle {
    case info, success, warning, error, neutral

    var tint: Color {
        switch self {
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        case .neutral: .secondary
        }
    }
}

struct StatusBadge: View {
    let text: String
    let style: StatusBadgeStyle

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(style.tint)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(style.tint)
        .background(Capsule().fill(style.tint.opacity(style == .success ? 0.14 : 0.11)))
        .overlay(Capsule().stroke(style.tint.opacity(0.24), lineWidth: 0.5))
    }
}

struct MetricCard<Trailing: View>: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption).foregroundStyle(tint)
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            trailing()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.15), lineWidth: 1))
    }
}

extension MetricCard where Trailing == EmptyView {
    init(title: String, value: String, icon: String, tint: Color) {
        self.init(title: title, value: value, icon: icon, tint: tint) { EmptyView() }
    }
}

/// 充电宝的单个端口。空闲端口只显示状态，不显示功率 —— 固件那个槽位是粘滞的，
/// 端口断开后仍留着上一次的读数，照原样画出来就是在报几分钟前的数。
struct PowerBankPortCard: View {
    let port: PowerBankPort

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(port.name).font(.headline)
                Spacer()
                if let direction = port.direction {
                    Label(direction == "in" ? "输入" : "输出",
                          systemImage: direction == "in" ? "arrow.down.circle" : "arrow.up.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(direction == "in" ? .green : .blue)
                }
            }
            if port.isActive {
                Text(String(format: "%.1f W", port.powerW ?? 0))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(String(format: "%.1f V · %.1f A", port.voltageV ?? 0, port.currentA ?? 0))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if port.isEnergized {
                Text("待机").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                Text(String(format: "%.1f V，无负载", port.voltageV ?? 0))
                    .font(.caption).foregroundStyle(.secondary)
            } else if port.attached {
                Text("已插线").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                Text("未协商供电").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("空闲").font(.title3.weight(.medium)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}
