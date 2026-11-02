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
                        // 介入呈现不在消息流里（2026-11-02 16:01 定版）：确认／手输等待
                        // 改由 ContentView 置顶层的 InterventionPrompt 固定呈现（输入栏
                        // 上方、小窗与展开态都可见），本列表只剩消息本体，避免双卡并存。
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
                // 手输等待的「已处理，继续」由置顶介入卡独占（同一时刻一个主入口，
                // 见 InterventionPrompt）；本行「继续」只管暂停／失败的续跑。
                Button("继续") { engine.resume() }
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
    private var canResume: Bool {
        guard engine.active, questionID == nil else { return false }
        // .waitingManual（手输等待）不在此列：续跑入口在置顶介入卡的「已处理，继续」，
        // 本行只处理暂停／失败（同一时刻只有一个可点的主入口，避免双入口打架）。
        switch engine.status { case .paused, .failed: return true; default: return false }
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

// 内部可见：对话区置顶介入卡专用的确认卡片（ContentView 的 InterventionPrompt 层渲染，
// 小窗与展开态都可见；同一 engine.confirm 路径与防重复守卫，语义不变）。
// 展示口径（INTERVENTION-PROMPT 定版）：待确认动作的全字段不删减——动作／目标序号、
// 元素摘要 summary、拟输入内容 text、目标网址 url、理由 reason，再加所在页面标题／域名；
// 按钮三个：「确认执行」「拒绝」走既有 pending 确认解决路径，「打开浏览器查看」是
// 用户主动展开坞（经 ContentView 的 expandRequest 令牌），不经过确认守卫。
struct ConfirmCard: View {
    @ObservedObject var engine: AgentEngine
    let action: AgentAction
    let taskID: UUID?
    /// 所在页面标题／域名（执行页口径，由 InterventionPrompt 从 WebController 取得后传入）
    var pageTitle: String = ""
    var pageHost: String = ""
    /// 「打开浏览器查看」：用户主动展开坞的回调；nil 时不显示该按钮。
    var onOpenBrowser: (() -> Void)? = nil
    @State private var locked = false
    private var detailText: String {
        var lines = ["动作：\(action.action)，目标序号：\(action.index)"]
        if !action.summary.isEmpty { lines.append("元素：\(action.summary)") }
        if !action.text.isEmpty { lines.append("内容：\(action.text)") }
        if !action.url.isEmpty { lines.append("目标网址：\(action.url)") }
        lines.append(action.reason)
        if !pageTitle.isEmpty {
            lines.append("页面：\(pageTitle)" + (pageHost.isEmpty ? "" : "（\(pageHost)）"))
        }
        lines.append("请核对网页。")
        return lines.joined(separator: "\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("等待确认").font(.headline)
            Text(detailText)
            HStack {
                Button("确认执行", role: .destructive) { submit(true) }.disabled(locked)
                Button("拒绝") { submit(false) }.disabled(locked)
                if let onOpenBrowser {
                    Spacer()
                    Button("打开浏览器查看") { onOpenBrowser() }
                }
            }
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

/// 介入提示层（2026-11-02 16:01 Joey 定版，案卷 INTERVENTION-PROMPT-IMPL-2026-11-02.md）：
/// 由 ContentView 放在坞之上、输入栏之下的置顶位置渲染——agent 需要用户介入时
/// **只在对话里出卡**，坞纹丝不动，用户自己决定点不点开浏览器：
/// - 确认等待（.waitingConfirm）：ConfirmCard（全字段＋页面标题/域名），按钮
///   「确认执行」「拒绝」「打开浏览器查看」；
/// - 手输等待（.waitingManual＋waitingInput 为 .manual）：提示卡，说明文字沿用引擎
///   既有文案（waitingInput.manual 的 text，如「请手动填写密码或验证码后继续」），
///   按钮「打开浏览器」「已处理，继续」（后者走 engine.resume() 既有路径）。
/// 「打开浏览器*」经 onOpenBrowser 回调让 ContentView 递增 expandRequest 令牌下传坞
/// 展开——是用户点击、不是自动展开。ask_user 提问（waitingInput 为 .question）不在
/// 此列：它在输入栏作答，本层不渲染。同一时刻只有这一张卡是可点的主入口：坞底旧
/// 介入 UI 已收起、消息流内嵌卡已摘除、按钮行的手输续跑已让位（见本文件与坞案卷）。
struct InterventionPrompt: View {
    @ObservedObject var engine: AgentEngine
    @ObservedObject var web: WebController
    var onOpenBrowser: () -> Void
    var body: some View {
        if case .waitingConfirm(let action) = engine.status {
            ConfirmCard(engine: engine, action: action, taskID: engine.conversationTaskID,
                        pageTitle: pageTitle, pageHost: pageHost, onOpenBrowser: onOpenBrowser)
        } else if case .waitingManual = engine.status, case .some(.manual(_, let text)) = engine.waitingInput {
            VStack(alignment: .leading, spacing: 8) {
                Text("需要你手动处理").font(.headline)
                Text(text)
                Text("完成后点击「已处理，继续」。")
                HStack {
                    Button("打开浏览器") { onOpenBrowser() }
                    Spacer()
                    Button("已处理，继续") { engine.resume() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    /// 确认动作作用于执行页（任务绑定的标签页），标题/域名按执行页取，不用当前页冒充。
    private var pageTitle: String {
        web.tabTitle(for: web.executionTabID ?? web.activeTabID)
    }
    private var pageHost: String {
        URL(string: web.executionTab.urlString)?.host ?? ""
    }
}
