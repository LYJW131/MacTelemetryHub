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
 * 还要剥的是应用自己挂在末尾的名字：Chromium 系和多数 Electron 应用都会把
 * 标题写成 `页面 - Google Chrome`、`文件 - 项目 - Visual Studio Code`，Firefox
 * 是 `页面 — Mozilla Firefox`。这一段和应用名字段重复，只占长度、只添噪音，
 * 而且同一个页面在不同浏览器里会因此算成不同的键。按常见分隔符取最后一段，
 * 等于应用名、或以应用名整词收尾，就整段剥掉，只剥一次；最后一段不是应用名
 * （`Claude Status - Incident History`）就不动。这是确定性规则，不劳 Jev。
 *
 * 剥完压缩空白、去掉两端剩下的分隔符（`— · | -` 这类，剥掉装饰后常常裸露在
 * 开头），空串按 nil。长度上限 200 个 **Unicode 标量**，和 Worker 侧同一个单位 ——
 * 用 `String.prefix` 数的是字素簇，两边会在 emoji 和组合字符上对不齐。
 */
enum WindowTitleNormalizer {
    /// 上报和判断共用的长度上限，单位是 Unicode 标量。Worker 侧同样按这个数截断。
    static let maximumScalarCount = 200

    /**
     * - Parameter applicationNames: 前台应用可能用来署名的几个名字：本地化名、
     *   `CFBundleName`、`CFBundleDisplayName`。VS Code 的本地化名是 `Code`，
     *   标题末尾写的却是 `Visual Studio Code`，所以要几个一起给，按整词收尾匹配。
     */
    static func normalize(_ raw: String?, applicationNames: [String] = []) -> String? {
        guard let raw else { return nil }
        var text = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !isDecoration($0) }))
        for pattern in strippedPatterns {
            text = pattern.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: " "
            )
        }
        text = strippingApplicationSuffix(text, applicationNames: applicationNames)
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: edgeSeparators)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.unicodeScalars.count > maximumScalarCount else { return collapsed }
        return String(String.UnicodeScalarView(collapsed.unicodeScalars.prefix(maximumScalarCount)))
    }

    /**
     * 末尾那段应用署名。
     *
     * 只看最后一个分隔符之后的那段，只剥一次：`Google Chrome Help - Google Chrome`
     * 剥完是 `Google Chrome Help`，不会连着把前面同名的段也吃掉。整段就是应用名
     * 时（Chrome 的空白新标签页）剥完为空，上层照旧按 nil 处理。
     */
    private static func strippingApplicationSuffix(_ text: String, applicationNames: [String]) -> String {
        let names = applicationNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return text }
        let matches = segmentSeparator.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let last = matches.last, let range = Range(last.range, in: text) else {
            // 没有分隔符、整条就是应用名：说了等于没说，按没有标题
            let whole = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return names.contains(whole) ? "" : text
        }
        let tail = text[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !tail.isEmpty else { return text }
        let signed = names.contains { name in
            tail == name || (tail.hasSuffix(name) && endsOnWordBoundary(tail, before: name))
        }
        return signed ? String(text[..<range.lowerBound]) : text
    }

    /// `visual studio code` 以 `code` 收尾算署名，`barcode` 以 `code` 收尾不算。
    private static func endsOnWordBoundary(_ tail: String, before name: String) -> Bool {
        let cut = tail.index(tail.endIndex, offsetBy: -name.count)
        guard cut > tail.startIndex else { return true }
        let previous = tail[tail.index(before: cut)]
        return !(previous.isLetter || previous.isNumber)
    }

    /// 段与段之间的分隔：两侧带空白的 `-`、`–`、`—`、`|`、`·`。
    private static let segmentSeparator = try! NSRegularExpression(pattern: #"\s+[-–—|·]\s+"#)

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
