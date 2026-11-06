import Foundation

/// 知乎回答发布的程序策略。模型只解释这份状态；是否允许首次发布尝试、
/// 是否已经尝试、以及回读能否晋级为已发布，都由这里的纯函数裁决。
enum ZhihuPublishPolicy {
    static let fullTextComparisonRule = "crlf_to_lf_full_equality_v1"
    static let readbackWindow: TimeInterval = 20
    static let unknownNotice = "发布结果未确认，可能已经成功。已暂停同题自动重试，请先检查回答详情。"

    static func normalizeFullText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in normalizeFullText(text).utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        return String(value, radix: 16)
    }

    /// 兼容自检/迁移的只读入口。生产控制流保存并更新 PublishAuthorization，
    /// 不会在点击时重新扫描原始 goal。
    static func taskIncludesPublish(_ instruction: String) -> Bool {
        PublishAuthorization.initial(instruction: instruction).allowsZhihuAnswer
    }

    static func shouldAttemptPublish(taskID: UUID, authorization: PublishAuthorization, proof: WriteProof?,
                                     binding: ZhihuPublishBinding?, account: ZhihuAccountIdentity?,
                                     records: [ZhihuPublishRecord]) -> PublishDecision {
        guard authorization.allowsZhihuAnswer else {
            return .blocked("当前发布授权无效：\(authorization.explanation)")
        }
        guard let proof else { return .blocked("缺少当前任务、当前正文的有效 WriteProof") }
        guard let account, account.isResolved else { return .blocked("当前知乎账号连续性不可确认，不能核对同账号发布账") }
        if ZhihuPublishLedger.pending(account: account, questionID: proof.questionID, in: records) != nil {
            return .readbackOnly("同题存在未决发布尝试，只允许回读")
        }
        if ZhihuPublishLedger.verified(account: account, questionID: proof.questionID,
                                       textHash: proof.expectedTextHash, in: records) != nil {
            return .alreadyPublished("同题同文已有独立回读证据")
        }
        guard proof.taskID == taskID, proof.isValid else { return .blocked("缺少当前任务、当前正文的有效 WriteProof") }
        guard let binding, binding.matches(proof: proof) else { return .blocked("发布按钮与当前问题/编辑器/回答容器未形成唯一绑定") }
        guard binding.revealed else { return .blocked("发布目标尚未揭示") }
        guard !binding.blocked else { return .blocked("发布目标仍被页面阻挡层覆盖") }
        return .attemptOnce
    }

    /// 主循环使用的确定性改写钩子；wait/done/click 等模型动作在 ready 时
    /// 一律落到同一个专用动作名，避免提示词意见重新夺回发布决策权。
    static func finalAction(for decision: PublishDecision?, proposedAction: String) -> String {
        if case .some(.attemptOnce) = decision { return "attempt_publish_once" }
        return proposedAction
    }
}

/// 发布授权不是从网页正文推断的意图，而是用户指令形成的可追溯状态。
/// 解析先去除引号/代码引用，再按指令分句处理否定、未来时序与目标范围；
/// 最新可执行分句覆盖旧状态，没有可执行谓词的插话则保持原状态。
struct PublishAuthorization: Codable, Equatable {
    struct Change: Codable, Equatable {
        var revision: Int
        var instruction: String
        var source: String
        var authorized: Bool
        var pending: Bool? = nil
        var scopes: [String]
        var reason: String
        var changedAt: Date
    }

    var authorized: Bool
    var pending: Bool? = nil
    var scopes: [String]
    var sourceInstruction: String
    var source: String
    var revision: Int
    var reason: String
    var updatedAt: Date
    var history: [Change]

    var allowsZhihuAnswer: Bool { authorized && scopes.contains("zhihu_answer") }
    var awaitsConfirmation: Bool { pending == true }
    var explanation: String {
        "revision=\(revision)，state=\(awaitsConfirmation ? "pending" : (authorized ? "authorized" : "blocked"))，source=\(source)，reason=\(reason)，instruction=\(sourceInstruction)"
    }

    static func initial(instruction: String) -> PublishAuthorization {
        var value = PublishAuthorization(authorized: false, scopes: [], sourceInstruction: instruction,
            source: "task_goal", revision: 0, reason: "任务目标没有当前发布授权",
            updatedAt: Date(), history: [])
        value.apply(instruction: instruction, source: "task_goal")
        return value
    }

    mutating func apply(instruction: String, source: String) {
        guard let parsed = Self.parse(instruction, inheritedScopes: scopes,
                                      inheritedPending: awaitsConfirmation) else { return }
        revision += 1
        authorized = parsed.authorized
        pending = parsed.pending
        scopes = parsed.scopes
        sourceInstruction = instruction
        self.source = source
        reason = parsed.reason
        updatedAt = Date()
        history.append(Change(revision: revision, instruction: instruction, source: source,
                              authorized: authorized, pending: pending, scopes: scopes,
                              reason: reason, changedAt: updatedAt))
        if history.count > 12 { history.removeFirst(history.count - 12) }
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 真正把用户指令本体与 Markdown 引用块、代码块和行内引文分离。
    /// 被分离的引用永不进入授权分句。
    private static func instructionBody(_ raw: String) -> String {
        var inFence = false
        var kept: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence || trimmed.hasPrefix(">") { continue }
            kept.append(line)
        }
        var text = kept.joined(separator: "\n")
        for pattern in ["“[^”]*”", "‘[^’]*’", "「[^」]*」", "『[^』]*』", "\"[^\"]*\"", "`[^`]*`"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return text
    }

    /// 返回 nil 表示这条插话没有发布授权语义，不能误撤销/误授予。
    private static func parse(_ raw: String, inheritedScopes: [String], inheritedPending: Bool)
        -> (authorized: Bool, pending: Bool, scopes: [String], reason: String)? {
        let text = instructionBody(raw)
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: "，。；;！？!?\n"))
            .flatMap { $0.components(separatedBy: "但") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var result: (Bool, Bool, [String], String)?
        for clause in clauses {
            if matches("(原文|正文|草稿|引用|示例|标题).*(写着|包含|出现|提到)", clause) { continue }
            let hasPublishVerb = matches("(发出去|发出|发到|发布|发表|提交(回答)?|发了|post|publish|submit)", clause)
            let draftDirective = matches("(只|仅).{0,6}(写|存|保存).{0,4}草稿", clause)
            let confirmation = matches("^(我)?(已)?(确认|批准|同意)(了)?$", clause) ||
                matches("^(现在)?可以(发|发布|发表|提交)(了)?$", clause)
            if inheritedPending, confirmation, !inheritedScopes.isEmpty {
                result = (true, false, inheritedScopes, "后续用户指令已满足待确认条件，当前发布授权转正")
                continue
            }
            let future = matches("(稍后|以后|之后|待会|回头|将来).{0,8}(发|发布|发表|提交)", clause)
            let conditional = matches("(等|待).{0,10}(确认|批准|同意).{0,8}(后|以后|再).{0,8}(发|发布|发表|提交)", clause) ||
                matches("(确认|批准|同意)(之)?后.{0,4}(再)?(发|发布|发表|提交)", clause) ||
                matches("待(确认|批准|同意)", clause)
            guard hasPublishVerb || draftDirective || conditional else { continue }
            let negated = matches("(暂不|暂时不|不要|别|勿|无需|不再|停止).{0,8}(发|发布|发表|提交)", clause) ||
                matches("(不发布|不发表|不提交)", clause) || draftDirective
            let scopes: [String]
            if matches("(想法)", clause) { scopes = ["zhihu_thought"] }
            else if matches("(回答|答复|这篇|该篇|当前内容|这份)", clause) { scopes = ["zhihu_answer"] }
            else if inheritedScopes.contains("zhihu_answer") { scopes = ["zhihu_answer"] }
            else if matches("(知乎)", text) { scopes = ["zhihu_answer"] }
            else if matches("^(把)?(这篇|这个|该)?(回答|内容)?(发出去|发出|发布|发表|提交(回答)?|发了)$", clause) { scopes = ["zhihu_answer"] }
            else { scopes = [] }
            if conditional {
                result = (false, true, scopes.isEmpty ? inheritedScopes : scopes,
                          "发布条件尚未满足，记为待授权；当前不允许点击")
            } else if negated || future {
                result = (false, false, scopes.isEmpty ? inheritedScopes : scopes,
                          future ? "指令只表达未来发布，不授权当前点击" : "最新指令明确撤销当前发布或限定仅草稿")
            } else if hasPublishVerb, !scopes.isEmpty {
                result = (true, false, scopes, "最新用户指令明确授权当前发布到 \(scopes.joined(separator: ","))")
            }
        }
        return result
    }
}

/// stableID 是持久化等价类主键，aliases 是已验证属于同一知乎账号的
/// id/urlToken 并集。页面只暴露部分别名时不再生成“新账号”。
struct ZhihuAccountIdentity: Codable, Equatable {
    var stableID: String
    var aliases: [String]

    var isResolved: Bool { !stableID.isEmpty && !aliases.isEmpty }

    static func normalizedAliases(_ raw: [String]) -> [String] {
        Array(Set(raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
    }

    static func legacyAliases(_ legacy: String?) -> [String] {
        normalizedAliases((legacy ?? "").split(separator: "|").map(String.init))
    }

    func intersects(_ other: [String]) -> Bool {
        !Set(aliases).isDisjoint(with: Set(Self.normalizedAliases(other)))
    }
}

struct WriteProof: Codable, Equatable {
    var taskID: UUID
    var tabID: UUID
    var documentEpoch: Int
    var frameID: String
    var questionID: String
    var editorIdentity: String
    var composerIdentity: String
    var bodyVersion: String
    var expectedTextHash: String
    var committedTextHash: String
    var comparisonRule: String
    var comparisonResult: String
    var observedAt: Date
    /// 导出必须能取回源稿与 committed 全文，不能只留附件引用。
    var expectedText: String
    var committedText: String

    var isValid: Bool {
        comparisonRule == ZhihuPublishPolicy.fullTextComparisonRule &&
        comparisonResult == "equal" &&
        !questionID.isEmpty && !editorIdentity.isEmpty && !composerIdentity.isEmpty &&
        expectedTextHash == committedTextHash &&
        ZhihuPublishPolicy.normalizeFullText(expectedText) == ZhihuPublishPolicy.normalizeFullText(committedText)
    }
}

struct ZhihuPublishBinding: Codable, Equatable {
    var tabID: UUID
    var documentEpoch: Int
    var questionID: String
    var editorIdentity: String
    var composerIdentity: String
    var buttonIdentity: String
    var buttonIndex: Int
    var buttonLabel: String
    var candidateCount: Int
    var revealed: Bool
    var blocked: Bool
    var nativeDisabled: Bool
    var disabledFieldset: Bool
    var ariaDisabled: Bool
    var observationSource: String

    var disabledSummary: String {
        "native=\(nativeDisabled), fieldset=\(disabledFieldset), aria=\(ariaDisabled), source=\(observationSource)"
    }

    func matches(proof: WriteProof) -> Bool {
        tabID == proof.tabID && documentEpoch == proof.documentEpoch &&
        questionID == proof.questionID && editorIdentity == proof.editorIdentity &&
        composerIdentity == proof.composerIdentity && candidateCount == 1 && buttonIndex >= 0
    }
}

enum PublishDecision: Equatable {
    case attemptOnce
    case readbackOnly(String)
    case alreadyPublished(String)
    case blocked(String)
}

enum ZhihuPublishStatus: String, Codable {
    case attemptStarted
    case attempted
    case verifiedPublished
    case submittedForReview
    case explicitlyFailed
    case unknown

    /// submittedForReview/explicitlyFailed 只为旧账解码保留。保守规格把两者
    /// 都视为未决，永久保留同题阻断；新生产路径不得再生成这两个状态。
    var isPending: Bool {
        self == .attemptStarted || self == .attempted || self == .unknown ||
        self == .submittedForReview || self == .explicitlyFailed
    }
    var needsReadback: Bool { self == .attemptStarted || self == .attempted || self == .unknown }
    var display: String {
        switch self {
        case .attemptStarted, .attempted: return "已尝试"
        case .verifiedPublished: return "已核实发布"
        case .submittedForReview, .explicitlyFailed, .unknown:
            return ZhihuPublishPolicy.unknownNotice
        }
    }
}

struct ZhihuPublishRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var taskID: UUID
    var runID: UUID
    /// 规范化账号别名键（id/urlToken 排序连接）；旧记录为 nil，不能跨账号命中。
    var accountIdentity: String?
    /// FIX6 稳定账号主键与已验证别名并集。可选字段保证 FIX4/FIX5 旧账可解码迁移。
    var accountStableID: String? = nil
    var accountAliases: [String]? = nil
    var questionID: String
    var expectedTextHash: String
    var bodyVersion: String
    var sourceText: String
    var status: ZhihuPublishStatus
    /// nil 表示尚未执行 FIX5 要求的那一次有界回读；unknown 配合非 nil
    /// 表示窗口已经收口，后续只报告、不重复开窗口。
    var readbackCompletedAt: Date? = nil
    var attemptStartedAt: Date
    var clickCallCount: Int
    var clickResult: String
    var answerID: String?
    var answerURL: String?
    var authorIdentity: String?
    var readbackText: String?
    var resultDetail: String
}

struct ZhihuReadbackTarget: Codable, Equatable {
    var questionID: String
    var expectedTextHash: String
    var sourceText: String
    /// accountIdentity 在 FIX6 起保存稳定主键；页面匹配使用 accountAliases 的交集。
    var accountIdentity: String
    var accountAliases: [String]
    var attemptID: UUID
    var taskID: UUID
}

struct ZhihuPublicationEvidence: Codable, Equatable {
    var status: ZhihuPublishStatus
    var questionID: String
    var answerID: String
    var answerURL: String
    var currentAccountIdentity: String
    var authorIdentity: String
    var bodyText: String
    var fullTextEqual: Bool
    var pageState: String
    var rejectionText: String
    var observedAt: Date

    var verifiesPublished: Bool {
        status == .verifiedPublished && !answerID.isEmpty && !answerURL.isEmpty &&
        !currentAccountIdentity.isEmpty && currentAccountIdentity == authorIdentity && fullTextEqual
    }
}

struct ZhihuPublishDirective: Codable, Equatable {
    var writeStatus: String
    var publicationStatus: String
    var publishTarget: String
    var evidenceSource: String
    var disabledObservation: String
    var disabledTrustForThisDecision: String
    var nextAction: String
    var blockingReason: String?

    func promptBlock() -> String {
        var lines = [
            "【知乎发布派生指令】（引擎生成；每轮保留）",
            "writeStatus: \(writeStatus)",
            "publicationStatus: \(publicationStatus)",
            "publishTarget: \(publishTarget)",
            "evidenceSource: \(evidenceSource)",
            "disabledObservation: \(disabledObservation)",
            "disabledTrustForThisDecision: \(disabledTrustForThisDecision)",
            "nextAction: \(nextAction)"
        ]
        if let blockingReason { lines.append("blockingReason: \(blockingReason)") }
        return lines.joined(separator: "\n")
    }
}
