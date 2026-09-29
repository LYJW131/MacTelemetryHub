import ChargerTelemetryKit
import Foundation
import Testing

@testable import TelemetryCore

/**
 * 信封是发给 Cloudflare Worker 的线上契约：模块键名、字段名、`version`，
 * 以及 includeDesktop / includeAppleMusic 那两个显式 null 的语义。
 * 这些值改了就是协议改了，所以这里逐个钉死。
 */
struct TelemetryEnvelopeTests {
    private func envelope(
        chargingDevices: ChargingDevicesPayload? = nil,
        desktop: DesktopActivitySnapshot? = nil,
        appleMusic: AppleMusicSnapshot? = nil,
        appleMusicCredentials: AppleMusicCredentialsPayload? = nil,
        timezone: TimeZoneSnapshot? = nil,
        coding: [CodingModule: JSONValue] = [:],
        includeDesktop: Bool = false,
        includeAppleMusic: Bool = false,
        activeModules: [String] = [],
        presence: String = "online"
    ) -> TelemetryEnvelope {
        TelemetryEnvelope(
            heartbeatAt: 1_789_099_506_000,
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

    private func object(_ envelope: TelemetryEnvelope) throws -> [String: Any] {
        let data = try JSONCoding.encoder().encode(envelope)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// 一个模块都不带的信封就是一次纯心跳，靠 presence 和 heartbeatAt 起作用。
    @Test func emptyModulesIsAHeartbeat() throws {
        let json = try object(envelope(presence: "offline"))
        #expect(json["version"] as? Int == 4)
        #expect(json["heartbeatAt"] as? Int64 == 1_789_099_506_000)
        #expect(json["presence"] as? String == "offline")
        #expect((json["activeModules"] as? [String])?.isEmpty == true)
        let modules = try #require(json["modules"] as? [String: Any])
        #expect(modules.isEmpty)
        #expect(Set(json.keys) == ["version", "heartbeatAt", "activeModules", "modules", "presence"])
    }

    /// includeDesktop / includeAppleMusic 打开时必须发显式 null，否则网页会
    /// 一直保留上一次的前台应用和上一首歌。
    @Test func includeFlagsEmitExplicitNull() throws {
        let modules = try #require(
            try object(envelope(includeDesktop: true, includeAppleMusic: true))["modules"]
                as? [String: Any]
        )
        #expect(modules["desktop"] is NSNull)
        #expect(modules["appleMusic"] is NSNull)
        #expect(Set(modules.keys) == ["desktop", "appleMusic"])
    }

    /// 开关关着时那个键整个不出现 —— 和「发了个 null」是两件事。
    @Test func absentFlagsOmitTheKeyEntirely() throws {
        let modules = try #require(try object(envelope())["modules"] as? [String: Any])
        #expect(modules["desktop"] == nil)
        #expect(modules["appleMusic"] == nil)
    }

    @Test func moduleKeysMatchTheWireContract() throws {
        let desktop = DesktopActivitySnapshot(
            applicationName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            iconHash: "icon-hash",
            iconData: nil,
            iconObjectKey: "abc.png",
            windowTitle: "ReportDecision.swift — MacTelemetryHub",
            observedAt: 1_789_099_506_000
        )
        let json = try object(envelope(
            chargingDevices: ChargingDevicesPayload(devices: [
                ChargingDevicePayload(
                    id: "SN-1", kind: .charger, model: "A2687", connected: true,
                    updatedAt: nil, firmware: nil, ports: []
                ),
            ]),
            desktop: desktop,
            appleMusicCredentials: AppleMusicCredentialsPayload(musicUserToken: "mut"),
            timezone: TimeZoneSnapshot(
                identifier: "Asia/Shanghai", abbreviation: "GMT+8",
                secondsFromGMT: 28_800, observedAt: 1_789_099_506_000
            ),
            coding: [
                .usage: .object(["agents": .array([])]),
                .activity: .object(["collectedAt": .number(1_789_099_506_000), "agents": .array([])]),
                .buckets: .object(["windows": .array([])]),
            ],
            includeDesktop: true,
            activeModules: ["charger", "desktop", "timezone", "coding"]
        ))

        let modules = try #require(json["modules"] as? [String: Any])
        #expect(Set(modules.keys) == [
            "chargingDevices", "desktop", "appleMusicCredentials", "timezone",
            "codingUsage", "codingActivity", "codingTokenBuckets",
        ])
        let activity = try #require(modules["codingActivity"] as? [String: Any])
        #expect((activity["collectedAt"] as? NSNumber)?.int64Value == 1_789_099_506_000)
        let desktopJSON = try #require(modules["desktop"] as? [String: Any])
        #expect(Set(desktopJSON.keys) == [
            "applicationName", "bundleIdentifier", "iconHash", "iconObjectKey",
            "windowTitle", "observedAt",
        ])
        #expect(desktopJSON["windowTitle"] as? String == "ReportDecision.swift — MacTelemetryHub")
        // developer token 已经归后端，带上它的信封会被整封退回：这一格只能有 user token
        let credentialsJSON = try #require(modules["appleMusicCredentials"] as? [String: Any])
        #expect(Set(credentialsJSON.keys) == ["musicUserToken"])
        #expect(json["activeModules"] as? [String] == ["charger", "desktop", "timezone", "coding"])
    }

    /// coding 的三格与站点 shared/ingest/coding.ts 的 CODING_MODULES 同名；开关在 activeModules 里只有一个 `coding`
    @Test func codingModuleNamesMatchTheSite() {
        #expect(CodingModule.allCases.map(\.rawValue) == ["codingUsage", "codingActivity", "codingTokenBuckets"])
        #expect(TelemetryModule.coding.rawValue == "coding")
        #expect(TelemetryModule.allCases.map(\.rawValue) == ["desktop", "appleMusic", "charger", "powerBank", "timezone", "coding"])
    }

    /// 只带某几格的信封：没带的 coding 键整个不出现
    @Test func absentCodingModulesOmitTheirKeys() throws {
        let modules = try #require(
            try object(envelope(coding: [.activity: .object([:])]))["modules"] as? [String: Any]
        )
        #expect(Set(modules.keys) == ["codingActivity"])
    }

    /**
     * 202 回执里站点自己判下的两件事：`ignored` 不认识的模块名、`rejected` 校验不过只丢了自己的 coding 模块。
     * 旧站点的回执没有这两个键，照样解得开。
     */
    @Test func ingestReceiptCarriesIgnoredAndRejectedModules() throws {
        let body = #"""
        {"ok":true,"data":{"desktopIconAvailable":true,"ignored":["vibeCodingNow"],
          "rejected":[{"module":"codingUsage","error":"agents[0].days[1].totalTokens 小于四列之和"}]}}
        """#
        let result = try JSONDecoder().decode(TelemetryIngestResponse.self, from: Data(body.utf8)).data
        #expect(result.refusal(of: "codingUsage") == "站点拒收：agents[0].days[1].totalTokens 小于四列之和")
        #expect(result.refusal(of: "vibeCodingNow") == "站点不认识这个模块，没有收下")
        #expect(result.refusal(of: "codingActivity") == nil)
        let old = try JSONDecoder().decode(
            TelemetryIngestResponse.self, from: Data(#"{"ok":true,"data":{"desktopIconAvailable":true}}"#.utf8)
        ).data
        #expect(old.ignored == nil && old.rejected == nil)
        #expect(old.refusal(of: "codingUsage") == nil)
    }

    /// 黑名单命中时发的虚拟身份：真实应用的名字和图标一个都不进载荷。
    @Test func hiddenDesktopSnapshotCarriesNoRealIdentity() {
        let hidden = DesktopActivitySnapshot.hidden(observedAt: 42)
        #expect(hidden.bundleIdentifier == "com.liangyangjunwei.MacTelemetryHub.hidden")
        #expect(hidden.applicationName == "Hidden Application")
        #expect(hidden.iconHash == nil)
        #expect(hidden.iconData == nil)
        // 标题一个字都不带：连真实应用叫什么都没说，它更不该在这里。
        #expect(hidden.windowTitle == nil)
        #expect(hidden.observedAt == 42)
    }

    /// nil 的标题整个不出现在 JSON 里。缺省和 null 对站点是同一个意思。
    @Test func desktopPayloadOmitsAbsentWindowTitle() throws {
        let json = try object(envelope(
            desktop: DesktopActivitySnapshot.hidden(observedAt: 42),
            includeDesktop: true,
            activeModules: ["desktop"]
        ))
        let modules = try #require(json["modules"] as? [String: Any])
        let desktopJSON = try #require(modules["desktop"] as? [String: Any])
        #expect(desktopJSON["windowTitle"] == nil)
    }

    /// 待传字节只在本机流转，`withIconData(nil, …)` 是发出去之前那一步。
    @Test func withIconDataReplacesBytesAndKey() {
        let snapshot = DesktopActivitySnapshot(
            applicationName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode",
            iconHash: "h", iconData: Data([1, 2]), iconObjectKey: nil,
            windowTitle: "已放行的标题", observedAt: 7
        )
        let stripped = snapshot.withIconData(nil, iconObjectKey: "h.png")
        #expect(stripped.iconData == nil)
        // 图标那一步不该顺手把判断放行的标题抹掉
        #expect(stripped.windowTitle == "已放行的标题")
        #expect(stripped.iconObjectKey == "h.png")
        #expect(stripped.iconHash == "h")
        #expect(stripped.observedAt == 7)
    }

    /// 站点 4xx 的正文是 `{ ok: false, error: "…" }`，只显示状态码会看不出真因。
    @Test func ingestErrorDetailPrefersTheJSONErrorField() {
        #expect(ReporterError.ingestErrorDetail(Data(#"{"ok":false,"error":" desktop 模块缺少 applicationName "}"#.utf8))
            == "desktop 模块缺少 applicationName")
        #expect(ReporterError.ingestErrorDetail(Data("  plain text  ".utf8)) == "plain text")
        #expect(ReporterError.ingestErrorDetail(Data()) == nil)
        #expect(ReporterError.ingestErrorDetail(Data(#"{"ok":false,"error":"  "}"#.utf8))
            == #"{"ok":false,"error":"  "}"#)
    }
}
