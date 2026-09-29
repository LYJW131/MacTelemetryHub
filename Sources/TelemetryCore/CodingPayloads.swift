import Foundation

/**
 * 信封里的三份 coding 模块，rawValue 就是 `modules` 里的键（站点 shared/ingest/coding.ts 的 CODING_MODULES）。
 *
 * 三份各判各的变化，规则是同一条（`shouldSend`）：
 * - 去掉采集时刻之后的内容变了，就发；
 * - 内容没变，但整份（含采集时刻）有更新、距上次发出也隔够了 `keepaliveInterval`，再发一次 ——
 *   站点靠采集时刻前进知道采集器还活着（活动报告超过 10 分钟没前进，Pulse 就把 agent 当未知；
 *   桶报告的 `to` 不前进，最近的桶落在覆盖范围外也是未知）；
 * - 站点拒收或不认识这一格（回执的 `rejected` / `ignored`）：门闩照样推进，之后只在内容再变时重发，
 *   不拿同一份去反复撞校验。
 */
enum CodingModule: String, CaseIterable, Hashable, Sendable {
    /// 本机各来源的完整日行、会话数、采集状态
    case usage = "codingUsage"
    /// 各 agent 最近一条用量事件的时刻与模型
    case activity = "codingActivity"
    /// Codex、Claude 滚动 24 小时的五分钟 token 桶
    case buckets = "codingTokenBuckets"

    /**
     * 内容没变时隔多久重发一次。
     *
     * 用量是 0：每一轮新采到的都发，采集时刻前进本身就是站点要的事实；它本来就十分钟、一小时
     * 才采一轮。活动和桶一分钟扫一次，内容不变时至少五分钟发一封，站点那边十分钟才判过期。
     */
    var keepaliveInterval: TimeInterval {
        switch self {
        case .usage: 0
        case .activity, .buckets: 300
        }
    }

    /// 去掉采集时刻之后的内容。它变了才算「内容变了」
    func content(of value: JSONValue) -> JSONValue {
        guard case var .object(object) = value else { return value }
        switch self {
        case .usage:
            // 每个 agent 的 collectedAt 每轮都前进，日行、状态、会话数才是内容
            guard case let .array(agents) = object["agents"] else { return value }
            object["agents"] = .array(agents.map { agent in
                guard case var .object(fields) = agent else { return agent }
                fields.removeValue(forKey: "collectedAt")
                return .object(fields)
            })
        case .activity:
            object.removeValue(forKey: "collectedAt")
        case .buckets:
            // 滚动窗口的起止和采集时刻每扫一次都变
            object.removeValue(forKey: "from")
            object.removeValue(forKey: "to")
            object.removeValue(forKey: "collectedAt")
        }
        return .object(object)
    }

    /// 这一份该不该发。`latch` 是上一次发出去的那一份，没发过就是 nil
    func shouldSend(_ payload: CodingPayload, after latch: CodingPayloadLatch?, now: Date) -> Bool {
        guard let latch else { return true }
        if payload.contentChangedAt > latch.contentChangedAt { return true }
        guard !latch.refused, payload.updatedAt > latch.updatedAt else { return false }
        return now.timeIntervalSince(latch.postedAt) >= keepaliveInterval
    }
}

/// 采集器手上的一份 coding 载荷：最新那一份，以及内容 / 整份各自上一次变化的时刻
struct CodingPayload: Equatable, Sendable {
    /// 最新一次采集的整份，发出去的就是它（带着最新的采集时刻）
    var value: JSONValue
    /// 去掉采集时刻后的内容上一次变化的时刻
    var contentChangedAt: Date
    /// 整份（含采集时刻）上一次变化的时刻
    var updatedAt: Date

    /// 采集器新拿到一份时算出的状态
    static func next(after previous: CodingPayload?, value: JSONValue, module: CodingModule, at now: Date) -> CodingPayload {
        guard let previous else { return CodingPayload(value: value, contentChangedAt: now, updatedAt: now) }
        guard value != previous.value else { return previous }
        let contentChanged = module.content(of: value) != module.content(of: previous.value)
        return CodingPayload(
            value: value,
            contentChangedAt: contentChanged ? now : previous.contentChangedAt,
            updatedAt: now
        )
    }
}

/// 一份 coding 载荷发出去的是哪一版
struct CodingPayloadLatch: Equatable, Sendable {
    var contentChangedAt: Date
    var updatedAt: Date
    var postedAt: Date
    /// 站点拒收或不认识这一格：之后只在内容再变时重发
    var refused: Bool
}
