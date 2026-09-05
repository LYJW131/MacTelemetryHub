import Foundation
import XCTest
@testable import CodingUsageKit

final class CursorUsageTests: XCTestCase, @unchecked Sendable {
    private let lower = Date(timeIntervalSince1970: 0)
    private let upper = Date(timeIntervalSince1970: 10)

    private func event(_ timestamp: Int, input: Int = 10, extra: String = "") -> String {
        """
        {"timestamp":"\(timestamp)","model":"fixture-model","tokenUsage":{"inputTokens":\(input),"outputTokens":5,"cacheReadTokens":2,"cacheWriteTokens":3,"totalCents":50},"chargedCents":4\(extra)}
        """
    }

    private func page(_ total: Int, _ rows: [String]) -> Data {
        Data("{\"totalUsageEventsCount\":\(total),\"usageEventsDisplay\":[\(rows.joined(separator: ","))]}".utf8)
    }

    private func client(_ pages: [Data], pageSize: Int = 2, maxPages: Int = 20) -> CursorUsageClient {
        CursorUsageClient(pageSize: pageSize, maxPages: maxPages) { request in
            let fields = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let number = fields["page"] as! Int
            let body = pages[min(number - 1, pages.count - 1)]
            return CursorUsageHTTPResponse(status: 200, data: body)
        }
    }

    private func report(_ client: CursorUsageClient) async throws -> CursorUsageReport {
        try await client.fetchHistory(accountHash: "fixture-hash", cookie: "fixture-cookie", since: lower, until: upper)
    }

    func testTokenColumnsAndCostsRemainSeparate() throws {
        let result = try CursorUsageParsing.page(page(1, [event(1_000)]), lower: 0, upper: 10_000)
        let row = try XCTUnwrap(result.events.first?.record)
        XCTAssertEqual(row.inputTokens, 10)
        XCTAssertEqual(row.cacheCreationTokens, 3)
        XCTAssertEqual(row.cacheReadTokens, 2)
        XCTAssertEqual(row.outputTokens, 5)
        XCTAssertEqual(row.totalTokens, 20)
        XCTAssertEqual(row.reportedTokenCostUSD, 0.5)
        XCTAssertEqual(row.chargedUSD, 0.04)
    }

    func testInvalidNumbersAndOverflowFailClosed() throws {
        for value in ["-1", "1.5", "true", "null", "\"4wrong\"", "9223372036854775807"] {
            let data = page(1, [event(1_000).replacingOccurrences(of: "\"inputTokens\":10", with: "\"inputTokens\":\(value)")])
            XCTAssertThrowsError(try CursorUsageParsing.page(data, lower: 0, upper: 10_000))
        }
        let stringNumber = event(1_000).replacingOccurrences(of: "\"inputTokens\":10", with: "\"inputTokens\":\"10.0\"")
        XCTAssertEqual(try CursorUsageParsing.page(page(1, [stringNumber]), lower: 0, upper: 10_000).events[0].record.inputTokens, 10)
    }

    func testLegacyRequestWithoutTokensDoesNotInventTokenUsage() throws {
        let row = #"{"timestamp":"1000","model":"fixture-model","isTokenBasedCall":false}"#
        let record = try CursorUsageParsing.page(page(1, [row]), lower: 0, upper: 10_000).events[0].record
        XCTAssertEqual(record.totalTokens, 0)
        XCTAssertFalse(record.tokenCountsAvailable)
        let missing = #"{"timestamp":"1000","model":"fixture-model","isTokenBasedCall":true}"#
        XCTAssertThrowsError(try CursorUsageParsing.page(page(1, [missing]), lower: 0, upper: 10_000))
    }

    func testMissingMetadataOrOutOfRangeEventsFailClosed() throws {
        for body in ["{}", "<html>Login</html>", #"{"usageEventsDisplay":[]}"#] {
            XCTAssertThrowsError(try CursorUsageParsing.page(Data(body.utf8), lower: 0, upper: 10_000))
        }
        XCTAssertThrowsError(try CursorUsageParsing.page(page(1, [event(10_001)]), lower: 0, upper: 10_000))
    }

    func testPaginationRemovesOnlyProvenBoundaryOverlap() async throws {
        let result = try await report(client([
            page(3, [event(3_000), event(2_000)]),
            page(3, [event(2_000), event(1_000)]),
            page(3, []),
        ]))
        XCTAssertEqual(result.rawRecordCount, 4)
        XCTAssertEqual(result.reportedRecordCount, 3)
        XCTAssertEqual(result.records.count, 3)
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.earliestRecordAt, Date(timeIntervalSince1970: 1))
    }

    func testLegitimateIdenticalRowsWithinPageKeepMultiplicity() async throws {
        let result = try await report(client([page(2, [event(1_000), event(1_000)])], pageSize: 3))
        XCTAssertEqual(result.records.count, 2)
    }

    func testRepeatedPageThrowsInsteadOfReplacingHistory() async {
        do {
            _ = try await report(client([page(4, [event(2_000), event(1_000)])]))
            XCTFail("Expected repeated page failure")
        } catch { XCTAssertEqual(error as? CursorUsageError, .inconsistentPagination) }
    }

    func testShortIncompletePageAndFullSafetyCapFail() async {
        for source in [
            client([page(2, [event(1_000)])]),
            client([page(2, [event(2_000), event(1_000)])], maxPages: 1),
        ] {
            do { _ = try await report(source); XCTFail("Expected incomplete pagination") }
            catch { XCTAssertEqual(error as? CursorUsageError, .incompletePagination) }
        }
    }

    func testChangedTotalAndUnexplainedExtraRowsFail() async {
        for source in [
            client([page(2, [event(3_000), event(2_000)]), page(3, [event(1_000)])]),
            client([page(2, [event(3_000), event(2_000)]), page(2, [event(1_000)])]),
        ] {
            do { _ = try await report(source); XCTFail("Expected inconsistent pagination") }
            catch { XCTAssertEqual(error as? CursorUsageError, .inconsistentPagination) }
        }
    }

    func testVerifiedEmptyReportIsDifferentFromMalformedResponse() async throws {
        let result = try await report(client([page(0, [])]))
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertNil(result.earliestRecordAt)
    }

    func testHistoricalCorrectionReturnsReplacementValue() async throws {
        let original = try await report(client([page(1, [event(1_000, input: 100)])]))
        let revised = try await report(client([page(1, [event(1_000, input: 20)])]))
        XCTAssertEqual(original.records[0].inputTokens, 100)
        XCTAssertEqual(revised.records.count, 1)
        XCTAssertEqual(revised.records[0].inputTokens, 20)
    }

    func testHTTPAndOffOriginRedirectDoNotPublish() async {
        for status in [401, 403, 500, 302] {
            let source = CursorUsageClient { _ in
                CursorUsageHTTPResponse(status: status, data: Data(), location: "https://outside.example/history")
            }
            do { _ = try await report(source); XCTFail("Expected HTTP error") }
            catch {
                let expected: CursorUsageError = status == 401 ? .notLoggedIn : status == 302 ? .unsafeRedirect : .http(status)
                XCTAssertEqual(error as? CursorUsageError, expected)
            }
        }
    }

    func testRequestCarriesFixedExplicitWindow() async throws {
        let response = page(0, [])
        let recorder = CursorRequestRecorder()
        let source = CursorUsageClient { request in
            await recorder.record(request)
            return CursorUsageHTTPResponse(status: 200, data: response)
        }
        _ = try await report(source)
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/dashboard/get-filtered-usage-events")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://cursor.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "fixture-cookie")
        let fields = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(fields["startDate"] as? String, "0")
        XCTAssertEqual(fields["endDate"] as? String, "10000")
        XCTAssertNil(fields["teamId"])
    }

    func testAccountHashSurvivesTokenRotationAndSeparatesAccounts() throws {
        func token(_ subject: String, signature: String) -> String {
            let data = Data("{\"sub\":\"\(subject)\"}".utf8)
            let encoded = data.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "header.\(encoded).\(signature)"
        }
        let first = try CursorUsageLocalAuth.from(token: token("auth0|user_fixture", signature: "one"))
        let rotated = try CursorUsageLocalAuth.from(token: token("auth0|user_fixture", signature: "two"))
        let other = try CursorUsageLocalAuth.from(token: token("auth0|user_other", signature: "three"))
        XCTAssertEqual(first.accountHash, rotated.accountHash)
        XCTAssertNotEqual(first.accountHash, other.accountHash)
        XCTAssertFalse(first.accountHash.contains("fixture"))
        XCTAssertTrue(first.cookie.hasPrefix("WorkosCursorSessionToken=user_fixture%3A%3A"))
        XCTAssertThrowsError(try CursorUsageLocalAuth.from(token: "secret\r\nInjected: header"))
    }

    func testCSVReorderedColumnsAndEscapedFields() throws {
        let csv = #"""
        Model,Automation ID,Date,Output Tokens,Cache Read,Input (w/o Cache Write),Input (w/ Cache Write),Total Tokens,Cost
        "fixture,""quoted""",,2026-09-04T16:00:00.123Z,5,2,10,3,20,$9
        """#
        let rows = try CursorUsageCSV.parse(csv)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].model, "fixture,\"quoted\"")
        XCTAssertEqual(rows[0].totalTokens, 20)
        XCTAssertNil(rows[0].reportedTokenCostUSD)
        XCTAssertNil(rows[0].chargedUSD)
        XCTAssertEqual(rows[0].timestampMs, 1_788_537_600_123)
    }

    func testCSVEmptyMalformedAndHeaderOnly() throws {
        let header = "Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens"
        XCTAssertEqual(try CursorUsageCSV.parse(header), [])
        for value in ["", "<html>login</html>", header + "\ninvalid", header + "\n\"unfinished", header + "\n2026-09-04T00:00:00Z,m,1,2,0,0,1"] {
            XCTAssertThrowsError(try CursorUsageCSV.parse(value))
        }
    }

    func testCSVTimezoneMapsToTheSameInstant() throws {
        let header = "Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens\r\n"
        let utc = try CursorUsageCSV.parse(header + "2026-09-04T16:00:00Z,m,0,1,0,0,1\r\n")
        let local = try CursorUsageCSV.parse(header + "2026-09-05T00:00:00+08:00,m,0,1,0,0,1\r\n")
        XCTAssertEqual(utc[0].timestampMs, local[0].timestampMs)
    }
}

private actor CursorRequestRecorder {
    var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}
