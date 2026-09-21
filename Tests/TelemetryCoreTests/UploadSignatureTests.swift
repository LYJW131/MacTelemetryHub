import ChargerTelemetryKit
import Foundation
import Testing

@testable import TelemetryCore

struct ChargingDevicesStructuralSignatureTests {
    private func port(
        active: Bool = true,
        attached: Bool? = true,
        powerW: Double? = 45,
        model: String? = "iPhone 17 Pro"
    ) -> DevicePortPayload {
        DevicePortPayload(
            name: "C1",
            active: active,
            direction: "out",
            voltageV: 9,
            currentA: powerW.map { $0 / 9 },
            powerW: powerW,
            attached: attached,
            cable: "5A",
            chargingInfo: "PD",
            attachedDevice: AttachedDevicePayload(model: model, vendor: "Apple")
        )
    }

    private func payload(
        port: DevicePortPayload,
        percent: Double? = 80,
        thermalLimited: Bool? = false,
        totalOutputW: Double? = 45
    ) -> ChargingDevicesPayload {
        ChargingDevicesPayload(devices: [
            ChargingDevicePayload(
                id: "SN-1",
                kind: .charger,
                model: "A2687",
                connected: true,
                updatedAt: 1_789_099_506,
                firmware: "1.0.0",
                totalOutputW: totalOutputW,
                battery: BatteryPayload(
                    percent: percent,
                    charging: true,
                    timeToFullMinutes: 30,
                    thermalLimited: thermalLimited
                ),
                ports: [port],
                cover: CoverPayload(name: "封面", iconHash: "hash-1", iconObjectKey: nil)
            ),
        ])
    }

    /// 功率、电压、电流、电量都是滚动读数，它们该走节流窗口而不是即时上报。
    @Test func rollingReadingsDoNotCountAsStructuralChange() {
        let before = ChargingDevicesStructuralSignature(payload(port: port(powerW: 45)))
        let after = ChargingDevicesStructuralSignature(
            payload(port: port(powerW: 12.5), percent: 79.2, totalOutputW: 12.5)
        )
        #expect(before == after)
    }

    @Test func unplugFlipsTheSignature() {
        let plugged = ChargingDevicesStructuralSignature(payload(port: port()))
        let unplugged = ChargingDevicesStructuralSignature(
            payload(port: port(active: false, attached: false, powerW: 0, model: nil))
        )
        #expect(plugged != unplugged)
    }

    /// 表里查不到名字的设备插上来时，`attached` 会翻，身份查不出也拦不住。
    @Test func swappingTheAttachedDeviceFlipsTheSignature() {
        let iphone = ChargingDevicesStructuralSignature(payload(port: port(model: "iPhone 17 Pro")))
        let macbook = ChargingDevicesStructuralSignature(payload(port: port(model: "MacBook Pro")))
        #expect(iphone != macbook)
    }

    @Test func thermalLimitAndCoverIdentityAreStructural() {
        let normal = ChargingDevicesStructuralSignature(payload(port: port()))
        let throttled = ChargingDevicesStructuralSignature(
            payload(port: port(), thermalLimited: true)
        )
        #expect(normal != throttled)
    }
}

struct DesktopAndTimeZoneSignatureTests {
    private func snapshot(
        name: String,
        iconHash: String?,
        observedAt: Int64,
        windowTitle: String? = nil
    ) -> DesktopActivitySnapshot {
        DesktopActivitySnapshot(
            applicationName: name,
            bundleIdentifier: "com.example.App",
            iconHash: iconHash,
            iconData: Data([1, 2, 3]),
            iconObjectKey: nil,
            windowTitle: windowTitle,
            observedAt: observedAt
        )
    }

    /// 采集时刻和待传字节都不进签名，否则每一轮采集都算「有变化」。
    @Test func desktopSignatureIgnoresObservedAt() {
        let first = DesktopUploadSignature(snapshot(name: "Xcode", iconHash: "h", observedAt: 1))
        let second = DesktopUploadSignature(snapshot(name: "Xcode", iconHash: "h", observedAt: 999))
        #expect(first == second)
        #expect(first != DesktopUploadSignature(snapshot(name: "Safari", iconHash: "h", observedAt: 1)))
        #expect(first != DesktopUploadSignature(snapshot(name: "Xcode", iconHash: nil, observedAt: 1)))
    }

    /// 标题进签名：判断放行后要靠它触发补发，锁回 nil 也要靠它撤下旧标题。
    @Test func desktopSignatureTracksWindowTitle() {
        let untitled = DesktopUploadSignature(snapshot(name: "Xcode", iconHash: "h", observedAt: 1))
        let titled = DesktopUploadSignature(
            snapshot(name: "Xcode", iconHash: "h", observedAt: 1, windowTitle: "A.swift")
        )
        let other = DesktopUploadSignature(
            snapshot(name: "Xcode", iconHash: "h", observedAt: 1, windowTitle: "B.swift")
        )
        #expect(untitled != titled)
        #expect(titled != other)
    }

    @Test func timeZoneSignatureIgnoresObservedAt() {
        let shanghai = TimeZoneSnapshot(
            identifier: "Asia/Shanghai", abbreviation: "GMT+8", secondsFromGMT: 28_800, observedAt: 1
        )
        let later = TimeZoneSnapshot(
            identifier: "Asia/Shanghai", abbreviation: "GMT+8", secondsFromGMT: 28_800, observedAt: 2
        )
        let tokyo = TimeZoneSnapshot(
            identifier: "Asia/Tokyo", abbreviation: "GMT+9", secondsFromGMT: 32_400, observedAt: 1
        )
        #expect(TimeZoneUploadSignature(shanghai) == TimeZoneUploadSignature(later))
        #expect(TimeZoneUploadSignature(shanghai) != TimeZoneUploadSignature(tokyo))
    }
}

struct AppleMusicSignatureTests {
    private func snapshot(
        state: String = "playing",
        trackID: String? = "t1",
        positionMs: Int = 10_000,
        repeatOne: Bool = false,
        observedAt: Int64 = 1_000,
        queueIndex: Int? = 0
    ) -> AppleMusicSnapshot {
        AppleMusicSnapshot(
            state: state,
            title: "歌名",
            artist: "艺人",
            album: "专辑",
            trackID: trackID,
            positionMs: positionMs,
            durationMs: 240_000,
            repeatOne: repeatOne,
            observedAt: observedAt,
            queue: AppleMusicQueueSnapshot(
                beta: true,
                source: "资料库",
                index: queueIndex,
                tracks: [AppleMusicQueueTrack(title: "歌名", artist: "艺人", album: "专辑", trackID: "t1")]
            )
        )
    }

    /// 进度不进签名 —— 进了的话「有变化才发」就退化成定时轮询。
    @Test func signatureIgnoresPlaybackPosition() {
        #expect(AppleMusicUploadSignature(snapshot(positionMs: 10_000))
            == AppleMusicUploadSignature(snapshot(positionMs: 90_000)))
    }

    @Test func signatureNoticesRepeatModeAndQueuePosition() {
        let base = AppleMusicUploadSignature(snapshot())
        #expect(base != AppleMusicUploadSignature(snapshot(repeatOne: true)))
        #expect(base != AppleMusicUploadSignature(snapshot(queueIndex: 3)))
        #expect(base != AppleMusicUploadSignature(snapshot(trackID: "t2")))
    }

    /// 网页照锚点往前推，所以锚点的预测值就是网页此刻显示的进度。
    @Test func anchorInterpolatesWhilePlayingAndHoldsWhilePaused() {
        let playing = AppleMusicPositionAnchor(snapshot(positionMs: 10_000, observedAt: 1_000))
        #expect(playing.predicted(at: 1_000) == 10_000)
        #expect(playing.predicted(at: 3_500) == 12_500)
        // 时钟倒退不该把进度也倒推回去
        #expect(playing.predicted(at: 500) == 10_000)

        let paused = AppleMusicPositionAnchor(
            snapshot(state: "paused", positionMs: 10_000, observedAt: 1_000)
        )
        #expect(paused.predicted(at: 99_000) == 10_000)
    }

    /// 2.5 秒容差：采样抖动不算 seek，真拖动算。判断本身在上报循环里，
    /// 这里钉的是它依赖的那条预测。
    @Test func anchorDriftSeparatesJitterFromSeek() {
        let anchor = AppleMusicPositionAnchor(snapshot(positionMs: 10_000, observedAt: 1_000))
        let jitter = 11_200 - anchor.predicted(at: 2_000)   // 预测 11_000
        let seeked = 60_000 - anchor.predicted(at: 2_000)
        #expect(abs(jitter) <= 2_500)
        #expect(abs(seeked) > 2_500)
    }
}
