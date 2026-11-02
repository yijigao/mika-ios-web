import SwiftUI
import Combine
import UIKit

enum ChatEntryKind: Equatable { case userTask, userAnswer, process, result, error, pause, question, manual, local }
enum ChatEntrySource { case userTask, userAnswer, engineStep, engineStatus, localValidation }
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
}

@MainActor final class AgentConversationStore: ObservableObject {
    @Published private(set) var entries: [ChatEntry] = []
    @Published var draft = ""
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
            self.taskID = id; self.seenSteps = []; self.seenWaits = []
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
    }
    private func flushBatch() {
        batching = false
        guard !batchedEntries.isEmpty else { return }
        entries.append(contentsOf: batchedEntries)
        batchedEntries = []
    }
    private func trimHistory() {
        let older = entries.filter { $0.taskID != taskID }
        if older.count > 500 { entries.removeFirst(older.count - 500) }
    }
}
