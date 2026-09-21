import Foundation

#if TELEMETRY_CORE_SPM
import ChargerTelemetryKit
#endif

/**
 * 问 Jev 一条窗口标题能不能公开。
 *
 * TypeSafe 的 System One 走一个裸 HTTP 端点，回来的是**分布**而不是一段话：
 * 一个 `choice` 题，三个选项，三个概率。所以这一整块是纯的 —— 题面是常量、
 * 请求体是 Encodable、响应是 Decodable，落档交给
 * `WindowTitleJudgmentThresholds`。能被测的就是这三件。
 *
 * ⚠️ 题面和阈值是一对。实测数字和调题面的过程记在
 * `WindowTitleJudgmentThresholds` 上，改这里的字必须重跑那张表。
 * 特别是「陌生项目名默认算站长自己的」这一句：没有它的时候，
 * `ReportDecision.swift — MacTelemetryHub` 只拿到 public 0.53 —— 模型按
 * 「未公开的工作内容」把自家仓库也算了进去。
 */
enum JevWindowTitleQuestion {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-latest"
    /// 问题 ID 只给代码用，模型看不到它，所以含义必须写在 instructions 里。
    static let questionID = "windowTitlePublishable"
    static let defaultTimeout: TimeInterval = 10

    static let purpose = """
        The owner is an individual developer whose personal homepage shows a live \
        "what I am using right now" card. The application name is already published there on \
        purpose. The window title below was read from the owner's own Mac and would be published \
        next to it, verbatim, visible to anyone on the internet.
        """

    static let instructions = """
        Decide whether `state.title` can be published verbatim next to `state.applicationName`. \
        The owner wants their own work visible: their own repositories, source files, shell \
        sessions, personal notes about hobby projects, public web pages and public media are not \
        secrets, even when the project name is unfamiliar — assume an unfamiliar project name \
        is the owner's own. Treat the title as private only when publishing it would expose a \
        credential, key, token or password; a financial, banking, payment, medical, legal or \
        relationship matter; a named third party or a private message from one; or material that \
        belongs to an employer or client rather than the owner, such as an internal document, a \
        customer name or an unreleased commercial product. Judge only `state.title` in the \
        context of `state.applicationName`.
        """

    static let criteria: [String: String] = [
        WindowTitleJudgmentThresholds.publicOption: """
            Nothing in the title is sensitive. Examples: a source file and repository name, a \
            shell prompt with a project path, a public website or documentation page, a public \
            video, song or article title, an empty or placeholder document name, and ordinary \
            application chrome such as "Untitled", "Preferences" or the bare app name.
            """,
        WindowTitleJudgmentThresholds.privateOption: """
            Publishing the title would expose something that must stay private. Examples: a bank, \
            brokerage or payment account view; a medical, legal or relationship matter; a \
            password, API key or token; a named private individual or the subject line of a \
            personal message; an employer's or client's internal document, customer or unreleased \
            product.
            """,
        WindowTitleJudgmentThresholds.unsureOption: """
            The title clearly names specific content, but there is not enough in it to tell \
            whether that content is the owner's own public work or something sensitive, so a \
            human should look at it before it is published.
            """,
    ]

    static func request(
        applicationName: String,
        bundleIdentifier: String?,
        title: String
    ) -> JevSystemOneRequest {
        JevSystemOneRequest(
            model: model,
            state: JevWindowTitleState(
                purpose: purpose,
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                title: title
            ),
            questions: [
                questionID: JevChoiceQuestion(instructions: instructions, criteria: criteria),
            ]
        )
    }
}

struct JevWindowTitleState: Encodable, Equatable, Sendable {
    let purpose: String
    let applicationName: String
    let bundleIdentifier: String?
    let title: String
}

struct JevChoiceQuestion: Encodable, Equatable, Sendable {
    let type = "choice"
    let instructions: String
    let criteria: [String: String]

    private enum CodingKeys: String, CodingKey {
        case type, instructions, criteria
    }
}

struct JevSystemOneRequest: Encodable, Equatable, Sendable {
    let model: String
    let state: JevWindowTitleState
    let questions: [String: JevChoiceQuestion]
}

struct JevSystemOneResponse: Decodable, Equatable, Sendable {
    struct Answer: Decodable, Equatable, Sendable {
        let type: String
        let choice: String
        let confidence: Double
        let probabilities: [String: Double]
    }

    let model: String
    let answers: [String: Answer]
}

/// 一次判断的结果。落档已经算好，原始分布一起带上留给界面和缓存。
struct WindowTitleJudgmentOutcome: Equatable, Sendable {
    let verdict: WindowTitleVerdict
    let choice: String
    let probabilities: [String: Double]
}

enum JevError: LocalizedError, Equatable {
    case missingAPIKey
    case httpStatus(Int, detail: String?)
    case missingAnswer

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "没有配置 TypeSafe API key。"
        case let .httpStatus(code, detail):
            detail.map { "TypeSafe 返回 HTTP \(code)：\($0)" } ?? "TypeSafe 返回 HTTP \(code)"
        case .missingAnswer: "TypeSafe 响应里没有这道题的答案。"
        }
    }

    /**
     * 值得退避重试的失败。
     *
     * 429 是限额、529 是过载，两个都该指数退避；5xx 同理。401 / 422 是这边
     * 的问题（key 不对、题面写坏了），重试多少次都一样。
     */
    var isRetryable: Bool {
        switch self {
        case .missingAPIKey: false
        case let .httpStatus(code, _): code == 429 || code >= 500
        case .missingAnswer: false
        }
    }
}

enum JevClient {
    static func request(apiKey: String, body: Data, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: JevWindowTitleQuestion.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    static func judgeWindowTitle(
        applicationName: String,
        bundleIdentifier: String?,
        title: String,
        apiKey: String,
        timeout: TimeInterval = JevWindowTitleQuestion.defaultTimeout
    ) async throws -> WindowTitleJudgmentOutcome {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw JevError.missingAPIKey }
        let body = try JSONCoding.encoder().encode(
            JevWindowTitleQuestion.request(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                title: title
            )
        )
        let (data, response) = try await IsolatedHTTPClient.data(
            for: request(apiKey: key, body: body, timeout: timeout)
        )
        guard let http = response as? HTTPURLResponse else {
            throw JevError.httpStatus(0, detail: "TypeSafe 返回了无效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JevError.httpStatus(http.statusCode, detail: errorDetail(data))
        }
        return try outcome(from: data)
    }

    /// 响应解析。分档只看 `probabilities`，`choice` 只是记录下来给界面看。
    static func outcome(from data: Data) throws -> WindowTitleJudgmentOutcome {
        let decoded = try JSONDecoder().decode(JevSystemOneResponse.self, from: data)
        guard let answer = decoded.answers[JevWindowTitleQuestion.questionID] else {
            throw JevError.missingAnswer
        }
        return WindowTitleJudgmentOutcome(
            verdict: WindowTitleJudgmentThresholds.verdict(probabilities: answer.probabilities),
            choice: answer.choice,
            probabilities: answer.probabilities
        )
    }

    private static func errorDetail(_ data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for field in ["error", "detail", "message"] {
                if let text = object[field] as? String, !text.isEmpty { return text }
            }
        }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
