import SwiftUI

struct AgentChatView: View {
    @ObservedObject var engine: AgentEngine
    @ObservedObject var settings: SettingsStore
    @ObservedObject var conversation: AgentConversationStore
    /// 对话输入框焦点：由 ContentView 持有并下传（浏览器坞展开盖住对话层时需代为收起，见
    /// CHAT-KEYBOARD-FIX-2026-11-02.md）。此前本视图无任何焦点管理：发送不清焦点、
    /// 列表不收键盘、点按无收起手势，键盘一旦唤起便无路可收。
    var inputFocus: FocusState<Bool>.Binding
    @State private var followLatest = true
    private var questionID: UUID? {
        guard case .some(.question(let id, _)) = engine.waitingInput else { return nil }
        switch engine.status { case .waitingManual, .paused: return id; default: return nil }
    }
    private var isNewTask: Bool {
        switch engine.status { case .idle, .done, .failed: return true; case .paused: return questionID == nil; default: return false }
    }
    private var canSend: Bool { engine.active && !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (isNewTask || questionID != nil) }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mika 助手").font(.headline)
                    Text("\(engine.status.label) · 已记录步骤 \(engine.steps.count)／本任务上限 \(engine.conversationTaskID == nil ? settings.maxSteps : engine.taskLimit)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(conversation.entries) { entry in
                            entryView(entry).id(entry.id)
                        }
                        if case .waitingConfirm(let action) = engine.status {
                            ConfirmCard(engine: engine, action: action, taskID: engine.conversationTaskID)
                        }
                        if case .waitingManual = engine.status, case .some(.manual(_, _)) = engine.waitingInput {
                            Text("请在网页完成处理，然后点击下方「已处理，继续」。").font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
                // 对话层改为全屏常驻根层（悬浮窗改造）：消息区不再受并屏时代的 240pt 上限约束
                .frame(maxHeight: .infinity)
                // 收键盘（对齐主流聊天 App）：拖动消息列表时键盘交互式跟随收起；
                // 点按消息区（空白或气泡皆可）顺带收起——用 simultaneousGesture 只做
                // 收键盘这一件事，不拦截 ConfirmCard 按钮等内容本身的点击。
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(TapGesture().onEnded { inputFocus.wrappedValue = false })
                .onChange(of: conversation.entries.count) { _, _ in
                    if followLatest, let last = conversation.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField(questionID != nil ? "回答问题" : "输入网页任务", text: $conversation.draft, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder)
                    .focused(inputFocus)
                Button(questionID != nil ? "回答并继续" : (isNewTask && isPaused ? "新任务" : "发送")) { send() }
                    .disabled(!canSend).buttonStyle(.borderedProminent)
            }
            HStack(spacing: 8) {
                Button("停止") { engine.stop() }.disabled(!engine.busy || !engine.active)
                Button(manualWaiting ? "已处理，继续" : "继续") { engine.resume() }
                    .disabled(!canResume)
                Spacer()
                if !settings.hasKey { Text("请先在设置中配置密钥").font(.caption).foregroundStyle(.orange) }
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding(12)
    }
    private var isPaused: Bool { if case .paused = engine.status { return true }; return false }
    private var manualWaiting: Bool {
        if case .waitingManual = engine.status, case .some(.manual(_, _)) = engine.waitingInput { return true }
        return false
    }
    private var canResume: Bool {
        guard engine.active, questionID == nil else { return false }
        switch engine.status { case .paused, .failed: return true; case .waitingManual: return manualWaiting; default: return false }
    }
    private func send() {
        guard canSend else { return }
        let text = conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let questionID {
            switch engine.submitAnswer(text, requestID: questionID) {
            case .accepted:
                conversation.acceptedAnswer(text); conversation.draft = ""; followLatest = true
                dismissKeyboard()
            case .rejected(let reason): conversation.localFeedback(reason)
            }
        } else if isNewTask {
            let previous = engine.conversationTaskID
            engine.taskText = text
            engine.start()
            if engine.conversationTaskID != previous {
                conversation.draft = ""; followLatest = true
                dismissKeyboard()
            }
        }
    }
    /// 发送成功后收起键盘：仅在两条真成功路径调用（作答被接受／新任务真启动）——
    /// 被拒或启动失败时保留焦点与草稿，方便用户改完重发。draft 已先清空，多行输入框
    /// 的高度由内容驱动，随之自动复位到单行收起态。
    private func dismissKeyboard() {
        inputFocus.wrappedValue = false
    }
    private func entryView(_ entry: ChatEntry) -> some View {
        let user = entry.kind == .userTask || entry.kind == .userAnswer
        return Text(entry.text)
            .font(entry.kind == .process ? .caption : .callout)
            .foregroundStyle(entry.kind == .error ? .red : .primary)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
            .background(user ? Color.blue.opacity(0.14) : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel(entry.text)
    }
}

// 内部可见：浏览器坞展开态的确认浮层复用同一张卡片（同一 engine.confirm 路径与防重复守卫）
struct ConfirmCard: View {
    @ObservedObject var engine: AgentEngine
    let action: AgentAction
    let taskID: UUID?
    @State private var locked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("等待确认").font(.headline)
            Text("动作：\(action.action)，目标序号：\(action.index)\n\(action.reason)\n请核对网页。")
            HStack {
                Button("执行", role: .destructive) { submit(true) }
                Button("跳过") { submit(false) }
            }.disabled(locked)
        }
        .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
    private func submit(_ execute: Bool) {
        guard !locked, engine.conversationTaskID == taskID else { return }
        guard case .waitingConfirm(let current) = engine.status,
              current.action == action.action, current.index == action.index,
              current.reason == action.reason, current.text == action.text,
              current.url == action.url, current.direction == action.direction,
              current.seconds == action.seconds, current.summary == action.summary,
              current.question == action.question else { return }
        locked = true
        engine.confirm(execute: execute)
    }
}
