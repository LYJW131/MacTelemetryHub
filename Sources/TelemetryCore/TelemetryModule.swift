import Foundation

enum TelemetryModule: String, CaseIterable, Hashable, Sendable {
    case desktop
    case appleMusic
    case charger
    case powerBank
    case timezone
    /// 一个开关管 coding 的三份载荷（`CodingModule`）：用量、活动、五分钟桶
    case coding

    var displayName: String {
        switch self {
        case .desktop: "前台应用"
        case .appleMusic: "Apple Music"
        case .charger: "充电头"
        case .powerBank: "充电宝"
        case .timezone: "Mac 时区"
        case .coding: "Vibe Coding"
        }
    }
}
