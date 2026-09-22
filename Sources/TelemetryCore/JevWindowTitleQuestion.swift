import Foundation

#if TELEMETRY_CORE_SPM
import ChargerTelemetryKit
#endif

/**
 * 问 Jev 两件关于一条窗口标题的事。
 *
 * TypeSafe 的 System One 走一个裸 HTTP 端点，回来的是**概率**而不是一段话。
 * 这里问两道是非题（noul）：会不会泄密，以及有没有信息量。两道在同一个请求
 * 里、看同一份 state、互相看不到对方的答案，一次往返就完。
 *
 * 为什么不用三选一的 `choice`：noul 的中间地带本来就是「模型也说不准」，
 * 落档交给 `WindowTitleJudgmentThresholds` 的三条线即可；把「拿不准」写成
 * choice 的一个选项，是让模型替我们表达把握不足，而那是概率自己的事。
 *
 * 所以这一整块是纯的 —— 题面是常量、请求体是 Encodable、响应是 Decodable，
 * 落档在阈值那边。能被测的就是这三件。
 *
 * ⚠️ 题面和阈值是一对。实测数字记在 `WindowTitleJudgmentThresholds` 上，
 * 改这里的字必须重跑那张表。特别是「陌生项目名默认算站长自己的」这一句：
 * 没有它的时候，`ReportDecision.swift — MacTelemetryHub` 会被当成「未公开的
 * 工作内容」，自家仓库跟着一起遭殃。
 */
enum JevWindowTitleQuestion {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-latest"
    /// 问题 ID 只给代码用，模型看不到它，所以含义必须写在 instructions 里。
    static let sensitiveQuestionID = "windowTitleSensitive"
    static let informativeQuestionID = "windowTitleInformative"
    static let defaultTimeout: TimeInterval = 10

    static let purpose = """
        The owner is an individual developer whose personal homepage shows a live \
        "what I am using right now" card. The application name is already published there on \
        purpose. The window title below was read from the owner's own Mac and would be published \
        next to it, verbatim, visible to anyone on the internet.
        """

    /// 第一题：公开这条标题会不会泄密。
    static let sensitiveInstructions = """
        Decide whether publishing `state.title` verbatim next to `state.applicationName` would \
        expose something that must stay private. The owner wants their own work visible: their own \
        repositories, source files, shell sessions, personal notes about hobby projects, public web \
        pages and public media are not secrets, even when the project name is unfamiliar — assume \
        an unfamiliar project name is the owner's own. Answer yes only when the title would expose \
        a credential, key, token or password; a financial, banking, payment, medical, legal or \
        relationship matter; a named third party or a private message from one; or material that \
        belongs to an employer or client rather than the owner, such as an internal document, a \
        customer name or an unreleased commercial product. Judge only `state.title` in the context \
        of `state.applicationName`.
        """

    static let sensitiveCriteria: [String: String] = [
        "true": """
            Publishing the title would expose something that must stay private: a bank, brokerage \
            or payment account view; a medical, legal or relationship matter; a password, API key \
            or token; a named private individual or the subject line of a personal message; an \
            employer's or client's internal document, customer or unreleased product.
            """,
        "false": """
            Nothing in the title is sensitive: a source file and repository name, a shell prompt \
            with a project path, a public website or documentation page, a public video, song or \
            article title, the owner's own hobby project, an empty or placeholder document name, \
            or ordinary application chrome such as "Untitled", "Preferences" or the bare app name.
            """,
    ]

    /**
     * 第二题：这条标题除了应用名之外还说了什么。
     *
     * 和第一题互不蕴含，所以是单独一道题：第一题问风险，这一题问信息量。
     * `Claude` 在第一题上是干干净净的 sensitive 0.03 —— 它该被挡下来的
     * 理由和隐私无关，而是没什么可说。
     */
    static let informativeInstructions = """
        Decide whether `state.title` tells a visitor anything beyond `state.applicationName` \
        itself — what is being read, edited, watched, played or worked on, such as a file, a \
        page, a repository, a document, a conversation partner or a track. Answer yes when the \
        title names such content, even briefly. Answer no when the title is only the \
        application's own name or a close variant of it, or generic window chrome that any user \
        of that application would see, such as "Untitled", "无标题", "主窗口", "New Tab", \
        "Preferences", "Settings", "Window" or an empty name. Judge only how much the title adds \
        to the application name; whether the content is sensitive is not this question.
        """

    static let informativeCriteria: [String: String] = [
        "true": """
            The title names specific content or context worth showing next to the application \
            name: a file or document name, a web page or site, a repository or project, a media \
            title, a conversation, a shell path.
            """,
        "false": """
            The title adds nothing: it repeats or paraphrases the application name, or it is \
            generic chrome such as an untitled or new document, a preferences or settings \
            window, a bare window label, or an empty string.
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
                sensitiveQuestionID: JevNoulQuestion(
                    instructions: sensitiveInstructions,
                    criteria: sensitiveCriteria
                ),
                informativeQuestionID: JevNoulQuestion(
                    instructions: informativeInstructions,
                    criteria: informativeCriteria
                ),
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

/// 是非题。`criteria` 的键固定是 `true` / `false`，这是 TypeSafe 那侧的形状。
struct JevNoulQuestion: Encodable, Equatable, Sendable {
    let type = "noul"
    let instructions: String
    let criteria: [String: String]

    private enum CodingKeys: String, CodingKey {
        case type, instructions, criteria
    }
}

struct JevSystemOneRequest: Encodable, Equatable, Sendable {
    let model: String
    let state: JevWindowTitleState
    let questions: [String: JevNoulQuestion]
}

struct JevSystemOneResponse: Decodable, Equatable, Sendable {
    /// 一道是非题的答案。`noul` 是「是」的概率（0 到 1），
    /// 没有单独的 confidence —— 这个数自己就是把握。
    struct Answer: Decodable, Equatable, Sendable {
        let type: String
        let noul: Double?
    }

    let model: String
    let answers: [String: Answer]
}

/// 一次判断的结果。落档已经算好，两个概率一起带上留给界面和缓存。
struct WindowTitleJudgmentOutcome: Equatable, Sendable {
    let verdict: WindowTitleVerdict
    let sensitive: Double
    let informative: Double

    /// 落盘和显示用的形状：缓存条目里就一个 `probabilities` 字典。
    var probabilities: [String: Double] {
        [
            WindowTitleJudgmentThresholds.sensitiveOption: sensitive,
            WindowTitleJudgmentThresholds.informativeOption: informative,
        ]
    }
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

    /**
     * 响应解析。
     *
     * 两道题缺哪一道都算 `missingAnswer`：它们出自同一次调用，少一个说明那次
     * 回答本身不对劲，这条标题就当判断失败处理（按锁定、不写缓存、退避重试），
     * 而不是用半份答案把它钉死在某一档上。
     */
    static func outcome(from data: Data) throws -> WindowTitleJudgmentOutcome {
        let decoded = try JSONDecoder().decode(JevSystemOneResponse.self, from: data)
        guard let sensitive = decoded.answers[JevWindowTitleQuestion.sensitiveQuestionID]?.noul,
              let informative = decoded.answers[JevWindowTitleQuestion.informativeQuestionID]?.noul
        else {
            throw JevError.missingAnswer
        }
        return WindowTitleJudgmentOutcome(
            verdict: WindowTitleJudgmentThresholds.verdict(
                sensitive: sensitive,
                informative: informative
            ),
            sensitive: sensitive,
            informative: informative
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
