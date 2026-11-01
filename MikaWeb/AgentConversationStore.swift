import SwiftUI
import Combine

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
    func bind(to engine: AgentEngine) {
        guard !bound else { return }
        bound = true
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
    func acceptedAnswer(_ text: String) { append(ChatEntry(taskID: taskID, kind: .userAnswer, text: text, source: .userAnswer)) }
    private func append(_ entry: ChatEntry) { entries.append(entry) }
    private func trimHistory() {
        let older = entries.filter { $0.taskID != taskID }
        if older.count > 500 { entries.removeFirst(older.count - 500) }
    }
}
