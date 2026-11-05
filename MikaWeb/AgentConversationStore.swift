import SwiftUI
import Combine
import UIKit

@MainActor final class AgentConversationStore: ObservableObject {
    @Published private(set) var entries: [ChatEntry] = []
    @Published var draft = ""
    /// 正在查看的会话（M1，2026-11-02）：entries 只装这一条会话的条目。
    /// 与引擎的 runSessionID（任务所属会话）是两个概念：任务在会话 A
    /// 执行期间用户切到 B 浏览，entries 换成 B 的，A 的新条目直写 A 的
    /// 文件（见 route），切回 A 时整表载入自然在位。切换由
    /// switchDisplayedSession 完成，编排顺序见 SessionListView。
    private(set) var displayedSessionID: UUID = SessionStore.shared.currentSessionID
    /// 输入草稿按会话暂存（内存态）：在 B 写了一半切去 A，回来草稿还在。
    private var draftsBySession: [UUID: String] = [:]
    /// 绑定的引擎（弱引用）：条目路由按 engine.runSessionID 判定归属。
    private weak var engineRef: AgentEngine?
    /// 条目独立持久化（见文件末 MARK）：启动先把上次落盘的对话读回，
    /// 进程被杀重开后对话仍在位（此前 entries 纯内存、进程一死全丢）。
    init() { loadPersisted() }
    private var cancellables: Set<AnyCancellable> = []
    private var bound = false
    private var taskID: UUID?
    private var seenSteps: Set<Int> = []
    private var seenWaits: Set<UUID> = []
    /// 后台攒批（BACKGROUND-RESILIENCE）：App 离开前台期间，引擎事件条目先攒在
    /// batchedEntries 里、不逐条刷进消息列表（逐条 append 会连环触发列表 diff 与
    /// 滚动跟随，正是场景更新窗口里要避开的高频 SwiftUI 更新）；回到前台一次性
    /// 刷入。顺序与去重口径不变（仍按到达顺序、seenSteps/seenWaits 先行判定）。
    private var batching = false
    private var batchedEntries: [ChatEntry] = []
    private var uiObservers: [NSObjectProtocol] = []
    /// 通行密钥降级提示的节流状态（DOCK-NAV-PASSKEY-FIX）：同一站点短时间内只提示一次
    private var lastWebAuthnNoticeHost: String?
    private var lastWebAuthnNoticeAt: Date?
    func bind(to engine: AgentEngine) {
        guard !bound else { return }
        bound = true
        engineRef = engine
        engine.bindSteeringConversation(self)
        if uiObservers.isEmpty {
            uiObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.batching = true }
            })
            uiObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.flushBatch() }
            })
            uiObservers.append(NotificationCenter.default.addObserver(forName: .mikaWebAuthnBlocked, object: nil, queue: .main) { [weak self] note in
                let host = note.userInfo?["host"] as? String ?? ""
                Task { @MainActor [weak self] in self?.webAuthnBlockedNotice(host: host) }
            })
        }
        engine.$conversationTaskID.sink { [weak self, weak engine] id in
            guard let self, let engine, let id, id != self.taskID else { return }
            self.taskID = id
            // 条目归属任务所在会话（M1）：正看的就是它，走内存列表路径；
            // 正看别的会话，任务条目直写它自己的文件（去重按文件查）
            guard engine.runSessionID == self.displayedSessionID else {
                // seenSteps/seenWaits 跟的是引擎当前任务的步流（与看哪个
                // 会话无关），新任务一律重置，否则会误吞新任务的前几步
                self.seenSteps = []; self.seenWaits = []
                if !self.fileContains(taskID: id, sessionID: engine.runSessionID) {
                    self.appendToFile(ChatEntry(taskID: id, kind: .userTask, text: engine.taskText, source: .userTask), sessionID: engine.runSessionID)
                }
                return
            }
            // 该任务的条目已持久化在位（进程被杀重开、引擎按快照恢复会话时
            // 会重发同一 taskID）：不重复追加任务条目，并把已存条目的
            // stepID 预置进 seenSteps，避免恢复时步流被整段重推一遍。
            if self.entries.contains(where: { $0.taskID == id }) {
                self.seenSteps = Set(self.entries.filter { $0.taskID == id }.compactMap { $0.stepID })
                self.seenWaits = []
                return
            }
            self.seenSteps = []; self.seenWaits = []
            self.append(ChatEntry(taskID: id, kind: .userTask, text: engine.taskText, source: .userTask))
            self.trimHistory()
        }.store(in: &cancellables)
        engine.$steps.sink { [weak self, weak engine] steps in
            guard let self, let engine, let id = engine.conversationTaskID else { return }
            for step in steps where self.seenSteps.insert(step.id).inserted {
                if step.action == "done" || step.action == "ask_user" { continue }
                let prefix = step.action == "skip" ? "已跳过" : (step.reason.contains("未执行") ? "未执行" : "尝试")
                self.route(ChatEntry(taskID: id, kind: .process, text: "\(prefix) · \(step.action)：\(step.reason)", stepID: step.id, action: step.action, reason: step.reason, source: .engineStep), engine: engine)
            }
        }.store(in: &cancellables)
        engine.$status.sink { [weak self, weak engine] state in
            guard let self, let engine else { return }
            engine.steeringStatusChanged(state)
            let id = engine.conversationTaskID ?? self.taskID
            switch state {
            case .done(let text): self.route(ChatEntry(taskID: id, kind: .result, text: text, source: .engineStatus), engine: engine)
            case .failed(let text): self.route(ChatEntry(taskID: id, kind: .error, text: text, source: .engineStatus), engine: engine)
            case .paused(let text): self.route(ChatEntry(taskID: id, kind: .pause, text: text, source: .engineStatus), engine: engine)
            case .waitingManual(let text):
                guard let wait = engine.waitingInput else { return }
                switch wait {
                case .question(let wid, _):
                    if self.seenWaits.insert(wid).inserted { self.route(ChatEntry(taskID: id, kind: .question, text: text, source: .engineStatus), engine: engine) }
                case .manual(let wid, _):
                    if self.seenWaits.insert(wid).inserted { self.route(ChatEntry(taskID: id, kind: .manual, text: text, source: .engineStatus), engine: engine) }
                }
            default: break
            }
        }.store(in: &cancellables)
    }

    /// 条目路由（M1）：引擎事件属于 engine.runSessionID——正看的就是它
    /// 则进内存列表（既有路径）；正看别的会话则直写所属会话的文件，
    /// 不进当前列表、不触发 UI 刷新，切回时整表载入自然在位。
    private func route(_ entry: ChatEntry, engine: AgentEngine) {
        if engine.runSessionID == displayedSessionID {
            append(entry)
        } else {
            appendToFile(entry, sessionID: engine.runSessionID)
        }
    }

    /// 切换查看会话（M1）：旧会话先落盘收尾（攒批条目刷入旧列表再写
    /// 文件）、草稿按会话暂存，然后整表载入新会话的条目与草稿，并按
    /// 已载入条目重建任务跟踪（引擎当前任务正属本会话时，sink 不会为
    /// 未变化的 taskID 重发，靠 syncTaskTracking 对齐 seenSteps，
    /// 否则切回后步流会被整段重推）。
    /// 前置：编排方已先 SessionStore.setCurrentSession（顺序见
    /// SessionListView 的切换动作）；本函数之后编排方再调引擎 adopt。
    func switchDisplayedSession(to id: UUID) {
        guard id != displayedSessionID else { return }
        flushBatch()
        draftsBySession[displayedSessionID] = draft
        displayedSessionID = id
        entries = []
        loadPersisted()
        draft = draftsBySession[id] ?? ""
        syncTaskTracking()
    }

    private func syncTaskTracking() {
        guard let engine = engineRef, engine.runSessionID == displayedSessionID else { return }
        taskID = engine.conversationTaskID
        if let id = taskID {
            seenSteps = Set(entries.filter { $0.taskID == id }.compactMap { $0.stepID })
        } else {
            seenSteps = []
        }
        seenWaits = []
    }
    func localFeedback(_ text: String) {
        // 归属修正（M1）：正看的不是任务所在会话时，本地反馈记在当前
        // 会话名下但不挂别的会话的任务 id（免得切回去时去重/归属串位）
        let attributed = (engineRef == nil || engineRef!.runSessionID == displayedSessionID) ? taskID : nil
        append(ChatEntry(taskID: attributed, kind: .local, text: text, source: .localValidation))
    }
    /// 队列回执（M1）：「任务已排队」这类反馈记在用户当前查看的会话里，
    /// 独立成条、不挂任何任务 id（那条任务还没启动、没有 id）。
    func queueReceipt(_ text: String) { append(ChatEntry(taskID: nil, kind: .local, text: text, source: .localValidation)) }
    /// 通行密钥降级提示（DOCK-NAV-PASSKEY-FIX）：页面发起 WebAuthn 被平台拒绝时由
    /// BrowserTab 经通知送达。同一站点 120 秒内只提示一次（站点重试不刷屏；诊断侧
    /// 全量记录不受此节流影响）。文案口径：只说清「这边弹不出来」与可走的替代路径，
    /// 不声称支持通行密钥、更不提任何代填凭据的办法。
    private func webAuthnBlockedNotice(host: String) {
        let shownHost = host.isEmpty ? "这个网站" : host
        if lastWebAuthnNoticeHost == shownHost, let at = lastWebAuthnNoticeAt, Date().timeIntervalSince(at) < 120 { return }
        lastWebAuthnNoticeHost = shownHost
        lastWebAuthnNoticeAt = Date()
        localFeedback("提示：\(shownHost) 刚才想用通行密钥（passkey）登录，但 iOS 不允许在 Mika Web 的内置浏览器里弹出通行密钥确认框——只有 Safari 和拿到 Apple 专门授权的浏览器能调它，这边弹不出来。请改用密码在这里登录一次（在 Safari 里登录不会同步到 Mika Web，两边状态是分开的）。")
    }
    func acceptedAnswer(_ text: String) { append(ChatEntry(taskID: taskID, kind: .userAnswer, text: text, source: .userAnswer)) }
    /// 侧车先写、条目后写；固定条目 ID 让崩溃恢复补写可幂等重试。
    /// 只更新插话新增字段，不改变既有条目的生成、路由和后台攒批口径。
    func materializeSteering(_ state: SteerState) throws {
        let current = state.sessionID == displayedSessionID
        let url = SessionStore.shared.entriesURL(for: state.sessionID)
        var logical: [ChatEntry]
        if current { logical = entries + batchedEntries }
        else if FileManager.default.fileExists(atPath: url.path) {
            logical = try JSONDecoder().decode([PersistedChatEntry].self, from: Data(contentsOf: url)).map { ChatEntry(restoring: $0) }
        } else { logical = [] }
        logical = SteerProjection.apply(state, to: logical)
        let retained = Array(logical.suffix(Self.sessionEntryCap))
        try JSONEncoder().encode(retained.map { PersistedChatEntry($0) }).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if current {
            let batchedIDs = Set(batchedEntries.map { $0.id })
            let previousIDs = Set(entries.map { $0.id })
            entries = logical.filter { !batchedIDs.contains($0.id) && (!batching || previousIDs.contains($0.id)) }
            batchedEntries = logical.filter { batchedIDs.contains($0.id) || (batching && !previousIDs.contains($0.id)) }
        }
        SessionStore.shared.touch(id: state.sessionID)
    }
    private func append(_ entry: ChatEntry) {
        if batching { batchedEntries.append(entry) } else { entries.append(entry) }
        if entry.kind == .userTask {
            SessionStore.shared.adoptAutomaticTitleIfNeeded(id: displayedSessionID, firstUserMessage: entry.text)
        }
        persistNow()
    }
    private func flushBatch() {
        batching = false
        guard !batchedEntries.isEmpty else { return }
        entries.append(contentsOf: batchedEntries)
        batchedEntries = []
        persistNow()
    }
    private func trimHistory() {
        // H1 前的旧口径是「旧任务条目全局只留 500 条」——那正是新任务挤掉
        // 旧历史的机制。H1 起只保留按会话计的防爆上限（见 sessionEntryCap），
        // 任务之间不再互相挤占。
        if entries.count > Self.sessionEntryCap { entries.removeFirst(entries.count - Self.sessionEntryCap); persistNow() }
    }

    // MARK: - 条目持久化（CRASH-1031 追加项：任务完成后切后台再回来对话被清空；H1 改按会话分库）

    // 对话记录是用户的事后凭证（发了什么任务、agent 做了什么、结果如何都在
    // 里面），与引擎的会话执行快照（终结／停止即清除）解耦、独立落盘：
    // 切后台、回前台、进程被系统杀掉后重开都不丢。落盘口径：每次条目变化
    // 写全量逻辑列表（entries＋攒批中的 batchedEntries，杀进程发生在攒批期
    // 也不丢）；当前产品没有任何「清空对话」的用户动作，条目只随
    // trimHistory 的防爆上限滚动——将来若加显式清空，须同步删本文件。
    //
    // H1（会话级分库）：落盘位置改由 SessionStore 按会话给出（当前会话的
    // entries.json），旧版单文件已在 SessionStore 初始化时迁入默认会话。
    // 条数上限按会话计：每会话 5000 条是防爆值（单条条目约百字节量级，
    // 5000 条约亚 MB 到数 MB），不是产品策略上限——它的作用只是防病态
    // 膨胀撑爆磁盘，正常使用够不到；新会话不再挤掉旧会话的历史。
    static let sessionEntryCap = 5000

    private var persistenceFileURL: URL {
        SessionStore.shared.entriesURL(for: displayedSessionID)
    }

    /// 直写某会话的条目文件（M1 路由的落点）：读现有文件→追加→按会话
    /// 上限截断→原子写回。小文件全量读写与既有 persistNow 同形态；
    /// 只在「任务在别的会话跑、用户正看这一个」时发生，频率即步流频率。
    private func appendToFile(_ entry: ChatEntry, sessionID: UUID) {
        let url = SessionStore.shared.entriesURL(for: sessionID)
        var decoded: [PersistedChatEntry] = []
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode([PersistedChatEntry].self, from: data) {
            decoded = existing
        }
        decoded.append(PersistedChatEntry(entry))
        guard let data = try? JSONEncoder().encode(Array(decoded.suffix(Self.sessionEntryCap))) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if entry.kind == .userTask {
            SessionStore.shared.adoptAutomaticTitleIfNeeded(id: sessionID, firstUserMessage: entry.text)
        }
        SessionStore.shared.touch(id: sessionID)
    }

    /// 某会话的落盘条目里是否已有该任务（路由去重用）。
    private func fileContains(taskID: UUID, sessionID: UUID) -> Bool {
        let url = SessionStore.shared.entriesURL(for: sessionID)
        guard let data = try? Data(contentsOf: url),
              let existing = try? JSONDecoder().decode([PersistedChatEntry].self, from: data) else { return false }
        return existing.contains { $0.taskID == taskID }
    }

    private func loadPersisted() {
        guard let data = try? Data(contentsOf: persistenceFileURL),
              let decoded = try? JSONDecoder().decode([PersistedChatEntry].self, from: data) else { return }
        entries = decoded.suffix(Self.sessionEntryCap).map { ChatEntry(restoring: $0) }
    }

    private func persistNow() {
        let logical = (entries + batchedEntries).suffix(Self.sessionEntryCap)
        guard let data = try? JSONEncoder().encode(logical.map { PersistedChatEntry($0) }) else { return }
        try? data.write(to: persistenceFileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        SessionStore.shared.touch(id: displayedSessionID, status: "active")
    }

    /// 自检八口径：当前查看会话落盘文件里的条数（解码失败为 nil）。
    func onDiskEntryCount() -> Int? {
        SessionStore.shared.entryCountOnDisk(for: displayedSessionID)
    }
}
