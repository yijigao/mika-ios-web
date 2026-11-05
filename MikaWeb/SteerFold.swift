import Foundation

/// 呈现变换只读原条目；组 ID 按 taskID＋该任务的过程组序号确定。
enum ProcessFold {
    enum Phase: Equatable { case executing, completed, stopped }
    struct Node: Identifiable {
        let id: String
        var entries: [ChatEntry]
        let isGroup: Bool
    }
    static func nodes(_ entries: [ChatEntry]) -> [Node] {
        var result: [Node] = []
        var ordinals: [String: Int] = [:]
        for entry in entries {
            let key = entry.taskID?.uuidString ?? "unowned"
            if entry.kind == .process {
                if let index = result.indices.last, result[index].isGroup, result[index].entries.last?.taskID == entry.taskID {
                    result[index].entries.append(entry)
                } else {
                    let ordinal = ordinals[key, default: 0]
                    ordinals[key] = ordinal + 1
                    result.append(Node(id: "process-\(key)-\(ordinal)", entries: [entry], isGroup: true))
                }
            } else {
                result.append(Node(id: entry.id.uuidString, entries: [entry], isGroup: false))
            }
        }
        return result
    }
    static func summary(action: String?, reason: String?, text: String) -> String {
        let raw = action.map { "\($0)：\(reason ?? text)" } ?? text
        return String(raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(96))
    }
    static func header(_ entries: [ChatEntry], phase: Phase) -> String {
        guard let latest = entries.last else { return "" }
        switch phase {
        case .executing:
            return "正在执行 · 第 \(latest.stepID ?? entries.count) 步 · \(summary(action: latest.action, reason: latest.reason, text: latest.text))"
        case .completed: return "已完成 \(entries.count) 步"
        case .stopped: return "已停止 · 共 \(entries.count) 步"
        }
    }
    static func accessibility(_ entries: [ChatEntry], phase: Phase) -> String {
        guard let latest = entries.last else { return "" }
        return header(entries, phase: phase) + "，共 \(entries.count) 步，最新动作：" + summary(action: latest.action, reason: latest.reason, text: latest.text)
    }
    static func phase(taskID: UUID?, entries: [ChatEntry], currentTaskID: UUID?, current: Phase) -> Phase {
        if taskID == currentTaskID { return current }
        if entries.contains(where: { $0.taskID == taskID && $0.kind == .result }) { return .completed }
        if entries.contains(where: { $0.taskID == taskID && ($0.kind == .error || $0.action == "ended") }) { return .stopped }
        if let last = entries.last(where: { $0.kind == .userTask }), last.taskID != taskID { return .stopped }
        return .executing
    }
}

enum ProcessFoldTierA {
    static func verify() -> [String] {
        let a = UUID(), b = UUID()
        func entry(_ kind: ChatEntryKind, _ task: UUID, _ n: Int = 1) -> ChatEntry {
            ChatEntry(taskID: task, kind: kind, text: "动作 \(n)", stepID: n, action: "click", reason: "目标 \(n)", source: .engineStep)
        }
        let pair = [entry(.process, a), entry(.process, a, 2)]
        let nodes = ProcessFold.nodes(pair)
        let barriers: [ChatEntryKind] = [.error, .result, .userTask, .userAnswer, .userSteer, .question, .manual, .pause, .local]
        let plain = [entry(.userTask, a), entry(.error, a)]
        let checks: [(Bool, String)] = [
            (nodes.count == 1 && nodes[0].entries.count == 2 && ProcessFold.header(pair, phase: .executing) == "正在执行 · 第 2 步 · click：目标 2", "连续过程合组，步数与最新摘要"),
            (barriers.allSatisfy { ProcessFold.nodes([pair[0], entry($0, a), pair[1]]).count == 3 }, "错误、结果、用户及介入条目逐项打断分组"),
            (ProcessFold.nodes([]).isEmpty && ProcessFold.nodes(plain).flatMap { $0.entries.map { $0.id } } == plain.map { $0.id } && ProcessFold.nodes([plain[0]])[0].entries[0].id == plain[0].id, "空流、单条与无过程等价"),
            (ProcessFold.header(pair, phase: .completed) == "已完成 2 步" && ProcessFold.header(pair, phase: .stopped) == "已停止 · 共 2 步" && ProcessFold.accessibility(pair, phase: .completed).contains("目标 2"), "运行实时尾行、终态标题及无障碍最新动作"),
            (ProcessFold.nodes([pair[0], entry(.process, b)]).count == 2 && ProcessFold.nodes(pair).map { $0.id } == nodes.map { $0.id }, "跨任务不合并且变换确定")
        ]
        return checks.map { "\($0.0 ? "✓" : "✗") \($0.1)" }
    }
}

struct SteerItem: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let enqueuedAt: Date
    var consumedStep: Int? = nil
    var disposition: Disposition = .pending
    enum Disposition: String, Codable { case pending, frozen, applied, withdrawn, queued, interrupt, discarded }
    var isPending: Bool { disposition == .pending || disposition == .frozen }
    var label: String {
        switch disposition {
        case .pending: return "插话 · 将在下一步生效"
        case .frozen: return "插话 · 已暂停，继续后生效"
        case .applied: return "插话 · 已生效"
        case .withdrawn: return "插话 · 已撤回"
        case .queued: return "插话 · 已改为排队"
        case .interrupt: return "插话 · 已改为中断并发送"
        case .discarded: return "插话 · 未生效（任务已结束）"
        }
    }
}

/// 只拥有插话数据，不接触 goal、answerContext 或模型步数预算。
struct SteerState: Codable, Equatable {
    let taskID: UUID
    let sessionID: UUID
    var items: [SteerItem] = []
    var invalidationReason: String? = nil
    let feedbackID: UUID
    init(taskID: UUID, sessionID: UUID) {
        self.taskID = taskID; self.sessionID = sessionID; feedbackID = UUID()
    }
    var pending: [SteerItem] { items.filter { $0.isPending } }
    static func allowsThreeWay(viewingRun: Bool, running: Bool, waiting: Bool) -> Bool {
        viewingRun && running && !waiting
    }
    mutating func enqueue(_ text: String, id: UUID = UUID(), now: Date = Date()) -> Bool {
        guard pending.count < 3, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        items.append(SteerItem(id: id, text: text, enqueuedAt: now)); return true
    }
    mutating func freeze() {
        for i in items.indices where items[i].isPending { items[i].disposition = .frozen }
    }
    mutating func thaw() {
        for i in items.indices where items[i].disposition == .frozen { items[i].disposition = .pending }
    }
    mutating func consume(step: Int) -> String? {
        let ready = pending
        guard !ready.isEmpty else { return nil }
        for i in items.indices where items[i].isPending {
            items[i].disposition = .applied; items[i].consumedStep = step
        }
        return ready.map { $0.text }.joined(separator: "\n")
    }
    mutating func move(_ id: UUID, to disposition: SteerItem.Disposition) -> SteerItem? {
        guard let i = items.firstIndex(where: { $0.id == id && $0.isPending }) else { return nil }
        items[i].disposition = disposition; return items[i]
    }
    static func restoredDraft(_ draft: String, text: String) -> String {
        draft.isEmpty ? text : draft + " " + text
    }
    mutating func invalidate(_ reason: String) {
        guard !pending.isEmpty else { return }
        invalidationReason = reason
        for i in items.indices where items[i].isPending { items[i].disposition = .discarded }
    }
    var feedback: String? {
        guard let reason = invalidationReason else { return nil }
        let discarded = items.filter { $0.disposition == .discarded }
        let heading = reason == "因新任务启动未生效" ? "\(discarded.count) 条插话因新任务启动未生效" : "\(discarded.count) 条插话未生效（\(reason)）"
        return heading + "，已作废，不会自动重发：" + discarded.map { "[\($0.id.uuidString)]「\($0.text)」" }.joined(separator: "；")
    }
}

/// 中断请求先落盘，再取消旧 worker；startingID 用于崩溃后识别是否已启动，禁止重放。
struct SteerInterrupt: Codable, Equatable, Identifiable {
    let id: UUID
    let taskID: UUID
    let sessionID: UUID
    let text: String
    let startingID: UUID
    var attempted = false
}

/// 一次中断的内存启动权。代次换代、非运行态和退出回执缺一不可。
struct SteerInterruptGate {
    let taskID: UUID?
    let oldGeneration: UUID
    private(set) var exited = false
    private(set) var launched = false
    init(taskID: UUID?, oldGeneration: UUID) {
        self.taskID = taskID; self.oldGeneration = oldGeneration
    }
    mutating func acknowledgeWorkerExit() { exited = true }
    mutating func reserveStart(taskID: UUID?, generation: UUID, running: Bool) -> Bool {
        guard taskID == self.taskID, oldGeneration != generation, !running, exited, !launched else { return false }
        launched = true
        return true
    }
}

/// 原文条目与反馈采用稳定 ID；一次事务任意次数补写都只有同一份去向凭证。
enum SteerProjection {
    static func apply(_ state: SteerState, to entries: [ChatEntry]) -> [ChatEntry] {
        var result = entries
        for item in state.items {
            if let i = result.firstIndex(where: { $0.id == item.id }) {
                result[i].steerStatus = item.label
            } else {
                var entry = ChatEntry(id: item.id, taskID: state.taskID, kind: .userSteer, text: item.text, source: .userAnswer, createdAt: item.enqueuedAt)
                entry.steerStatus = item.label
                result.append(entry)
            }
        }
        if let feedback = state.feedback {
            let retryText = state.items.filter { $0.disposition == .discarded }.map { $0.text }.joined(separator: "\n")
            if let index = result.firstIndex(where: { $0.id == state.feedbackID }) {
                result[index].steerRetryText = retryText
            } else {
                var entry = ChatEntry(id: state.feedbackID, taskID: state.taskID, kind: .local, text: feedback, source: .localValidation, createdAt: state.items.last?.enqueuedAt ?? Date(timeIntervalSince1970: 0))
                entry.steerRetryText = retryText
                result.append(entry)
            }
        }
        return result
    }
}

struct SteerSidecar: Codable {
    var tasks: [SteerState] = []
    var interrupt: SteerInterrupt? = nil
    mutating func recover(resumableTaskID: UUID?, snapshotTaskID: UUID?) {
        for i in tasks.indices {
            if tasks[i].taskID != resumableTaskID { tasks[i].invalidate("任务已结束或不可恢复") }
            else { tasks[i].freeze() }
        }
        if let request = interrupt, snapshotTaskID == request.startingID {
            interrupt = nil // 有目标现场就恢复目标任务，不重提中断请求。
        }
    }
    mutating func beforeStart(in sessionID: UUID) {
        for i in tasks.indices where tasks[i].sessionID == sessionID {
            tasks[i].invalidate("因新任务启动未生效")
        }
    }
    mutating func clearProjectedTasks(in sessionID: UUID) {
        tasks.removeAll { $0.sessionID == sessionID }
    }
}

enum SteerTierA {
    static func verify() -> [String] {
        var lines: [String] = []
        func check(_ ok: Bool, _ note: String) { lines.append("\(ok ? "✓" : "✗") \(note)") }
        let task = UUID(), session = UUID(), secondSession = UUID()
        var state = SteerState(taskID: task, sessionID: session)
        _ = state.enqueue("先看列表")
        _ = state.enqueue("保留原文")
        let first = state.consume(step: 7)
        let second = state.consume(step: 7)
        check(first == "先看列表\n保留原文" && second == nil && state.pending.isEmpty && state.items.allSatisfy { $0.consumedStep == 7 && $0.disposition == .applied }, "① 顺序取尽，一次性消费，二次组装不再注入")
        var full = SteerState(taskID: task, sessionID: session)
        let accepted = (1...4).map { full.enqueue("要求 \($0)") }
        check(accepted == [true, true, true, false] && full.pending.count == 3, "② 上限三条，第四条拒绝且不丢前三条")
        let withdrawn = full.move(full.pending[0].id, to: .withdrawn)
        check(withdrawn != nil && full.pending.count == 2 && SteerState.restoredDraft("", text: "补充") == "补充" && SteerState.restoredDraft("已有草稿", text: "补充") == "已有草稿 补充", "③ 撤回移除，空草稿直接回填，非空以空格追加")
        let queueID = full.pending[0].id, interruptID = full.pending[1].id
        let queued = full.move(queueID, to: .queued), interrupted = full.move(interruptID, to: .interrupt)
        check(queued?.id == queueID && interrupted?.id == interruptID && full.pending.isEmpty && full.consume(step: 8) == nil, "④ 改为排队/中断后原列表移除，不能再作为插话消费")
        var paused = SteerState(taskID: task, sessionID: session)
        _ = paused.enqueue("冻结要求")
        let frozenID = paused.pending[0].id
        paused.freeze()
        let frozenOK = paused.pending.count == 1 && paused.pending[0].label == "插话 · 已暂停，继续后生效"
        var resumed = paused
        resumed.thaw()
        let thawed = resumed.pending[0].label == "插话 · 将在下一步生效"
        let resumedHint = resumed.consume(step: 9)
        var ended = paused, done = paused
        ended.invalidate("任务已结束"); done.invalidate("任务已结束")
        check(frozenOK && thawed && resumedHint == "冻结要求" && ended.pending.isEmpty && done.pending.isEmpty && ended.items[0].text == "冻结要求" && ended.feedback?.contains(frozenID.uuidString) == true && done.feedback?.contains("1 条插话") == true, "⑤ 暂停保留，继续消费；结束/done 作废并保留原文、条数和定位反馈")
        // 编码边界只承载插话数据，状态机没有目标、问答或预算的读写能力。
        let keys = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(state))) as? [String: Any]
        check(keys != nil && keys?["goal"] == nil && keys?["taskText"] == nil && keys?["answerContext"] == nil && keys?["stepBudget"] == nil && state.items.count == 2, "⑥ 插话状态与 goal/taskText/问答/模型预算隔离，不产生模型决策或新步骤")
        check(SteerState.allowsThreeWay(viewingRun: true, running: true, waiting: false) && !SteerState.allowsThreeWay(viewingRun: true, running: true, waiting: true) && !SteerState.allowsThreeWay(viewingRun: true, running: false, waiting: true) && !SteerState.allowsThreeWay(viewingRun: false, running: true, waiting: false), "⑦ 运行会话才启用，确认/手输/提问等待及异会话均禁用三态入口")
        var other = SteerState(taskID: UUID(), sessionID: secondSession)
        _ = other.enqueue("另一会话的要求"); other.freeze()
        var file = SteerSidecar(tasks: [paused, other])
        file.beforeStart(in: session)
        let feedback = file.tasks.first { $0.taskID == task }?.feedback
        file.clearProjectedTasks(in: session)
        var b = SteerState(taskID: UUID(), sessionID: session)
        check(!file.tasks.contains { $0.taskID == task } && feedback?.contains("因新任务启动未生效") == true && feedback?.contains("冻结要求") == true && b.consume(step: 1) == nil && file.tasks.first == other, "⑧ A停止→同会话B启动：A侧车清除，作废反馈可定位，B不消费；异会话侧车不动")
        let old = UUID(), fresh = UUID()
        var gate = SteerInterruptGate(taskID: task, oldGeneration: old)
        let rejectsEarly = !gate.reserveStart(taskID: task, generation: fresh, running: false)
        gate.acknowledgeWorkerExit()
        let wrongTask = !gate.reserveStart(taskID: UUID(), generation: fresh, running: false)
        let unchangedGeneration = !gate.reserveStart(taskID: task, generation: old, running: false)
        let stillRunning = !gate.reserveStart(taskID: task, generation: fresh, running: true)
        let once = gate.reserveStart(taskID: task, generation: fresh, running: false)
        let noReentry = !gate.reserveStart(taskID: task, generation: fresh, running: false)
        check(rejectsEarly && wrongTask && unchangedGeneration && stillRunning && once && noReentry, "中断启动权：等待实际退出、绑定原任务、换代且非running，仅可启动一次")
        let request = SteerInterrupt(id: UUID(), taskID: task, sessionID: session, text: "中断后新任务", startingID: UUID())
        var acceptedRequest = SteerSidecar(tasks: [paused], interrupt: request)
        acceptedRequest.recover(resumableTaskID: task, snapshotTaskID: task)
        var stoppedRequest = SteerSidecar(interrupt: request)
        stoppedRequest.recover(resumableTaskID: nil, snapshotTaskID: nil)
        var committedRequest = SteerSidecar(interrupt: request)
        committedRequest.recover(resumableTaskID: request.startingID, snapshotTaskID: request.startingID)
        check(acceptedRequest.interrupt == request && acceptedRequest.tasks[0].pending == paused.pending && stoppedRequest.interrupt?.text == request.text && committedRequest.interrupt == nil, "中断崩溃边界：受理/停止后文字仍待发，目标快照落定后只恢复目标、不重复启动")
        do {
            let data = try JSONEncoder().encode(SteerSidecar(tasks: [paused, state]))
            let restored = try JSONDecoder().decode(SteerSidecar.self, from: data)
            var recovered = restored.tasks[1]
            check(restored.tasks[0].pending == paused.pending && recovered.consume(step: 99) == nil, "侧车往返保留冻结项，已生效项不重放")
            let entry = ChatEntry(taskID: task, kind: .userAnswer, text: "旧条目", source: .userAnswer)
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PersistedChatEntry(entry))) as! [String: Any]
            json.removeValue(forKey: "steerStatus")
            json.removeValue(forKey: "steerRetryText")
            let legacy = try JSONDecoder().decode(PersistedChatEntry.self, from: JSONSerialization.data(withJSONObject: json))
            json["kind"] = "futureUnknownKind"
            let unknown = try JSONDecoder().decode(PersistedChatEntry.self, from: JSONSerialization.data(withJSONObject: json))
            check(legacy.kind == .userAnswer && legacy.steerStatus == nil && legacy.steerRetryText == nil && unknown.kind == .local && unknown.text == "旧条目", "旧条目缺新增字段可解码，未知kind降为local并保留原文")
        } catch { check(false, "持久化兼容/侧车往返失败：\(error.localizedDescription)") }
        return lines
    }
}

/// 每会话一个原子文件，内部记录以 taskID 为键；已消费的记录是防重放凭证。
struct SteerSidecarFile {
    let url: URL
    func load() throws -> SteerSidecar {
        guard FileManager.default.fileExists(atPath: url.path) else { return SteerSidecar() }
        return try JSONDecoder().decode(SteerSidecar.self, from: Data(contentsOf: url))
    }
    func save(_ value: SteerSidecar) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum ChatEntryKind: String, Equatable, Codable {
    case userTask, userAnswer, userSteer, process, result, error, pause, question, manual, local
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .local
    }
}
enum ChatEntrySource: String, Codable { case userTask, userAnswer, engineStep, engineStatus, localValidation }
struct ChatEntry: Identifiable {
    let id: UUID
    let taskID: UUID?
    let createdAt: Date
    let kind: ChatEntryKind
    let text: String
    let stepID: Int?
    let action: String?
    let reason: String?
    let source: ChatEntrySource
    var steerStatus: String? = nil
    var steerRetryText: String? = nil
    init(id: UUID = UUID(), taskID: UUID?, kind: ChatEntryKind, text: String, stepID: Int? = nil, action: String? = nil, reason: String? = nil, source: ChatEntrySource, createdAt: Date = Date()) {
        self.id = id; self.taskID = taskID; self.createdAt = createdAt; self.kind = kind; self.text = text
        self.stepID = stepID; self.action = action; self.reason = reason; self.source = source
    }
    /// 从持久化记录还原（保留原 id 与时间戳，见 AgentConversationStore 的条目持久化）。
    init(restoring p: PersistedChatEntry) {
        id = p.id; self.taskID = p.taskID; createdAt = p.createdAt; self.kind = p.kind; self.text = p.text
        self.stepID = p.stepID; self.action = p.action; self.reason = p.reason; self.source = p.source; steerStatus = p.steerStatus; steerRetryText = p.steerRetryText
    }
}

/// 对话条目的持久化形态（Codable 镜像）：与 ChatEntry 分开，避免给 UI 模型
/// 本身加编解码负担；字段一一对应、还原时不改 id／时间戳。
struct PersistedChatEntry: Codable {
    let id: UUID
    let taskID: UUID?
    let createdAt: Date
    let kind: ChatEntryKind
    let text: String
    let stepID: Int?
    let action: String?
    let reason: String?
    let source: ChatEntrySource
    var steerStatus: String? = nil
    var steerRetryText: String? = nil
    init(_ e: ChatEntry) {
        id = e.id; taskID = e.taskID; createdAt = e.createdAt; kind = e.kind; text = e.text
        stepID = e.stepID; action = e.action; reason = e.reason; source = e.source; steerStatus = e.steerStatus; steerRetryText = e.steerRetryText
    }
}

