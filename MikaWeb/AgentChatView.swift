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
    @ObservedObject private var sessionStore = SessionStore.shared
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
                    if viewingRunSession {
                        Text("\(engine.status.label) · 已记录步骤 \(engine.steps.count)／本任务上限 \(engine.conversationTaskID == nil ? settings.maxSteps : engine.taskLimit)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        // 看的不是任务所在会话（M1）：标题行说清两边各是谁，
                        // 免得把另一个会话的执行状态误读成本会话的
                        Text("会话「\(sessionTitle(conversation.displayedSessionID))」· 任务在会话「\(sessionTitle(engine.runSessionID))」\(engine.busy ? "执行中" : "（已结束）")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
            }
            if !viewingRunSession, engine.busy {
                Text("这里写的新任务会加入队列，等当前任务结束后在本会话启动；要给正在跑的任务回答问题或确认动作，请先切回那个会话。")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                // 停止走 stopFromUser（M1）：停掉当前任务后队列自动推进；
                // 只在任务所在会话里可点——在别的会话点停会串会话
                Button("停止") { engine.stopFromUser() }.disabled(!engine.busy || !engine.active || !viewingRunSession)
                // 结束任务（SELFCHECK-UNBLOCK-FIX）：暂停态的彻底终结出口。
                // 与「停止＝暂停、可继续」相对：点了清快照、不可续跑，引擎
                // 随之解锁（自检与新任务不再被一个暂停任务挡住）；文案带
                // 「不可续跑」明示区别。只在暂停态、且正看任务所在会话时
                // 呈现（同停止／继续的会话归属口径）。
                if isPaused, viewingRunSession {
                    Button("结束任务（不可续跑）") { engine.finishTaskFromUser() }.disabled(!engine.active)
                }
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
    /// 正看的就是任务所在会话（M1）：停止／继续／作答都只对本会话的
    /// 任务生效，看别的会话时这些入口一律让位（队列与浏览不受影响）。
    private var viewingRunSession: Bool { conversation.displayedSessionID == engine.runSessionID }
    private func sessionTitle(_ id: UUID) -> String {
        sessionStore.sessions.first(where: { $0.id == id })?.title ?? "会话"
    }
    private var canResume: Bool {
        guard engine.active, questionID == nil, viewingRunSession else { return false }
        // .waitingManual（手输等待）不在此列：续跑入口在置顶介入卡的「已处理，继续」，
        // 本行只处理暂停／失败（同一时刻只有一个可点的主入口，避免双入口打架）。
        switch engine.status { case .paused, .failed: return true; default: return false }
    }
    private var questionID: UUID? {
        guard viewingRunSession, case .some(.question(let id, _)) = engine.waitingInput else { return nil }
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
    /// 正看的就是任务所在会话（M1）：作答与续跑短语拦截都只对本会话的
    /// 任务生效；看别的会话时输入一律按「给本会话的新任务」理解。
    private var viewingRunSession: Bool { conversation.displayedSessionID == engine.runSessionID }
    private var questionID: UUID? {
        guard viewingRunSession, case .some(.question(let id, _)) = engine.waitingInput else { return nil }
        switch engine.status { case .waitingManual, .paused: return id; default: return nil }
    }
    private var isNewTask: Bool {
        switch engine.status { case .idle, .done, .failed: return true; case .paused: return questionID == nil; default: return false }
    }
    private var isPaused: Bool { if case .paused = engine.status { return true }; return false }
    /// 可入队（M1）：看着别的会话、而执行器正忙——发送即把任务排进
    /// 队列（在本会话名下），不打断正在跑的任务、也不串进它的对话。
    private var canQueue: Bool { !viewingRunSession && engine.busy }
    private var canSend: Bool { engine.active && !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (isNewTask || questionID != nil || canQueue) }
    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(questionID != nil ? "回答问题" : "输入网页任务", text: $conversation.draft, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder)
                .focused(inputFocus)
            Button(questionID != nil ? "回答并继续" : (canQueue ? "加入队列" : (isNewTask && isPaused ? "新任务" : "发送"))) { send() }
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
    /// 有可续跑的会话上下文（暂停／失败且目标还在、当前不在等回答）：此时
    /// 输入框的语义对用户是「跟这个任务对话」，一句「继续」若按新任务处理，
    /// start() 会把已恢复的目标、步骤、问答整体冲掉——真机实证（2026-11-02
    /// 19:36）：中断恢复后用户打「现在继续」，agent 随即反问任务内容与网址，
    /// 如同失忆。故续跑类短语在此拦截、改走 resume()（RESUME-CONTEXT-FIX）。
    private var hasLiveSession: Bool {
        guard viewingRunSession, questionID == nil, !engine.activeGoal.isEmpty else { return false }
        switch engine.status { case .paused, .failed: return true; default: return false }
    }
    private func isContinuation(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["继续", "现在继续", "继续吧", "继续跑", "接着", "接着跑", "接着来", "继续任务", "continue", "resume", "go on"].contains(t) { return true }
        return t.count <= 6 && t.contains("继续")
    }
    private func send() {
        guard canSend else { return }
        let text = conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // 入队分支（M1）必须排在作答／续跑拦截之前：那些路径都属于任务
        // 所在会话，在别的会话里输入的文字一律是给本会话排队的新任务
        if canQueue {
            engine.enqueueTask(sessionID: conversation.displayedSessionID, text: text)
            conversation.queueReceipt("已加入队列：当前执行的是另一个会话的任务，这条会按顺序在本会话里启动（在「会话」列表里可查看或取消）。")
            conversation.draft = ""; followLatest.wrappedValue = true
            dismissKeyboard()
            return
        }
        if questionID == nil, hasLiveSession, isContinuation(text) {
            engine.resume()
            switch engine.status {
            case .running, .waitingConfirm, .waitingManual:
                conversation.acceptedAnswer(text); conversation.draft = ""; followLatest.wrappedValue = true
                dismissKeyboard()
            default:
                conversation.localFeedback("没能接着跑（当前状态：\(engine.status.label)），请点上方「继续」按钮再试，或先检查模型设置")
            }
            return
        }
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
            engine.startFromUI()
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

/// 置顶浮层呈现规格（UI-LEGIBILITY，2026-11-03，案卷 UI-LEGIBILITY-IMPL-2026-11-03.md）：
/// 介入层三张卡（确认／上传／手输）共用的背景与遮罩参数，单点定义、自检
/// 十七按此断言。症状定性（Joey 2026-11-03 真机截图）：旧背景只有一层
/// .orange.opacity(0.12~0.15)，无材质、无遮罩，卡片直接压在对话消息流与
/// 浏览器小窗之上，背后文字几乎无衰减透出；同一介入文案又同时在场于
/// 步骤行、标题状态行与回复条目，透过卡面以不同偏移叠在一起，看着像
/// 文字被重复绘制（视图层级里卡只渲染一处，不是重复绘制 bug）。
/// 修法只动呈现：卡面＝厚材质（强模糊）＋系统底色高覆盖＋橙色调（身份
/// 色），卡后整屏另加变暗遮罩；文字仍由各卡原样单层绘制，交互、布局
/// 顺序、文案与安全确认流程一律不动。
enum OverlayStyle {
    /// 卡面基底材质名（自检断言用）：ultraThickMaterial 是系统最厚一档，
    /// 采样模糊最强、自身接近不透明——背景文字先被它糊掉，不成字形。
    static let baseMaterialName = "ultraThickMaterial"
    /// 系统底色覆盖层不透明度：叠在厚材质之上，把残余透字再压一轮；
    /// 与橙色调层复合后卡面在视觉上接近不透明。
    static let coverTintOpacity = 0.72
    /// 橙色调层不透明度：只负责身份色，不再承担遮字（旧版 0.12~0.15
    /// 的单层背景到此降为纯色调）。
    static let accentTintOpacity = 0.14
    /// 变暗遮罩不透明度（ContentView 介入层）：卡外区域整体压暗，
    /// 背景文字不再与卡内文字争夺可读性。
    static let scrimOpacity = 0.42
    /// 遮罩不拦截触摸：用户照常能亲手点网页弹窗与坞控件，介入流程的
    /// 触摸路径与旧版完全一致。
    static let scrimAllowsHitTesting = false
    /// 未模糊直透比例（自检断言用）：两层色调之后直透比例
    /// (1−0.72)×(1−0.14)≈0.24，且这部分先经厚材质模糊，不成字形。
    static var unblurredShowThrough: Double { (1 - coverTintOpacity) * (1 - accentTintOpacity) }
}

extension View {
    /// 介入层三卡共用背景（UI-LEGIBILITY）：厚材质＋系统底色覆盖＋橙色调，
    /// 圆角 12 与旧版一致，另加描边与投影帮卡面与被压暗的背景分离。
    /// 只管背景呈现，不碰各卡的文字、按钮与布局。
    func interventionCardBackground() -> some View {
        background {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.ultraThickMaterial)
                RoundedRectangle(cornerRadius: 12).fill(Color(.systemBackground).opacity(OverlayStyle.coverTintOpacity))
                RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(OverlayStyle.accentTintOpacity))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.30), radius: 16, x: 0, y: 6)
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
    /// 小条形态（ZORDER-FIX）：浏览器置顶态下收成单行条（标题＋解决
    /// 按钮＋「说明」），全字段说明不绘制；解决按钮仍走本卡的 submit
    /// 守卫路径。紧凑渲染是 body 内分支，本卡 @State（locked）不因
    /// 形态切换丢失。
    var compact: Bool = false
    /// 小条上的「说明」：回到全卡形态（ContentView 复位置顶状态）。
    var onShowFull: (() -> Void)? = nil
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
        if compact {
            // 小条（ZORDER-FIX）：用户已从全卡读过详情、正在浏览器里
            // 核对页面——条上只留标题与两个解决按钮（同一 submit 守卫）
            // 及回全卡的「说明」，不挡网页操作区。
            HStack(spacing: 10) {
                Text("等待确认").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let onShowFull { Button("说明") { onShowFull() } }
                Button("拒绝") { submit(false) }.disabled(locked)
                Button("确认执行", role: .destructive) { submit(true) }.disabled(locked)
            }
            .font(.callout).padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .interventionCardBackground()
        } else {
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
            .interventionCardBackground()
        }
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
/// 上传介入卡（F1）：PendingUpload 的两个阶段各一张——
/// - confirmUpload（SP-01 确认卡）：展示文件名与目标页面，用户确认才
///   消费一次性凭据并进入选文件阶段；取消即作废凭据、任务继续。
/// - pickFile（选文件等待卡）：引擎已尝试触发页面上的文件控件；系统
///   选择器若没弹出，用户照卡上指引在浏览器里点上传按钮选文件；选好
///   点「已选好，继续核验」由引擎回读页面持有状态，点「取消上传」按
///   取消口径继续任务。
/// 与 ConfirmCard 同口径：本地 locked 防重复点按，解决动作都走引擎的
/// 既有等待解决路径，不在此新造状态。
/// 浏览器置顶小条形态（ZORDER-FIX，2026-11-03）：用户在卡上点「打开
/// 浏览器*」后，根层级把坞升到遮罩之上、卡收成本层的 compact 小条
/// （层级表 InterventionZOrder 在 ContentView.swift）——网页不再被卡
/// 与遮罩挡住，用户亲手处理完点小条上的解决按钮（与全卡同一路径）
/// 即随介入解除恢复常态；小条上的「说明」可随时回全卡重读详情。
struct UploadCard: View {
    @ObservedObject var engine: AgentEngine
    let upload: AgentEngine.PendingUpload
    var onOpenBrowser: (() -> Void)? = nil
    /// 小条形态（ZORDER-FIX）：同 ConfirmCard 口径——body 内分支渲染
    /// 单行条（短标题＋本阶段解决按钮＋「说明」），解决按钮仍走本卡
    /// lock 守卫与引擎既有路径，@State 锁不因形态切换丢失。
    var compact: Bool = false
    /// 小条上的「说明」：回到全卡形态（ContentView 复位置顶状态）。
    var onShowFull: (() -> Void)? = nil
    @State private var locked = false
    var body: some View {
        if compact {
            HStack(spacing: 10) {
                if upload.stage == .confirmUpload {
                    Text("上传确认").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let onShowFull { Button("说明") { onShowFull() } }
                    Button("取消") { lock { engine.cancelPendingUpload() } }.disabled(locked)
                    Button("确认上传") { lock { engine.confirmPendingUpload() } }.disabled(locked)
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("选择文件").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let onShowFull { Button("说明") { onShowFull() } }
                    Button("取消上传") { lock { engine.finishUploadPick(completed: false) } }.disabled(locked)
                    Button("已选好，继续核验") { lock { engine.finishUploadPick(completed: true) } }.disabled(locked)
                        .buttonStyle(.borderedProminent)
                }
            }
            .font(.callout).padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .interventionCardBackground()
        } else {
        VStack(alignment: .leading, spacing: 8) {
            if upload.stage == .confirmUpload {
                Text("上传前确认").font(.headline)
                Text("将把你的文件「\(upload.attachmentName)」上传到 \(upload.pageHost.isEmpty ? "当前页面" : upload.pageHost)（页面上的「\(upload.elementLabel)」）。确认后进入选文件一步：系统支持自动供文件时（iOS 18.4+）由 App 直接把这份文件交给页面，不用你再选；不支持或未触发时再由你在选择器里选定。这张确认只对这一个文件、这一个页面有效，取消或失败后不会被复用。")
                HStack {
                    Button("确认上传") { lock { engine.confirmPendingUpload() } }.disabled(locked)
                        .buttonStyle(.borderedProminent)
                    Button("取消") { lock { engine.cancelPendingUpload() } }.disabled(locked)
                    if let onOpenBrowser {
                        Spacer()
                        Button("打开浏览器查看") { onOpenBrowser() }
                    }
                }
            } else {
                Text("请选择要上传的文件").font(.headline)
                Text("已尝试打开页面上的文件控件（「\(upload.elementLabel)」）。\(AgentEngine.uploadPickGuidance(upload: upload, supplyArmed: engine.uploadSupplyArmed))如果系统选择器没有弹出，点「打开浏览器查看」，在页面上点该上传按钮/区域再选。选好后回到这里点「已选好，继续核验」，我会回读页面确认它已持有该文件；不想传了点「取消上传」，任务会继续做其他部分。")
                HStack {
                    Button("已选好，继续核验") { lock { engine.finishUploadPick(completed: true) } }.disabled(locked)
                        .buttonStyle(.borderedProminent)
                    Button("取消上传") { lock { engine.finishUploadPick(completed: false) } }.disabled(locked)
                }
                if let onOpenBrowser {
                    HStack { Button("打开浏览器查看") { onOpenBrowser() } }
                }
            }
        }
        .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .interventionCardBackground()
        }
    }
    private func lock(_ action: () -> Void) {
        guard !locked else { return }
        locked = true
        action()
    }
}

struct InterventionPrompt: View {
    @ObservedObject var engine: AgentEngine
    @ObservedObject var web: WebController
    var onOpenBrowser: () -> Void
    /// 小条形态（ZORDER-FIX）：浏览器置顶态下由 ContentView 下传 true，
    /// 三卡各收成单行小条浮在浏览器之上（短标题＋解决按钮＋「说明」），
    /// 说明文字不绘制、不挡网页操作区；解决按钮与全卡走同一引擎路径
    /// 与防重复守卫（紧凑渲染在各卡内部 body 分支，@State 锁不丢）。
    var compact: Bool = false
    /// 小条上的「说明」：回到全卡形态（ContentView 复位置顶状态）。
    var onShowFull: (() -> Void)? = nil
    /// 同一时刻只出一张卡的种类判定（纯函数，UI-LEGIBILITY 抽出供自检
    /// 十七断言真值表）：上传优先于确认、确认优先于手输，与 body 的
    /// 渲染优先级一致——保证介入文字只在一张卡里绘制一层，不叠印。
    enum CardKind { case upload, confirm, manual, none }
    static func cardKind(hasPendingUpload: Bool, isWaitingConfirm: Bool, isWaitingManualWithInput: Bool) -> CardKind {
        if hasPendingUpload { return .upload }
        if isWaitingConfirm { return .confirm }
        if isWaitingManualWithInput { return .manual }
        return .none
    }
    private var confirmAction: AgentAction? {
        if case .waitingConfirm(let action) = engine.status { return action }
        return nil
    }
    private var manualText: String? {
        if case .waitingManual = engine.status, case .some(.manual(_, let text)) = engine.waitingInput { return text }
        return nil
    }
    var body: some View {
        switch Self.cardKind(hasPendingUpload: engine.pendingUpload != nil,
                             isWaitingConfirm: confirmAction != nil,
                             isWaitingManualWithInput: manualText != nil) {
        case .upload:
            if let upload = engine.pendingUpload {
                UploadCard(engine: engine, upload: upload, onOpenBrowser: onOpenBrowser,
                           compact: compact, onShowFull: onShowFull)
            }
        case .confirm:
            if let action = confirmAction {
                ConfirmCard(engine: engine, action: action, taskID: engine.conversationTaskID,
                            pageTitle: pageTitle, pageHost: pageHost, onOpenBrowser: onOpenBrowser,
                            compact: compact, onShowFull: onShowFull)
            }
        case .manual:
            if let text = manualText {
                if compact {
                    // 小条（ZORDER-FIX）：用户正亲手在浏览器里处理，条上
                    // 只留标题、回全卡的「说明」与「已处理，继续」（走
                    // engine.resume() 既有路径，与全卡同一落点）。
                    HStack(spacing: 10) {
                        Text("需要你手动处理").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        if let onShowFull { Button("说明") { onShowFull() } }
                        Button("已处理，继续") { engine.resume() }
                            .buttonStyle(.borderedProminent)
                    }
                    .font(.callout).padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .interventionCardBackground()
                } else {
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
                    .interventionCardBackground()
                }
            }
        case .none:
            EmptyView()
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
