import Foundation

// 成果台账（OUTCOME-LEDGER，2026-11-02）：会话级「已完成关键动作」记录。
//
// 缘起（Joey 2026-11-02 20:50 真机复测 1218 实证）：agent 已完成微头条投稿并在
// 内容列表核实「稿件存在、状态审核中」，用户一句「成功了对吗？」后它回编辑器
// 发现 407 字稿件还在，又提交了一遍（重复投稿风险），最后还把先前核实过的
// 结论推翻成「无法确认是否提交成功」。台账记录动作实录，防重复提交；
// 提交是否生效须由内容列表/记录页回读，模型结案自述不构成核验证据。
// 本文件只定义记录结构与提交类判定／内容指纹，
// 台账的持有、落记、软门与注入都在 AgentEngine。
//
// 口径要点：
// - 「会话级」按 App 会话理解：台账跨任务、跨进程存活（自有 UserDefaults
//   持久化＋随会话快照双写，见 AgentEngine）。新任务不清台账——追问在 App
//   里就是一条新任务，台账必须跨得过这道界；未决永久保留，仅已决条目裁剪。
// - 内容只存规范化正文的哈希指纹与前 24 字短前缀，不存全文副本（正文已在
//   对话条目与页面里）；凭据不经此路。
struct OutcomeRecord: Codable, Identifiable {
    enum DispatchState: String, Codable, Equatable { case sent, notSent = "not_sent", unknown }
    var id: UUID
    /// 提交发生的页面地址（完整 URL）与主机名（file URL 时主机为空串）
    var pageURL: String
    var host: String
    /// 被点的提交类元素的人读标签（按钮文案，回退 aria-label）
    var elementLabel: String
    /// 内容指纹：正文规范化后的 FNV-1a 哈希（与 LoopDetector 同算法）；
    /// 本会话无打字记录时为空串，此时匹配退到「同页面＋同按钮」标识
    var contentFingerprint: String
    /// 内容短前缀（规范化正文前 24 字），仅供人／模型辨认，不存全文
    var contentPrefix: String
    /// 旧展示说明；派发与核验真值分别由结构字段承载。
    var statusNote: String
    var recordedAt: Date
    /// 经软门提醒（或用户确认）后再次提交的最近时间（可选，旧记录无此键照常解码）
    var resubmittedAt: Date?
    // Optional for v1 UserDefaults and SessionSnapshot compatibility. A missing
    // receipt is unresolved, never proof that a submission was not dispatched.
    var taskID: UUID? = nil
    var actionID: UUID? = nil
    var dispatchState: DispatchState? = nil
    var verificationVerdict: VerificationVerdict? = nil
    var dispatchEvidence: String? = nil
    var verificationEvidenceID: UUID? = nil
    var unresolved: Bool {
        dispatchState != .notSent && (dispatchState != .sent || verificationVerdict != .verified)
    }
}

/// One host-dispatch attempt. Receipt and business verification are separate axes.
/// A prepared receipt starts as unknown so a crash can never imply not_sent.
struct ExecutionReceipt: Codable, Identifiable {
    var id: UUID
    var actionID: UUID
    var taskID: UUID
    var actionName: String
    var targetHash: String
    var critical: Bool
    var dispatchState: OutcomeRecord.DispatchState
    var verificationVerdict: VerificationVerdict?
    var evidenceRef: String
    var createdAt: Date
    var updatedAt: Date

    var blocksDependencies: Bool {
        critical && dispatchState != .notSent &&
            (dispatchState != .sent || verificationVerdict != .verified)
    }
    var resolved: Bool { !blocksDependencies && dispatchState != .unknown }
}

/// 提交类元素的判定与内容指纹（与 SafetyPolicy 分工：SafetyPolicy 管
/// 付款／授权类确认门，本分类只认「把内容发出去」的发布／提交类动作；
/// 两边在 runTargeted／runConfirmed 的执行成功点汇合——经确认执行的
/// 「提交订单」类元素同样会被台账记下，防重复提交）。
enum SubmissionClassifier {
    static let keywords = ["publish", "submit", "post", "send", "share",
                           "发布", "发表", "提交", "投稿", "发送", "分享"]
    static func isSubmissionElement(_ element: PageElement) -> Bool {
        let label = [element.text, element.ariaLabel, element.placeholder, element.name]
            .joined(separator: " ").lowercased()
        return keywords.contains(where: label.contains)
    }
    /// 内容指纹：先按 ElementDescriptor.norm 规范化（小写＋空白折叠，首尾
    /// 空白天然去掉），再走 LoopDetector 的 FNV-1a；前缀取规范化后前 24 字。
    /// 空正文返回空指纹（调用方走页面＋按钮标识匹配）。
    static func contentFingerprint(of raw: String) -> (hash: String, prefix: String) {
        let normalized = ElementDescriptor.norm(raw)
        guard !normalized.isEmpty else { return ("", "") }
        return (LoopDetector.textFingerprint(normalized), String(normalized.prefix(24)))
    }
}

/// FIX6 账号别名等价类。stableID 一经建立保持不变；后续页面同时暴露新旧别名
/// 时只扩充 aliases 并集，不重算主键。这样 id|token、token 两种页面表示仍命中
/// 同一发布账。无法和既有同题记录确认连续性时 resolve 返回 nil（fail-closed）。
struct ZhihuAccountRegistry: Codable, Equatable {
    var identities: [ZhihuAccountIdentity] = []

    private mutating func register(aliases raw: [String], preferredStableID: String? = nil) -> ZhihuAccountIdentity? {
        let aliases = ZhihuAccountIdentity.normalizedAliases(raw)
        guard !aliases.isEmpty else { return nil }
        let hits = identities.indices.filter { identities[$0].intersects(aliases) }
        let stableID = hits.compactMap { identities[$0].stableID.isEmpty ? nil : identities[$0].stableID }.first ??
            preferredStableID.flatMap { $0.isEmpty ? nil : $0 } ??
            "zhacct-\(ZhihuPublishPolicy.hash(aliases.joined(separator: "|")))"
        let union = ZhihuAccountIdentity.normalizedAliases(aliases + hits.flatMap { identities[$0].aliases })
        for index in hits.sorted(by: >) { identities.remove(at: index) }
        let identity = ZhihuAccountIdentity(stableID: stableID, aliases: union)
        identities.append(identity)
        return identity
    }

    /// 兼容读取旧 accountIdentity 拼接键，并把迁移结果回填到记录的新字段。
    mutating func migrate(records: inout [ZhihuPublishRecord]) {
        for index in records.indices {
            let aliases = ZhihuAccountIdentity.normalizedAliases(
                (records[index].accountAliases ?? []) + ZhihuAccountIdentity.legacyAliases(records[index].accountIdentity))
            guard let identity = register(aliases: aliases,
                                          preferredStableID: records[index].accountStableID) else { continue }
            records[index].accountStableID = identity.stableID
            records[index].accountAliases = identity.aliases
        }
        // 前面逐条扩并集后，按别名交集回填最终等价类。旧记录原先各自带着
        // 不同拼接键时也会统一到合并后的 stableID，而非只补 aliases。
        for index in records.indices {
            let aliases = ZhihuAccountIdentity.normalizedAliases(
                (records[index].accountAliases ?? []) + ZhihuAccountIdentity.legacyAliases(records[index].accountIdentity))
            guard let identity = identities.first(where: { $0.intersects(aliases) }) else { continue }
            records[index].accountStableID = identity.stableID
            records[index].accountAliases = identity.aliases
        }
    }

    mutating func resolve(observedAliases raw: [String], questionID: String,
                          records: [ZhihuPublishRecord]) -> ZhihuAccountIdentity? {
        let aliases = ZhihuAccountIdentity.normalizedAliases(raw)
        guard !aliases.isEmpty else { return nil }
        let cached = identities.filter { $0.intersects(aliases) }
        let candidateAliases = ZhihuAccountIdentity.normalizedAliases(
            aliases + cached.flatMap(\.aliases))
        let candidateStableIDs = Set(cached.map(\.stableID).filter { !$0.isEmpty })

        // 缓存命中也必须先核对同题旧账。跨题分别见过 me-id / me-token 只会
        // 建立两个候选身份，不构成“它们属于不同账号”的区分证据；回到有
        // me-id 未决账的题目而页面仅暴露 me-token 时必须 fail-closed。
        let hasAmbiguousSameQuestion = records.contains { record in
            guard record.questionID == questionID,
                  let recorded = ZhihuPublishLedger.identity(for: record) else { return false }
            return !candidateStableIDs.contains(recorded.stableID) &&
                !recorded.intersects(candidateAliases)
        }
        guard !hasAmbiguousSameQuestion else { return nil }
        return register(aliases: aliases)
    }
}

/// 发布账按「稳定账号等价类＋题目＋全文哈希」查询；taskID 不能解除同题未决。
enum ZhihuPublishLedger {
    static func identity(for record: ZhihuPublishRecord) -> ZhihuAccountIdentity? {
        let aliases = ZhihuAccountIdentity.normalizedAliases(
            (record.accountAliases ?? []) + ZhihuAccountIdentity.legacyAliases(record.accountIdentity))
        guard !aliases.isEmpty else { return nil }
        let stableID = record.accountStableID.flatMap { $0.isEmpty ? nil : $0 } ??
            "zhacct-\(ZhihuPublishPolicy.hash(aliases.joined(separator: "|")))"
        return ZhihuAccountIdentity(stableID: stableID, aliases: aliases)
    }

    static func accountMatches(_ record: ZhihuPublishRecord, account: ZhihuAccountIdentity) -> Bool {
        guard let recorded = identity(for: record) else { return false }
        return recorded.stableID == account.stableID || recorded.intersects(account.aliases)
    }

    static func pending(account: ZhihuAccountIdentity, questionID: String,
                        in records: [ZhihuPublishRecord]) -> ZhihuPublishRecord? {
        records.last { accountMatches($0, account: account) && $0.questionID == questionID && $0.status.isPending }
    }

    static func verified(account: ZhihuAccountIdentity, questionID: String, textHash: String? = nil,
                         in records: [ZhihuPublishRecord]) -> ZhihuPublishRecord? {
        records.last {
            accountMatches($0, account: account) && $0.questionID == questionID &&
            (textHash == nil || $0.expectedTextHash == textHash) && $0.status == .verifiedPublished
        }
    }
}
