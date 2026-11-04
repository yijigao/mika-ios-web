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
//   里就是一条新任务，台账必须跨得过这道界；24 小时过期、最多 20 条封顶。
// - 内容只存规范化正文的哈希指纹与前 24 字短前缀，不存全文副本（正文已在
//   对话条目与页面里）；凭据不经此路。
struct OutcomeRecord: Codable, Identifiable {
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
    /// 状态说明：落记时为「已提交（待核查）」；done 可附未经独立核实的
    /// 结案自述，仍保持待核查。旧「已核实（完成总结）」仅展示时降级。
    var statusNote: String
    var recordedAt: Date
    /// 经软门提醒（或用户确认）后再次提交的最近时间（可选，旧记录无此键照常解码）
    var resubmittedAt: Date?
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
