import Foundation

/**
 * 已经判过的标题。
 *
 * 键是 Bundle ID + 归一化标题：同一条标题在同一个应用里只问一次 Jev，
 * 之后切回去是本地查表。转动的圆点被归一化剥掉了，所以一个「正在下载
 * ⠋ 47%」的窗口在这里始终只占一条。
 *
 * 按 `lastSeenAt` 做 LRU，上限 500 条。上限存在的理由不是省内存（五百条
 * 标题不到一百 KB），是别让一份陈年名单无限长下去 —— 里面装的是用户用过
 * 什么、开过哪些文件。
 *
 * 落盘的 JSON 时间戳用毫秒整数而不是 `Date` 的默认编码（参考日起算的浮点
 * 秒），这份文件是给人看的。
 */
struct WindowTitleJudgmentCache: Equatable, Sendable {
    static let capacity = 500
    /**
     * 文件里带一个版本号：格式改了直接丢掉重判，不做迁移。
     *
     * 2：加了「已省略」一档。字段形状没变，但旧名单里的 `Claude`、
     * `Mac Telemetry Hub` 这类条目当时被判成了「已公开」，不重判的话它们
     * 永远不会进新档 —— 整份作废比逐条猜它们该去哪里可靠。
     */
    static let formatVersion = 2

    /// 最近用过的排在最后。淘汰从头上开始。
    private(set) var entries: [WindowTitleJudgmentEntry] = []

    init(entries: [WindowTitleJudgmentEntry] = []) {
        self.entries = []
        for entry in entries { store(entry) }
    }

    static func key(bundleIdentifier: String?, title: String) -> String {
        // Bundle ID 缺失的应用（少数非 bundle 进程）用一个固定占位，
        // 免得它们的标题互相串到同一个键上。
        "\(bundleIdentifier ?? "-")\n\(title)"
    }

    func entry(forKey key: String) -> WindowTitleJudgmentEntry? {
        entries.first { $0.key == key }
    }

    /// 查表并把这一条顶到最近使用。命中才更新 `lastSeenAt`。
    mutating func lookup(key: String, at now: Date) -> WindowTitleJudgmentEntry? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        var entry = entries.remove(at: index)
        entry.lastSeenAt = now
        entries.append(entry)
        return entry
    }

    mutating func store(_ entry: WindowTitleJudgmentEntry) {
        entries.removeAll { $0.key == entry.key }
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    @discardableResult
    mutating func remove(key: String) -> Bool {
        let before = entries.count
        entries.removeAll { $0.key == key }
        return entries.count != before
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

extension WindowTitleJudgmentCache: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        guard version == Self.formatVersion else {
            // 旧格式不迁移：名单重新长出来只是多问几次 Jev。
            self.init()
            return
        }
        self.init(entries: try container.decode([WindowTitleJudgmentEntry].self, forKey: .entries))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .version)
        try container.encode(entries, forKey: .entries)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    func encoded() throws -> Data {
        try Self.encoder().encode(self)
    }

    /// 读坏了就当空的。这份名单是缓存，丢了只是重判一次。
    static func decoded(from data: Data) -> WindowTitleJudgmentCache {
        (try? decoder().decode(WindowTitleJudgmentCache.self, from: data)) ?? WindowTitleJudgmentCache()
    }
}
