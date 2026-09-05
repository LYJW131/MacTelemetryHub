import CryptoKit
import CoreFoundation
import Foundation
import SQLite3

/*
 Adjacent-page overlap reconciliation is adapted from CodexBar's CursorUsageEventsFetcher.
 https://github.com/steipete/CodexBar
 MIT License — Copyright (c) 2026 Peter Steinberger

 Permission is hereby granted, free of charge, to any person obtaining a copy of this software
 and associated documentation files (the "Software"), to deal in the Software without restriction,
 including without limitation the rights to use, copy, modify, merge, publish, distribute,
 sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
 BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
 DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

/// Token events are account data. No login token, account name, or conversation content is retained.
public struct CursorUsageRecord: Codable, Sendable, Equatable {
    public let timestampMs: Int64
    public let model: String
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheCreationTokens: Int64
    /// Older request-based events have no token measurements, even though an event exists.
    public let tokenCountsAvailable: Bool
    /// The event's token valuation, separate from what a subscription actually deducts.
    /// Consumers applying a shared price table should price the token columns themselves.
    public let reportedTokenCostUSD: Double?
    public let chargedUSD: Double?

    public var totalTokens: Int64 { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
    public var date: Date { Date(timeIntervalSince1970: Double(timestampMs) / 1_000) }
}

public struct CursorUsageReport: Codable, Sendable, Equatable {
    public let accountHash: String
    public let records: [CursorUsageRecord]
    public let fetchedAt: Date
    public let requestedStart: Date
    public let requestedEnd: Date
    public let rawRecordCount: Int
    public let reportedRecordCount: Int
    public let pageCount: Int
    /// True only after every page agrees with the server count. This is not a retention guarantee.
    public let isComplete: Bool

    public var earliestRecordAt: Date? { records.map(\.date).min() }
    public var latestRecordAt: Date? { records.map(\.date).max() }
    public var tokenCountsComplete: Bool { records.allSatisfy(\.tokenCountsAvailable) }
}

public enum CursorUsageError: Error, LocalizedError, Sendable, Equatable {
    case notLoggedIn
    case localAuthUnavailable
    case invalidCredentials
    case http(Int)
    case unsafeRedirect
    case invalidResponse(String)
    case incompletePagination
    case inconsistentPagination
    case invalidDateRange

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Cursor 未登录；请在 Cursor 中登录后重试。"
        case .localAuthUnavailable: "无法读取 Cursor 本机登录状态。"
        case .invalidCredentials: "Cursor 本机登录状态无效，请重新登录。"
        case let .http(status): "Cursor 历史接口返回 HTTP \(status)。"
        case .unsafeRedirect: "Cursor 历史接口返回了不允许的跳转。"
        case let .invalidResponse(reason): "Cursor 历史数据格式无效：\(reason)。"
        case .incompletePagination: "Cursor 历史分页未完整返回，保留上次历史。"
        case .inconsistentPagination: "Cursor 历史分页数量不一致，保留上次历史。"
        case .invalidDateRange: "Cursor 历史查询时间范围无效。"
        }
    }
}

public struct CursorUsageHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public let location: String?

    public init(status: Int, data: Data, location: String? = nil) {
        self.status = status
        self.data = data
        self.location = location
    }
}

public struct CursorUsageClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> CursorUsageHTTPResponse
    private let transport: Transport
    private let pageSize: Int
    private let maxPages: Int

    public init(pageSize: Int = 1_000, maxPages: Int = 1_000, transport: Transport? = nil) {
        self.pageSize = max(1, min(pageSize, 1_000))
        self.maxPages = max(1, maxPages)
        if let transport { self.transport = transport }
        else { self.transport = { request in try await Self.send(request) } }
    }

    public func fetchLocalHistory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        since: Date = Date(timeIntervalSince1970: 0),
        until: Date = Date()
    ) async throws -> CursorUsageReport {
        let auth = try CursorUsageLocalAuth.read(home: home)
        return try await fetchHistory(
            accountHash: auth.accountHash, cookie: auth.cookie, since: since, until: until
        )
    }

    // Internal so production callers cannot accidentally retain raw credentials in a Codable report.
    func fetchHistory(
        accountHash: String, cookie: String, since: Date, until: Date
    ) async throws -> CursorUsageReport {
        let lower = try CursorUsageParsing.milliseconds(since)
        let upper = try CursorUsageParsing.milliseconds(until)
        guard lower >= 0, upper >= lower else { throw CursorUsageError.invalidDateRange }
        var pages: [[CursorUsageEvent]] = []
        var expected: Int?
        var complete = false
        var pageCount = 0
        var seenPages = Set<String>()

        for page in 1...maxPages {
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "page": page, "pageSize": pageSize, "startDate": String(lower), "endDate": String(upper),
            ])
            let response = try await fetch(request)
            let parsed = try CursorUsageParsing.page(response, lower: lower, upper: upper)
            pageCount += 1
            if let expected, expected != parsed.total { throw CursorUsageError.inconsistentPagination }
            expected = parsed.total
            guard parsed.events.count <= pageSize else { throw CursorUsageError.inconsistentPagination }
            if !parsed.events.isEmpty {
                let signature = CursorUsageParsing.hash(parsed.events.map(\.fingerprint).joined(separator: ":"))
                // Without event IDs an entirely repeated page cannot prove progress. Fail closed.
                guard seenPages.insert(signature).inserted else { throw CursorUsageError.inconsistentPagination }
                pages.append(parsed.events)
            }
            if parsed.events.count < pageSize {
                complete = true
                break
            }
        }
        guard complete, let expected else { throw CursorUsageError.incompletePagination }
        let rawCount = pages.reduce(0) { $0 + $1.count }
        let events = try CursorUsageParsing.reconcile(pages: pages, expected: expected)
        return CursorUsageReport(
            accountHash: accountHash,
            records: events.map(\.record).sorted { $0.timestampMs < $1.timestampMs },
            fetchedAt: Date(), requestedStart: since, requestedEnd: until,
            rawRecordCount: rawCount, reportedRecordCount: expected, pageCount: pageCount, isComplete: true
        )
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        var current = request
        for attempt in 0...1 {
            let response = try await transport(current)
            if response.status == 401 { throw CursorUsageError.notLoggedIn }
            if [301, 302, 307, 308].contains(response.status) {
                guard attempt == 0, let location = response.location,
                      let target = URL(string: location, relativeTo: current.url)?.absoluteURL,
                      target.scheme == "https", ["cursor.com", "www.cursor.com"].contains(target.host),
                      target.port == nil || target.port == 443, target.user == nil, target.password == nil
                else { throw CursorUsageError.unsafeRedirect }
                current.url = target
                current.setValue("https://\(target.host!)", forHTTPHeaderField: "Origin")
                continue
            }
            guard response.status == 200 else { throw CursorUsageError.http(response.status) }
            guard response.data.count <= 32 * 1_024 * 1_024 else {
                throw CursorUsageError.invalidResponse("response too large")
            }
            return response.data
        }
        throw CursorUsageError.unsafeRedirect
    }

    private static func send(_ request: URLRequest) async throws -> CursorUsageHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: CursorUsageNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CursorUsageError.invalidResponse("non-HTTP response")
        }
        return CursorUsageHTTPResponse(status: http.statusCode, data: data, location: http.value(forHTTPHeaderField: "Location"))
    }
}

private final class CursorUsageNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

struct CursorUsageEvent: Sendable {
    let record: CursorUsageRecord
    let fingerprint: String
}

enum CursorUsageParsing {
    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func milliseconds(_ date: Date) throws -> Int64 {
        guard let result = Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded(.down)) else {
            throw CursorUsageError.invalidDateRange
        }
        return result
    }

    static func page(_ data: Data, lower: Int64, upper: Int64) throws -> (total: Int, events: [CursorUsageEvent]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["usageEventsDisplay"] as? [[String: Any]],
              let total64 = integer(root["totalUsageEventsCount"]), let total = Int(exactly: total64)
        else { throw CursorUsageError.invalidResponse("missing event array or total count") }
        let events = try rows.map { row -> CursorUsageEvent in
            guard let timestamp = integer(row["timestamp"]), timestamp > 0,
                  timestamp >= lower, timestamp <= upper,
                  let model = row["model"] as? String, !model.trimmingCharacters(in: .whitespaces).isEmpty
            else { throw CursorUsageError.invalidResponse("event timestamp or model") }
            let tokenUsage: [String: Any]
            let hasTokenUsage: Bool
            if let raw = row["tokenUsage"], !(raw is NSNull) {
                guard let value = raw as? [String: Any] else {
                    throw CursorUsageError.invalidResponse("token usage")
                }
                tokenUsage = value
                hasTokenUsage = true
            } else {
                // Request-based legacy events legitimately have no token breakdown.
                guard row["isTokenBasedCall"] as? Bool == false else {
                    throw CursorUsageError.invalidResponse("missing token usage")
                }
                tokenUsage = [:]
                hasTokenUsage = false
            }
            let counts = try ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"].map { key in
                if tokenUsage[key] == nil { return Int64(0) }
                guard let count = integer(tokenUsage[key]) else {
                    throw CursorUsageError.invalidResponse("invalid token count")
                }
                return count
            }
            try validateTotal(counts)
            let record = CursorUsageRecord(
                timestampMs: timestamp, model: model, inputTokens: counts[0], outputTokens: counts[1],
                cacheReadTokens: counts[2], cacheCreationTokens: counts[3],
                tokenCountsAvailable: hasTokenUsage,
                reportedTokenCostUSD: try money(tokenUsage["totalCents"]).map { $0 / 100 },
                chargedUSD: try money(row["chargedCents"]).map { $0 / 100 }
            )
            let canonical = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            return CursorUsageEvent(record: record, fingerprint: hash(String(decoding: canonical, as: UTF8.self)))
        }
        return (total, events)
    }

    /// IDs are not available. Preserve legitimate identical rows and remove only adjacent overlap
    /// whose multiplicity is proved redundant by the authoritative response count.
    static func reconcile(pages: [[CursorUsageEvent]], expected: Int) throws -> [CursorUsageEvent] {
        let rawCount = pages.reduce(0) { $0 + $1.count }
        guard rawCount >= expected else { throw CursorUsageError.incompletePagination }
        var remaining = rawCount - expected
        var output = pages.first ?? []
        for index in pages.indices.dropFirst() {
            let previous = pages[index - 1]
            let current = pages[index]
            let bound = min(previous.count, current.count)
            var overlap = 0
            if bound > 0 {
                for length in stride(from: bound, through: 1, by: -1) {
                    if previous.suffix(length).map(\.fingerprint) == current.prefix(length).map(\.fingerprint) {
                        overlap = length
                        break
                    }
                }
            }
            let removed = min(remaining, overlap)
            remaining -= removed
            output.append(contentsOf: current.dropFirst(removed))
        }
        guard remaining == 0, output.count == expected else { throw CursorUsageError.inconsistentPagination }
        return output
    }

    static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            // Decimal parsing avoids losing large integer precision through Double.
            return nonnegativeInteger(number.stringValue)
        }
        if let string = value as? String { return nonnegativeInteger(string) }
        return nil
    }

    private static func nonnegativeInteger(_ text: String) -> Int64? {
        guard text.range(of: "^[0-9]+(?:\\.0+)?$", options: .regularExpression) != nil else { return nil }
        if let integer = Int64(text), integer >= 0 { return integer }
        guard let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              decimal >= 0, decimal <= Decimal(Int64.max)
        else { return nil }
        var input = decimal
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        guard input == rounded else { return nil }
        return NSDecimalNumber(decimal: decimal).int64Value
    }

    static func money(_ value: Any?) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        let result: Double?
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            result = number.doubleValue
        } else if let text = value as? String {
            result = Double(text)
        } else { result = nil }
        guard let result, result.isFinite, result >= 0 else {
            throw CursorUsageError.invalidResponse("invalid cost")
        }
        return result
    }

    static func validateTotal(_ values: [Int64]) throws {
        var total: Int64 = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard value >= 0, !overflow else { throw CursorUsageError.invalidResponse("token overflow") }
            total = next
        }
    }
}

struct CursorUsageLocalAuth {
    let accountHash: String
    let cookie: String

    static func read(home: URL) throws -> Self {
        let database = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: database.path) else { throw CursorUsageError.notLoggedIn }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            throw CursorUsageError.localAuthUnavailable
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 1_000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1", -1, &statement, nil
        ) == SQLITE_OK else { throw CursorUsageError.localAuthUnavailable }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { throw CursorUsageError.notLoggedIn }
        guard status == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw CursorUsageError.localAuthUnavailable
        }
        let token = String(cString: text)
        return try from(token: token)
    }

    static func from(token: String) throws -> Self {
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard components.count == 3, token.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CursorUsageError.invalidCredentials
        }
        var encoded = String(components[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = payload["sub"] as? String
        else { throw CursorUsageError.invalidCredentials }
        let parts = subject.split(separator: "|", omittingEmptySubsequences: false)
        let userID: String
        if parts.count == 2, parts[1].hasPrefix("user_") { userID = String(parts[1]) }
        else if parts.count == 2, ["auth0", "google-oauth2", "github", "oidc"].contains(String(parts[0])) {
            userID = subject
        } else if parts.count == 1, subject.hasPrefix("user_") { userID = subject }
        else { throw CursorUsageError.invalidCredentials }
        let identityAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_|.-"))
        guard !userID.isEmpty, userID.unicodeScalars.allSatisfy(identityAllowed.contains) else {
            throw CursorUsageError.invalidCredentials
        }
        return Self(accountHash: CursorUsageParsing.hash("cursor-account:\(userID)"), cookie: "WorkosCursorSessionToken=\(userID)%3A%3A\(token)")
    }
}
