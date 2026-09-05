import Foundation

/// Strict parser for export comparison and explicitly imported Cursor exports.
/// Live collection uses the paginated JSON API because CSV has no completeness metadata.
/// The ambiguous CSV Cost column is deliberately not treated as API valuation or plan spend.
public enum CursorUsageCSV {
    public static func parse(_ text: String) throws -> [CursorUsageRecord] {
        let table = try rows(text)
        guard let first = table.first else { throw invalid("missing CSV header") }
        let header = first.enumerated().map { index, value in
            index == 0 ? value.replacingOccurrences(of: "\u{feff}", with: "") : value
        }
        guard Set(header).count == header.count else { throw invalid("duplicate CSV columns") }
        let columns = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        let names = ["Date", "Model", "Input (w/ Cache Write)", "Input (w/o Cache Write)", "Cache Read", "Output Tokens", "Total Tokens"]
        guard names.allSatisfy({ columns[$0] != nil }) else { throw invalid("missing CSV columns") }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        return try table.dropFirst().map { row in
            guard row.count == header.count else { throw invalid("CSV row width") }
            func value(_ column: String) -> String { row[columns[column]!] }
            guard let date = fractional.date(from: value("Date")) ?? standard.date(from: value("Date")),
                  date.timeIntervalSince1970 > 0,
                  !value("Model").trimmingCharacters(in: .whitespaces).isEmpty
            else { throw invalid("CSV date or model") }
            func count(_ column: String) throws -> Int64 {
                if value(column).isEmpty { return 0 }
                guard let result = CursorUsageParsing.integer(value(column)) else { throw invalid("CSV token count") }
                return result
            }
            let input = try count("Input (w/o Cache Write)")
            // The current export gives cache creation separately, despite its ambiguous name.
            // Live JSON/CSV reconciliation confirms all four columns sum to Total Tokens.
            let write = try count("Input (w/ Cache Write)")
            let output = try count("Output Tokens")
            let read = try count("Cache Read")
            try CursorUsageParsing.validateTotal([input, output, read, write])
            guard try count("Total Tokens") == input + output + read + write else { throw invalid("CSV token total mismatch") }
            return CursorUsageRecord(
                timestampMs: try CursorUsageParsing.milliseconds(date), model: value("Model"),
                inputTokens: input, outputTokens: output, cacheReadTokens: read, cacheCreationTokens: write,
                tokenCountsAvailable: !value("Total Tokens").isEmpty,
                reportedTokenCostUSD: nil, chargedUSD: nil
            )
        }
    }

    private static func invalid(_ message: String) -> CursorUsageError { .invalidResponse(message) }

    private static func rows(_ text: String) throws -> [[String]] {
        var table: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var afterQuote = false
        var iterator = text.makeIterator()
        var character = iterator.next()
        func finishRow() {
            row.append(field)
            if row.contains(where: { !$0.isEmpty }) { table.append(row) }
            row = []
            field = ""
            afterQuote = false
        }
        while let current = character {
            if quoted {
                if current == "\"" {
                    let next = iterator.next()
                    if next == "\"" { field.append("\""); character = iterator.next(); continue }
                    quoted = false
                    afterQuote = true
                    character = next
                    continue
                }
                field.append(current)
            } else if current == "," {
                row.append(field)
                field = ""
                afterQuote = false
            } else if current == "\n" || current == "\r" || current == "\r\n" {
                finishRow()
            } else if current == "\"" && field.isEmpty && !afterQuote {
                quoted = true
            } else {
                guard !afterQuote, current != "\"" else { throw invalid("invalid CSV quoting") }
                field.append(current)
            }
            character = iterator.next()
        }
        guard !quoted else { throw invalid("unterminated CSV field") }
        if !field.isEmpty || !row.isEmpty || afterQuote { finishRow() }
        return table
    }
}
