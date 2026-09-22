import Foundation

/**
 * 本机 HTTP 接口：状态查询和两条充电设备推流。
 *
 * 和远端上报是两件事 —— 这边只读此刻的内存状态，不发任何请求、不推进任何门闩。
 * 从前挤在 ServiceController 末尾，读起来像是上报循环的一部分。
 *
 * Swift 的 private 是文件级的，所以这里用到的几个成员在主文件里由 private 提到
 * internal：route、chargingSSE、streamEvent(for:)、icons，以及 ChargingSSEBroker
 * 本身。图标的三份交付状态从前是三个裸字段，现在走 IconUploadCoordinator 的
 * 三个只读方法。chargingStream 和 json 只在本文件里用，仍然是 private。
 */
extension ServiceController {
    func route(_ request: HTTPRequest) async -> HTTPHandlerResult {
        if request.method == "OPTIONS" { return json(EmptyObject()) }
        switch (request.method, request.path) {
        case ("GET", "/"):
            return json([
                "health": "/health",
                "charger": "/sse/charger",
                "powerBank": "/sse/powerbank",
                "appleMusicAuthorization": "/apple-music/authorization",
            ])
        case ("GET", "/apple-music/authorization"):
            // 只报状态，token 的值绝不出本机。给排查「后端为什么没拿到 user token」用
            return json(AppleMusicAuthorizationPayload(
                status: appleMusicAuthorization.statusDescription,
                authorized: appleMusicAuthorization.isAuthorized,
                hasUserToken: appleMusicAuthorization.hasUserToken,
                lastUploadAt: appleMusicCredentialsUploadAt.map { Int($0.timeIntervalSince1970 * 1000) },
                lastError: appleMusicCredentialsUploadError ?? appleMusicAuthorization.lastError
            ))
        case ("GET", "/health"):
            let desktop = desktopActivity.snapshot
            return json(HealthPayload(
                ok: true,
                reporter: .init(
                    postEnabled: settings.postEnabled,
                    lastSuccessAt: reporterLastSuccess.map { Int($0.timeIntervalSince1970 * 1000) },
                    lastError: reporterLastError,
                    r2Configured: settings.r2UploadConfiguration != nil
                ),
                desktopIcon: desktop.map { snapshot in
                    .init(
                        applicationName: snapshot.applicationName,
                        iconHash: snapshot.iconHash,
                        iconEncoded: snapshot.iconData != nil,
                        objectKeyConfirmed: snapshot.iconHash.map { icons.isConfirmed($0) } ?? false,
                        uploadAttempts: snapshot.iconHash.map { icons.uploadAttempts($0) } ?? 0,
                        resolving: snapshot.iconHash.map { icons.isResolving($0) } ?? false
                    )
                },
                windowTitle: .init(
                    status: desktopActivity.windowTitleStatus.rawValue,
                    // 「此刻有没有标题发出去」，不是「这一档准不准发」——判断中接力
                    // 上一条放行标题时，status 是 judging 而标题确实在信封里。
                    reportable: desktopActivity.reportableWindowTitle != nil,
                    title: desktopActivity.reportableWindowTitle
                ),
                charger: .init(
                    enabled: settings.chargerModuleEnabled,
                    connected: chargerLink.isConnected,
                    phase: chargerLink.phase.label,
                    lastError: chargerLink.lastError
                ),
                powerBank: .init(
                    enabled: settings.powerBankModuleEnabled,
                    connected: powerBankLink.isConnected,
                    phase: powerBankLink.phase.label,
                    lastError: powerBankLink.lastError
                )
            ))
        case ("GET", "/sse/charger"):
            return chargingStream(.charger)
        case ("GET", "/sse/powerbank"):
            return chargingStream(.powerBank)
        default:
            return json(["detail": "not found"], status: 404, reason: "Not Found")
        }
    }

    /**
     * 订阅一条充电设备的推流。
     *
     * 先把当前快照发出去，之后每一帧蓝牙遥测（约 1 Hz）再跟一帧。没有本地定时器，
     * 设备不推这边就不发。连上瞬间那一次也走这条路，因为断开之后没有帧再来。
     */
    private func chargingStream(_ slot: ChargingDeviceSlot) -> HTTPHandlerResult {
        .stream { [weak self] stream in
            guard let self, stream.isOpen else {
                stream.close()
                return
            }
            chargingSSE.attach(stream, slot: slot)
            chargingSSE.send(streamEvent(for: link(for: slot)), to: stream)
        }
    }

    private func json<T: Encodable>(
        _ value: T,
        status: Int = 200,
        reason: String = "OK"
    ) -> HTTPHandlerResult {
        do {
            return .response(.json(try JSONCoding.encoder().encode(value), status: status, reason: reason))
        } catch {
            return .response(.text(
                "{\"detail\":\"encoding failed\"}",
                contentType: "application/json",
                status: 500,
                reason: "Internal Server Error"
            ))
        }
    }
}

@MainActor
final class ChargingSSEBroker {
    private var streams: [ChargingDeviceSlot: [ObjectIdentifier: HTTPStream]] = [:]

    func attach(_ stream: HTTPStream, slot: ChargingDeviceSlot) {
        let id = ObjectIdentifier(stream)
        streams[slot, default: [:]][id] = stream
        let previous = stream.onClose
        stream.onClose = { [weak self] in
            previous?()
            self?.streams[slot]?[id] = nil
        }
    }

    func send(_ event: ChargingStreamEvent, to stream: HTTPStream) {
        guard let data = try? JSONCoding.encoder().encode(event) else { return }
        stream.send(json: data)
    }

    func publish(_ event: ChargingStreamEvent, slot: ChargingDeviceSlot) {
        guard let data = try? JSONCoding.encoder().encode(event) else { return }
        for stream in (streams[slot] ?? [:]).values where stream.isOpen {
            stream.send(json: data)
        }
    }

    func closeAll() {
        let open = streams.values.flatMap(\.values)
        streams.removeAll()
        for stream in open { stream.close() }
    }
}

