import SwiftUI

/// 对话消息层（层级见 ContentView 与 CHAT-KEYBOARD-FIX-2026-11-02.md 问题 3）：
/// ZStack 自下而上为 消息层 ＜ 浏览器坞 ＜ 聊天输入栏。输入栏（输入框＋发送键）已
/// 拆出为独立的 ChatInputBar 放在最上层，坞在任何形态下都盖不住它；本层只剩标题、
/// 消息列表与停止／继续按钮行，底部留出实测的输入栏高度（bottomInset），保证最后
/// 一条消息与按钮行不被输入栏压住。
struct AgentChatView: View {
    @ObservedObject var engine: AgentEngine
    @ObservedObject var settings: SettingsStore
    @ObservedObject var conversation: AgentConversationStore
    /// 对话输入框焦点：由 ContentView 持有并下传（浏览器坞展开盖住对话层时需代为收起）。
    /// 焦点本体绑在 ChatInputBar 的 TextField 上；本层只用它做点按收键盘。
    var inputFocus: FocusState<Bool>.Binding
    /// 跟随最新消息：发送成功后由 ChatInputBar 置真，本层据此滚动到底部。
    var followLatest: Binding<Bool>
    /// 底部避让：输入栏的实测高度（ContentView 测得后下传），本层底部留白与之等高。
    var bottomInset: CGFloat
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
                    if followLatest.wrappedValue, let last = conversation.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
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
        // 输入栏浮在最上层，本层底部留出其实测高度，按钮行与最后一条消息不被压住
        .padding(.bottom, bottomInset)
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
    private var questionID: UUID? {
        guard case .some(.question(let id, _)) = engine.waitingInput else { return nil }
        switch engine.status { case .waitingManual, .paused: return id; default: return nil }
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

/// 聊天输入栏（输入框＋发送键）：ContentView 的 ZStack 最上层，渲染在浏览器坞之上——
/// 小窗态、展开态都一样，坞怎么拖、怎么展开都盖不住它（问题 3）。背景用材质填充并
/// 向底部安全区延伸，键盘升起时随根层安全区上浮、仍在最上层。高度由 ContentView
/// 实测（草稿多行时变高）并下传给消息层避让与坞的钳制／避让。
struct ChatInputBar: View {
    @ObservedObject var engine: AgentEngine
    @ObservedObject var conversation: AgentConversationStore
    var inputFocus: FocusState<Bool>.Binding
    var followLatest: Binding<Bool>
    private var questionID: UUID? {
        guard case .some(.question(let id, _)) = engine.waitingInput else { return nil }
        switch engine.status { case .waitingManual, .paused: return id; default: return nil }
    }
    private var isNewTask: Bool {
        switch engine.status { case .idle, .done, .failed: return true; case .paused: return questionID == nil; default: return false }
    }
    private var isPaused: Bool { if case .paused = engine.status { return true }; return false }
    private var canSend: Bool { engine.active && !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (isNewTask || questionID != nil) }
    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(questionID != nil ? "回答问题" : "输入网页任务", text: $conversation.draft, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder)
                .focused(inputFocus)
            Button(questionID != nil ? "回答并继续" : (isNewTask && isPaused ? "新任务" : "发送")) { send() }
                .disabled(!canSend).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            // 顶部分隔线＋材质背景，背景向底部安全区（Home 指示条区）延伸填满
            VStack(spacing: 0) {
                Divider()
                Rectangle().fill(.regularMaterial)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
    private func send() {
        guard canSend else { return }
        let text = conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let questionID {
            switch engine.submitAnswer(text, requestID: questionID) {
            case .accepted:
                conversation.acceptedAnswer(text); conversation.draft = ""; followLatest.wrappedValue = true
                dismissKeyboard()
            case .rejected(let reason): conversation.localFeedback(reason)
            }
        } else if isNewTask {
            let previous = engine.conversationTaskID
            engine.taskText = text
            engine.start()
            if engine.conversationTaskID != previous {
                conversation.draft = ""; followLatest.wrappedValue = true
                dismissKeyboard()
            }
        }
    }
    /// 发送成功后收起键盘：仅在两条真成功路径调用（作答被接受／新任务真启动）——
    /// 被拒或启动失败时保留焦点与草稿，方便用户改完重发。draft 已先清空，多行输入框
    /// 的高度由内容驱动，随之自动复位到单行收起态（问题 1）。
    private func dismissKeyboard() {
        inputFocus.wrappedValue = false
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
