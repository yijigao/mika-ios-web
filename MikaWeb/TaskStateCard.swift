import Foundation

// 结构化任务状态卡（H1，2026-11-02）：程序维护的任务事实账，随会话快照
// 持久化、每轮 prompt 注入。它与「模型散文摘要」的区别是硬性的：每个字段
// 都由程序在确定事件点更新（任务开始、动作记账、用户答复、用户跳过、
// 等待状态变化、成果台账落记），不让模型用一段总结改写事实。长任务里
// 历史步骤会被确定性折叠（见 AgentEngine 的 historyText），状态卡不参与
// 折叠——目标、已完成里程碑与关键事实始终全文在场。
//
// pinnedFacts（关键事实）口径：永不参与任何压缩/折叠/滚动淘汰。来源只
// 有程序事件：用户的答复（对 ask_user 的回答）、用户明确跳过某步的决定。
// 它有防爆上限（去重后仍超限才丢最旧），但那只是防病态膨胀的保险丝，
// 不是常规淘汰策略——常规任务的答复量远够不到。
struct TaskStateCard: Codable, Equatable {
    var goal: String = ""
    /// 已完成里程碑（每条一行「动作：说明」，由 record 路径记账）
    var completed: [String] = []
    /// 待办（由引擎按当前等待/运行状态派生刷新，不是模型写的计划）
    var todos: [String] = []
    /// 关键事实：永不压缩（见文件头口径）
    var pinnedFacts: [String] = []
    /// 未决问题（当前等待用户回答的问题原文；无等待时为空）
    var openQuestions: [String] = []
    /// 成果台账引用（人读短行；台账详情与定力口径仍由台账注入段承担）
    var outcomeRefs: [String] = []
    /// 成功写入页面的短记录；可选键使旧状态卡快照照常解码。
    var writes: [String]? = nil
    var updatedAt: Date = Date()

    /// 防爆值：已完成里程碑滚动保留最近 30 条（更早的里程碑仍在原始步流
    /// 记录里，可回溯；卡片只承担「当前事实速览」，不能无限长）。
    static let completedCap = 30
    /// 防爆值：关键事实去重后超过 50 条才丢最旧（见文件头口径）。
    static let pinnedCap = 50
    static let writesCap = 8

    mutating func addCompleted(_ line: String) {
        let trimmed = String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !trimmed.isEmpty else { return }
        completed.append(trimmed)
        if completed.count > Self.completedCap { completed.removeFirst(completed.count - Self.completedCap) }
        updatedAt = Date()
    }

    mutating func pinFact(_ fact: String) {
        let trimmed = String(fact.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        guard !trimmed.isEmpty, !pinnedFacts.contains(trimmed) else { return }
        pinnedFacts.append(trimmed)
        if pinnedFacts.count > Self.pinnedCap { pinnedFacts.removeFirst(pinnedFacts.count - Self.pinnedCap) }
        updatedAt = Date()
    }

    mutating func addWrite(target: String, body: String) {
        let label = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = String(body.prefix(24)).map { $0.isNewline ? " " : String($0) }.joined()
        let line = "\(label.isEmpty ? "（目标未名）" : label)←\(preview)（\(body.count)字）"
        var entries = writes ?? []
        entries.append(line)
        if entries.count > Self.writesCap { entries.removeFirst(entries.count - Self.writesCap) }
        writes = entries
        updatedAt = Date()
    }

    /// prompt 注入形态：只列非空段；目标为空（无任务）返回空串不注入。
    /// 「关键事实」段带不可丢弃声明——它与历史折叠相互独立，折叠级别
    /// 再高也不会动这一段（自检八对此有断言）。
    func promptBlock() -> String {
        guard !goal.isEmpty else { return "" }
        var lines = ["【任务状态卡】（程序维护的事实账，不是模型摘要；「关键事实」在任何压缩下都不丢弃）"]
        lines.append("目标：\(goal)")
        if !completed.isEmpty { lines.append("已完成：" + completed.joined(separator: "；")) }
        if !todos.isEmpty { lines.append("待办：" + todos.joined(separator: "；")) }
        if !pinnedFacts.isEmpty { lines.append("关键事实（不可丢弃）：" + pinnedFacts.joined(separator: "；")) }
        if !openQuestions.isEmpty { lines.append("未决问题：" + openQuestions.joined(separator: "；")) }
        if !outcomeRefs.isEmpty { lines.append("成果台账引用：" + outcomeRefs.joined(separator: "；")) }
        if let writes, !writes.isEmpty { lines.append("【已写入页面的内容】\n" + writes.map { "· " + $0 }.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }
}
