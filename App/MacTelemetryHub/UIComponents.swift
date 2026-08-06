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
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.15), lineWidth: 1))
    }
}

extension MetricCard where Trailing == EmptyView {
    init(title: String, value: String, icon: String, tint: Color) {
        self.init(title: title, value: value, icon: icon, tint: tint) { EmptyView() }
    }
}
