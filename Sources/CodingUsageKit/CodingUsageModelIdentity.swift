import Foundation

/**
 * Antigravity 用量日志里的 `model_placeholder_m318` 这类键，对上公开 catalog id。
 *
 * 账本仍按采集到的原始键存。快照和计价在出口做这一步，所以历史行不用改盘，
 * 映射表以后补了也能盖住已经记下的占位符。
 *
 * 编号来自对运行中 Antigravity language server 的登记（High / Medium / Low
 * 三档一组）。没把握的编号不写，原样露出占位符，好发现该补表了。
 */
public enum CodingUsageModelIdentity {
    public static func canonical(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return aliases[placeholderKey(trimmed)] ?? trimmed
    }

    private static func placeholderKey(_ raw: String) -> String {
        var key = raw.lowercased()
        if let range = key.range(of: "model_placeholder_") {
            key = String(key[range.upperBound...])
        } else if let range = key.range(of: "model-placeholder-") {
            key = String(key[range.upperBound...])
        }
        return key
    }

    /// Gemini 3.8 Flash High / Medium / Low = M318 / M319 / M320；
    /// 3.7 = M298 / M299 / M300；3.6 现号 M71–M73，退役号 M264–M266。
    private static let aliases: [String: String] = [
        "m318": "gemini-3.8-flash-high",
        "m319": "gemini-3.8-flash-medium",
        "m320": "gemini-3.8-flash-low",
        "m322": "gemini-3.8-flash",
        "m298": "gemini-3.7-flash-high",
        "m299": "gemini-3.7-flash-medium",
        "m300": "gemini-3.7-flash-low",
        "m71": "gemini-3.6-flash-high",
        "m72": "gemini-3.6-flash-medium",
        "m73": "gemini-3.6-flash-low",
        "m264": "gemini-3.6-flash-high",
        "m265": "gemini-3.6-flash-medium",
        "m266": "gemini-3.6-flash-low",
    ]
}
