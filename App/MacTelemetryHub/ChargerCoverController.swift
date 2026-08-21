import AppKit
import CryptoKit
import Foundation

struct CoverUploadSource: Equatable, Sendable {
    let name: String
    let iconHash: String?
    let iconData: Data?
}

@MainActor
final class ChargerCoverController: ObservableObject {
    @Published private(set) var pictures: [AnkerScreensaverPicture] = []
    @Published private(set) var previews: [Int: NSImage] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isLoggingIn = false
    @Published private(set) var selectingID: Int?
    @Published private(set) var transferringID: Int?
    @Published private(set) var transferProgress: (Int, Int)?
    @Published private(set) var lastError: String?
    @Published private(set) var loginMessage: String?
    @Published private(set) var cloudOnlyIDs: Set<Int> = []

    private let settings: AppSettings
    private let chargerLink: BluetoothService
    private var lastSerial: String?
    private var previewTasks: [Int: Task<Void, Never>] = [:]
    private var jpegs: [Int: Data] = [:]
    private var onDeviceIDs: Set<Int> = []
    private var lastCoverIdentity: CoverIdentity?
    var onChange: (() -> Void)?

    private struct CoverIdentity: Equatable {
        let id: Int?
        let hash: String?
    }

    init(settings: AppSettings, chargerLink: BluetoothService) {
        self.settings = settings
        self.chargerLink = chargerLink
    }

    var currentPictureID: Int? { chargerLink.chargerState?.screensaverId }

    var currentPicture: AnkerScreensaverPicture? {
        guard let id = currentPictureID else { return nil }
        return pictures.first { $0.id == id }
    }

    /// 当前封面上报源。BLE 已经给了 screensaverId 就发；云端列表对上之后补名字和图。
    var coverUploadSource: CoverUploadSource? {
        if let picture = currentPicture {
            let name = picture.name.isEmpty ? "Cover \(picture.id)" : picture.name
            let jpeg = jpegs[picture.id]
            let hash = jpeg.map(Self.sha256Hex)
            return CoverUploadSource(name: name, iconHash: hash, iconData: jpeg)
        }
        guard let id = currentPictureID else { return nil }
        return CoverUploadSource(name: "Cover \(id)", iconHash: nil, iconData: nil)
    }

    func coverPayload(objectKey: String?) -> CoverPayload? {
        guard let source = coverUploadSource else { return nil }
        return CoverPayload(name: source.name, iconHash: source.iconHash, iconObjectKey: objectKey)
    }

    var canSelect: Bool {
        chargerLink.isConnected && !isLoading && selectingID == nil && transferringID == nil
    }

    func chargerStateDidChange() {
        let serial = chargerLink.chargerState?.device.serialNumber
        if let serial, serial != lastSerial, settings.hasValidAnkerToken, !isLoading {
            Task { await refresh(force: false) }
        }
        emitCoverIfChanged()
    }

    func loginAndStoreUserID() async throws {
        isLoggingIn = true
        lastError = nil
        loginMessage = nil
        defer { isLoggingIn = false }
        let session = try await AnkerCloudClient.login(
            account: settings.ankerAccount,
            password: settings.ankerPassword
        )
        settings.userID = session.userID
        settings.ankerAuthToken = session.authToken
        settings.ankerAuthExpiresAt = session.expiresAt
        try settings.persistAnkerAccount()
        loginMessage = "已登录，用户 ID 已写入钥匙串。"
        await refresh(force: true)
    }

    func refresh(force: Bool) async {
        guard settings.chargerModuleEnabled else { return }
        let serial = chargerLink.chargerState?.device.serialNumber?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !serial.isEmpty else {
            if force { lastError = AnkerCloudError.missingSerial.localizedDescription }
            return
        }
        if !force, serial == lastSerial, !pictures.isEmpty { return }
        guard let session = storedSession() else {
            if force { lastError = AnkerCloudError.notLoggedIn.localizedDescription }
            return
        }

        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let list = try await AnkerCloudClient.listScreensavers(serial: serial, session: session)
            pictures = list
            lastSerial = serial
            let live = Set(list.map(\.id))
            cloudOnlyIDs = cloudOnlyIDs.intersection(live)
            onDeviceIDs = onDeviceIDs.intersection(live)
            prefetchPreviews(list)
            emitCoverIfChanged()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func select(_ picture: AnkerScreensaverPicture) async {
        guard canSelect else {
            lastError = chargerLink.isConnected ? nil : "充电头未连接，无法切封面。"
            return
        }
        guard currentPictureID != picture.id else { return }
        selectingID = picture.id
        lastError = nil
        defer { selectingID = nil }
        do {
            let ack = try await chargerLink.selectScreensaver(
                pictureID: UInt32(picture.id),
                hashCode: picture.hashCode
            )
            if A2687Protocol.isCloudOnlySelectAck(ack) {
                cloudOnlyIDs.insert(picture.id)
                onDeviceIDs.remove(picture.id)
                try await pushPixels(picture)
                return
            }
            onDeviceIDs.insert(picture.id)
            cloudOnlyIDs.remove(picture.id)
            if await waitForCurrent(picture.id, seconds: 4) { return }
            // ACK 00 but E1 didn't move — still try a pixel push (same as 11 ACK).
            cloudOnlyIDs.insert(picture.id)
            try await pushPixels(picture)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func pushPixels(_ picture: AnkerScreensaverPicture) async throws {
        transferringID = picture.id
        transferProgress = (0, 0)
        defer {
            transferringID = nil
            transferProgress = nil
        }
        let jpeg = try await jpegData(for: picture)
        try await chargerLink.transferScreensaver(
            jpeg: jpeg,
            pictureID: UInt32(picture.id),
            hashCode: picture.hashCode
        ) { [weak self] done, total in
            self?.transferProgress = (done, total)
        }
        onDeviceIDs.insert(picture.id)
        cloudOnlyIDs.remove(picture.id)
        if await waitForCurrent(picture.id, seconds: 6) { return }
        lastError = "像素已传完，但充电头没有切到这张图。"
    }

    private func waitForCurrent(_ pictureID: Int, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if chargerLink.chargerState?.screensaverId == pictureID { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func jpegData(for picture: AnkerScreensaverPicture) async throws -> Data {
        if let cached = jpegs[picture.id], !cached.isEmpty { return cached }
        guard let url = picture.imageURL else {
            throw AnkerCloudError.invalidResponse
        }
        let data = try await AnkerCloudClient.imageData(from: url)
        jpegs[picture.id] = data
        if previews[picture.id] == nil, let image = NSImage(data: data) {
            previews[picture.id] = image
        }
        emitCoverIfChanged()
        return data
    }

    private func storedSession() -> AnkerCloudSession? {
        guard settings.hasValidAnkerToken, settings.userID.utf8.count == 40 else { return nil }
        return AnkerCloudSession(
            userID: settings.userID,
            authToken: settings.ankerAuthToken,
            expiresAt: settings.ankerAuthExpiresAt
        )
    }

    private func prefetchPreviews(_ list: [AnkerScreensaverPicture]) {
        let liveIDs = Set(list.map(\.id))
        previews = previews.filter { liveIDs.contains($0.key) }
        jpegs = jpegs.filter { liveIDs.contains($0.key) }
        previewTasks.values.forEach { $0.cancel() }
        previewTasks.removeAll()
        for picture in list {
            guard previews[picture.id] == nil, let url = picture.imageURL else { continue }
            previewTasks[picture.id] = Task { [weak self] in
                guard let self else { return }
                do {
                    let data = try await AnkerCloudClient.imageData(from: url)
                    guard !Task.isCancelled else { return }
                    jpegs[picture.id] = data
                    if let image = NSImage(data: data) {
                        previews[picture.id] = image
                    }
                    emitCoverIfChanged()
                } catch {
                    // Keep the tile; a missing JPEG is not a switch failure.
                }
            }
        }
    }

    private func emitCoverIfChanged() {
        let identity = CoverIdentity(
            id: currentPictureID,
            hash: currentPictureID.flatMap { jpegs[$0] }.map(Self.sha256Hex)
        )
        guard identity != lastCoverIdentity else { return }
        lastCoverIdentity = identity
        onChange?()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
