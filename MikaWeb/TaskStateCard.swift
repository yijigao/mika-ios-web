import Foundation

/// 一条可跨任务保存的事实主张。sourceTaskID 是硬边界；verifiedByUser
/// 一旦置位便只能保持终局，任何待核查写入都会被拒绝。
struct TaskStateClaim: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case unverified, verified }
    var id: UUID
    var sourceTaskID: UUID
    var text: String
    private(set) var status: Status
    private(set) var verifiedByUser: Bool

    init(id: UUID = UUID(), sourceTaskID: UUID, text: String,
         status: Status = .unverified, verifiedByUser: Bool = false) {
        self.id = id; self.sourceTaskID = sourceTaskID; self.text = text
        self.status = verifiedByUser ? .verified : status
        self.verifiedByUser = verifiedByUser
    }

    @discardableResult mutating func setStatus(_ newStatus: Status, verifiedByUser: Bool = false) -> Bool {
        if self.verifiedByUser && newStatus != .verified { return false }
        status = verifiedByUser ? .verified : newStatus
        self.verifiedByUser = self.verifiedByUser || verifiedByUser
        return true
    }

    var displayText: String { verifiedByUser ? "\(text)（据用户确认）" : text }
}

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
    /// 页面写入尝试的短记录；尝试与核实结果分列，可选键使旧快照照常解码。
    var writes: [String]? = nil
    /// 知乎回答的正文与发布是两条独立状态轴。可选键保证旧快照兼容。
    var zhihuWriteStatus: String? = nil
    var zhihuPublicationStatus: String? = nil
    var updatedAt: Date = Date()

    /// 只由程序维护的任务归属主张；可选键保证旧快照兼容。
    var claims: [TaskStateClaim]? = nil

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

    mutating func addWrite(target: String, body: String, verification: String = "unknown") {
        let label = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = String(body.prefix(24)).map { $0.isNewline ? " " : String($0) }.joined()
        var entries = writes ?? []
        entries = entries.map { line in
            if line.hasPrefix("当前内容；") { return line.replacingOccurrences(of: "当前内容；", with: "旧版本；") }
            if line.hasPrefix("旧版本；") { return line }
            return "旧版本；旧格式；核实=unknown；" + line
        }
        let normalized = ["verified", "failed", "unknown"].contains(verification) ? verification : "unknown"
        let line = "当前内容；type=replace（整段替换）；目标=\(label.isEmpty ? "（目标未名）" : label)；尝试=attempt；核实=\(normalized)；预览=\(preview)（\(body.count)字）"
        entries.append(line)
        if entries.count > Self.writesCap { entries.removeFirst(entries.count - Self.writesCap) }
        writes = entries
        updatedAt = Date()
    }

    mutating func setZhihuStatus(write: String? = nil, publication: String? = nil) {
        if let write { zhihuWriteStatus = write }
        if let publication { zhihuPublicationStatus = publication }
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
        if let writes, !writes.isEmpty { lines.append("【页面写入版本账】（type 语义固定为 replace／整段替换；attempt 不等于已写入，核实仅取 verified/failed/unknown）\n" + writes.map { "· " + $0 }.joined(separator: "\n")) }
        if zhihuWriteStatus != nil || zhihuPublicationStatus != nil {
            lines.append("【知乎回答状态】正文：\(zhihuWriteStatus ?? "未核实")／发布：\(zhihuPublicationStatus ?? "未尝试")")
        }
        return lines.joined(separator: "\n")
    }

    /// 任务级呈现：本任务主张全部可见；跨任务只允许已核实事实作为只读
    /// 背景。旧任务未核实项只给一行存在性提示，不泄露细节也不派生待办。
    func claimPromptBlock(currentTaskID: UUID) -> String {
        let all = claims ?? []
        let current = all.filter { $0.sourceTaskID == currentTaskID }
        let background = all.filter { $0.sourceTaskID != currentTaskID && $0.status == .verified }
        let hasForeignUnverified = all.contains { $0.sourceTaskID != currentTaskID && $0.status == .unverified }
        guard !current.isEmpty || !background.isEmpty || hasForeignUnverified else { return "" }
        var lines = ["【任务主张账】（按任务隔离）"]
        if !background.isEmpty {
            lines.append("已核实事实（背景，只读；本任务不得重开或降级）：" + background.map(\.displayText).joined(separator: "；"))
        }
        if !current.isEmpty {
            lines.append("本任务主张：" + current.map { "\($0.displayText)［\($0.status == .verified ? "已核实" : "待核查")］" }.joined(separator: "；"))
        }
        if hasForeignUnverified { lines.append("上个任务有未核实记录（不属于本任务）") }
        return lines.joined(separator: "\n")
    }
}
