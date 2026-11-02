import SwiftUI
import Combine
import UIKit

enum ChatEntryKind: String, Equatable, Codable { case userTask, userAnswer, process, result, error, pause, question, manual, local }
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
    init(taskID: UUID?, kind: ChatEntryKind, text: String, stepID: Int? = nil, action: String? = nil, reason: String? = nil, source: ChatEntrySource) {
        id = UUID(); self.taskID = taskID; createdAt = Date(); self.kind = kind; self.text = text
        self.stepID = stepID; self.action = action; self.reason = reason; self.source = source
    }
    /// 从持久化记录还原（保留原 id 与时间戳，见 AgentConversationStore 的条目持久化）。
    init(restoring p: PersistedChatEntry) {
        id = p.id; self.taskID = p.taskID; createdAt = p.createdAt; self.kind = p.kind; self.text = p.text
        self.stepID = p.stepID; self.action = p.action; self.reason = p.reason; self.source = p.source
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
    init(_ e: ChatEntry) {
        id = e.id; taskID = e.taskID; createdAt = e.createdAt; kind = e.kind; text = e.text
        stepID = e.stepID; action = e.action; reason = e.reason; source = e.source
    }
}

@MainActor final class AgentConversationStore: ObservableObject {
    @Published private(set) var entries: [ChatEntry] = []
    @Published var draft = ""
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
        engine.$steps.sink { [weak self] steps in
            guard let self, let id = self.taskID else { return }
            for step in steps where self.seenSteps.insert(step.id).inserted {
                if step.action == "done" || step.action == "ask_user" { continue }
                let prefix = step.action == "skip" ? "已跳过" : (step.reason.contains("未执行") ? "未执行" : "尝试")
                self.append(ChatEntry(taskID: id, kind: .process, text: "\(prefix) · \(step.action)：\(step.reason)", stepID: step.id, action: step.action, reason: step.reason, source: .engineStep))
            }
        }.store(in: &cancellables)
        engine.$status.sink { [weak self, weak engine] state in
            guard let self, let engine else { return }
            switch state {
            case .done(let text): self.append(ChatEntry(taskID: self.taskID, kind: .result, text: text, source: .engineStatus))
            case .failed(let text): self.append(ChatEntry(taskID: self.taskID, kind: .error, text: text, source: .engineStatus))
            case .paused(let text): self.append(ChatEntry(taskID: self.taskID, kind: .pause, text: text, source: .engineStatus))
            case .waitingManual(let text):
                guard let wait = engine.waitingInput else { return }
                switch wait {
                case .question(let id, _):
                    if self.seenWaits.insert(id).inserted { self.append(ChatEntry(taskID: self.taskID, kind: .question, text: text, source: .engineStatus)) }
                case .manual(let id, _):
                    if self.seenWaits.insert(id).inserted { self.append(ChatEntry(taskID: self.taskID, kind: .manual, text: text, source: .engineStatus)) }
                }
            default: break
            }
        }.store(in: &cancellables)
    }
    func localFeedback(_ text: String) { append(ChatEntry(taskID: taskID, kind: .local, text: text, source: .localValidation)) }
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
    private func append(_ entry: ChatEntry) {
        if batching { batchedEntries.append(entry) } else { entries.append(entry) }
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
        SessionStore.shared.entriesURL(for: SessionStore.shared.currentSessionID)
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
        SessionStore.shared.touch(id: SessionStore.shared.currentSessionID, status: "active")
    }

    /// 自检八口径：当前会话落盘文件里的条数（解码失败为 nil）。
    func onDiskEntryCount() -> Int? {
        SessionStore.shared.entryCountOnDisk(for: SessionStore.shared.currentSessionID)
    }
}
