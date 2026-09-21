import SwiftUI

/**
 * 面板共用的那几个数字。
 *
 * 卡片背景以前在七八处各写一遍，圆角和描边浓度就慢慢对不上了。收在这里，改一次
 * 全站一起变。
 */
enum PanelMetrics {
    /// 卡片圆角
    static let cornerRadius: CGFloat = 8
    /// 卡片描边浓度
    static let strokeOpacity: Double = 0.08
    /// 卡片内边距
    static let padding: CGFloat = 13
    /// 状态圆点直径
    static let statusDot: CGFloat = 7
    /// 遥测静默多久算「数据过期」。两台设备都是约 1 Hz 推流，15 秒远在抖动之外。
    static let staleThreshold: TimeInterval = 15
}

extension View {
    /// 卡片统一的底：控件底色、一圈细描边、圆角裁切。
    /// `stroke` 只给需要高亮的卡片（比如当前封面）用，默认那圈灰边。
    func panelBackground(stroke: Color? = nil, lineWidth: CGFloat = 1) -> some View {
        background(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius)
                    .stroke(
                        stroke ?? Color.primary.opacity(PanelMetrics.strokeOpacity),
                        lineWidth: lineWidth
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius))
    }
}

enum LocalHTTPStatusText {
    static func sentence(enabled: Bool, listening: Bool) -> String {
        if !enabled { return "本地 HTTP 已关闭" }
        return listening ? "本地 HTTP 正在监听" : "本地 HTTP 未启动"
    }
}

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
