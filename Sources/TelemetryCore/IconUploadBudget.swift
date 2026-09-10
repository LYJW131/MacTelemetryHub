import Foundation

/**
 * 图标直传的重试额度与退避，按图标身份哈希记。
 *
 * 从前是散在 ServiceController 里的两个字典加两段算式。它是纯的：给它一个
 * `now`，它就能告诉你还能不能试、下一次该等多久 —— 所以搬出来单独测。
 */
struct IconUploadBudget {
    /// 连续失败到这个次数就不再试，避免打成热循环
    static let maxAttempts = 3
    /**
     * 三次都失败后隔多久允许再试。
     *
     * 从前用尽三次就到进程重启为止：三次之间又没有间隔，启动初期一次瞬时的
     * TLS 错误几毫秒内就把额度烧光，那个应用的图标从此在网页上消失，直到重启。
     * 实测 Chrome 就是这样丢的。现在失败之间退避，用尽后过了冷却再从头来。
     */
    static let retryCooldown: TimeInterval = 10 * 60

    private var attempts: [String: Int] = [:]
    /// 用尽三次的时刻，按 iconHash 记；过了冷却就清掉重来
    private var gaveUpAt: [String: Date] = [:]

    init() {}

    /// 这个图标已经连续失败了几次。健康接口用它做展示。
    func attemptCount(_ iconHash: String) -> Int { attempts[iconHash, default: 0] }

    /**
     * 这个图标还有没有重试额度。
     *
     * 额度用尽后不是永久放弃：过了冷却期就清零重来。放弃的时刻记在
     * `gaveUpAt`，没有记录说明从没用尽过。清零发生在这里，所以它是 mutating。
     */
    mutating func isAvailable(_ iconHash: String, now: Date) -> Bool {
        if attempts[iconHash, default: 0] < Self.maxAttempts { return true }
        guard let gaveUpAt = gaveUpAt[iconHash],
              now.timeIntervalSince(gaveUpAt) >= Self.retryCooldown else {
            return false
        }
        attempts[iconHash] = 0
        self.gaveUpAt.removeValue(forKey: iconHash)
        return true
    }

    /**
     * 记一次直传失败，返回累计次数和下一次尝试前该等多久。
     *
     * 退避 2s、4s、8s：瞬时的网络抖动（启动初期的 TLS 失败、切网）几秒内就过去，
     * 连着立刻重试等于把三次都撞在同一个故障上。
     */
    mutating func noteFailure(_ iconHash: String, now: Date) -> (attempts: Int, delay: Duration) {
        let count = attempts[iconHash, default: 0] + 1
        attempts[iconHash] = count
        if count >= Self.maxAttempts { gaveUpAt[iconHash] = now }
        return (count, .seconds(2 << (count - 1)))
    }

    /// 传成功了，额度归零。
    mutating func noteSuccess(_ iconHash: String) {
        attempts[iconHash] = 0
    }

    /// 重启上报会话时整份丢掉。
    mutating func removeAll() {
        attempts.removeAll(keepingCapacity: true)
        gaveUpAt.removeAll(keepingCapacity: true)
    }
}
