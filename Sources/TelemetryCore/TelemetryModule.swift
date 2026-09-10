import Foundation

enum TelemetryModule: String, CaseIterable, Hashable, Sendable {
    case desktop
    case appleMusic
    case charger
    case powerBank
    case timezone
    case vibeCoding
    case vibeCodingYear

    var displayName: String {
        switch self {
        case .desktop: "前台应用"
        case .appleMusic: "Apple Music"
        case .charger: "充电头"
        case .powerBank: "充电宝"
        case .timezone: "Mac 时区"
        case .vibeCoding: "Vibe Coding"
        case .vibeCodingYear: "年度用量"
        }
    }
}
