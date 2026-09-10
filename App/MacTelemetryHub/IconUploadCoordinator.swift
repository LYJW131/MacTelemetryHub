import Foundation
import os

/**
 * 图标直传 R2 的唯一入口：谁已经确认在桶里、谁还有重试额度、谁正在飞。
 *
 * 桌面图标和充电头封面从前是两段并排的 resolver，各自 60 行，除了对象后缀、
 * 日志里那个字和成功之后要不要叫醒循环之外一模一样 —— 而它们共用同一份
 * `uploadedIconHashes`、同一条 LRU、同一份重试额度。共享状态被两处修改的结果
 * 就是改一处忘一处：曾经只在桌面那一侧加了「确认过期就重新 HEAD」，封面那边
 * 被手动清桶之后再也传不回去。
 *
 * 现在状态和流程都在这里，两处的差别缩到调用方传进来的那个 `onReady` 闭包。
 * 它们真的不一样，所以没有被合并：桌面要比对此刻的前台应用，封面要比对上一次
 * 发出去的那张封面。
 */
@MainActor
final class IconUploadCoordinator {
    /// 只影响日志里那个字。对象后缀由调用方按来源给，因为它是内容地址的一部分。
    enum Kind {
        case desktop
        case cover

        var label: String {
            switch self {
            case .desktop: "图标"
            case .cover: "封面"
            }
        }
    }

    /** 图标直传的失败只进过 reporterLastError；写进统一日志才能事后查 */
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "MacTelemetryHub",
        category: "desktop-icon"
    )
    private static let verificationInterval: TimeInterval = 5 * 60
    /// 防止长期运行、打开大量一次性应用时让图标缓存无限增长。
    private static let uploadedLimit = 64

    /// 这个上报会话里已经在 R2 确认存在的图标身份指纹。
    /// 桌面图标和充电头封面共用这一份记忆，所以名字里没有 desktop。
    private var uploadedHashes: Set<String> = []
    private var uploadedOrder: [String] = []
    /// 最近一次在 R2 确认存在的时间；过期后后台 HEAD 一次，接住手动清桶。
    private var verifiedAt: [String: Date] = [:]
    /// 图标直传的重试额度与退避，按身份哈希记。规则本身在 TelemetryCore，有单测。
    private var budget = IconUploadBudget()
    /// 同一枚图标在飞的那一次后台检查 / 直传。
    private var resolvers: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    /// 失败文案要露到界面上，但这里不该知道 @Published 长什么样。
    private let onError: (String) -> Void

    init(onError: @escaping (String) -> Void) {
        self.onError = onError
    }

    /// 已经确认在 R2 的对象键；没确认好就是 nil。纯读取，不发起解析。
    func objectKeyIfConfirmed(hash: String, data: Data, ext: String) -> String? {
        uploadedHashes.contains(hash) ? R2IconUploader.objectKey(for: data, ext: ext) : nil
    }

    func isConfirmed(_ hash: String) -> Bool { uploadedHashes.contains(hash) }
    func uploadAttempts(_ hash: String) -> Int { budget.attemptCount(hash) }
    func isResolving(_ hash: String) -> Bool { resolvers[hash] != nil }

    /// 桌面图标和充电头封面共用同一份「已确认在 R2」的记忆和同一条 LRU 淘汰。
    func remember(_ hash: String) {
        uploadedHashes.insert(hash)
        uploadedOrder.removeAll { $0 == hash }
        uploadedOrder.append(hash)
        if uploadedOrder.count > Self.uploadedLimit {
            let evicted = uploadedOrder.removeFirst()
            uploadedHashes.remove(evicted)
            verifiedAt.removeValue(forKey: evicted)
        }
    }

    func forget(_ hash: String) {
        uploadedHashes.remove(hash)
        uploadedOrder.removeAll { $0 == hash }
        verifiedAt.removeValue(forKey: hash)
    }

    func cancelAll() {
        for resolver in resolvers.values { resolver.task.cancel() }
        resolvers.removeAll(keepingCapacity: true)
    }

    /// 重开一轮上报会话：确认记忆、额度、在飞的解析全部清空。
    func reset() {
        uploadedHashes.removeAll(keepingCapacity: true)
        uploadedOrder.removeAll(keepingCapacity: true)
        budget.removeAll()
        verifiedAt.removeAll(keepingCapacity: true)
        cancelAll()
    }

    /**
     * 在后台把这枚图标弄到 R2 上：先 HEAD，对象还在就复用，被清掉就 PUT。
     *
     * 同一枚图标同时只有一次在飞，五分钟内不重复检查。失败最多试三次，且绝不
     * 靠反复 POST 遥测来驱动重试。
     *
     * `onReady` 只在这一次真的把对象弄好之后调用一次。调用方在里面比对「已经
     * 发出去的那份是不是还是当前这份」再决定要不要叫醒循环 —— 不比的话，用户
     * 早就切走了还把门闩清成 nil，会打成热循环。
     */
    func resolve(
        kind: Kind,
        hash: String,
        data: Data,
        ext: String,
        configuration: R2UploadConfiguration,
        timeout: TimeInterval,
        onReady: @escaping @MainActor () -> Void
    ) {
        guard budget.isAvailable(hash, now: Date()), resolvers[hash] == nil else { return }
        if uploadedHashes.contains(hash),
           let verifiedAt = verifiedAt[hash],
           Date().timeIntervalSince(verifiedAt) < Self.verificationInterval {
            return
        }

        let objectKey = R2IconUploader.objectKey(for: data, ext: ext)
        let resolverID = UUID()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.budget.isAvailable(hash, now: Date()) {
                do {
                    let exists = try await R2IconUploader.exists(
                        objectKey: objectKey,
                        configuration: configuration,
                        timeout: timeout
                    )
                    if !exists {
                        self.forget(hash)
                        try await R2IconUploader.upload(
                            data: data,
                            contentHash: R2IconUploader.contentHash(of: data),
                            objectKey: objectKey,
                            configuration: configuration,
                            timeout: timeout
                        )
                    }
                    guard !Task.isCancelled else { break }
                    self.budget.noteSuccess(hash)
                    self.verifiedAt[hash] = Date()
                    self.remember(hash)
                    onReady()
                    break
                } catch is CancellationError {
                    break
                } catch {
                    if Task.isCancelled { break }
                    let delay = self.noteFailure(hash, objectKey: objectKey, kind: kind, error: error)
                    try? await Task.sleep(for: delay)
                }
            }

            if self.resolvers[hash]?.id == resolverID {
                self.resolvers.removeValue(forKey: hash)
            }
        }
        resolvers[hash] = (resolverID, task)
    }

    /// 记一次直传失败并写日志，返回下一次尝试前该等多久。退避规则在额度里。
    private func noteFailure(
        _ hash: String,
        objectKey: String,
        kind: Kind,
        error: Error
    ) -> Duration {
        let (attempts, delay) = budget.noteFailure(hash, now: Date())
        onError("\(kind.label)上传失败：\(error.localizedDescription)")
        Self.logger.error(
            "\(kind.label, privacy: .public) \(objectKey, privacy: .public) 上传失败（第 \(attempts) 次）：\(error.localizedDescription, privacy: .public)"
        )
        return delay
    }
}
