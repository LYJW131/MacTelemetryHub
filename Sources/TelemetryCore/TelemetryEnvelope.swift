import Foundation

#if TELEMETRY_CORE_SPM
import ChargerTelemetryKit
#endif

struct TelemetryModulesPayload: Encodable, Sendable {
    let chargingDevices: ChargingDevicesPayload?
    let desktop: DesktopActivitySnapshot?
    let appleMusic: AppleMusicSnapshot?
    let appleMusicCredentials: AppleMusicCredentialsPayload?
    let timezone: TimeZoneSnapshot?
    /// 三份摘要来自同一历史账本；now 的会话元数据独立按分钟刷新。
    /// 套餐与限额由 NAS 走 /api/ingest/agents 上报。
    let vibeCodingUsage: JSONValue?
    let vibeCodingNow: JSONValue?
    let vibeCodingYear: JSONValue?
    let includeDesktop: Bool
    let includeAppleMusic: Bool

    private enum CodingKeys: String, CodingKey {
        case chargingDevices, desktop, appleMusic, appleMusicCredentials, timezone
        case vibeCodingUsage, vibeCodingNow, vibeCodingYear
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(chargingDevices, forKey: .chargingDevices)
        if includeDesktop { try container.encode(desktop, forKey: .desktop) }
        if includeAppleMusic { try container.encode(appleMusic, forKey: .appleMusic) }
        try container.encodeIfPresent(appleMusicCredentials, forKey: .appleMusicCredentials)
        try container.encodeIfPresent(timezone, forKey: .timezone)
        try container.encodeIfPresent(vibeCodingUsage, forKey: .vibeCodingUsage)
        try container.encodeIfPresent(vibeCodingNow, forKey: .vibeCodingNow)
        try container.encodeIfPresent(vibeCodingYear, forKey: .vibeCodingYear)
    }
}

/**
 * 发往站点的唯一信封。
 *
 * v4 把从前那个独立的 presence 端点并了进来：`modules` 里一个模块都没有的信封
 * 就是一次纯心跳，靠 `presence` 和 `heartbeatAt` 起作用。从前心跳走另一个 URL、
 * 另一套请求组装，「这台 Mac 还活着」这件事在两边各写了一遍。
 */
struct TelemetryEnvelope: Encodable, Sendable {
    let version = 4
    let heartbeatAt: Int64
    let activeModules: [String]
    let modules: TelemetryModulesPayload
    /**
     * 上报器自己声明的在线状态。
     *
     * 平时恒为 online —— 能发出这个包本身就说明在线。有意义的是 offline：
     * 退出、睡眠这类**优雅**离开时抢在断开前发一条，网页就不用等心跳超时。
     *
     * 但它取代不了超时判定：崩溃、断网、强制关机时上报器根本没机会发这一条，
     * 那些情况只能靠「多久没收到心跳」兜底。两者是互补的，不是二选一。
     */
    let presence: String
}

struct TelemetryIngestResponse: Decodable {
    struct Result: Decodable {
        let desktopIconAvailable: Bool?
        let chargerCoverIconAvailable: Bool?
    }

    let data: Result
}

enum ReporterError: LocalizedError {
    case httpStatus(Int, detail: String?)
    case invalidTelemetryResponse

    var errorDescription: String? {
        switch self {
        case let .httpStatus(code, detail):
            if let detail, !detail.isEmpty { return "POST 端点返回 HTTP \(code)：\(detail)" }
            return "POST 端点返回 HTTP \(code)"
        case .invalidTelemetryResponse:
            return "遥测端点响应缺少图标确认状态。"
        }
    }

    /// 站点 4xx 的 JSON 是 `{ ok: false, error: "…" }`。只显示状态码的话，
    /// 年度热力图校验失败会看起来像信封改坏了。
    static func ingestErrorDetail(_ data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            return error
        }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
