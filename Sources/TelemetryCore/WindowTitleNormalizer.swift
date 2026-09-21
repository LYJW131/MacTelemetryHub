import Foundation

/**
 * 窗口标题的归一化。
 *
 * 判断、缓存、上报**全都**以归一化后的文本为准 —— 同一个键既是问 Jev 的输入，
 * 也是缓存的键，还是最终发出去的那串字。三者用同一份文本，才不会出现
 * 「问的是 A、缓存的是 B、发出去的是 C」这种对不上的情况。
 *
 * 要剥掉的是那些**每秒都在变、却不改变标题含义**的装饰：
 *
 * - 转轮。盲文点阵（U+2800–U+28FF，`⠋⠙⠹…`，npm / cargo / 各类 CLI 的默认转轮）
 *   和几何图形块（U+25A0–U+25FF，`●○◐◓◑◒▪▫◌◍◉`）。后者按整块剥而不是逐个字符
 *   列举：这一块里没有会出现在正经标题里的字形，而转轮的字符集各家不同，逐个
 *   列举必然漏。
 * - 进度 `[3/10]`、百分比 `47%`、未读角标 `(3)`。角标两头都剥 —— 规范里写的是
 *   末尾，但 Gmail / Slack / Discord 都放在开头（`(3) 收件箱`），同一类东西。
 *
 * 剥完压缩空白、去掉两端剩下的分隔符（`— · | -` 这类，剥掉装饰后常常裸露在
 * 开头），空串按 nil。长度上限 200 个 **Unicode 标量**，和 Worker 侧同一个单位 ——
 * 用 `String.prefix` 数的是字素簇，两边会在 emoji 和组合字符上对不齐。
 */
enum WindowTitleNormalizer {
    /// 上报和判断共用的长度上限，单位是 Unicode 标量。Worker 侧同样按这个数截断。
    static let maximumScalarCount = 200

    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var text = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !isDecoration($0) }))
        for pattern in strippedPatterns {
            text = pattern.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: " "
            )
        }
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: edgeSeparators)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.unicodeScalars.count > maximumScalarCount else { return collapsed }
        return String(String.UnicodeScalarView(collapsed.unicodeScalars.prefix(maximumScalarCount)))
    }

    /// 转轮字符。整块剥，不逐个列举。
    private static func isDecoration(_ scalar: Unicode.Scalar) -> Bool {
        // 盲文点阵：CLI 转轮的默认字符集
        if (0x2800...0x28FF).contains(scalar.value) { return true }
        // 几何图形：●○◐◓◑◒▪▫◌◍◉ 全在这一块里
        if (0x25A0...0x25FF).contains(scalar.value) { return true }
        return false
    }

    /// 剥完装饰后两端常常裸着一个分隔符，一起去掉。
    private static let edgeSeparators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "-–—·|:•*"))

    private static let strippedPatterns: [NSRegularExpression] = [
        // 进度：[3/10]
        #"\[\s*\d+\s*/\s*\d+\s*\]"#,
        // 百分比：47%、12.5%
        #"\b\d{1,3}(?:\.\d+)?\s*%"#,
        // 未读角标：开头或结尾的 (3)
        #"(?:^\s*\(\d+\)|\(\d+\)\s*$)"#,
    ].map { try! NSRegularExpression(pattern: $0) }
}
