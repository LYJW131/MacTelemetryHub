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
        vibeCodingUsage: JSONValue? = nil,
        vibeCodingNow: JSONValue? = nil,
        vibeCodingYear: JSONValue? = nil,
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
                vibeCodingUsage: vibeCodingUsage,
                vibeCodingNow: vibeCodingNow,
                vibeCodingYear: vibeCodingYear,
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
            vibeCodingUsage: .object(["totalCostUSD": .number(1.5)]),
            vibeCodingNow: .object(["active": .bool(true)]),
            vibeCodingYear: .object(["weeks": .array([])]),
            includeDesktop: true,
            activeModules: ["charger", "desktop", "timezone"]
        ))

        let modules = try #require(json["modules"] as? [String: Any])
        #expect(Set(modules.keys) == [
            "chargingDevices", "desktop", "appleMusicCredentials", "timezone",
            "vibeCodingUsage", "vibeCodingNow", "vibeCodingYear",
        ])
        let desktopJSON = try #require(modules["desktop"] as? [String: Any])
        #expect(Set(desktopJSON.keys) == [
            "applicationName", "bundleIdentifier", "iconHash", "iconObjectKey", "observedAt",
        ])
        // developer token 已经归后端，带上它的信封会被整封退回：这一格只能有 user token
        let credentialsJSON = try #require(modules["appleMusicCredentials"] as? [String: Any])
        #expect(Set(credentialsJSON.keys) == ["musicUserToken"])
        #expect(json["activeModules"] as? [String] == ["charger", "desktop", "timezone"])
    }

    /// 黑名单命中时发的虚拟身份：真实应用的名字和图标一个都不进载荷。
    @Test func hiddenDesktopSnapshotCarriesNoRealIdentity() {
        let hidden = DesktopActivitySnapshot.hidden(observedAt: 42)
        #expect(hidden.bundleIdentifier == "com.liangyangjunwei.MacTelemetryHub.hidden")
        #expect(hidden.applicationName == "Hidden Application")
        #expect(hidden.iconHash == nil)
        #expect(hidden.iconData == nil)
        #expect(hidden.observedAt == 42)
    }

    /// 待传字节只在本机流转，`withIconData(nil, …)` 是发出去之前那一步。
    @Test func withIconDataReplacesBytesAndKey() {
        let snapshot = DesktopActivitySnapshot(
            applicationName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode",
            iconHash: "h", iconData: Data([1, 2]), iconObjectKey: nil, observedAt: 7
        )
        let stripped = snapshot.withIconData(nil, iconObjectKey: "h.png")
        #expect(stripped.iconData == nil)
        #expect(stripped.iconObjectKey == "h.png")
        #expect(stripped.iconHash == "h")
        #expect(stripped.observedAt == 7)
    }

    /// 站点 4xx 的正文是 `{ ok: false, error: "…" }`，只显示状态码会看不出真因。
    @Test func ingestErrorDetailPrefersTheJSONErrorField() {
        #expect(ReporterError.ingestErrorDetail(Data(#"{"ok":false,"error":" 年度数据非法 "}"#.utf8))
            == "年度数据非法")
        #expect(ReporterError.ingestErrorDetail(Data("  plain text  ".utf8)) == "plain text")
        #expect(ReporterError.ingestErrorDetail(Data()) == nil)
        #expect(ReporterError.ingestErrorDetail(Data(#"{"ok":false,"error":"  "}"#.utf8))
            == #"{"ok":false,"error":"  "}"#)
    }
}
