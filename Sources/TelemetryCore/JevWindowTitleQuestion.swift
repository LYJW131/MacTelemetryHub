import Foundation

#if TELEMETRY_CORE_SPM
import ChargerTelemetryKit
#endif

/**
 * 问 Jev 六件关于一条窗口标题的事。
 *
 * TypeSafe 的 System One 走一个裸 HTTP 端点，回来的是**概率**而不是一段话。
 * 这里一次请求问六道是非题（noul），看同一份 state，互相看不到对方的答案，
 * 一次往返就完。
 *
 * 为什么是六道而不是两道：早一版把凭据、财务、医疗、法律、感情、具名第三方、
 * 雇主材料全揉进一道 `windowTitleSensitive` 里，结果是一条
 * 「二次元毛邓江胡！…键政密码本」的 YouTube 标题只拿到 0.07 —— 它确实不涉及
 * 钱、病、合同和密码，而那道题里压根没有「政治」和「成人内容」这两个词，
 * 模型没被问到的东西当然答不出来。TypeSafe 的说法是一个标签一道 noul：互相
 * 独立的维度各问各的，组合规则留在代码里（见 `WindowTitleJudgmentThresholds`），
 * 原始概率照样可复用。
 *
 * 所以这一整块是纯的 —— 题面是常量、请求体是 Encodable、响应是 Decodable，
 * 落档在阈值那边。能被测的就是这三件。
 *
 * ⚠️ 题面和阈值是一对。实测数字记在 `WindowTitleJudgmentThresholds` 上，
 * 改这里的字必须重跑那张表。两句尤其要留着：
 *
 * - 「陌生项目名默认算站长自己的」（在 `exposesConfidentialWork` 里）：
 *   没有它的时候 `ReportDecision.swift — MacTelemetryHub` 会被当成「未公开的
 *   工作内容」，自家仓库跟着一起遭殃。
 * - 每道题末尾那句「别的维度有别的题在问」：没有它的话一条政治标题会顺手把
 *   私人事务和成人内容一起点亮（「少女」「键政」），`lockedBy` 就成了噪声。
 */
enum JevWindowTitleQuestion {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-latest"
    static let defaultTimeout: TimeInterval = 10

    static let purpose = """
        The owner is an individual developer whose personal homepage shows a live \
        "what I am using right now" card. The application name is already published there on \
        purpose. The window title below was read from the owner's own Mac and would be published \
        next to it, verbatim, visible to anyone on the internet.
        """

    /// 每道题末尾都补这一句。六道题同时在问，谁也别替别人回答。
    private static func scopeFence(_ mine: String, others: String) -> String {
        """
        \(others) are judged by separate questions asked alongside this one; answer only about \
        \(mine) here. Judge only `state.title` in the context of `state.applicationName`.
        """
    }

    // MARK: - 五道风险题

    static let secretInstructions = """
        Decide whether publishing `state.title` verbatim next to `state.applicationName` would \
        expose a secret credential: a password, passphrase, API key, access key, client secret, \
        token, private key, recovery phrase, one-time code, or an account, card or licence \
        number. Answer yes when the title carries such a value, or when it names one specific \
        credential record closely enough that the credential itself is identified, such as a \
        password-manager entry for a named production key. A file, repository, command or page \
        that merely deals with authentication in general — documentation about OAuth, a source \
        file named for a login flow, a sign-in page — carries no secret. \
        \(scopeFence(
            "credentials",
            others: "Private personal matters, employer or client material, adult content and political topics"
        ))
        """

    static let secretCriteria: [String: String] = [
        "true": """
            The title reveals a credential or pins down one specific credential record: a \
            password, passphrase, API or access key, client secret, token, private key, recovery \
            phrase or one-time code, an account, card or licence number, or a password-manager \
            entry naming a particular production key or account.
            """,
        "false": """
            No credential is revealed: source files and repositories, a shell prompt, \
            documentation about authentication or security, a sign-in or account page with no \
            secret in the title, or any title that only mentions keys and passwords as a subject \
            without carrying one.
            """,
    ]

    static let privateMatterInstructions = """
        Decide whether publishing `state.title` verbatim next to `state.applicationName` would \
        expose a private matter of the owner's own life or of someone they deal with: money — a \
        bank, brokerage, payment, tax or invoice view, a balance, a salary; health or medical \
        care; a legal matter or a signed agreement; a romantic or family relationship. Answer \
        yes as well when the title names a private individual the owner deals with: a person's \
        name in a mail subject, a chat or call with a named person, the subject line of a direct \
        message or e-mail. A public figure, an author, an artist, a fictional character, a \
        company or a product name is not a private individual. \
        \(scopeFence(
            "private personal matters",
            others: "Credentials, employer or client material, adult content and political topics"
        ))
        """

    static let privateMatterCriteria: [String: String] = [
        "true": """
            The title exposes a private personal matter: a bank, brokerage, payment, tax or \
            invoice view, a balance or salary figure, a medical, pharmaceutical or mental-health \
            topic, a legal case or a contract being signed, a romantic or family matter, or a \
            named private individual such as the recipient or subject of a personal e-mail, \
            message or call.
            """,
        "false": """
            Nothing private is exposed: public web pages and documentation, source code, shell \
            sessions, public media, published books, films, games and articles, the owner's own \
            hobby projects and their notes and plans, and titles naming only public figures, \
            authors, companies, products or fictional characters.
            """,
    ]

    static let confidentialWorkInstructions = """
        Decide whether publishing `state.title` verbatim next to `state.applicationName` would \
        expose material that belongs to an employer or a client rather than to the owner: an \
        internal or confidential company document, a named customer or client account, an \
        unreleased commercial product or feature, an internal ticket, incident or roadmap item, \
        or a business figure that is not public. The owner is an individual developer working on \
        their own things: their own repositories, source files and shell sessions, and their \
        personal notes, plans, agendas and drafts about their own life or hobby projects, are \
        not an employer's material, even when the project name is unfamiliar — assume an \
        unfamiliar project name is the owner's own. \
        \(scopeFence(
            "employer or client confidentiality",
            others: "Credentials, private personal matters, adult content and political topics"
        ))
        """

    static let confidentialWorkCriteria: [String: String] = [
        "true": """
            The title exposes something owned by an employer or a client: an internal or \
            confidential company document, a named customer or client account, an unreleased \
            commercial product or feature, an internal ticket, incident or roadmap item, or a \
            business figure that has not been published.
            """,
        "false": """
            The material is the owner's own or already public: their own repositories and source \
            files, a shell prompt with a project path, their own notes, plans, agendas and \
            drafts, public documentation and web pages, public media, or an unfamiliar project \
            name that is most likely one of the owner's own.
            """,
    ]

    static let adultContentInstructions = """
        Decide whether `state.title` is pornographic or sexually explicit. Answer yes when the \
        title names an adult site, an explicit video, gallery or story, an NSFW community, board \
        or channel, or sex-work advertising, or when it otherwise describes explicit sexual \
        content. Answer no for mainstream books, films, television, games, anime and music whose \
        titles are not themselves explicit, even when the work carries mature, violent or \
        romantic themes, and no for clinical, biological or educational material about sexuality \
        and the body. \
        \(scopeFence(
            "explicit adult content",
            others: "Credentials, private personal matters, employer or client material and political topics"
        ))
        """

    static let adultContentCriteria: [String: String] = [
        "true": """
            The title is pornographic or explicitly sexual: an adult video or image site, an \
            explicit clip, gallery or story, an NSFW forum, subreddit or channel, or an \
            advertisement for sexual services.
            """,
        "false": """
            The title is not explicit: ordinary sites, files and code; mainstream books, films, \
            series, games, anime and music, including works with mature, violent or romantic \
            themes; and clinical, biological or educational material about sexuality.
            """,
    ]

    static let politicallySensitiveInstructions = """
        Decide whether `state.title` touches a political subject that would cause trouble for \
        the owner if it appeared on their public personal homepage. Answer yes when the title is \
        about a political leader, head of state or party official; a government, party or regime \
        and its conduct as a subject of praise, criticism or commentary; a political movement, \
        protest, uprising, crackdown or other contested historical or current political event; \
        censorship, surveillance, dissidents or human rights; or an ethnic, religious or \
        territorial dispute. Answer yes as well when the title points at such a subject through \
        a nickname, homophone, abbreviation, code word, meme or fan-culture substitution instead \
        of a plain name — political commentary dressed up as entertainment still counts. Answer \
        no for neutral coverage of economics, business, technology, science or sport that takes \
        no political side and names no contested political subject, and no for the owner's own \
        code, files and tools. \
        \(scopeFence(
            "political sensitivity",
            others: "Credentials, private personal matters, employer or client material and adult content"
        ))
        """

    static let politicallySensitiveCriteria: [String: String] = [
        "true": """
            The title is about a politically contested subject: a named political leader or \
            official, a government, party or regime and its conduct, a political movement, \
            protest or suppressed historical event, censorship, surveillance, dissidents or \
            human rights, or an ethnic, religious or territorial dispute — including when that \
            subject is named indirectly through nicknames, homophones, initials, code words or \
            memes.
            """,
        "false": """
            The title is politically neutral: source code, tools and documentation; ordinary \
            technology, science or sport coverage; business and economic reporting that takes no \
            political side and names no contested political subject; entertainment with no \
            political referent; and everyday personal content.
            """,
    ]

    // MARK: - 信息量

    /**
     * 第六题：这条标题除了应用名之外还说了什么。
     *
     * 和五道风险题互不蕴含，所以单独一道：那五道问风险，这一道问信息量。
     * `Claude` 在五道风险题上干干净净 —— 它该被挡下来的理由和隐私无关，
     * 而是没什么可说。
     */
    static let informativeInstructions = """
        Decide whether `state.title` tells a visitor anything beyond `state.applicationName` \
        itself — what is being read, edited, watched, played or worked on, such as a file, a \
        page, a repository, a document, a conversation partner or a track. Answer yes when the \
        title names such content, even briefly. Answer no when the title is only the \
        application's own name or a close variant of it, or generic window chrome that any user \
        of that application would see, such as "Untitled", "无标题", "主窗口", "New Tab", \
        "Preferences", "Settings", "Window" or an empty name. Judge only how much the title adds \
        to the application name; whether the content is sensitive is judged by separate \
        questions asked alongside this one.
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

    /**
     * 维度到题面。
     *
     * 题目 ID 就是维度的 rawValue —— 一个名字管到底：请求里的键、响应里的键、
     * 落盘 `probabilities` 的键都是它，代码里没有第二套映射需要对齐。
     */
    static func question(for dimension: WindowTitleDimension) -> JevNoulQuestion {
        switch dimension {
        case .exposesSecret:
            JevNoulQuestion(instructions: secretInstructions, criteria: secretCriteria)
        case .exposesPrivateMatter:
            JevNoulQuestion(
                instructions: privateMatterInstructions,
                criteria: privateMatterCriteria
            )
        case .exposesConfidentialWork:
            JevNoulQuestion(
                instructions: confidentialWorkInstructions,
                criteria: confidentialWorkCriteria
            )
        case .isAdultContent:
            JevNoulQuestion(instructions: adultContentInstructions, criteria: adultContentCriteria)
        case .isPoliticallySensitive:
            JevNoulQuestion(
                instructions: politicallySensitiveInstructions,
                criteria: politicallySensitiveCriteria
            )
        case .isInformative:
            JevNoulQuestion(instructions: informativeInstructions, criteria: informativeCriteria)
        }
    }

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
            questions: Dictionary(
                uniqueKeysWithValues: WindowTitleDimension.allCases.map {
                    ($0.rawValue, question(for: $0))
                }
            )
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

/**
 * 一次判断的结果。
 *
 * 落档已经算好，六个概率和触发锁定的维度一起带上 —— 界面要拿它说出
 * 「已锁定 · 政治敏感」，缓存要把这句理由一起存下来。
 */
struct WindowTitleJudgmentOutcome: Equatable, Sendable {
    let verdict: WindowTitleVerdict
    /// 六道题的概率。键是维度的 rawValue，也就是题目 ID。
    let probabilities: [String: Double]
    /// 把这条标题锁掉的那些维度。没锁定就是空的。
    let lockedBy: [WindowTitleDimension]

    func probability(of dimension: WindowTitleDimension) -> Double? {
        probabilities[dimension.rawValue]
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
     * 六道题缺哪一道都算 `missingAnswer`：它们出自同一次调用，少一个说明那次
     * 回答本身不对劲，这条标题就当判断失败处理（按锁定、不写缓存、退避重试），
     * 而不是拿残缺的答案把它钉死在某一档上 —— 缺的偏偏是政治那道的话，一条
     * 键政标题会以「风险题全干净」的名义直接公开出去。
     */
    static func outcome(from data: Data) throws -> WindowTitleJudgmentOutcome {
        let decoded = try JSONDecoder().decode(JevSystemOneResponse.self, from: data)
        var probabilities: [WindowTitleDimension: Double] = [:]
        for dimension in WindowTitleDimension.allCases {
            guard let noul = decoded.answers[dimension.rawValue]?.noul else {
                throw JevError.missingAnswer
            }
            probabilities[dimension] = noul
        }
        let judged = WindowTitleJudgmentThresholds.judge(probabilities)
        return WindowTitleJudgmentOutcome(
            verdict: judged.verdict,
            probabilities: Dictionary(
                uniqueKeysWithValues: probabilities.map { ($0.key.rawValue, $0.value) }
            ),
            lockedBy: judged.lockedBy
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
