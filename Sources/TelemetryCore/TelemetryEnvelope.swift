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
    /// 这一封带的 coding 模块（键见 `CodingModule`）。用量来自本机账本，活动和五分钟桶
    /// 来自每分钟的会话扫描；套餐与限额不在这里，由容器里的上报器走 /api/ingest/agents。
    let coding: [CodingModule: JSONValue]
    let includeDesktop: Bool
    let includeAppleMusic: Bool

    private enum CodingKeys: String, CodingKey {
        case chargingDevices, desktop, appleMusic, appleMusicCredentials, timezone
        case codingUsage, codingActivity, codingTokenBuckets
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(chargingDevices, forKey: .chargingDevices)
        if includeDesktop { try container.encode(desktop, forKey: .desktop) }
        if includeAppleMusic { try container.encode(appleMusic, forKey: .appleMusic) }
        try container.encodeIfPresent(appleMusicCredentials, forKey: .appleMusicCredentials)
        try container.encodeIfPresent(timezone, forKey: .timezone)
        try container.encodeIfPresent(coding[.usage], forKey: .codingUsage)
        try container.encodeIfPresent(coding[.activity], forKey: .codingActivity)
        try container.encodeIfPresent(coding[.buckets], forKey: .codingTokenBuckets)
    }
}

/**
 * 发往站点的唯一信封。
 *
 * 空 `modules` 表示纯心跳，由 `presence` 和 `heartbeatAt` 表达存活状态。
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

extension TelemetryEnvelope {
    /**
     * 组装一封信。
     *
     * `activeModules` 由调用方算好传进来 —— 它要读一圈开关和蓝牙连接状态，
     * 是这里唯一一处非纯的来源。把它挪成参数之后，组装本身只是把手上的载荷
     * 摆进固定的格子，跟主 actor 再无关系。
     */
    static func make(
        chargingDevices: ChargingDevicesPayload? = nil,
        desktop: DesktopActivitySnapshot? = nil,
        timezone: TimeZoneSnapshot? = nil,
        appleMusic: AppleMusicSnapshot? = nil,
        appleMusicCredentials: AppleMusicCredentialsPayload? = nil,
        coding: [CodingModule: JSONValue] = [:],
        includeDesktop: Bool,
        includeAppleMusic: Bool,
        activeModules: [String],
        now: Date,
        presence: String = "online"
    ) -> TelemetryEnvelope {
        TelemetryEnvelope(
            heartbeatAt: Int64(now.timeIntervalSince1970 * 1_000),
            activeModules: activeModules,
            modules: TelemetryModulesPayload(
                chargingDevices: chargingDevices,
                desktop: desktop,
                appleMusic: appleMusic,
                appleMusicCredentials: appleMusicCredentials,
                timezone: timezone,
                coding: coding,
                includeDesktop: includeDesktop,
                includeAppleMusic: includeAppleMusic
            ),
            presence: presence
        )
    }
}

struct TelemetryIngestResponse: Decodable {
    /// 回执里一条拒收：哪个模块、哪条校验没过
    struct Rejection: Decodable, Equatable, Sendable {
        let module: String
        let error: String
    }

    struct Result: Decodable {
        let desktopIconAvailable: Bool?
        let chargerCoverIconAvailable: Bool?
        /// 信封里站点不认识的模块名，原样回来
        var ignored: [String]? = nil
        /// 校验不过、站点只丢了它自己的 coding 模块（其余模块照常收下）
        var rejected: [Rejection]? = nil

        /// 站点没收下这一格的原因；收下了是 nil
        func refusal(of module: String) -> String? {
            if let rejection = rejected?.first(where: { $0.module == module }) {
                return "站点拒收：\(rejection.error)"
            }
            if ignored?.contains(module) == true { return "站点不认识这个模块，没有收下" }
            return nil
        }
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
    /// 某个模块校验失败会看起来像信封改坏了。
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
